//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 名单页的界面检查（UIKit）：入口（动态设置页的一行、「我的动态」右上角）、名单入口页、四张名单、「关心的人」，样例数据（`SampleFeedSource+Lists.swift`）。
/// 读失败 / 动作失败 / 限速 / `feed_hidden` / 对方已撤回 / 名额满用 `source.simulation` 的 `lists…`、`followRequestWithdrawn`、`closePeople…` 开关切。
final class TellomiFeedListsUITests: XCTestCase {

    @MainActor
    private func makeSource() -> SampleFeedSource {
        return SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
    }

    @MainActor
    private func host(_ page: UIViewController) -> (OWSNavigationController, UIWindow) {
        let navigation = OWSNavigationController(rootViewController: page)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        return (navigation, window)
    }

    // MARK: - 入口

    @MainActor
    func testTheFlagIsOffByDefaultAndTheSettingsPageIsUnchanged() async throws {
        XCTAssertFalse(TellomiFeed.isListsEnabled, "默认关（测试里没人打开过）")
        let source = makeSource()
        let page = FeedRecommendationSettingsViewController(source: source, blockedKeywords: InMemoryFeedBlockedKeywords())
        let (navigation, window) = host(page)
        defer { window.isHidden = true }
        await page.store.waitForTasks()
        window.layoutIfNeeded()
        XCTAssertEqual(page.contents.sections.count, 11, "关着：和之前一样，没有多出名单那一行")
        page.openLists()   // 关着：什么也不做
        XCTAssertTrue(navigation.topViewController === page)
    }

    @MainActor
    func testWhenOnTheSettingsPageHasAListsRowThatPushesTheHub() async throws {
        let source = makeSource()
        let page = FeedRecommendationSettingsViewController(source: source, blockedKeywords: InMemoryFeedBlockedKeywords(), listsEnabled: true)
        let (navigation, window) = host(page)
        defer { window.isHidden = true }
        await page.store.waitForTasks()
        window.layoutIfNeeded()
        XCTAssertEqual(page.contents.sections.count, 12)
        XCTAssertEqual(page.contents.sections.first?.itemCount, 1)
        page.openLists()
        XCTAssertTrue(navigation.topViewController is FeedListsViewController)
    }

    @MainActor
    func testMyPostsHasNoListsButtonByDefaultAndOneWhenOn() async throws {
        let off = FeedMyPostsViewController(source: makeSource(), feed: nil, composeExtras: false, listsEnabled: false)
        XCTAssertNil(off.navigationItem.rightBarButtonItem)
        off.openLists()   // 关着：什么也不做（没有导航栏也不崩）

        let on = FeedMyPostsViewController(source: makeSource(), feed: nil, composeExtras: false, listsEnabled: true)
        let button = try XCTUnwrap(on.navigationItem.rightBarButtonItem)
        XCTAssertEqual(button.accessibilityLabel, FeedListsViewController.title)
        XCTAssertNotNil(button.image)
        XCTAssertNotNil(button.primaryAction)
        let (navigation, window) = host(on)
        defer { window.isHidden = true }
        on.openLists()
        XCTAssertTrue(navigation.topViewController is FeedListsViewController)
    }

    // MARK: - 入口页

    @MainActor
    func testTheHubListsFiveRowsInOrderAndEachOpensItsPage() async throws {
        let hub = FeedListsViewController(source: makeSource())
        let (navigation, window) = host(hub)
        defer { window.isHidden = true }
        hub.loadViewIfNeeded()
        XCTAssertEqual(hub.title, FeedListsViewController.title)
        XCTAssertEqual(hub.contents.sections.map(\.itemCount), [5])
        hub.open(.followRequests)
        XCTAssertEqual((navigation.topViewController as? FeedPeopleViewController)?.mode, .followRequests)
        // `open` 是带动画的 push；测试窗口里紧接着 pop / 再 push 会被正在进行的转场吞掉（Mac 上实测：拿到的是 nil / 上一页）。
        // 后面几项只看 `open` 建出来、交给导航的那一页对不对；导航本身上面第一步已经验过。
        hub.open(.blocked)
        XCTAssertEqual((hub.lastOpened as? FeedPeopleViewController)?.mode, .blocked)
        hub.open(.closePeople)
        XCTAssertTrue(hub.lastOpened is FeedClosePeopleViewController)
    }

    // MARK: - 四张名单

    @MainActor
    private func openPeople(_ mode: FeedPeopleMode, source: SampleFeedSource) async -> (FeedPeopleViewController, UIWindow) {
        let page = FeedPeopleViewController(mode: mode, source: source)
        let (_, window) = host(page)
        page.loadViewIfNeeded()
        await page.store.waitForTasks()
        window.layoutIfNeeded()
        return (page, window)
    }

    @MainActor
    func testFollowRequestsShowTheSeedsAndApprovingTakesTheRowAway() async throws {
        let (page, window) = await openPeople(.followRequests, source: makeSource())
        defer { window.isHidden = true }
        XCTAssertEqual(page.title, FeedPeopleViewController.title(for: .followRequests))
        XCTAssertEqual(page.contents.sections.map(\.itemCount), [3])
        let first = try XCTUnwrap(page.store.state.rows.first)
        page.store.answer(first, approve: true)
        XCTAssertEqual(page.contents.sections.map(\.itemCount), [2], "先从名单里拿掉")
        await page.store.waitForTasks()
        for _ in 0..<60 where page.lastToastText == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(page.lastToastText, FeedPeopleViewController.toastText(for: .approved))
    }

