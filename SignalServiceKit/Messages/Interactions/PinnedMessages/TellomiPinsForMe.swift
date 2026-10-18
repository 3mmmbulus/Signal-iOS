//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Tellomi（ADR-0081 §4.3）：「仅为我置顶」。与安卓 `MessageTable.TELLOMI_PIN_FOR_ME` 同一套语义。
///
/// - 存：和别的置顶一样是 `PinnedMessage` 一行，另在 KeyValueStore 里按消息的行号记一笔「仅为我」。每插一行置顶
///   （`PinnedMessageRecord.insertRecord`：别人的、我的、同步来的、备份恢复的）都先抹掉这一笔，「仅为我」那条路插完再记上，
///   所以「为双方」的置顶盖过来就不再是「仅为我」；读的时候那一行还在才算。不改表、不加迁移。
/// - 发：只发「已发送」同步给自己的其它设备（`TellomiPinForMeTranscript`），没有已链接设备就不发；发出去了（或不用发）才在这台生效，
///   和普通置顶「发成功才生效」一样。从不发给对方或群成员，所以也不需要置顶权限。
/// - 收：别人发来带 `pinForSelfOnly` 的置顶 / 取消置顶整条丢弃；别人的取消置顶不动我「仅为我」的置顶；
///   我另一台设备同步来的照样置顶，不插「置顶了一条消息」。
public enum TellomiPinsForMe {

    private static let store = NewKeyValueStore(collection: "TellomiPinsForMe")

    /// 收到取消置顶时，「仅为我」的置顶怎么算。
    public enum UnpinRule {
        /// 照上游：置顶了就取消。
        case any
        /// 别人发来的取消：不动我「仅为我」的置顶。
        case keepPinForMe
        /// 我另一台设备「仅为我」的取消：只取消「仅为我」的置顶。
        case onlyPinForMe
    }

    /// 置顶 / 取消置顶上带着 `pinForSelfOnly`（别的消息上的不算）。
    public static func isSelfOnly(_ dataMessage: SSKProtoDataMessage) -> Bool {
        guard dataMessage.pinMessage != nil || dataMessage.unpinMessage != nil else {
            return false
        }
        return dataMessage.tellomi?.pinForSelfOnly == true
    }

    /// 这是一条「仅为我」的置顶 / 取消置顶（`tellomiPinForSelfOnly`），要走 `send`。
    public static func isForMe(_ change: TSOutgoingMessage) -> Bool {
        return (change as? OutgoingPinMessage)?.tellomiPinForSelfOnly == true
            || (change as? OutgoingUnpinMessage)?.tellomiPinForSelfOnly == true
    }

    /// 发出去的置顶 / 取消置顶要带的 Tellomi 字段；都不带时为 nil，字节与上游一样。`pinSilent` 只跟群里的置顶走。
    static func tellomiProto(isPin: Bool, forSelfOnly: Bool, silent: Bool, isGroup: Bool) -> SSKProtoTellomiDataMessage? {
        let silent = silent && isPin && isGroup
        guard forSelfOnly || silent else {
            return nil
        }
        let builder = SSKProtoTellomiDataMessage.builder()
        if forSelfOnly {
            builder.setPinForSelfOnly(true)
        }
        if silent {
            builder.setPinSilent(true)
        }
        return builder.buildInfallibly()
    }

    /// 每插一行置顶都先调：新插的置顶默认是「为双方」的。
    static func forget(interactionId: Int64, tx: DBWriteTransaction) {
        store.removeValue(forKey: key(interactionId), tx: tx)
    }

    /// 「仅为我」那条路插完置顶后调。
    static func remember(interactionId: Int64, tx: DBWriteTransaction) {
        store.writeValue(true, forKey: key(interactionId), tx: tx)
    }

    /// 这条消息现在是「仅为我」置顶的。
    public static func isPinnedForMe(interactionId: Int64, tx: DBReadTransaction) -> Bool {
        guard store.fetchValue(Bool.self, forKey: key(interactionId), tx: tx) == true else {
            return false
        }
        return failIfThrows {
            try PinnedMessageRecord
                .filter(PinnedMessageRecord.Columns.interactionId == interactionId)
                .fetchCount(tx.database) > 0
        }
    }

    /// 这个会话里「仅为我」置顶的消息（行号）。
    public static func pinnedForMeInteractionIds(threadId: Int64, tx: DBReadTransaction) -> Set<Int64> {
        let interactionIds: [Int64] = failIfThrows {
            try PinnedMessageRecord
                .filter(PinnedMessageRecord.Columns.threadId == threadId)
                .select(PinnedMessageRecord.Columns.interactionId)
                .fetchAll(tx.database)
        }
        return Set(interactionIds.filter { store.fetchValue(Bool.self, forKey: key($0), tx: tx) == true })
    }

    /// 把带了 `tellomiPinForSelfOnly` 的置顶 / 取消置顶发给自己的其它设备；发出去后在这台生效。没有已链接设备就不发，直接生效。
    public static func send(_ change: TSOutgoingMessage, thread: TSThread, tx: DBWriteTransaction) -> Promise<Void> {
        guard DependenciesBridge.shared.deviceStore.hasLinkedDevices(tx: tx) else {
            change.updateWithSendSuccess(tx: tx)
            return .value(())
        }
        guard let localThread = TSContactThread.getOrCreateLocalThread(transaction: tx) else {
            return Promise(error: OWSAssertionError("Missing local thread"))
        }
        let transcript = TellomiPinForMeTranscript(
            localThread: localThread,
            messageThread: thread,
            message: change,
            isRecipientUpdate: false,
            tx: tx,
        )
        // In memory only: a transcript can't be archived into a job record (and a pin change is moot after a restart anyway).
        return SSKEnvironment.shared.messageSenderJobQueueRef.add(
            .promise,
            message: .preprepared(transientMessageWithoutAttachments: transcript),
            limitToCurrentProcessLifetime: true,
            transaction: tx,
        )
    }

    private static func key(_ interactionId: Int64) -> String {
        return String(interactionId)
    }
}

/// Tellomi (ADR-0081 §4.3): the "sent" transcript of a pin / unpin for me only. As an `OutgoingSyncMessage` it only ever goes to my
/// own devices; once it is out, the change applies here too — the same moment an ordinary pin applies (`OutgoingPinMessage`).
final class TellomiPinForMeTranscript: OutgoingSentMessageTranscript {
    override func updateWithSendSuccess(tx: DBWriteTransaction) {
        message.updateWithSendSuccess(tx: tx)
    }
}
