//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB

/// Tellomi（chat-telegram-parity F03）：按日期跳转要的两样——会话里哪些天有消息（日历上只有这些天能选），某天开头的第一条。
///
/// 和会话页显示的是同一批：不算群里动态的回复、编辑过的旧版本、解密占位（`InteractionFinder` 的 `filterForConversationView`）。
/// 「哪天」按 `timestamp`（发出时间）在本地时区算，和会话页的日期头（`CVComponentDateHeader.buildState`）一样。
public enum TellomiConversationDays {

    /// 有消息的那些天，每天取本地时区的 0 点。
    public static func daysWithMessages(threadUniqueId: String, calendar: Calendar = .current, tx: DBReadTransaction) -> Set<Date> {
        let sql = """
            SELECT \(interactionColumn: .timestamp)
            FROM \(InteractionRecord.databaseTableName)
            WHERE \(interactionColumn: .threadUniqueId) = ?
            \(conversationViewFilter)
            """
        do {
            let timestamps = try UInt64.fetchAll(tx.database, sql: sql, arguments: [threadUniqueId])
            return Set(timestamps.map { calendar.startOfDay(for: Date(millisecondsSince1970: $0)) })
        } catch {
            owsFailDebug("Failed to fetch message days: \(error)")
            return []
        }
    }

    /// [day] 0 点起（含）的第一条，按会话里的先后；那天之后没有消息时为 nil。
    public static func firstMessageUniqueId(onOrAfter day: Date, threadUniqueId: String, tx: DBReadTransaction) -> String? {
        let sql = """
            SELECT \(interactionColumn: .uniqueId)
            FROM \(InteractionRecord.databaseTableName)
            WHERE \(interactionColumn: .threadUniqueId) = ?
            AND \(interactionColumn: .timestamp) >= ?
            \(conversationViewFilter)
            ORDER BY \(interactionColumn: .id) ASC
            LIMIT 1
            """
        do {
            return try String.fetchOne(tx.database, sql: sql, arguments: [threadUniqueId, day.ows_millisecondsSince1970])
        } catch {
            owsFailDebug("Failed to fetch the first message of a day: \(error)")
            return nil
        }
    }

    private static var conversationViewFilter: String {
        """
        \(InteractionFinder.filterGroupStoryRepliesClause())
        \(InteractionFinder.filterEditHistoryClause())
        \(InteractionFinder.filterPlaceholdersClause)
        """
    }
}
