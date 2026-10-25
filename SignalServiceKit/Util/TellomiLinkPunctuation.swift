//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（产品 2026-10-24 / 2026-10-25）：全角中文／日文标点、右括号／右引号，以及省略号、破折号、
/// 全角句点／连字符不算进链接，在链接末尾或中间都一样（「https://x.com/abc，后面」只认「https://x.com/abc」），
/// 聊天和动态点到的范围都不带它们。
/// 表和 Android `Linkifier.CJK_SENTENCE_PUNCTUATION`、`LinkUtil.CJK_URL_TERMINATORS` 相同。
/// 只改 NSDataDetector 认出来的范围：系统没把这些字算进链接时什么都不变；半角 ASCII 标点照旧交给系统。
public enum TellomiLinkPunctuation {

    /// ，。！？；：、  右括号／右引号 ）」』】》〉”’  以及 …—－．
    public static let terminators: Set<UInt16> = Set("，。！？；：、）」』】》〉”’…—－．".utf16)

    /// 链接文字里第一个全角标点前的长度（UTF-16）；没有这类标点时 nil。
    public static func cutLength(of linkText: NSString) -> Int? {
        for i in 0..<linkText.length where terminators.contains(linkText.character(at: i)) {
            return i
        }
        return nil
    }

    /// 把一条链接匹配截在第一个全角标点前，再用同一个识别器认一遍截下来的那段，拿到正确的 URL。
    /// 返回原文里的新范围和 URL；截完不剩链接时 nil（这一条丢掉）；不需要截时原样返回。
    public static func trimmedLink(
        range: NSRange,
        url: URL?,
        in text: String,
        detector: NSDataDetector,
    ) -> (range: NSRange, url: URL?)? {
        let nsText = text as NSString
        guard NSMaxRange(range) <= nsText.length else { return (range, url) }
        guard let cut = cutLength(of: nsText.substring(with: range) as NSString) else {
            return (range, url)
        }
        guard cut > 0 else { return nil }
        let head = nsText.substring(with: NSRange(location: range.location, length: cut))
        let headRange = NSRange(location: 0, length: (head as NSString).length)
        guard
            let match = detector.matches(in: head, options: [], range: headRange).first(where: {
                $0.resultType.contains(.link) && $0.range.location == 0 && $0.url != nil
            })
        else {
            return nil
        }
        return (NSRange(location: range.location, length: match.range.length), match.url)
    }
}

/// Tellomi（TF43 P1，产品 2026-10-25）：正文里没写协议的链接（`baidu.com`、`www.jd.com/a`）。
///
/// NSDataDetector 认得出这种写法，但给的是 `http://`；点开要默认走 https（同 Telegram）。
/// 另外排除一些长得像文件名的写法（`setup.py`、`README.md`、`a.zip`）：顶级域恰好也是常见扩展名，
/// 而且后面没有路径、前面没有 `www.` 时不算链接。版本号（`1.2.3`、`v2.0`）NSDataDetector 本来就不认，这里再兜一层：
/// 顶级域必须是字母。「CJK 标点不进链接」由 `TellomiLinkPunctuation` 先处理，这里不变。
public enum TellomiSchemelessLink {

    /// 同时是顶级域和常见文件扩展名的后缀（`.cc`、`.ai`、`.io` 是常用网址后缀，不在表里：`tell.cc` 要认）。
    public static let fileLikeTopLevelDomains: Set<String> = [
        "zip", "mov", "py", "md", "sh", "rs", "pl", "gz", "kt", "js", "ts", "swift",
        "txt", "pdf", "doc", "docx", "png", "jpg", "jpeg", "gif", "mp3", "mp4", "apk", "ipa", "exe", "dmg",
    ]

    /// 用户写的这段文字没有协议（不含 `://`，也不是 `mailto:` 之类）吗。
    public static func isSchemeless(_ snippet: String) -> Bool {
        let lower = snippet.lowercased()
        if lower.contains("://") { return false }
        for prefix in ["mailto:", "tel:", "sms:", "tellomi:", "sgnl:"] where lower.hasPrefix(prefix) {
            return false
        }
        return true
    }

    /// 处理一条没写协议的链接：返回要用的 URL（https），nil 表示这段不算链接。
    /// 有协议的原样返回 `url`。
    public static func resolve(snippet: String, url: URL?) -> URL?? {
        guard isSchemeless(snippet) else { return .some(url) }
        guard let url, let host = url.host?.lowercased(), !host.isEmpty else { return .some(url) }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last.map(String.init) else { return nil }
        // 顶级域必须是字母（排除版本号、IP）。
        guard tld.count >= 2, tld.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) || tld.hasPrefix("xn--") else {
            return nil
        }
        let hasPath = !(url.path.isEmpty || url.path == "/") || url.query != nil || url.fragment != nil
        if fileLikeTopLevelDomains.contains(tld), !host.hasPrefix("www."), !hasPath {
            return nil
        }
        guard url.scheme?.lowercased() == "http" else { return .some(url) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return .some(components?.url ?? url)
    }
}
