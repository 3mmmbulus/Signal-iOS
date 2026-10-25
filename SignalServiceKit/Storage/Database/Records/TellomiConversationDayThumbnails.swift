//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（清单 7.2 / chat-telegram-parity F03b）：跳日期的月历上每天显示一张缩略图——那天的第一张图片或视频。
///
/// 跟会话里「所有媒体」用同一个查询（`MediaGalleryAttachmentFinder`，照片和视频分类），所以阅后即焚、编辑前的旧版本不会出现。
/// 媒体按收到时间（`receivedAtTimestamp`）分天，日历上能不能选按发出时间分天（`TellomiConversationDays`），
/// 两者跨午夜时可能差一天，只影响缩略图落在哪一格，不影响跳转。
public enum TellomiConversationDayThumbnails {

    /// [days] 里每一天（本地 0 点）的第一张图片或视频；那天没有就不在结果里。
    public static func firstVisualMedia(
        threadRowId: Int64,
        days: [Date],
        calendar: Calendar = .current,
        tx: DBReadTransaction,
    ) -> [Date: ReferencedAttachment] {
        let finder = MediaGalleryAttachmentFinder(threadId: threadRowId, filter: .allPhotoVideoCategory)
        var result = [Date: ReferencedAttachment]()
        for day in Set(days.map { calendar.startOfDay(for: $0) }) {
            guard let interval = dayInterval(day, calendar: calendar) else {
                continue
            }
            finder.enumerateMediaAttachments(
                in: interval,
                excluding: [],
                range: NSRange(location: 0, length: 1),
                tx: tx,
            ) { _, attachment in
                if result[day] == nil {
                    result[day] = attachment
                }
            }
        }
        return result
    }

    /// [day] 0 点到第二天 0 点（夏令时那天也对）。
    public static func dayInterval(_ day: Date, calendar: Calendar = .current) -> DateInterval? {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }
}
