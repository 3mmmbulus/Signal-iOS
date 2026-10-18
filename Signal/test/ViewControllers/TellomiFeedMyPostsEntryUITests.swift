//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 「我的动态」入口的检查：默认关、动态页一点没变；打开后动态页左上角有个文档图标，点了推我的动态页（和铃铛并排时铃铛在前）。
final class TellomiFeedMyPostsEntryUITests: XCTestCase {

    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow
    }

    @MainActor
    private func makeHarness(myPostsEnabled: Bool, notificationsEnabled: Bool = false) async -> Harness {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source, profilePageEnabled: false, searchEnabled: false, notificationsEnabled: notificationsEnabled, myPostsEnabled: myPostsEnabled)
        let navigation = OWSNavigationController(rootViewController: feed)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        await feed.store.loadConfig()
        await feed.store.waitForLoad(.recommend)
        window.layoutIfNeeded()
        return Harness(feed: feed, navigation: navigation, window: window)
    }

    @MainActor
    func testEverythingIsOffByDefault() async throws {
        XCTAssertFalse(TellomiFeed.isMyPostsEnabled, "默认关（测试里没人打开过）")
        let harness = await makeHarness(myPostsEnabled: TellomiFeed.isMyPostsEnabled)
        defer { harness.window.isHidden = true }
        XCTAssertFalse(harness.feed.myPostsEnabled)
        XCTAssertNil(harness.feed.myPostsItem)
        XCTAssertNil(harness.feed.navigationItem.leftBarButtonItem, "关着：动态页上没有多出任何按钮")
        XCTAssertNil(harness.feed.navigationItem.leftBarButtonItems)

        harness.feed.openMyPosts()
        XCTAssertEqual(harness.navigation.viewControllers.count, 1, "关着：不推我的动态页")
    }

    @MainActor
    func testWhenOnTheFeedHasADocumentButtonThatOpensTheMyPostsPage() async throws {
        let harness = await makeHarness(myPostsEnabled: true)
        defer { harness.window.isHidden = true }
        let item = try XCTUnwrap(harness.feed.myPostsItem)
        XCTAssertEqual(harness.feed.navigationItem.leftBarButtonItems, [item])
        XCTAssertEqual(item.accessibilityLabel, FeedMyPostsViewController.title)
        XCTAssertNotNil(item.image)

        XCTAssertNotNil(item.primaryAction)
        harness.feed.openMyPosts()   // 按钮的动作就是它
        let page = try XCTUnwrap(harness.navigation.topViewController as? FeedMyPostsViewController)
        await page.store.waitForTasks()
        XCTAssertEqual(page.store.state.posts.count, 30)
        XCTAssertTrue(page.store.isObservingFeed, "和动态页同一个 FeedStore")
    }

    @MainActor
    func testTheBellStaysFirstWhenBothAreOn() async throws {
        let harness = await makeHarness(myPostsEnabled: true, notificationsEnabled: true)
        defer { harness.window.isHidden = true }
        let items = try XCTUnwrap(harness.feed.navigationItem.leftBarButtonItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].customView === harness.feed.notificationsButton)
        XCTAssertTrue(items[1] === harness.feed.myPostsItem)
        XCTAssertTrue(harness.feed.navigationItem.leftBarButtonItem?.customView === harness.feed.notificationsButton)
    }
}
