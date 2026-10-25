//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 未成年人时限（I-15）的界面接线（UIKit）：每个动态页面都过同一个检查（`FeedMinorLockController`），
/// 锁着时盖上提示页、导航栏按钮不能点、「返回聊天」；发布页锁着不能发、草稿留着。计时和判定在逻辑测试里。
final class TellomiFeedMinorLockUITests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: hour, minute: minute))!
    }

    @MainActor
    private func session(now: Date, minor: Bool?, usedMillis: Int64 = 0) -> FeedMinorSession {
        let usage = InMemoryFeedMinorUsage()
        usage.add(day: FeedMinorTime.dayKey(now, calendar: calendar), millis: usedMillis)
        let gate = FeedMinorGate(memory: InMemoryFeedMinorModeMemory(lastKnown: minor), usage: usage, clock: { now }, monotonicMillis: { 0 }, calendar: calendar)
        return FeedMinorSession(gate: gate)
    }

    @MainActor
    private func show(_ controller: UIViewController) -> UIWindow {
        let navigation = OWSNavigationController(rootViewController: controller)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    override func tearDown() {
        MainActor.assumeIsolated { FeedMinorSession.overrideForTesting = nil }
        super.tearDown()
    }

    /// 锁定提示的文案还在法务待审：标记不能被悄悄去掉，开关也必须还是关的（默认值，不是测试里关的）。
    func testLockCopyIsMarkedPendingLegalReviewAndTheSwitchStaysOff() {
        XCTAssertTrue(FeedMinorTime.lockCopyPendingLegalReview, "文案法务审过之前不能去掉这个标记")
        UserDefaults.standard.removeObject(forKey: "TellomiFeed.minorTime")
        XCTAssertFalse(TellomiFeed.isMinorTimeEnabled, "开关默认关")
    }

    @MainActor
    func testTheSwitchIsOffByDefaultAndOffMeansNothingIsInstalled() {
        XCTAssertFalse(TellomiFeed.isMinorTimeEnabled)
        XCTAssertNil(FeedMinorSession.current)
        let feed = FeedViewController(source: SampleFeedSource())
        feed.loadViewIfNeeded()
        XCTAssertNil(feed.minorSession)
        XCTAssertNil(feed.minorLock)
        XCTAssertFalse(feed.composeButton.isHidden)
        XCTAssertNil(FeedMinorLockController.install(in: UIViewController(), session: nil))
    }

    @MainActor
    func testAtNightTheFeedTabIsCoveredWithTheRestPage() {
        let s = session(now: date(23), minor: true)
        let feed = FeedViewController(source: SampleFeedSource(), searchEnabled: true, minorSession: s)
        let window = show(feed)
        defer { window.isHidden = true }
        let lock = try? XCTUnwrap(feed.minorLock)
        XCTAssertEqual(lock?.isLocked, true)
        XCTAssertEqual(lock?.lockView.lock, .night)
        XCTAssertEqual(lock?.lockView.titleLabel.text, FeedMinorLockView.title(.night))
        XCTAssertEqual(lock?.lockView.bodyLabel.text, FeedMinorLockView.body(.night))
        XCTAssertEqual(lock?.lockView.returnButton.configuration?.title, FeedMinorLockView.returnTitle)
        XCTAssertEqual(lock?.lockView.bodyLabel.numberOfLines, 0, "大字号不截断")
        XCTAssertTrue(feed.view.subviews.last === lock?.view, "盖在最上面")
        XCTAssertTrue(feed.composeButton.isHidden)
        let items = (feed.navigationItem.rightBarButtonItems ?? []) + (feed.navigationItem.leftBarButtonItems ?? [])
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { !$0.isEnabled })
    }

    @MainActor
    func testFortyMinutesUsedShowsTheDailyPage() {
        let s = session(now: date(12), minor: true, usedMillis: FeedMinorTime.dailyLimitMillis)
        let feed = FeedViewController(source: SampleFeedSource(), minorSession: s)
        let window = show(feed)
        defer { window.isHidden = true }
        XCTAssertEqual(feed.minorLock?.lockView.lock, .daily)
        XCTAssertEqual(feed.minorLock?.lockView.titleLabel.text, FeedMinorLockView.title(.daily))
    }

    @MainActor
    func testUnlockingTakesThePageAwayAndEnablesTheButtons() {
        let s = session(now: date(23), minor: true)
        let feed = FeedViewController(source: SampleFeedSource(), searchEnabled: true, minorSession: s)
        let window = show(feed)
        defer { window.isHidden = true }
        s.configLoaded(minorMode: false)
        XCTAssertEqual(feed.minorLock?.isLocked, false)
        XCTAssertFalse(feed.composeButton.isHidden)
        let items = (feed.navigationItem.rightBarButtonItems ?? []) + (feed.navigationItem.leftBarButtonItems ?? [])
        XCTAssertTrue(items.allSatisfy(\.isEnabled))
    }

    @MainActor
    func testADetailOpenedFromANotificationOrLinkIsCoveredToo() async throws {
        let s = session(now: date(23), minor: true)
        FeedMinorSession.overrideForTesting = s
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let fetched = try await source.card(contentId: "sample-1")
        let card = try XCTUnwrap(fetched)
        // 不经过动态标签：直接建详情页（通知推送 / 链接 / 搜索都是这样进来的）
        let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: false)
        let window = show(detail)
        defer { window.isHidden = true }
        XCTAssertEqual(detail.minorLock?.isLocked, true)
        XCTAssertEqual(s.visibleScreenCount, 1, "详情页也算在用动态")
    }

    @MainActor
    func testEveryFeedScreenInstallsTheSameCheck() {
        let s = session(now: date(23), minor: true)
        FeedMinorSession.overrideForTesting = s
        let source = SampleFeedSource()
        let screens: [UIViewController] = [
            FeedSearchViewController(source: source, feed: nil, history: InMemoryFeedSearchHistory()),
            FeedNotificationsViewController(source: source, feed: nil),
            FeedMyPostsViewController(source: source, feed: nil),
        ]
        for screen in screens {
            screen.loadViewIfNeeded()
            let lock = screen.children.compactMap { $0 as? FeedMinorLockController }.first
            XCTAssertNotNil(lock, "\(type(of: screen))")
            XCTAssertTrue(lock?.session === s)
            XCTAssertEqual(lock?.isLocked, true, "\(type(of: screen))")
        }
    }

    @MainActor
    func testReturnToChatsCallsTheHandlerWithTheHost() {
        let s = session(now: date(23), minor: true)
        let host = UIViewController()
        let window = show(host)
        defer { window.isHidden = true }
        let lock = FeedMinorLockController.install(in: host, session: s)
        var returnedFrom: UIViewController?
        lock?.returnToChats = { returnedFrom = $0 }
        lock?.lockView.returnButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(returnedFrom === host)
    }

    @MainActor
    func testAppearingAndDisappearingDriveTheSession() {
        let s = session(now: date(12), minor: true)
        let host = UIViewController()
        let lock = FeedMinorLockController.install(in: host, session: s)
        lock?.beginAppearanceTransition(true, animated: false)
        lock?.endAppearanceTransition()
        XCTAssertTrue(s.isTicking)
        lock?.beginAppearanceTransition(false, animated: false)
        lock?.endAppearanceTransition()
        XCTAssertFalse(s.isTicking)
    }

    @MainActor
    func testALockedComposePageCannotPublishAndSaysWhy() {
        let s = session(now: date(12), minor: true, usedMillis: FeedMinorTime.dailyLimitMillis)
        let compose = FeedComposeViewController(source: SampleFeedSource(), minorSession: s) { _ in }
        let window = show(compose)
        defer { window.isHidden = true }
        compose.setText("还没写完")
        XCTAssertEqual(compose.navigationItem.rightBarButtonItem?.isEnabled, false)
        XCTAssertEqual(compose.navigationItem.prompt, FeedMinorLockView.title(.daily))
        compose.publish()
        XCTAssertEqual(compose.draft.text, "还没写完", "草稿留着")
        s.configLoaded(minorMode: false)
        XCTAssertEqual(compose.navigationItem.rightBarButtonItem?.isEnabled, true, "解锁后接着发")
        XCTAssertNil(compose.navigationItem.prompt)
    }

    @MainActor
    func testTheComposePageCountsAsUsingTheFeed() {
        let s = session(now: date(12), minor: true)
        let compose = FeedComposeViewController(source: SampleFeedSource(), minorSession: s) { _ in }
        compose.beginAppearanceTransition(true, animated: false)
        compose.endAppearanceTransition()
        XCTAssertTrue(s.isTicking)
        compose.beginAppearanceTransition(false, animated: false)
        compose.endAppearanceTransition()
        XCTAssertFalse(s.isTicking)
    }
}
