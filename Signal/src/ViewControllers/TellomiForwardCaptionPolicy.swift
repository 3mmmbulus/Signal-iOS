//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

/// Tellomi（iOS 对照 Telegram 清单 5.4，第一步只有逻辑）：转发时「隐藏发送人 / 隐藏说明文字」。
///
/// - 发送人：Signal 协议转发出去的是一条新消息，本来就不带原发送人，所以「隐藏发送人」恒成立，
///   不需要开关，也不改协议。
/// - 说明文字：只对带附件的消息生效（图片、视频、文件下面的文字）。纯文字消息的文字就是内容本身，不能隐藏。
///   只有空白的说明文字当作没有说明文字。
/// - 转发时用户另外写的附言不受影响，照常单独发出。
///
/// 还没有接到转发界面上；开关和界面在下一轮做。
enum TellomiForwardCaptionPolicy {

    /// 原发送人永远不会随转发发出。
    static let senderAlwaysHidden = true

    /// 这条消息有没有可以隐藏的说明文字（决定界面上要不要给「隐藏说明文字」开关）。
    static func canHideCaption(body: MessageBody?, hasAttachments: Bool) -> Bool {
        guard hasAttachments, let body else { return false }
        return !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 实际随转发发出的正文。
    static func outgoingBody(_ body: MessageBody?, hasAttachments: Bool, hideCaption: Bool) -> MessageBody? {
        guard hideCaption, canHideCaption(body: body, hasAttachments: hasAttachments) else { return body }
        return nil
    }

    /// 选了多条消息时，只要有一条能隐藏说明文字就显示开关。
    static func showsHideCaptionToggle(_ items: [(body: MessageBody?, hasAttachments: Bool)]) -> Bool {
        items.contains { canHideCaption(body: $0.body, hasAttachments: $0.hasAttachments) }
    }
}
