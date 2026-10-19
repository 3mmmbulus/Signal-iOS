//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 搜索页 / 话题页的入口检查：默认全关、帖子行为不变；打开后动态页右上角有搜索按钮，帖子上的 `#话题` 能点进话题页。
final class TellomiFeedSearchEntryUITests: XCTestCase {

    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow
        let source: SampleFeedSource
    }

    @MainActor
    private func makeHarness(searchEnabled: Bool, profilePageEnabled: Bool = false) async -> Harness {
        let source = SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source, profilePageEnabled: profilePageEnabled, searchEnabled: searchEnabled)
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
    func testEverythingIsOffByDefaultAndTheCellsStayInert() async throws {
        XCTAssertFalse(TellomiFeed.isSearchEnabled, "默认关（测试里没人打开过）")
        let harness = await makeHarness(searchEnabled: TellomiFeed.isSearchEnabled)
        defer { harness.window.isHidden = true }
        XCTAssertFalse(harness.feed.searchEnabled)
        XCTAssertNil(harness.feed.navigationItem.rightBarButtonItem, "关着：动态页上没有搜索按钮")
        XCTAssertNil(harness.feed.pages[0].onOpenTopic)
        let table = harness.feed.pages[0].tableView
        table.layoutIfNeeded()
        let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)) as? FeedPostCell)
        XCTAssertNil(cell.onTopicTap)

        harness.feed.openSearch()
        harness.feed.openTopic(FeedTopic(slug: "food", label: "美食"))
        XCTAssertEqual(harness.navigation.viewControllers.count, 1, "关着：不推搜索页 / 话题页")
    }

    @MainActor
    func testWhenOnTheFeedHasASearchButtonAndTopicsOpenTheTopicPage() async throws {
        let harness = await makeHarness(searchEnabled: true)
        defer { harness.window.isHidden = true }
        let button = try XCTUnwrap(harness.feed.navigationItem.rightBarButtonItem)
        XCTAssertEqual(button.accessibilityLabel, OWSLocalizedString("TELLOMI_FEED_SEARCH_BUTTON", comment: "Feed: accessibility label of the search button at the top of the feed."))

        let page = harness.feed.pages[0]
        XCTAssertNotNil(page.onOpenTopic)
        page.tableView.layoutIfNeeded()
        let cell = try XCTUnwrap(page.tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? FeedPostCell)
        XCTAssertNotNil(cell.onTopicTap)
        let topic = try XCTUnwrap(cell.card?.topics.first)

        cell.onTopicTap?(topic)
        let topicPage = try XCTUnwrap(harness.navigation.topViewController as? FeedTopicViewController)
        XCTAssertEqual(topicPage.store.slug, topic.slug)
        XCTAssertEqual(topicPage.navigationItem.title, "#\(topic.label)", "标题先用帖子上的话题名")
        XCTAssertNotNil(topicPage.onOpenTopic, "话题页里点别的话题也能进")
        // 入口是 animated: true 的 push：等动画走完再 pop，不然 UINavigationController 会忽略后面的 push（嵌套转场）
        try await Task.sleep(nanoseconds: 800_000_000)
        harness.navigation.popViewController(animated: false)
        try await Task.sleep(nanoseconds: 300_000_000)

        harness.feed.openSearch()
        XCTAssertTrue(harness.navigation.topViewController is FeedSearchViewController)
    }

    @MainActor
    func testTheDetailPostTopicsAreWiredOnlyWhenOn() async throws {
        let harness = await makeHarness(searchEnabled: true)
        defer { harness.window.isHidden = true }
        let page = harness.feed.pages[0]
        page.tableView.layoutIfNeeded()
        let cell = try XCTUnwrap(page.tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? FeedPostCell)
        page.onOpenPost?(try XCTUnwrap(cell.card))
        try await Task.sleep(nanoseconds: 800_000_000)
        let detail = try XCTUnwrap(harness.navigation.topViewController as? FeedPostDetailViewController)
        detail.loadViewIfNeeded()
        harness.window.layoutIfNeeded()
        XCTAssertNotNil(detail.onOpenTopic)
        XCTAssertNotNil(detail.postCell?.onTopicTap)
        detail.onOpenTopic?(FeedTopic(slug: "food", label: "美食"))
        XCTAssertTrue(harness.navigation.topViewController is FeedTopicViewController)
    }

    @MainActor
    func testATopicWithoutASlugDoesNothing() async throws {
        let harness = await makeHarness(searchEnabled: true)
        defer { harness.window.isHidden = true }
        harness.feed.openTopic(FeedTopic(slug: "", label: "?"))
        XCTAssertEqual(harness.navigation.viewControllers.count, 1)
    }
}
