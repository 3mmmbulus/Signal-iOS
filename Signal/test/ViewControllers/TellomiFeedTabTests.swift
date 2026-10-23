//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// M11 动态（tellomi/tellomi#1355）第一刀：「动态」标签的开关、位置和顶栏。与 Android `FeedTabTest` 同口径。
final class TellomiFeedTabTests: XCTestCase {

    /// 内部用户强制打开就显示；否则要服务端下发**并且**内容引擎说能看（`engineVisible`）。默认关。
    /// 与 Android `TellomiFeed.isTabEnabled(remoteEnabled, engineVisible, forcedByInternalUser)` 同口径。
    func testTabIsShownWhenServerAndEngineAllowItOrInternalUserForcesIt() {
        XCTAssertFalse(TellomiFeed.isTabEnabled(remoteEnabled: false, engineVisible: false, forcedByInternalUser: false))
        XCTAssertFalse(TellomiFeed.isTabEnabled(remoteEnabled: true, engineVisible: false, forcedByInternalUser: false))
        XCTAssertFalse(TellomiFeed.isTabEnabled(remoteEnabled: false, engineVisible: true, forcedByInternalUser: false))
        XCTAssertTrue(TellomiFeed.isTabEnabled(remoteEnabled: true, engineVisible: true, forcedByInternalUser: false))
        XCTAssertTrue(TellomiFeed.isTabEnabled(remoteEnabled: false, engineVisible: false, forcedByInternalUser: true))
        XCTAssertTrue(TellomiFeed.isTabEnabled(remoteEnabled: true, engineVisible: false, forcedByInternalUser: true))
    }

    /// 没下发 `global.feed.enabled` 时远程配置读出来是关；下发 true 才开。
    func testRemoteConfigDefaultsToOff() {
        XCTAssertFalse(RemoteConfig(clockSkew: 0, valueFlags: [:]).isTellomiFeedEnabled)
        XCTAssertTrue(RemoteConfig(clockSkew: 0, valueFlags: ["global.feed.enabled": "true"]).isTellomiFeedEnabled)
        XCTAssertFalse(RemoteConfig(clockSkew: 0, valueFlags: ["global.feed.enabled": "false"]).isTellomiFeedEnabled)
    }

    /// 动态在底栏最左（第三节第 17 条）；关掉时底栏和上游一样。
    func testFeedIsTheLeftmostTab() {
        XCTAssertEqual(
            HomeTabBarController.tabsToShow(areStoriesEnabled: true, isFeedEnabled: true),
            [.feed, .chatList, .calls, .stories],
        )
        XCTAssertEqual(
            HomeTabBarController.tabsToShow(areStoriesEnabled: false, isFeedEnabled: true),
            [.feed, .chatList, .calls],
        )
        XCTAssertEqual(
            HomeTabBarController.tabsToShow(areStoriesEnabled: true, isFeedEnabled: false),
            [.chatList, .calls, .stories],
        )
    }

    /// 底栏顺序：动态、聊天、通话、好友、我；有好友/我时快拍开着也不显示（正好 5 个）；默认选「聊天」（TF34）。
    func testFriendsAndMeTabOrderAndDefaultTab() {
        XCTAssertEqual(
            HomeTabBarController.tabsToShow(areStoriesEnabled: false, isFeedEnabled: true, showsFriendsAndMe: true),
            [.feed, .chatList, .calls, .friends, .me],
        )
        XCTAssertEqual(
            HomeTabBarController.tabsToShow(areStoriesEnabled: true, isFeedEnabled: true, showsFriendsAndMe: true),
            [.feed, .chatList, .calls, .friends, .me],
        )
        XCTAssertEqual(
            HomeTabBarController.tabsToShow(areStoriesEnabled: true, isFeedEnabled: true, showsFriendsAndMe: true).count,
            5,
        )
        // 商店版（没有好友/我）底栏不变：快拍照旧排最后
        XCTAssertEqual(
            HomeTabBarController.tabsToShow(areStoriesEnabled: true, isFeedEnabled: false, showsFriendsAndMe: false),
            [.chatList, .calls, .stories],
        )
        XCTAssertEqual(
            HomeTabBarController.tabsToShow(areStoriesEnabled: true, isFeedEnabled: true, showsFriendsAndMe: false),
            [.feed, .chatList, .calls, .stories],
        )
        XCTAssertEqual(
            HomeTabBarController.tabsToShow(areStoriesEnabled: true, isFeedEnabled: false),
            [.chatList, .calls, .stories],
        )
        XCTAssertEqual(HomeTabBarController.defaultTab, .chatList)
        XCTAssertEqual(HomeTabBarController.Tabs.friends.tabIdentifier, "friends")
        XCTAssertEqual(HomeTabBarController.Tabs.me.tabIdentifier, "me")
        XCTAssertNotNil(HomeTabBarController.Tabs.friends.image)
        XCTAssertNotNil(HomeTabBarController.Tabs.me.image)
    }

