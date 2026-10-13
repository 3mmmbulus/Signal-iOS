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

    /// 服务端下发或内部用户强制打开，任一个为真就显示；都没有就不显示（默认关）。
    func testTabIsShownWhenServerEnablesItOrInternalUserForcesIt() {
        XCTAssertFalse(TellomiFeed.isTabEnabled(remoteEnabled: false, forcedByInternalUser: false))
        XCTAssertTrue(TellomiFeed.isTabEnabled(remoteEnabled: true, forcedByInternalUser: false))
        XCTAssertTrue(TellomiFeed.isTabEnabled(remoteEnabled: false, forcedByInternalUser: true))
        XCTAssertTrue(TellomiFeed.isTabEnabled(remoteEnabled: true, forcedByInternalUser: true))
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
        let feed = FeedViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
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

        let feed = FeedViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
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
}
