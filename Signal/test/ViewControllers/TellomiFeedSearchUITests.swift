//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 搜索页的界面检查（UIKit）：在测试进程里放一个真的 `FeedViewController`（样例数据）+ 导航栏，推一个搜索页。
/// 样例搜索：「山」「面包」「夜跑」「云」「周末」有结果，「zzz」没有；「的」命中很多条（能看到翻页）。
/// 各种失败 / 慢 / 限速用 `source.simulation` 的 `search…` 开关切，截图方法见报告。
final class TellomiFeedSearchUITests: XCTestCase {

    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow
        let source: SampleFeedSource
        let history = InMemoryFeedSearchHistory()

        func openSearch(debounceNanos: UInt64 = 20_000_000) -> FeedSearchViewController {
            let search = FeedSearchViewController(source: source, feed: feed.store, history: history, debounceNanos: debounceNanos)
            navigation.pushViewController(search, animated: false)
            search.loadViewIfNeeded()
            window.layoutIfNeeded()
            return search
        }

        /// 像用户一样在搜索框里打字，等搜索回来。
        func type(_ text: String, into search: FeedSearchViewController) async {
            search.searchBar.text = text
            search.searchBar(search.searchBar, textDidChange: text)
            await search.store.waitForTasks()
            window.layoutIfNeeded()
        }
    }

    @MainActor
    private func makeHarness() async -> Harness {
        let source = SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source, profilePageEnabled: false)
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
    private func statusCell(of search: FeedSearchViewController, at row: Int) -> FeedStatusRowCell? {
        search.searchTableView.layoutIfNeeded()
        return search.searchTableView.cellForRow(at: IndexPath(row: row, section: 0)) as? FeedStatusRowCell
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<60 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func isPost(_ row: FeedSearchPresentation.Row) -> Bool {
        if case .post = row { return true }
        return false
    }

    private func isUser(_ row: FeedSearchPresentation.Row) -> Bool {
        if case .user = row { return true }
        return false
    }

    // MARK: - 没输入时

    @MainActor
    func testAnEmptyPageWithoutHistoryShowsTheHintAndNoScopeBar() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let search = harness.openSearch()
        XCTAssertEqual(search.rows, [.status(.hint)])
        XCTAssertTrue(search.scopeControl.superview?.isHidden ?? false, "没输入时不显示范围")
        XCTAssertEqual(search.scopeControl.numberOfSegments, 3)
        XCTAssertEqual(search.scopeControl.titleForSegment(at: 0), FeedSearchViewController.scopeTitle(FeedAPI.searchAll))
        XCTAssertNotNil(FeedSearchViewController.statusTexts(for: .hint).title)
        XCTAssertTrue(search.navigationItem.titleView === search.searchBar)
    }

    @MainActor
    func testRecentSearchesAndPeopleShowAndCanBeUsedRemovedAndCleared() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.history.addQuery("面包")
        harness.history.addQuery("山")
        harness.history.addPerson(FeedPersonSummary(id: "s-1", handle: "shanfeng", displayName: "山风", avatarKey: nil))
        let search = harness.openSearch()
        XCTAssertEqual(search.rows, [.recentQueriesHeader, .recentQuery("山"), .recentQuery("面包"), .recentPeopleHeader, .recentPerson(id: "s-1")])

        // 点一条最近搜索：搜索框里换成它，马上搜
        search.tableView(search.searchTableView, didSelectRowAt: IndexPath(row: 2, section: 0))
        await search.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertEqual(search.searchBar.text, "面包")
        XCTAssertEqual(search.store.state.results?.query, "面包")
        XCTAssertFalse(search.scopeControl.superview?.isHidden ?? true, "输入了就显示范围")

        // 清空回到最近搜索；左滑删一条
        await harness.type("", into: search)
        XCTAssertEqual(search.rows.first, .recentQueriesHeader)
        let swipe = search.tableView(search.searchTableView, trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 1, section: 0))
        let action = try XCTUnwrap(swipe?.actions.first)
        action.handler(action, UIView(), { _ in })
        XCTAssertFalse(search.rows.contains(.recentQuery("面包")), "刚搜过的 面包 排到最前（第 1 行），左滑删掉的是它")
        XCTAssertEqual(harness.history.queries(), ["山"])

        // 清除按钮
        let header = try XCTUnwrap({ () -> FeedSearchHeaderCell? in
            search.searchTableView.layoutIfNeeded()
            return search.searchTableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? FeedSearchHeaderCell
        }())
        header.actionButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(harness.history.queries(), [])
        XCTAssertFalse(search.rows.contains(.recentQueriesHeader))
        XCTAssertTrue(search.rows.contains(.recentPeopleHeader), "只清了搜索，最近看过的人还在")
    }

    // MARK: - 结果

    @MainActor
    func testAllScopeShowsPeopleThenPostsWithHeadersAndOtherScopesDoNot() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let search = harness.openSearch()
        await harness.type("山", into: search)

        XCTAssertEqual(search.rows.first, .usersHeader)
        XCTAssertTrue(search.rows.contains(.postsHeader))
        XCTAssertTrue(search.rows.contains(where: isUser))
        XCTAssertTrue(search.rows.contains(where: isPost))
        XCTAssertFalse(search.scopeControl.superview?.isHidden ?? true)

        search.scopeControl.selectedSegmentIndex = 2
        search.scopeControl.sendActions(for: .valueChanged)
        await search.store.waitForTasks()
        XCTAssertEqual(search.store.state.scope, FeedAPI.searchPosts)
        XCTAssertTrue(search.rows.allSatisfy(isPost), "「动态」范围：只有帖子，没有标题")

        search.scopeControl.selectedSegmentIndex = 1
        search.scopeControl.sendActions(for: .valueChanged)
        await search.store.waitForTasks()
        XCTAssertTrue(search.rows.allSatisfy(isUser), "「用户」范围：只有人，没有标题")
        XCTAssertFalse(search.rows.isEmpty)
    }

    @MainActor
    func testNoResultsNamesTheQueryAndTheSearchBoxKeepsAtMostFiftyCodePoints() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let search = harness.openSearch()
        await harness.type("zzz", into: search)
        XCTAssertEqual(search.rows, [.status(.noResults(query: "zzz"))])
        XCTAssertTrue(FeedSearchViewController.statusTexts(for: .noResults(query: "zzz")).title?.contains("zzz") ?? false)

        let long = String(repeating: "山", count: 40) + String(repeating: "😀", count: 30)
        await harness.type(long, into: search)
        XCTAssertEqual(FeedTextCap.count(search.store.state.query), FeedAPI.searchMaxQuery)
        XCTAssertEqual(search.searchBar.text, search.store.state.query, "搜索框里的字也被截到上限")
    }

    @MainActor
    func testTypingAgainBeforeTheDebounceOnlySearchesTheLastWord() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let search = harness.openSearch(debounceNanos: 150_000_000)
        search.searchBar.text = "山"
        search.searchBar(search.searchBar, textDidChange: "山")
        search.searchBar.text = "云"
        search.searchBar(search.searchBar, textDidChange: "云")
        await search.store.waitForTasks()
        XCTAssertEqual(search.store.state.results?.query, "云", "前一个词被新的盖掉，不会回来")
    }

    @MainActor
    func testPagingLoadsMoreAndAFailedPageKeepsTheResultsWithARetryRow() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let search = harness.openSearch()
        // 样例每页只有 3 条，列表一画出来「最后 3 行里有一行显示」就自动预取下一页（willDisplay），
        // 所以不能先断言「只有 3 条」：让翻页从一开始就失败，这样第一页之后的自动翻页稳定地停在「重试」行上。
        harness.source.simulation.failsSearchMore = true
        await harness.type("的", into: search)
        search.scopeControl.selectedSegmentIndex = 2
        search.scopeControl.sendActions(for: .valueChanged)
        await search.store.waitForTasks()
        harness.window.layoutIfNeeded()
        await waitUntil { search.rows.last == .status(.loadMoreFailed(retryAfterSeconds: nil)) }
        harness.window.layoutIfNeeded()
        let before = search.presentation.posts.map(\.id)
        XCTAssertEqual(before.count, SampleFeedSource.searchPostsPageSize, "第一页 3 条留着")
        XCTAssertEqual(search.rows.last, .status(.loadMoreFailed(retryAfterSeconds: nil)))
        XCTAssertFalse(search.presentation.canLoadMore)
        // 重试行在列表最底下：先滚到底，cellForRow 才拿得到
        search.searchTableView.scrollToRow(at: IndexPath(row: search.rows.count - 1, section: 0), at: .bottom, animated: false)
        let retryCell = try XCTUnwrap(statusCell(of: search, at: search.rows.count - 1))
        XCTAssertFalse(retryCell.retryButton.isHidden)

        harness.source.simulation.failsSearchMore = false
        retryCell.retryButton.sendActions(for: .touchUpInside)
        await search.store.waitForTasks()
        XCTAssertGreaterThan(search.presentation.posts.count, before.count)
    }

    // MARK: - 失败 / 限速 / feed_hidden

    @MainActor
    func testFirstPageFailureShowsRetryAndThrottleSaysHowLong() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.failsSearch = true
        let search = harness.openSearch()
        await harness.type("山", into: search)
        XCTAssertEqual(search.rows, [.status(.failed(retryAfterSeconds: nil))])
        let failedCell = try XCTUnwrap(statusCell(of: search, at: 0))
        XCTAssertFalse(failedCell.retryButton.isHidden)

        harness.source.simulation.failsSearch = false
        harness.source.simulation.searchThrottledRetryAfterSeconds = 25
        failedCell.retryButton.sendActions(for: .touchUpInside)
        await search.store.waitForTasks()
        XCTAssertEqual(search.rows, [.status(.failed(retryAfterSeconds: 25))])
        XCTAssertTrue(FeedSearchViewController.statusTexts(for: .failed(retryAfterSeconds: 25)).body?.contains("25") ?? false)

        harness.source.simulation.searchThrottledRetryAfterSeconds = nil
        statusCell(of: search, at: 0)?.retryButton.sendActions(for: .touchUpInside)
        await search.store.waitForTasks()
        XCTAssertTrue(search.rows.contains(where: isPost) || search.rows.contains(where: isUser), "重试成功")
    }

    @MainActor
    func testFeedHiddenClosesThePage() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let search = harness.openSearch()
        XCTAssertTrue(harness.navigation.topViewController === search)
        harness.source.simulation.feedHidden = true
        await harness.type("山", into: search)
        await waitUntil { harness.navigation.topViewController !== search }
        XCTAssertTrue(search.didClose)
        XCTAssertTrue(harness.navigation.topViewController === harness.feed, "回到信息流，不是停在「搜索失败」")
    }

    // MARK: - 打开结果 / 和信息流同步

    @MainActor
    func testOpeningAPersonOrAPostRemembersTheSearchAndThePerson() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let search = harness.openSearch()
        await harness.type("山", into: search)
        var person: FeedPersonSummary?
        var post: FeedCard?
        search.onOpenPerson = { person = $0 }
        search.onOpenPost = { post = $0 }

        let userRow = try XCTUnwrap(search.rows.firstIndex(where: isUser))
        search.tableView(search.searchTableView, didSelectRowAt: IndexPath(row: userRow, section: 0))
        XCTAssertEqual(person?.id, "s-1")
        XCTAssertEqual(harness.history.people().map(\.id), ["s-1"])
        XCTAssertEqual(harness.history.queries(), ["山"], "点开了结果才记进最近搜索")

        let postRow = try XCTUnwrap(search.rows.firstIndex(where: isPost))
        search.tableView(search.searchTableView, didSelectRowAt: IndexPath(row: postRow, section: 0))
        XCTAssertEqual(post?.id, search.presentation.posts.first?.id)
    }

    @MainActor
    func testTappingAPostPushesItsDetailByDefault() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let search = harness.openSearch()
        await harness.type("山", into: search)
        let postRow = try XCTUnwrap(search.rows.firstIndex(where: isPost))
        search.tableView(search.searchTableView, didSelectRowAt: IndexPath(row: postRow, section: 0))
        await waitUntil { harness.navigation.topViewController is FeedPostDetailViewController }
        XCTAssertTrue(harness.navigation.topViewController is FeedPostDetailViewController)
    }

    @MainActor
    func testALikeInTheResultsIsTheSameLikeInTheFeedStoreAndThePageLetsGoWhenPopped() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let search = harness.openSearch()
        await harness.type("山", into: search)
        XCTAssertTrue(search.store.isObservingFeed)
        XCTAssertGreaterThan(search.store.leaseCount, 0)
        let card = try XCTUnwrap(search.presentation.posts.first)
        let wasLiked = card.viewer.liked

        search.store.toggleLike(card)
        await search.store.waitForTasks()
        XCTAssertEqual(harness.feed.store.card(id: card.id)?.viewer.liked, !wasLiked, "信息流 store 里是同一份")
        XCTAssertEqual(search.presentation.posts.first?.viewer.liked, !wasLiked)

        harness.navigation.popViewController(animated: false)
        await waitUntil { !search.store.isObservingFeed }
        XCTAssertFalse(search.store.isObservingFeed)
        XCTAssertEqual(search.store.leaseCount, 0)
    }
}
