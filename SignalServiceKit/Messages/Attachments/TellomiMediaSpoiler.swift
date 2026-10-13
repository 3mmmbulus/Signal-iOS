//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（tellomi/tellomi#1263，ADR-0068 §4.1 / §4.3，spec R-1）：收到的被罩住（spoiler）的图片 / 视频。
///
/// 线上是 `AttachmentPointer.tellomi.spoiler`。本机按附件在消息里的位置（消息行号 + `orderInMessage`；引用缩略图按回复那条的行号）
/// 记在一个 KeyValueStore 里：有这一项 = 发送方罩上了，值是「这台设备揭示过没有」。不给附件表加列、不加迁移；
/// `model_TSInteraction` 的行号是 AUTOINCREMENT，删掉的消息不会把行号让给新消息。
/// 揭示状态只记在这台设备上（D10，旧 ADR-0050 owner 定过），不上线路、不进备份；引用缩略图永远罩着（spec R-1）。
public enum TellomiMediaSpoiler {

    private static let store = KeyValueStore(collection: "TellomiMediaSpoiler")

    /// 这次运行里刚揭示的：写库、会话页重画之前就不再罩（同 Android `TellomiSpoiler.revealedThisSession`）。
    private static let revealedInMemory = AtomicSet<String>(lock: .init())

    // MARK: - Wire

    /// 收到的指针算不算罩着（ADR-0068 §4.1）：只有图片 / 视频算；同时标了 asFile 的按文件，不罩；别的组合忽略，消息照收。
    public static func isSpoiler(_ proto: SSKProtoAttachmentPointer, mimeType: String) -> Bool {
        guard let tellomi = proto.tellomi, tellomi.spoiler, !tellomi.asFile else {
            return false
        }
        return mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/")
    }

    /// 收到 / 同步来的指针落库时调：罩着的记下来（没揭示过）。
    static func markReceived(
        _ proto: SSKProtoAttachmentPointer,
        mimeType: String,
        owner: AttachmentReference.OwnerBuilder,
        tx: DBWriteTransaction,
    ) {
        guard isSpoiler(proto, mimeType: mimeType), let key = key(for: owner) else {
            return
        }
        store.setBool(false, key: key, transaction: tx)
    }

    // MARK: - Local state

    /// 发送方罩上了（不管这台设备揭示过没有）。
    public static func isSpoiler(_ reference: AttachmentReference, tx: DBReadTransaction) -> Bool {
        guard let key = key(for: reference.owner) else { return false }
        return store.getBool(key, transaction: tx) != nil
    }

    /// 现在还罩着：发送方罩上了，这台设备还没揭示。引用缩略图永远罩着。
    public static func isCovered(_ reference: AttachmentReference, tx: DBReadTransaction) -> Bool {
        guard let key = key(for: reference.owner), store.getBool(key, transaction: tx) == false else {
            return false
        }
        return !revealedInMemory.contains(key)
    }

    /// 建界面时读的状态（[isCovered]）之后又在这台设备上揭示了：用来让还没重画的地方马上不罩。
    public static func isRevealedSinceLoad(_ reference: AttachmentReference) -> Bool {
        guard let key = key(for: reference.owner) else { return false }
        return revealedInMemory.contains(key)
    }

    /// 揭示：马上生效（内存），再写库，并碰一下那条消息让会话页重画。引用缩略图不揭示。
    public static func reveal(_ reference: AttachmentReference) {
        guard case .message(.bodyAttachment(let metadata)) = reference.owner, let key = key(for: reference.owner) else {
            return
        }
        revealedInMemory.insert(key)
        SSKEnvironment.shared.databaseStorageRef.asyncWrite { tx in
            guard
                markRevealed(reference, tx: tx),
                let message = InteractionFinder.fetch(rowId: metadata.messageRowId, transaction: tx)
            else {
                return
            }
            SSKEnvironment.shared.databaseStorageRef.touch(interaction: message, shouldReindex: false, tx: tx)
        }
    }

    /// 写库那一半：还罩着的正文附件记成揭示过；改了返回 true。
    @discardableResult
    static func markRevealed(_ reference: AttachmentReference, tx: DBWriteTransaction) -> Bool {
        guard
            case .message(.bodyAttachment) = reference.owner,
            let key = key(for: reference.owner),
            store.getBool(key, transaction: tx) == false
        else {
            return false
        }
        store.setBool(true, key: key, transaction: tx)
        return true
    }

#if TESTABLE_BUILD
    /// 每个测试换一个新库，行号从头来：上一个测试在内存里揭示过的别带过去。
    public static func resetRevealedInMemoryForTesting() {
        revealedInMemory.removeAllValues()
    }
#endif

    /// 编辑消息时旧版本另起一行、附件复制过去（`EditManagerAttachmentsImpl`）：罩着的状态跟过去。
    static func copyForPastRevision(
        latestRevisionRowId: Int64,
        priorRevisionRowId: Int64,
        orderInMessage: UInt32,
        tx: DBWriteTransaction,
    ) {
        let from = bodyKey(messageRowId: latestRevisionRowId, orderInMessage: orderInMessage)
        guard let value = store.getBool(from, transaction: tx) else { return }
        store.setBool(value, key: bodyKey(messageRowId: priorRevisionRowId, orderInMessage: orderInMessage), transaction: tx)
    }

    // MARK: - Keys

    private static func bodyKey(messageRowId: Int64, orderInMessage: UInt32) -> String {
        "b\(messageRowId).\(orderInMessage)"
    }

    private static func quoteKey(messageRowId: Int64) -> String {
        "q\(messageRowId)"
    }

    private static func key(for owner: AttachmentReference.Owner) -> String? {
        switch owner {
        case .message(.bodyAttachment(let metadata)):
            return bodyKey(messageRowId: metadata.messageRowId, orderInMessage: metadata.orderInMessage)
        case .message(.quotedReply(let metadata)):
            return quoteKey(messageRowId: metadata.messageRowId)
        case .message, .storyMessage, .thread:
            return nil
        }
    }

    private static func key(for owner: AttachmentReference.OwnerBuilder) -> String? {
        switch owner {
        case .messageBodyAttachment(let builder):
            return bodyKey(messageRowId: builder.messageRowId, orderInMessage: builder.orderInMessage)
        case .quotedReplyAttachment(let builder):
            return quoteKey(messageRowId: builder.messageRowId)
        default:
            return nil
        }
    }
}
