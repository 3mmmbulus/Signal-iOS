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
