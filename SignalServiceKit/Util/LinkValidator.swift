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
}
