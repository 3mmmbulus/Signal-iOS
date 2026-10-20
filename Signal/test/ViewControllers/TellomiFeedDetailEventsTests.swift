//
// DRAFT — NOT COMPILED. Intended location: Signal/test/ViewControllers/TellomiFeedDetailEventsTests.swift (new file)
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class TellomiFeedDetailEventsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testOpenThenDwell() {
        var tracker = FeedDetailEventTracker()
        XCTAssertEqual(tracker.opened(contentId: "a", surface: .recommend, now: t0).map(\.type), ["open"])
        let events = tracker.closed(now: t0.addingTimeInterval(45))
        XCTAssertEqual(events.map(\.type), ["dwell"])
        XCTAssertEqual(events.first?.value, 45)
        XCTAssertEqual(events.first?.surface, "recommend")
        XCTAssertFalse(tracker.isOpen)
    }

    /// 决定（2026-10-16）：默认就报 quick_exit，3 秒内（含 3 秒整）退出算；quick_exit 和 dwell 互斥。
    func testDefaultsFollowTheDecision() {
        let tracker = FeedDetailEventTracker()
        XCTAssertTrue(tracker.reportsQuickExit)
        XCTAssertEqual(tracker.quickExitThreshold, 3)
        XCTAssertEqual(tracker.minDwellSeconds, 30)
    }

    func testQuickExitWithinThreeSeconds() {
        var tracker = FeedDetailEventTracker()
        _ = tracker.opened(contentId: "b", surface: .following, now: t0)
        let events = tracker.closed(now: t0.addingTimeInterval(1.5))
        XCTAssertEqual(events.map(\.type), ["quick_exit"])
        XCTAssertEqual(events.first?.value, 1.5)

        _ = tracker.opened(contentId: "c", surface: .following, now: t0)
        XCTAssertEqual(tracker.closed(now: t0.addingTimeInterval(3)).map(\.type), ["quick_exit"]) // 3 秒整还算 3 秒内
    }

    /// 3 秒以上、不到 30 秒：引擎不加权，客户端也不再补事件（只有之前的 open）。
    func testBetweenThreeAndThirtySecondsReportsNothingMore() {
        var tracker = FeedDetailEventTracker()
        _ = tracker.opened(contentId: "a", surface: .recommend, now: t0)
        XCTAssertTrue(tracker.closed(now: t0.addingTimeInterval(3.01)).isEmpty)
        _ = tracker.opened(contentId: "a", surface: .recommend, now: t0)
        XCTAssertTrue(tracker.closed(now: t0.addingTimeInterval(29.99)).isEmpty)
        _ = tracker.opened(contentId: "a", surface: .recommend, now: t0)
        XCTAssertEqual(tracker.closed(now: t0.addingTimeInterval(30)).map(\.type), ["dwell"]) // 30 秒整算深度阅读
    }

    func testQuickExitCanBeSwitchedOff() {
        var tracker = FeedDetailEventTracker()
        tracker.reportsQuickExit = false
        _ = tracker.opened(contentId: "a", surface: .following, now: t0)
        XCTAssertTrue(tracker.closed(now: t0.addingTimeInterval(1.5)).isEmpty)
    }

    func testNothingOpenReportsNothing() {
        var tracker = FeedDetailEventTracker()
        XCTAssertTrue(tracker.closed(now: t0.addingTimeInterval(9)).isEmpty)
    }

    func testOpeningAnotherClosesThePrevious() {
        var tracker = FeedDetailEventTracker()
        _ = tracker.opened(contentId: "a", surface: .profile, now: t0)
        let events = tracker.opened(contentId: "b", surface: .profile, now: t0.addingTimeInterval(40))
        XCTAssertEqual(events.map(\.type), ["dwell", "open"])
        XCTAssertEqual(events.map(\.contentId), ["a", "b"])
    }

    /// 引擎的 value 范围 0…86400，超出整批 400。
    func testValueIsClamped() {
        XCTAssertEqual(FeedEventPayload.dwell(contentId: "a", surface: .recommend, seconds: 1_000_000, at: t0).value, 86_400)
        XCTAssertEqual(FeedEventPayload.dwell(contentId: "a", surface: .recommend, seconds: -5, at: t0).value, 0)
        XCTAssertEqual(FeedEventPayload.dwell(contentId: "a", surface: .recommend, seconds: .nan, at: t0).value, 0)
    }

    /// 时钟往回拨：当作 0 秒，即一次 quick_exit，value 为 0（不能是负数，否则整批 400）。
    func testClockGoingBackwardsIsZeroSecondQuickExit() {
        var tracker = FeedDetailEventTracker()
        _ = tracker.opened(contentId: "a", surface: .recommend, now: t0)
        let events = tracker.closed(now: t0.addingTimeInterval(-30))
        XCTAssertEqual(events.map(\.type), ["quick_exit"])
        XCTAssertEqual(events.first?.value, 0)
    }

    /// 分享只在真的完成后才报；取消什么都不报。
    func testShareOnlyWhenCompleted() {
        XCTAssertEqual(FeedShareOutcome.completed.event(contentId: "a", surface: .recommend, shareable: true, at: t0)?.type, "share")
        XCTAssertNil(FeedShareOutcome.cancelled.event(contentId: "a", surface: .recommend, shareable: true, at: t0))
    }

    /// 产品 2026-10-20：选了分享目标就记（看 `activityType`，不看 `completed`）；没选目标关掉面板不记。
    func testShareSheetCountsOnceATargetIsPicked() {
        XCTAssertEqual(FeedShareOutcome.fromShareSheet(activityType: "com.apple.UIKit.activity.Message"), .completed)
        XCTAssertEqual(FeedShareOutcome.fromShareSheet(activityType: "com.tencent.xin.sharetimeline"), .completed, "选了目标、在目标 App 里取消也记")
        XCTAssertEqual(FeedShareOutcome.fromShareSheet(activityType: nil), .cancelled)
        XCTAssertEqual(FeedShareOutcome.fromShareSheet(activityType: "x").event(contentId: "a", surface: .recommend, shareable: true, at: t0)?.type, "share")
        XCTAssertNil(FeedShareOutcome.fromShareSheet(activityType: nil).event(contentId: "a", surface: .recommend, shareable: true, at: t0))
        XCTAssertNil(FeedShareOutcome.fromShareSheet(activityType: "x").event(contentId: "a", surface: .recommend, shareable: false, at: t0))
    }

    /// 卡片外层 `shareable == false`（私密账号 / 非公开）：没有分享入口，也不报 `share`（引擎不检查）。
    func testShareIsNotReportedForCardsThatAreNotShareable() {
        XCTAssertNil(FeedShareOutcome.completed.event(contentId: "a", surface: .profile, shareable: false, at: t0))
        XCTAssertNil(FeedShareOutcome.cancelled.event(contentId: "a", surface: .profile, shareable: false, at: t0))
    }

    func testShareAndSurfaceFromTab() {
        let event = FeedEventPayload.share(contentId: "a", surface: FeedEventSurface(tab: .following), at: t0)
        XCTAssertEqual(event.type, "share")
        XCTAssertEqual(event.surface, "following")
        XCTAssertNil(event.value)
    }
}