    /// 只有「推荐 / 关注」两栏；服务端给的顺序照用，不认识的跳过，一个都不认识时两栏都显示。
    func testTabsFromServerNames() {
        XCTAssertEqual(FeedTab.allCases, [.recommend, .following])
        XCTAssertEqual(FeedTab.fromApiNames(["following", "recommend"]), [.following, .recommend])
        XCTAssertEqual(FeedTab.fromApiNames(["following", "hot", "following"]), [.following])
        XCTAssertEqual(FeedTab.fromApiNames(["hot"]), [.recommend, .following])
        XCTAssertEqual(FeedTab.fromApiNames([]), [.recommend, .following])
        XCTAssertEqual(FeedTab.recommend.apiName, "recommend")
        XCTAssertEqual(FeedTab.following.apiName, "following")
    }

    /// 顶栏一行两栏、居中；滑块跟着横向滑动走，过半才算换到下一栏。
    @MainActor
    func testTopBarFollowsTheSwipe() {
        let topBar = FeedTopBarView(tabs: FeedTab.allCases)
        topBar.frame = CGRect(origin: .zero, size: topBar.intrinsicContentSize)
        topBar.layoutIfNeeded()

        XCTAssertEqual(topBar.selectedIndex, 0)
        topBar.setPosition(0.4)
        XCTAssertEqual(topBar.selectedIndex, 0)
        topBar.setPosition(0.6)
        XCTAssertEqual(topBar.selectedIndex, 1)
        topBar.setPosition(3)
        XCTAssertEqual(topBar.position, 1, "不会滑出最后一栏")

        var tapped = [Int]()
        topBar.onSelect = { tapped.append($0) }
        let buttons = topBar.subviews.flatMap { $0.subviews }.compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons.map { $0.configuration?.title }, [FeedTab.recommend.title, FeedTab.following.title])
        buttons[0].sendActions(for: .touchUpInside)
        XCTAssertEqual(tapped, [0])
    }

    /// 动态页两栏横排，翻到第二栏后顶栏跟着换；底栏再点一次「动态」不崩。
    @MainActor
    func testFeedPageHasTwoSwipeablePages() {
        let feed = FeedViewController(source: EmptyFeedSource.shared) // 不连引擎：默认的 FeedSources.current() 要 SSKEnvironment
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = OWSNavigationController(rootViewController: feed)
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        XCTAssertEqual(feed.pages.map(\.feedTab), [.recommend, .following])
        XCTAssertTrue(feed.navigationItem.titleView is FeedTopBarView)
        XCTAssertEqual(feed.selectedTab, .recommend)
        XCTAssertTrue(feed.pages[0].isCurrentPage)

        let scrollView = try! XCTUnwrap(feed.view.subviews.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(scrollView.contentSize.width, scrollView.bounds.size.width * 2, accuracy: 0.5)
        scrollView.contentOffset = CGPoint(x: scrollView.bounds.size.width, y: 0)
        XCTAssertEqual(feed.selectedTab, .following)
        XCTAssertTrue(feed.pages[1].isCurrentPage)
        XCTAssertFalse(feed.pages[0].isCurrentPage)

        feed.scrollToTop()
    }

    /// 给人看的截图（TELLOMI_SHOTS=1 时才跑）：动态页空状态。写到 `TELLOMI_SHOTS_DIR/<屏宽>/feed-*.png`。
    @MainActor
    func testShotsOfEmptyFeed() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(UIScreen.main.bounds.size.width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let feed = FeedViewController(source: EmptyFeedSource.shared) // 不连引擎：默认的 FeedSources.current() 要 SSKEnvironment
        let window = UIWindow.tellomiTestWindow(frame: UIScreen.main.bounds)
        window.rootViewController = OWSNavigationController(rootViewController: feed)
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)

        func shoot(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        }

        try shoot("feed-empty-recommend")
        let scrollView = try XCTUnwrap(feed.view.subviews.compactMap { $0 as? UIScrollView }.first)
        scrollView.contentOffset = CGPoint(x: scrollView.bounds.size.width * 0.5, y: 0)
        try shoot("feed-empty-mid-swipe")
        scrollView.contentOffset = CGPoint(x: scrollView.bounds.size.width, y: 0)
        try shoot("feed-empty-following")

        window.isHidden = true
        window.rootViewController = nil
    }

    /// TestFlight 动态预览：测试跑在模拟器 / Xcode 装的包里，没有 TestFlight 收据，所以开关行不出现、写不进去、读永远是 false，
    /// 动态标签和样例开关都不受它影响（和 App Store 包一样）。
    func testTestFlightPreviewIsUnavailableOutsideTestFlight() {
        let key = TellomiFeedPreview.storageKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        XCTAssertFalse(TellomiFeed.isTestFlightPreviewAvailable)
        TellomiFeed.isTestFlightPreviewEnabled = true
        XCTAssertFalse(TellomiFeed.isTestFlightPreviewEnabled)
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertFalse(TellomiFeed.isTestFlightPreviewEnabled)
        XCTAssertNil(TellomiFeed.testFlightPreviewPrompt)
    }
}
