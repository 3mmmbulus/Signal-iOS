//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// card-visual §3.5（2026-09-29，tellomi/tellomi#1423）：消息除了一条链接什么都没有时，只显示卡片、不显示链接文字，
/// 完整链接在长按菜单里能复制。没有预览（预览关了或没抓到），或者 rust/links 定成「纯链接」时，接收端只用这条 URL
/// 本地画一张无图卡：可注册域名 + 链接图标（§3.7 第一行）。消息里还有别的东西，照 Signal 原样。
/// 与 Android `TellomiLinkOnly.kt`、Desktop `linkOnlyMessage.std.ts` 同一套规则。
public enum TellomiLinkOnly {

    /// 正文去掉首尾空白后就是一条完整写出的 http(s) 链接；先用一次前缀判断排除普通文字，不对每条消息解析 URL。
    /// `hasOtherContent`：让消息不止是纯文字的东西（格式、提及、附件、贴纸、联系人、支付、礼物、投票、阅后即焚、故事、已删除）。
    /// `linkRanges`：Signal 自己的链接识别在这段正文里认出的每一条链接的范围；要整段就是一条。
    ///
    /// `allowSchemeless`（产品经理 2026-10-19 卡片样式定稿）：没写协议的链接（`b23.tv/abc`、`www.jd.com`）也算，返回它的 https 写法
    /// （§5.6：发送端按 https 抓的就是这条）。只在这条消息**带着预览**时由调用方打开——没有预览时不把「readme.md」这类
    /// 碰巧像域名的文字画成卡片。
    public static func linkOnlyUrl(
        body: String?,
        hasOtherContent: Bool,
        allowSchemeless: Bool = false,
        linkRanges: (String) -> [Range<String.Index>],
    ) -> String? {
        guard !hasOtherContent, let body, !body.isEmpty else {
            return nil
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let hasScheme = lowercased.hasPrefix("https://") || lowercased.hasPrefix("http://")
        guard hasScheme || (allowSchemeless && !trimmed.isEmpty && !trimmed.contains(":")) else {
            return nil
        }
        // 不能带任何空白：空格后面还有字就不是「只有一条链接」。
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        let urlString = hasScheme ? trimmed : "https://" + trimmed
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty, host.contains(".") || hasScheme else {
            return nil
        }
        // 正文里得显示成一条链接、而且是整段（Signal 的识别把结尾标点之类留在外面时，不算）。
        let ranges = linkRanges(trimmed)
        guard ranges.count == 1, ranges[0] == trimmed.startIndex..<trimmed.endIndex else {
            return nil
        }
        return urlString
    }

    /// 气泡只显示卡片：正文就是唯一那条预览的链接，并且 rust/links 给了定级（没有定级就照 Signal 原样）。
    public static func isLinkCardOnly(
        linkOnlyUrl: String?,
        previewUrls: [String],
        card: TellomiLinkCard?,
    ) -> Bool {
        guard let linkOnlyUrl, card != nil, previewUrls.count == 1 else {
            return false
        }
        return previewUrls[0] == linkOnlyUrl
    }

    /// 只用 URL 画的无图卡：rust/links 算的可注册域名，以及它是否冒充知名域名（§6.1）；
    /// 发送端写的、第一方卡补的，一概不要。
    public static func toPlainLinkCard(_ card: TellomiLinkCard, lookalike: String?) -> TellomiLinkCard {
        return TellomiLinkCard(
            level: .plainLink,
            domain: card.domain,
            lookalike: card.lookalike ?? lookalike,
            showImage: false,
            tintable: false,
            payment: card.payment,
            reason: card.reason,
        )
    }
}
