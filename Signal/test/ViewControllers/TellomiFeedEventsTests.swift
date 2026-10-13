//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// M11 动态第四刀：曝光上报（契约 `docs/adr/0071/client-api-2026-10.md` 6.1）。与 Android `FeedEventsTest` 同口径。
final class TellomiFeedEventsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_791_889_200)

    // MARK: - 判定

    /// 露出过半、连续停留满 1 秒算一次；同一张卡片同一次会话只算一次；中途离开重新计时。
    func testImpressionNeedsOneSecondAndCountsOnce() {
        var tracker = FeedImpressionTracker()
        XCTAssertEqual(tracker.update(visibleIds: ["a", "b"], now: t0), [])
        XCTAssertEqual(tracker.nextCheckAt, t0.addingTimeInterval(1))
        XCTAssertEqual(tracker.update(visibleIds: ["a", "b"], now: t0.addingTimeInterval(0.99)), [])

        // b 在满 1 秒前滑走了：重新计时
        XCTAssertEqual(tracker.update(visibleIds: ["a"], now: t0.addingTimeInterval(0.995)), [])
        XCTAssertEqual(tracker.update(visibleIds: ["a", "b"], now: t0.addingTimeInterval(1.0)), ["a"])
        XCTAssertEqual(tracker.update(visibleIds: ["a", "b"], now: t0.addingTimeInterval(1.5)), [])
        XCTAssertEqual(tracker.update(visibleIds: ["a", "b"], now: t0.addingTimeInterval(2.0)), ["b"])

        // 记过的不再记，离开再回来也不记
        XCTAssertNil(tracker.nextCheckAt)
        XCTAssertEqual(tracker.update(visibleIds: [], now: t0.addingTimeInterval(3)), [])
        XCTAssertEqual(tracker.update(visibleIds: ["a", "b"], now: t0.addingTimeInterval(4)), [])
        XCTAssertEqual(tracker.update(visibleIds: ["a", "b"], now: t0.addingTimeInterval(10)), [])
    }

    /// 露出比例：一半算过半（≥ 50%），不到一半不算。
    func testVisibleFraction() {
        XCTAssertEqual(FeedImpressionTracker.visibleFraction(itemMinY: 0, itemHeight: 100, viewportMinY: 0, viewportMaxY: 800), 1)
        XCTAssertEqual(FeedImpressionTracker.visibleFraction(itemMinY: 750, itemHeight: 100, viewportMinY: 0, viewportMaxY: 800), 0.5)
        XCTAssertEqual(FeedImpressionTracker.visibleFraction(itemMinY: -60, itemHeight: 100, viewportMinY: 0, viewportMaxY: 800), 0.4, accuracy: 0.0001)
        XCTAssertEqual(FeedImpressionTracker.visibleFraction(itemMinY: 900, itemHeight: 100, viewportMinY: 0, viewportMaxY: 800), 0)
        XCTAssertEqual(FeedImpressionTracker.visibleFraction(itemMinY: 0, itemHeight: 0, viewportMinY: 0, viewportMaxY: 800), 0)
        XCTAssertGreaterThanOrEqual(0.5, FeedImpressionTracker.minVisibleFraction)
    }

    // MARK: - 攒批与上报格式

    /// 攒满 50 条该发；一次取走、按 100 条一批切。
    func testBufferBatches() {
        var buffer = FeedEventBuffer()
        for index in 0..<49 {
            XCTAssertFalse(buffer.add(.impression(contentId: "c\(index)", tab: .recommend, at: t0)))
        }
        XCTAssertTrue(buffer.add(.impression(contentId: "c49", tab: .recommend, at: t0)))
        for index in 50..<230 {
            _ = buffer.add(.impression(contentId: "c\(index)", tab: .recommend, at: t0))
        }
        XCTAssertEqual(buffer.drain().map(\.count), [100, 100, 30])
        XCTAssertEqual(buffer.drain().count, 0)
        XCTAssertEqual(FeedEventBuffer.flushInterval, 30)
    }

    /// `POST /v1/feed/events`：只有契约字段，`surface` 是这一栏的路由名，`value` 为空就不发。
    func testEventsRequest() async throws {
        let transport = EventsTransport()
        let api = FeedAPI(baseURL: URL(string: "https://feed.example")!, transport: transport, tokens: EventTokens())
        try await api.events([.impression(contentId: "0192", tab: .following, at: t0)])
        XCTAssertEqual(transport.sent.map { "\($0.httpMethod!) \($0.url!.path)" }, ["POST /v1/feed/events"])
        XCTAssertEqual(
            transport.sent.first?.httpBody.map { String(decoding: $0, as: UTF8.self) },
            #"{"events":[{"content_id":"0192","occurred_at":"2026-10-13T11:00:00Z","surface":"following","type":"impression"}]}"#,
        )
    }

    // MARK: - FeedStore

    /// 露出满 1 秒自己补一次检查（不靠界面再来调），记一次曝光；藏起来时发出去。
    @MainActor
    func testStoreRecordsAfterOneSecondAndFlushesWhenHidden() async throws {
        let source = RecordingEventsSource()
        let store = FeedStore(source: source)

        store.onCardsVisible(.recommend, ["a", "b"])
        XCTAssertEqual(store.pendingEventCount, 0)
        for _ in 0..<150 where store.pendingEventCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.pendingEventCount, 2, "停着不动，满 1 秒后自己记上")

        store.onCardsVisible(.recommend, ["a", "b"])
        XCTAssertEqual(store.pendingEventCount, 2, "同一次会话不重复")

        store.onFeedHidden()
        XCTAssertEqual(store.pendingEventCount, 0)
        for _ in 0..<100 where source.batches.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(source.batches.count, 1)
        XCTAssertEqual(Set(source.batches[0].map(\.contentId)), ["a", "b"])
        XCTAssertTrue(source.batches[0].allSatisfy { $0.type == "impression" && $0.surface == "recommend" })
    }

    /// 没满 1 秒就藏起来：不算；上报失败直接丢，不重试。
    @MainActor
    func testHiddenBeforeOneSecondDoesNotCount() async throws {
        let source = RecordingEventsSource()
        source.fail = true
        let store = FeedStore(source: source)
        store.onCardsVisible(.following, ["a"])
        store.onFeedHidden()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(store.pendingEventCount, 0)
        XCTAssertEqual(source.calls, 0)
    }

    /// 攒满 50 条立刻发（不等 30 秒）；发失败的丢掉。
    @MainActor
    func testFullBatchIsSentRightAway() async throws {
        var clock = t0
        let source = RecordingEventsSource()
        source.fail = true
        let store = FeedStore(source: source, now: { clock })
        let ids = Set((0..<50).map { "c\($0)" })
        store.onCardsVisible(.recommend, ids)
        clock = clock.addingTimeInterval(1)
        store.onCardsVisible(.recommend, ids)
        XCTAssertEqual(store.pendingEventCount, 0)
        for _ in 0..<100 where source.calls == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(source.calls, 1)
        XCTAssertEqual(store.pendingEventCount, 0, "失败不放回去")
    }

    // MARK: - 列表

    /// 列表只报当前这一栏、动态页在屏幕上时露出过半的帖子；反馈卡不算。
    @MainActor
    func testTimelineReportsOnlyVisiblePostsOfTheCurrentPage() async throws {
        let feed = FeedViewController(source: SampleFeedSource())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = OWSNavigationController(rootViewController: feed)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        await feed.store.waitForLoad(.recommend)
        window.layoutIfNeeded()

        let page = feed.pages[0]
        page.isFeedVisible = false
        XCTAssertEqual(page.visibleCardIds(), [], "动态页不在屏幕上")
        feed.setFeedVisible(true)
        let visible = page.visibleCardIds()
        let cards = feed.store.tab(.recommend).cards
        XCTAssertFalse(visible.isEmpty)
        XCTAssertTrue(visible.contains(cards[0].id))
        XCTAssertFalse(visible.contains(cards[7].id), "屏幕外的不算")
        XCTAssertEqual(feed.pages[1].visibleCardIds(), [], "另一栏不算")

        feed.store.notInterested(cards[0])
        window.layoutIfNeeded()
        XCTAssertFalse(page.visibleCardIds().contains(cards[0].id), "反馈卡不算")
    }
}

private final class EventTokens: FeedTokenSource {
    func token(forceRefresh: Bool) async throws -> String { "t" }
}

private final class EventsTransport: FeedHTTPTransport {
    private(set) var sent = [URLRequest]()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        return (Data(#"{"accepted":1}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

private final class RecordingEventsSource: FeedSource {
    var fail = false
    private(set) var batches = [[FeedEventPayload]]()
    private(set) var calls = 0

    struct Failure: Error {}

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        throw Failure()
    }

    func reportEvents(_ events: [FeedEventPayload]) async throws {
        calls += 1
        if fail {
            throw Failure()
        }
        batches.append(events)
    }
}
