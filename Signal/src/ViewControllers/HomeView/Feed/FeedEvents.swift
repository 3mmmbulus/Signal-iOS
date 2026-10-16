//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 曝光判定（`docs/adr/0071/client-api-2026-10.md` 6.1）：卡片露出 ≥ 50% 且连续停留 ≥ 1 秒算一次，
/// 同一张卡片同一次会话只算一次。纯逻辑，界面每次滚动 / 布局变化时把「现在露出过半的卡片」交进来。
/// 和 Android `FeedImpressionTracker` 同一套判定。
struct FeedImpressionTracker {
    static let minVisibleSeconds: TimeInterval = 1
    static let minVisibleFraction: CGFloat = 0.5

    private let minVisibleSeconds: TimeInterval
    private var visibleSince = [String: Date]()
    private var counted = Set<String>()

    init(minVisibleSeconds: TimeInterval = FeedImpressionTracker.minVisibleSeconds) {
        self.minVisibleSeconds = minVisibleSeconds
    }

    /// `visibleIds` 是现在露出过半的卡片；返回这次刚满 1 秒、该记一次曝光的（按 id 排序，结果稳定）。
    mutating func update(visibleIds: Set<String>, now: Date) -> [String] {
        visibleSince = visibleSince.filter { visibleIds.contains($0.key) }
        var qualified = [String]()
        for id in visibleIds.sorted() where !counted.contains(id) {
            let since = visibleSince[id] ?? now
            visibleSince[id] = since
            if now.timeIntervalSince(since) >= minVisibleSeconds {
                counted.insert(id)
                visibleSince[id] = nil
                qualified.append(id)
            }
        }
        return qualified
    }

    /// 最早什么时候需要再看一次（有卡片在等满 1 秒）；没有就是 nil。
    var nextCheckAt: Date? {
        return visibleSince.values.min()?.addingTimeInterval(minVisibleSeconds)
    }

    /// 一个列表项在视口里露出的比例。
    static func visibleFraction(itemMinY: CGFloat, itemHeight: CGFloat, viewportMinY: CGFloat, viewportMaxY: CGFloat) -> CGFloat {
        guard itemHeight > 0 else { return 0 }
        let top = max(itemMinY, viewportMinY)
        let bottom = min(itemMinY + itemHeight, viewportMaxY)
        return max(bottom - top, 0) / itemHeight
    }
}

/// `POST /v1/feed/events` 的一条：只报日志类事件（曝光、打开、停留、快速退出、分享；契约 6.1）。
struct FeedEventPayload: Encodable, Equatable {
    var contentId: String
    var type: String
    var surface: String
    var value: Double?
    var occurredAt: String

    static let typeImpression = "impression"

    static func impression(contentId: String, tab: FeedTab, at date: Date) -> FeedEventPayload {
        return FeedEventPayload(contentId: contentId, type: typeImpression, surface: tab.apiName, value: nil, occurredAt: FeedDates.format(date))
    }

    private enum CodingKeys: String, CodingKey {
        case type, surface, value
        case contentId = "content_id"
        case occurredAt = "occurred_at"
    }
}

struct FeedEventsRequest: Encodable {
    var events: [FeedEventPayload]
}

/// 事件攒批（契约 6.1）：攒满 50 条立刻发，否则由调用方每 30 秒和退到后台时 `drain()`。
/// 一批最多 50 条（`FeedAPI.maxEvents`）；发失败的丢掉，不重试、不落盘。
struct FeedEventBuffer {
    static let batchSize = 50
    static let flushInterval: TimeInterval = 30

    private let batchSize: Int
    private(set) var pending = [FeedEventPayload]()

    init(batchSize: Int = FeedEventBuffer.batchSize) {
        self.batchSize = batchSize
    }

    /// 返回 true 表示攒满了，该发了。
    mutating func add(_ event: FeedEventPayload) -> Bool {
        pending.append(event)
        return pending.count >= batchSize
    }

    /// 取走全部待发的，按每批最多 50 条切好。
    mutating func drain() -> [[FeedEventPayload]] {
        guard !pending.isEmpty else { return [] }
        var batches = [[FeedEventPayload]]()
        var start = 0
        while start < pending.count {
            batches.append(Array(pending[start..<min(start + FeedAPI.maxEvents, pending.count)]))
            start += FeedAPI.maxEvents
        }
        pending.removeAll()
        return batches
    }
}
