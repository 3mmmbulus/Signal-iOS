//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 通知页入口的检查：默认关、动态页一点没变；打开后动态页左上角有铃铛，没读的通知在铃铛上亮红点（和通知页同一份未读数）。
final class TellomiFeedNotificationsEntryUITests: XCTestCase {

    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow
        let source: SampleFeedSource
    }

    @MainActor
    private func makeHarness(notificationsEnabled: Bool, searchEnabled: Bool = false) async -> Harness {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source, profilePageEnabled: false, searchEnabled: searchEnabled, notificationsEnabled: notificationsEnabled)
        let navigation = OWSNavigationController(rootViewController: feed)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        await feed.store.loadConfig()
        await feed.store.waitForLoad(.recommend)
        window.layoutIfNeeded()
        return Harness(feed: feed, navigation: navigation, window: window, source: source)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<60 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    func testEverythingIsOffByDefault() async throws {
        XCTAssertFalse(TellomiFeed.isNotificationsEnabled, "默认关（测试里没人打开过）")
        let harness = await makeHarness(notificationsEnabled: TellomiFeed.isNotificationsEnabled)
        defer { harness.window.isHidden = true }
        XCTAssertFalse(harness.feed.notificationsEnabled)
        XCTAssertNil(harness.feed.navigationItem.leftBarButtonItem, "关着：动态页上没有铃铛")

        harness.feed.viewDidAppear(false)
        await harness.feed.store.waitForNotificationUnread()
        XCTAssertEqual(harness.feed.store.notificationUnread, FeedUnreadCounts(), "关着：不去问未读数")
        XCTAssertTrue(harness.feed.notificationsButton.dot.isHidden)

        harness.feed.openNotifications()
        XCTAssertEqual(harness.navigation.viewControllers.count, 1, "关着：不推通知页")
    }

    @MainActor
    func testWhenOnTheFeedHasABellWithARedDotAndItOpensTheNotificationsPage() async throws {
        let harness = await makeHarness(notificationsEnabled: true)
        defer { harness.window.isHidden = true }
        let item = try XCTUnwrap(harness.feed.navigationItem.leftBarButtonItem)
        XCTAssertTrue(item.customView === harness.feed.notificationsButton)
        XCTAssertEqual(harness.feed.notificationsButton.accessibilityLabel, OWSLocalizedString("TELLOMI_FEED_NOTIF_TITLE", comment: "Feed notifications page: title."))

        // 出现在屏幕上时问一次未读数（窗口显示时可能已经问过，这里再调一次也只会问一次）
        harness.feed.viewDidAppear(false)
        await harness.feed.store.waitForNotificationUnread()
        XCTAssertEqual(harness.feed.store.notificationUnread, FeedUnreadCounts(interactions: 6, follows: 2, system: 2))
        XCTAssertFalse(harness.feed.notificationsButton.dot.isHidden)
        XCTAssertEqual(harness.feed.notificationsButton.accessibilityValue, OWSFormat.formatInt(10))

        harness.feed.notificationsButton.sendActions(for: .touchUpInside)
        let page = try XCTUnwrap(harness.navigation.topViewController as? FeedNotificationsViewController)
        // 铃铛是 animated 推页：页面的 view（和 viewDidLoad 里开始的第一次载入）要等一轮才有，先把它加载好再等 store
        page.loadViewIfNeeded()
        await page.store.waitForTasks()
        XCTAssertEqual(harness.feed.store.notificationUnread, FeedUnreadCounts(follows: 2, system: 2), "通知页里打开互动栏标了已读，铃铛同一份")
        XCTAssertFalse(harness.feed.notificationsButton.dot.isHidden, "新关注和系统通知还没看")

        page.store.selectTab(FeedAPI.notificationsFollows)
        await page.store.waitForTasks()
        page.store.selectTab(FeedAPI.notificationsSystem)
        await page.store.waitForTasks()
        XCTAssertTrue(harness.feed.notificationsButton.dot.isHidden, "三栏都看过：红点没了")
    }

    @MainActor
    func testTheBadgeFollowsTheStoreInBothDirections() async throws {
        let harness = await makeHarness(notificationsEnabled: true)
        defer { harness.window.isHidden = true }
        harness.feed.store.setNotificationUnread(FeedUnreadCounts(system: 1))
        XCTAssertFalse(harness.feed.notificationsButton.dot.isHidden)
        XCTAssertEqual(harness.feed.notificationsButton.accessibilityValue, OWSFormat.formatInt(1))
        harness.feed.store.setNotificationUnread(FeedUnreadCounts(interactions: 500))
        XCTAssertEqual(harness.feed.notificationsButton.accessibilityValue, OWSFormat.formatInt(99), "数字最多说 99")
        harness.feed.store.setNotificationUnread(FeedUnreadCounts())
        XCTAssertTrue(harness.feed.notificationsButton.dot.isHidden)
        XCTAssertNil(harness.feed.notificationsButton.accessibilityValue)
    }

    @MainActor
    func testTheBellAndTheSearchButtonLiveSideBySide() async throws {
        let harness = await makeHarness(notificationsEnabled: true, searchEnabled: true)
        defer { harness.window.isHidden = true }
        XCTAssertNotNil(harness.feed.navigationItem.leftBarButtonItem)
        XCTAssertNotNil(harness.feed.navigationItem.rightBarButtonItem)
        harness.feed.openSearch()
        XCTAssertTrue(harness.navigation.topViewController is FeedSearchViewController)
    }

    @MainActor
    func testAFailedUnreadCheckLeavesTheBellAlone() async throws {
        let harness = await makeHarness(notificationsEnabled: true)
        defer { harness.window.isHidden = true }
        harness.feed.store.setNotificationUnread(FeedUnreadCounts(follows: 3))
        harness.source.simulation.failsNotifications = true
        harness.feed.store.refreshNotificationUnread(force: true)
        await harness.feed.store.waitForNotificationUnread()
        XCTAssertEqual(harness.feed.store.notificationUnread, FeedUnreadCounts(follows: 3))
        XCTAssertFalse(harness.feed.notificationsButton.dot.isHidden)
    }
}
