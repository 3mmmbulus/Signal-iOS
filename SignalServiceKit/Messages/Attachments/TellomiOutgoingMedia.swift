//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（tellomi/tellomi#1263，ADR-0068 §4.4，spec P-5）：要发的这条消息上 Tellomi 自己的附件标记——
/// 选图「···」的「罩住图片」。按正文附件在消息里的位置（`orderInMessage`）给，消息落库后、进发送队列之前
/// 在同一个写事务里记上（`ThreadUtil.enqueueMessageSync`），发送时组 `AttachmentPointer` 读得到。
public struct TellomiOutgoingMedia: Equatable {

    /// 罩住的正文附件（位置）。只有图片 / 视频算（ADR-0068 §4.1），别的位置给了也不记。
    public var spoilerOrders: Set<UInt32>

    public init(spoilerOrders: Set<UInt32> = []) {
        self.spoilerOrders = spoilerOrders
    }

    public var isEmpty: Bool { spoilerOrders.isEmpty }

    /// 按附件的先后给的标记（`attachments[i]` 就是位置 i）。
    public init(spoilers: [Bool]) {
        self.init(spoilerOrders: Set(spoilers.enumerated().compactMap { $0.element ? UInt32($0.offset) : nil }))
    }

    /// 记上。每条要发的消息都过这里：没有标记时只看引用——回复一张被罩住的图，引用缩略图也罩着发（§4.4「引用回复」）。
    /// 一次性查看的消息不带遮罩（§4.4：与 `isViewOnce` 互斥），编辑消息不改附件（§4.4「编辑消息」）。
    public static func mark(_ preparedMessage: PreparedOutgoingMessage, media: TellomiOutgoingMedia, tx: DBWriteTransaction) {
        guard let (message, rowId) = preparedMessage.tellomiPersistedMessage else { return }
        if !media.spoilerOrders.isEmpty, !message.isViewOnceMessage {
            TellomiMediaSpoiler.markOutgoing(messageRowId: rowId, orders: media.spoilerOrders, tx: tx)
        }
        if let quotedMessage = message.quotedMessage {
            TellomiMediaSpoiler.markOutgoingQuote(
                messageRowId: rowId,
                quotedMessage: quotedMessage,
                threadUniqueId: message.uniqueThreadId,
                tx: tx,
            )
        }
    }
}
