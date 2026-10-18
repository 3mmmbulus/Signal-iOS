//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

/// Tellomi（chat-telegram-parity F01）：别人回应了我的消息、我还没在聊天里看到——聊天页右下角回应按钮上的数，数的就是这些消息。
///
/// Telegram 两端是「看到才算读」：
/// - iOS `ChatHistoryListNode` 把可视范围里有未读回应的消息交给 `unseenReactionsProcessingManager`（0.2 s 后标看到），
///   安卓滚动时对露出来的 `ChatMessageCell` 调 `checkUnreadReactions`；
/// - 点按钮跳过去（iOS `earliestUnseenPersonalReactionMessage`、安卓 `getNextReactionMention`）、长按「Read All Reactions」也算；
/// - 从对话列表「标为已读」不清回应（安卓 `DialogsActivity.markAsRead` 只清提及）。
///
/// Signal 自己的 `OWSReaction.read` 是另一回事：会话标已读时整段一起标掉（给通知用，`OWSReceiptManager.markUnreadReactionsBatch`），
/// 聊天里的按钮用不了。所以这里另记一份：别人的回应写进库的那一刻记下（[didRecordReaction]），在聊天里看到 / 跳到 / 全部已读才划掉。
///
/// - 只在本机（键值库，不进备份），换设备、恢复备份后从空开始；别的设备上看过不会同步过来。
/// - 只记我发的消息，群里动态的回复不算；我自己的回应、我别的设备同步来的回应不记。
/// - 删了的、别人的回应撤光了的，读的时候跳过，下一次写的时候划掉。
/// - 每个会话最多记 [maxPerThread] 条，多了丢最早记下的。安卓同一套：`TellomiUnseenReactions.kt`（Signal-Android#383）。
public enum TellomiUnseenReactions {

    /// 每个会话最多记这么多条消息；按钮上的数过了 99 本来也只显示「99+」。
    static let maxPerThread = 200

    private static let store = KeyValueStore(collection: "TellomiUnseenReactions")

    /// 有人回应了 [message]（`TSMessage.recordReaction` 写完库以后调）。
    static func didRecordReaction(on message: TSMessage, reactor: Aci, tx: DBWriteTransaction) {
        guard message is TSOutgoingMessage, !message.isGroupStoryReply else {
            return
        }
        guard
            let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci,
            reactor != localAci
        else {
            return
        }

        let recorded = store.getStringArray(message.uniqueThreadId, transaction: tx) ?? []
        let updated = adding(message.uniqueId, to: recorded, max: maxPerThread)
        if updated != recorded {
            store.setStringArray(updated, key: message.uniqueThreadId, transaction: tx)
        }
    }

    /// [message] 上有回应撤了（`TSMessage.removeReaction` 之后调）：别人的回应一个不剩，就不算还没看到。
    static func didRemoveReaction(on message: TSMessage, tx: DBWriteTransaction) {
        guard
            let recorded = store.getStringArray(message.uniqueThreadId, transaction: tx),
            recorded.contains(message.uniqueId),
            !hasReactionFromOthers(messageUniqueId: message.uniqueId, tx: tx)
        else {
            return
        }
        save(recorded.filter { $0 != message.uniqueId }, threadUniqueId: message.uniqueThreadId, tx: tx)
    }

    /// 在聊天里看到了，或者点按钮跳过去了。顺手划掉已经不算的。
    public static func markSeen(messageUniqueIds: [String], threadUniqueId: String, tx: DBWriteTransaction) {
        guard let recorded = store.getStringArray(threadUniqueId, transaction: tx) else {
            return
        }
        let seen = Set(messageUniqueIds)
        let stillUnseen = Set(unseenMessageIds(threadUniqueId: threadUniqueId, tx: tx))
        save(recorded.filter { !seen.contains($0) && stillUnseen.contains($0) }, threadUniqueId: threadUniqueId, tx: tx)
    }

    /// 长按回应按钮「所有回应标为已读」。
    public static func markAllSeen(threadUniqueId: String, tx: DBWriteTransaction) {
        store.removeValue(forKey: threadUniqueId, transaction: tx)
    }

    /// [threadUniqueId] 里还没看到回应的消息，按在会话里的先后、最早的在前（按钮跳的就是第一条）。删了的、别人的回应撤光了的不算。
    public static func unseenMessageIds(threadUniqueId: String, tx: DBReadTransaction) -> [String] {
        guard let recorded = store.getStringArray(threadUniqueId, transaction: tx), !recorded.isEmpty else {
            return []
        }
        let messages: [TSOutgoingMessage] = recorded.compactMap { uniqueId in
            guard
                let message = TSInteraction.anyFetch(uniqueId: uniqueId, transaction: tx) as? TSOutgoingMessage,
                message.uniqueThreadId == threadUniqueId,
                !message.wasRemotelyDeleted,
                hasReactionFromOthers(messageUniqueId: uniqueId, tx: tx)
            else {
                return nil
            }
            return message
        }
        return messages.sorted { $0.sortId < $1.sortId }.map(\.uniqueId)
    }

    /// 别人回应 [messageUniqueId] 里最新的那个表情（看到时在它上面爆开）。
    public static func latestEmojiFromOthers(messageUniqueId: String, tx: DBReadTransaction) -> String? {
        let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
        return ReactionFinder(uniqueMessageId: messageUniqueId)
            .allReactions(transaction: tx)
            .filter { $0.reactorAci != localAci }
            .max { $0.sortOrder < $1.sortOrder }?
            .emoji
    }

    private static func hasReactionFromOthers(messageUniqueId: String, tx: DBReadTransaction) -> Bool {
        let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
        return ReactionFinder(uniqueMessageId: messageUniqueId)
            .allReactions(transaction: tx)
            .contains { $0.reactorAci != localAci }
    }

    private static func save(_ messageUniqueIds: [String], threadUniqueId: String, tx: DBWriteTransaction) {
        if messageUniqueIds.isEmpty {
            store.removeValue(forKey: threadUniqueId, transaction: tx)
        } else {
            store.setStringArray(messageUniqueIds, key: threadUniqueId, transaction: tx)
        }
    }

    /// 记下一条；已经记着就不动。超过 [max] 条丢最早记下的。
    static func adding(_ messageUniqueId: String, to recorded: [String], max: Int) -> [String] {
        guard !recorded.contains(messageUniqueId) else {
            return recorded
        }
        return Array((recorded + [messageUniqueId]).suffix(max))
    }
}
