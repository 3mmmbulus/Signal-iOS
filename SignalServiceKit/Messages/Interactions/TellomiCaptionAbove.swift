//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（tellomi/tellomi#1263，ADR-0068 §4.7）：说明文字画在媒体上方。
///
/// 线上是 `DataMessage.tellomi.captionAboveMedia`（只在为真时写）。本机按消息的 `uniqueId` 记在一个
/// KeyValueStore 里（为真才有这一项），不给 `model_TSInteraction` 加列、不加迁移；编辑消息在原来那一行上改，`uniqueId` 不变，
/// 位置跟着走。收什么记什么，画的时候再看条件：有正文、至少一个按媒体显示的图片 / 视频。
///
/// ADR-0075：整条消息的说明（输入框那一条，`DataMessage.tellomi.messageCaption`）同样按 `uniqueId` 记在另一个 KeyValueStore；
/// 逐张说明记在各附件引用上游已有的 caption 上（`legacyMessageCaption`），查看器本来就显示。`body` 是兼容文本。
public enum TellomiCaptionAbove {

    private static let store = KeyValueStore(collection: "TellomiCaptionAboveMedia")
    private static let messageCaptionStore = KeyValueStore(collection: "TellomiMessageCaption")

    public static func isCaptionAboveMedia(messageUniqueId: String, tx: DBReadTransaction) -> Bool {
        store.getBool(messageUniqueId, defaultValue: false, transaction: tx)
    }

    public static func setCaptionAboveMedia(_ value: Bool, messageUniqueId: String, tx: DBWriteTransaction) {
        if value {
            store.setBool(true, key: messageUniqueId, transaction: tx)
        } else {
            store.removeValue(forKey: messageUniqueId, transaction: tx)
        }
    }

    /// ADR-0075：整条消息的说明；没有就是 nil。
    public static func messageCaption(messageUniqueId: String, tx: DBReadTransaction) -> String? {
        messageCaptionStore.getString(messageUniqueId, transaction: tx)
    }

    public static func setMessageCaption(_ caption: String?, messageUniqueId: String, tx: DBWriteTransaction) {
        if let caption = caption?.nilIfEmpty {
            messageCaptionStore.setString(caption, key: messageUniqueId, transaction: tx)
        } else {
            messageCaptionStore.removeValue(forKey: messageUniqueId, transaction: tx)
        }
    }

    /// 收到 / 同步来的 DataMessage 上的标记和整条消息的说明，记到这条消息上（没有就清掉：编辑带的是整条新内容）。
    public static func apply(from dataMessage: SSKProtoDataMessage, messageUniqueId: String, tx: DBWriteTransaction) {
        setCaptionAboveMedia(dataMessage.tellomi?.captionAboveMedia == true, messageUniqueId: messageUniqueId, tx: tx)
        setMessageCaption(dataMessage.tellomi?.messageCaption, messageUniqueId: messageUniqueId, tx: tx)
    }

    /// ADR-0075 §4.4（owner 2026-10-14 照 Telegram）：气泡里画哪段说明。一条消息里只有一个说明（整条的，或某一张的）就画它；
    /// 两个及以上只画整条消息的说明，没有就不画（返回 ""）；逐张的在查看器里看（Telegram `GroupedMessages.calculate()`
    /// 遇到第二个说明就把相册的说明清掉）。没有逐张说明、也没有整条说明的消息返回 nil：照旧画 body（兼容文本）。
    public static func bubbleCaption(message: TSMessage, tx: DBReadTransaction) -> String? {
        return bubbleCaption(
            messageUniqueId: message.uniqueId,
            messageRowId: message.sqliteRowId,
            attachmentStore: DependenciesBridge.shared.attachmentStore,
            tx: tx,
        )
    }

    static func bubbleCaption(
        messageUniqueId: String,
        messageRowId: Int64?,
        attachmentStore: AttachmentStore,
        tx: DBReadTransaction,
    ) -> String? {
        var mediaCaptions = [String?]()
        if let messageRowId {
            mediaCaptions = attachmentStore
                .fetchReferences(owner: .messageBodyAttachment(messageRowId: messageRowId), tx: tx)
                .map(\.legacyMessageCaption)
        }
        return bubbleCaption(messageCaption: messageCaption(messageUniqueId: messageUniqueId, tx: tx), mediaCaptions: mediaCaptions)
    }

    public static func bubbleCaption(messageCaption: String?, mediaCaptions: [String?]) -> String? {
        let messageCaption = messageCaption?.nilIfEmpty
        let captions = [messageCaption].compacted() + mediaCaptions.compactMap { $0?.nilIfEmpty }
        switch captions.count {
        case 0:
            return nil
        case 1:
            return captions[0]
        default:
            return messageCaption ?? ""
        }
    }

    /// 查看器里没有自己说明的那一张显示什么：有逐张说明的消息只给整条消息的说明（没有就是 ""）；别的消息返回 nil，照旧用正文。
    public static func viewerFallback(message: TSMessage, tx: DBReadTransaction) -> String? {
        guard bubbleCaption(message: message, tx: tx) != nil else {
            return nil
        }
        return messageCaption(messageUniqueId: message.uniqueId, tx: tx) ?? ""
    }

    /// ADR-0075：附件自己的说明——Tellomi 的逐张说明优先，其次上游旧的 `caption`；空的不算。
    static func attachmentCaption(_ proto: SSKProtoAttachmentPointer) -> String? {
        if let caption = proto.tellomi?.caption?.nilIfEmpty {
            return caption
        }
        return proto.hasCaption ? proto.caption : nil
    }

    /// 要发的这条（刚准备好、还没进发送队列）记成「说明在上方」。编辑的那条在原消息上改。
    public static func mark(_ preparedMessage: PreparedOutgoingMessage, tx: DBWriteTransaction) {
        guard let uniqueId = preparedMessage.tellomiPersistedMessageUniqueId else { return }
        setCaptionAboveMedia(true, messageUniqueId: uniqueId, tx: tx)
    }

    /// 发出去的 DataMessage 里的 `tellomi = 1000`：说明在上方、计时一次性查看的秒数（ADR-0079，只在有时写）。
    /// 都没有就是 nil（字节和上游一样）。
    static func proto(messageUniqueId: String, viewOnceSeconds: UInt32? = nil, tx: DBReadTransaction) -> SSKProtoTellomiDataMessage? {
        let captionAboveMedia = isCaptionAboveMedia(messageUniqueId: messageUniqueId, tx: tx)
        let seconds = viewOnceSeconds.flatMap { TellomiViewOnceTimer.isAllowed($0) ? $0 : nil }
        guard captionAboveMedia || seconds != nil else { return nil }
        let builder = SSKProtoTellomiDataMessage.builder()
        if captionAboveMedia {
            builder.setCaptionAboveMedia(true)
        }
        if let seconds {
            builder.setViewOnceSeconds(seconds)
        }
        return builder.buildInfallibly()
    }
}