    @MainActor
    func testAWithdrawnRequestCountsAsDoneAndAFailureBringsTheRowBack() async throws {
        let source = makeSource()
        let (page, window) = await openPeople(.followRequests, source: source)
        defer { window.isHidden = true }
        source.simulation.followRequestWithdrawn = true
        page.store.answer(try XCTUnwrap(page.store.state.rows.first), approve: false)
        await page.store.waitForTasks()
        XCTAssertEqual(page.contents.sections.map(\.itemCount), [2])
        source.simulation.followRequestWithdrawn = false
        source.simulation.failsListsActions = true
        page.store.answer(try XCTUnwrap(page.store.state.rows.first), approve: true)
        await page.store.waitForTasks()
        XCTAssertEqual(page.contents.sections.map(\.itemCount), [2], "失败：放回来")
    }

    @MainActor
    func testBlockedMutedAndHiddenFromShowTheirSeedsAndExplanations() async throws {
        let source = makeSource()
        let (blocked, w1) = await openPeople(.blocked, source: source)
        defer { w1.isHidden = true }
        XCTAssertEqual(blocked.contents.sections.map(\.itemCount), [2])
        XCTAssertEqual(blocked.contents.sections.first?.footerTitle, FeedPeopleViewController.explain(for: .blocked))
        let (muted, w2) = await openPeople(.muted, source: source)
        defer { w2.isHidden = true }
        XCTAssertEqual(muted.contents.sections.map(\.itemCount), [2])
        let (hidden, w3) = await openPeople(.hiddenFrom, source: source)
        defer { w3.isHidden = true }
        XCTAssertEqual(hidden.contents.sections.map(\.itemCount), [1])
        hidden.store.remove(try XCTUnwrap(hidden.store.state.rows.first))
        await hidden.store.waitForTasks()
        XCTAssertEqual(hidden.contents.sections.map(\.itemCount), [1], "空了：显示一句说明")
        XCTAssertTrue(hidden.store.state.rows.isEmpty)
    }

    @MainActor
    func testLoadFailureShowsRetryAndFeedHiddenClosesThePage() async throws {
        let source = makeSource()
        source.simulation.failsListsLoad = true
        let (page, window) = await openPeople(.muted, source: source)
        defer { window.isHidden = true }
        XCTAssertTrue(page.store.state.failed)
        XCTAssertEqual(page.contents.sections.map(\.itemCount), [2], "一句失败 + 重试")
        source.simulation.failsListsLoad = false
        page.store.refresh()
        await page.store.waitForTasks()
        XCTAssertEqual(page.contents.sections.map(\.itemCount), [2], "重试成功：两个人")

        let hiddenSource = makeSource()
        hiddenSource.simulation.feedHidden = true
        let (closed, w2) = await openPeople(.blocked, source: hiddenSource)
        defer { w2.isHidden = true }
        XCTAssertTrue(closed.didClose)
    }

    // MARK: - 关心的人

    @MainActor
    private func openClosePeople(source: SampleFeedSource) async -> (FeedClosePeopleViewController, UIWindow) {
        let page = FeedClosePeopleViewController(source: source)
        let (_, window) = host(page)
        page.loadViewIfNeeded()
        await page.store.waitForTasks()
        window.layoutIfNeeded()
        return (page, window)
    }

    @MainActor
    func testClosePeopleShowsSearchMineAndRequests() async throws {
        let (page, window) = await openClosePeople(source: makeSource())
        defer { window.isHidden = true }
        XCTAssertEqual(page.title, FeedClosePeopleViewController.title)
        XCTAssertEqual(page.contents.sections.map(\.itemCount), [1, 1, 1], "搜索框 / 我设的 1 个 / 设了我的 1 个")
        XCTAssertEqual(page.contents.sections[1].headerTitle, String(
            format: OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_MINE", comment: ""),
            OWSFormat.formatInt(1), OWSFormat.formatInt(FeedClosePersonEntry.max),
        ))
        XCTAssertEqual(page.searchField.placeholder, FeedClosePeopleViewController.searchHint)
    }

    @MainActor
    func testClosePeopleRemoveAndAnswerUpdateTheListsAtOnce() async throws {
        let (page, window) = await openClosePeople(source: makeSource())
        defer { window.isHidden = true }
        page.store.remove(try XCTUnwrap(page.store.state.mine.first))
        XCTAssertEqual(page.contents.sections.map(\.itemCount), [1, 1, 1], "空了：显示一句说明")
        XCTAssertTrue(page.store.state.mine.isEmpty)
        page.store.answer(try XCTUnwrap(page.store.state.requests.first), accept: true)
        XCTAssertEqual(page.store.state.requests.first?.state, FeedClosePersonEntry.stateAccepted)
        await page.store.waitForTasks()
    }

    @MainActor
    func testClosePeopleFullShowsTheLimitInsteadOfSearchResults() async throws {
        let source = makeSource()
        let (page, window) = await openClosePeople(source: source)
        defer { window.isHidden = true }
        _ = try await source.addClosePerson(profileId: "s-2")
        _ = try await source.addClosePerson(profileId: "s-3")
        page.store.refresh()
        await page.store.waitForTasks()
        XCTAssertFalse(page.store.state.canAdd)
        XCTAssertEqual(page.contents.sections.first?.itemCount, 2, "搜索框 + 「最多设 3 个」")
    }
}
