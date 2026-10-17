//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public enum LinkValidator {
    public static func canParseURLs(in entireMessage: String) -> Bool {
        if entireMessage.unicodeScalars.contains(where: isProblematicCodepointAnywhereInString(_:)) {
            return false
        }
        return true
    }

    public static func isValidLink(linkText: String) -> Bool {
        if linkText.unicodeScalars.contains(where: isProblematicCodepointInLink(_:)) {
            return false
        }
        return true
    }

    private static func isProblematicCodepointAnywhereInString(_ scalar: UnicodeScalar) -> Bool {
        switch scalar {
        case "\u{202C}", // POP DIRECTIONAL FORMATTING
             "\u{202D}", // LEFT-TO-RIGHT OVERRIDE
             "\u{202E}": // RIGHT-TO-LEFT OVERRIDE
            return true
        default:
            return false
        }
    }

    private static func isProblematicCodepointInLink(_ scalar: UnicodeScalar) -> Bool {
        if isProblematicCodepointAnywhereInString(scalar) {
            return true
        }
        switch scalar {
        case "\u{2500}"..."\u{25FF}": // Box Drawing, Block Elements, Geometric Shapes
            return true
        default:
            return false
        }
    }

    public static func firstLinkPreviewURL(in entireMessage: MessageBody) -> URL? {
        // Don't include link previews for oversize text messages.
        guard entireMessage.text.utf8.dropFirst(OWSMediaUtils.kOversizeTextMessageSizeThresholdBytes).isEmpty else {
            return nil
        }

        guard canParseURLs(in: entireMessage.text) else {
            return nil
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            owsFailDebug("Could not create NSDataDetector")
            return nil
        }

        var result: URL?
        detector.enumerateMatches(
            in: entireMessage.text,
            range: entireMessage.text.entireRange,
        ) { match, _, stop in
            guard let match else { return }
            guard let parsedUrl = match.url else { return }
            guard let matchedRange = Range(match.range, in: entireMessage.text) else { return }
            for style in entireMessage.ranges.collapsedStyles {
                if
                    style.value.style.contains(style: .spoiler),
                    style.range.intersection(match.range)?.location ?? NSNotFound != NSNotFound
                {
                    return
                }
                // Styles are ordered; no need to search past the matched range.
                if style.range.lowerBound >= match.range.upperBound {
                    break
                }
            }
            guard !parsedUrl.absoluteString.isEmpty else { return }
            let matchedText = String(entireMessage.text[matchedRange])
            if LinkPreviewHelper.isPermittedLinkPreviewUrl(parsedUrl, parsedFrom: matchedText) {
                result = parsedUrl
            } else if let trimmedUrl = tellomiUrlTrimmedBeforeGluedText(matchedText) {
                result = trimmedUrl
            } else if let upgradedUrl = tellomiHttpsUpgrade(parsedUrl, matchedText: matchedText) {
                result = upgradedUrl
            } else {
                return
            }
            stop.pointee = true
        }
        return result
    }

    /// Tellomi（2026-10-17，TestFlight 0.1.0 (16) 反馈「很多链接没有出信息卡片」）：中文（或别的非 ASCII 文字）紧贴在链接后面，
    /// 比如「看这个https://b23.tv/abc很好」，NSDataDetector 会把「很好」也算进链接，整条因为路径里有非 RFC 3986 字符被拒，一张卡片都没有。
    /// 这里在第一个非 ASCII 字符处截断再验一次：只在截断处前一个字符是 ASCII 字母或数字时截（「abc很好」「.html网易新闻」），
    /// 截断处紧跟在 `/ ? = & #` 后面的不截——那是链接自己的一段（「/wiki/中国」「?q=你好」），截了就成了另一页，照上游不出卡片。
    /// 只在路径 / 查询 / 片段里截，**域名里一个字都不截**：「https://www.wikipediа.org」（а 是西里尔字母）截成「https://www.wikipedi」
    /// 就成了仿冒域名的入口（上游 `LinkValidatorTest` 的混写域名用例守着这一条）。
    /// 只用在整条不合规的时候，原来能出卡片的链接一条都不变；收方 libsignal `url_appears_in_body` 本来就把非 ASCII 当链接的结尾。
    static func tellomiUrlTrimmedBeforeGluedText(_ linkText: String) -> URL? {
        let scalars = linkText.unicodeScalars
        guard let cut = scalars.firstIndex(where: { !$0.isASCII }), cut > scalars.startIndex else {
            return nil
        }
        // 域名（authority）在「://」之后、第一个 / ? # 之前；截断处必须在它后面
        guard
            let schemeEnd = linkText.range(of: "://")?.upperBound.samePosition(in: scalars),
            let authorityEnd = scalars[schemeEnd...].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }),
            authorityEnd < cut
        else {
            return nil
        }
        let last = scalars[scalars.index(before: cut)]
        guard ("0"..."9").contains(last) || ("a"..."z").contains(last) || ("A"..."Z").contains(last) else {
            return nil
        }
        let prefix = String(scalars[..<cut])
        guard let url = URL(string: prefix), url.host?.isEmpty == false else {
            return nil
        }
        guard LinkPreviewHelper.isPermittedLinkPreviewUrl(url, parsedFrom: prefix) else {
            return nil
        }
        return url
    }

    /// Tellomi（owner 2026-10-17，ADR-0063 补充「http 与无协议链接」）：写成 `http://b23.tv/abc` 或 `b23.tv/abc` 的链接
    /// （NSDataDetector 把没写协议的也当 http），换成 https 写法再验一遍上游的规则（含上面「后面紧贴中文」的截断）；
    /// 只有注册表认领这条 https（品牌、短链；第一方除外，`TellomiLinkClassifier.claimsHttpsUpgrade`）才用它出卡片。
    /// 抓的永远是 https，不抓明文 http；不归注册表的 http 链接照上游没有卡片。
    static func tellomiHttpsUpgrade(
        _ parsedUrl: URL,
        matchedText: String,
        claims: (String) -> Bool = TellomiLinkRegistry.classifier.claimsHttpsUpgrade(of:),
    ) -> URL? {
        guard parsedUrl.scheme?.lowercased() == "http" else {
            return nil
        }
        let rest: Substring
        if let scheme = matchedText.range(of: "http://", options: [.anchored, .caseInsensitive]) {
            rest = matchedText[scheme.upperBound...]
        } else if !matchedText.contains("://") {
            rest = matchedText[...]
        } else {
            return nil
        }
        guard !rest.isEmpty else {
            return nil
        }
        let text = "https://" + rest
        let url: URL
        if let candidate = URL(string: text), candidate.host?.isEmpty == false, LinkPreviewHelper.isPermittedLinkPreviewUrl(candidate, parsedFrom: text) {
            url = candidate
        } else if let trimmed = tellomiUrlTrimmedBeforeGluedText(text) {
            url = trimmed
        } else {
            return nil
        }
        guard claims(url.absoluteString) else {
            return nil
        }
        return url
    }
}
