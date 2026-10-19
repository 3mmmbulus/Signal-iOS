//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 通知页的界面检查（UIKit）：在测试进程里放一个真的 `FeedViewController`（样例数据）+ 导航栏，推一个通知页。
/// 样例通知（`SampleFeedSource+Notifications.swift`）：互动栏 36 条（第一页 30 条，能看到翻页；`sample-0` 上三个人的赞合成一行；一条回复只带 actor_id），
/// 新关注栏 4 条，系统栏 5 条。失败 / 慢 / 限速 / `feed_hidden` 用 `source.simulation` 的 `notifications…` 开关切，截图方法见报告。
final class TellomiFeedNotificationsUITests: XCTestCase {

    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow
        let source: SampleFeedSource

        func openNotifications(tab: String = FeedAPI.notificationsInteractions) async -> FeedNotificationsViewController {
            let notes = FeedNotificationsViewController(initialTab: tab, source: source, feed: feed.store)
            navigation.pushViewController(notes, animated: false)
            notes.loadViewIfNeeded()
            await notes.store.waitForTasks()
            window.layoutIfNeeded()
            return notes
        }
    }

    @MainActor
    private func makeHarness(configure: (SampleFeedSource) -> Void = { _ in }) async -> Harness {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        configure(source)
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
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<60 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    private func rowIndex(_ notes: FeedNotificationsViewController, where match: (FeedNotificationRow) -> Bool) -> Int? {
        return notes.rows.firstIndex { row in
            if case .notification(let value) = row { return match(value) }
            return false
        }
    }

    @MainActor
    private func cell<T: UITableViewCell>(_ notes: FeedNotificationsViewController, _ row: Int, as type: T.Type) -> T? {
        notes.notificationsTableView.layoutIfNeeded()
        return notes.notificationsTableView.cellForRow(at: IndexPath(row: row, section: 0)) as? T
    }

    @MainActor
    private func swipeActions(_ notes: FeedNotificationsViewController, _ row: Int) -> [UIContextualAction] {
        return notes.tableView(notes.notificationsTableView, trailingSwipeActionsConfigurationForRowAt: IndexPath(row: row, section: 0))?.actions ?? []
    }

    // MARK: - 页面

    @MainActor
    func testTheInteractionsTabShowsBadgesHeadersMergedLikesAndUnreadDots() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()

        XCTAssertEqual(notes.tabControl.numberOfSegments, 3)
        XCTAssertEqual(notes.tabControl.selectedSegmentIndex, 0)
        XCTAssertEqual(notes.tabControl.titleForSegment(at: 0), FeedNotificationsViewController.tabTitle(FeedAPI.notificationsInteractions, badge: 0), "打开这一栏就标已读，互动栏的数字没了")
        XCTAssertEqual(notes.tabControl.titleForSegment(at: 1), FeedNotificationsViewController.tabTitle(FeedAPI.notificationsFollows, badge: 2))
        XCTAssertEqual(notes.tabControl.titleForSegment(at: 2), FeedNotificationsViewController.tabTitle(FeedAPI.notificationsSystem, badge: 2))
        XCTAssertEqual(harness.feed.store.notificationUnread, FeedUnreadCounts(follows: 2, system: 2), "信息流的红点是同一份")

        XCTAssertEqual(notes.rows.first, .header(.today))
        let first = try XCTUnwrap(rowIndex(notes) { _ in true })
        guard case .notification(let row) = notes.rows[first] else { return XCTFail("应该是通知行") }
        XCTAssertEqual(row.actorIds.count, 3, "sample-0 上三个人的赞合成一行")
        let rowCell = try XCTUnwrap(cell(notes, first, as: FeedNotificationCell.self))
        XCTAssertEqual(rowCell.unreadDot.alpha, 1, "这次仍按服务端的已读状态画小点")
        XCTAssertTrue(rowCell.accessibilityLabel?.contains(FeedNotificationsViewController.summaryText(notes.presentation.summary(for: row))) ?? false)
        XCTAssertTrue(notes.presentation.canLoadMore)
    }

    @MainActor
    func testScrollingToTheEndLoadsTheNextPage() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()
        let before = notes.store.state.tab(FeedAPI.notificationsInteractions).items.count
        XCTAssertEqual(before, 30)
        let last = notes.rows.count - 1
        notes.tableView(notes.notificationsTableView, willDisplay: UITableViewCell(), forRowAt: IndexPath(row: last, section: 0))
        await notes.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertEqual(notes.store.state.tab(FeedAPI.notificationsInteractions).items.count, 36)
        XCTAssertFalse(notes.presentation.canLoadMore, "36 < 一页再来一页，没有下一页了")
    }

    @MainActor
    func testSwitchingTabsLoadsThemAndShowsTheirRows() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()
        notes.tabControl.selectedSegmentIndex = 1
        notes.tabControl.sendActions(for: .valueChanged)
        await notes.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertEqual(notes.presentation.tab, FeedAPI.notificationsFollows)
        XCTAssertTrue(notes.rows.contains { if case .notification(let r) = $0 { return r.kind == FeedNotification.kindFollowRequest }; return false })
        XCTAssertEqual(harness.feed.store.notificationUnread, FeedUnreadCounts(system: 2), "新关注栏也标了已读")

        notes.tabControl.selectedSegmentIndex = 2
        notes.tabControl.sendActions(for: .valueChanged)
        await notes.store.waitForTasks()
        XCTAssertEqual(notes.presentation.tab, FeedAPI.notificationsSystem)
        XCTAssertEqual(harness.feed.store.notificationUnread, FeedUnreadCounts())
    }

    @MainActor
    func testStatusTextsForEveryTabAndState() {
        for tab in FeedNotificationsStore.tabs {
            XCTAssertNotNil(FeedNotificationsViewController.statusTexts(for: .empty(tab: tab)).title)
            XCTAssertFalse(FeedNotificationsViewController.tabTitle(tab, badge: 0).isEmpty)
        }
        XCTAssertTrue(FeedNotificationsViewController.statusTexts(for: .loading).spins)
        XCTAssertTrue(FeedNotificationsViewController.statusTexts(for: .loadingMore).spins)
        XCTAssertTrue(FeedNotificationsViewController.statusTexts(for: .failed(retryAfterSeconds: nil)).retry)
        XCTAssertNil(FeedNotificationsViewController.statusTexts(for: .failed(retryAfterSeconds: nil)).body)
        XCTAssertEqual(FeedNotificationsViewController.statusTexts(for: .loadMoreFailed(retryAfterSeconds: 9)).body, FeedProfileViewController.throttledText(9))
        XCTAssertTrue(FeedNotificationsViewController.tabTitle(FeedAPI.notificationsSystem, badge: 120).hasSuffix("99+"))
    }

    // MARK: - 点一行

    @MainActor
    func testTappingALikeOpensThePostDetailOnTheFeedsCopyAndTheDetailTakesTheLease() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()
        let row = try XCTUnwrap(rowIndex(notes) { $0.kind == FeedNotification.kindLike })
        notes.tableView(notes.notificationsTableView, didSelectRowAt: IndexPath(row: row, section: 0))
        await waitUntil { harness.navigation.topViewController is FeedPostDetailViewController }
        XCTAssertTrue(harness.navigation.topViewController is FeedPostDetailViewController)
        XCTAssertNotNil(harness.feed.store.card(id: "sample-0"), "卡片换进了信息流 store")
        XCTAssertNil(notes.store.state.openCard)
        XCTAssertEqual(notes.store.leaseCount, 0, "详情页自己借着之后，通知页放手")
    }

    @MainActor
    func testTappingAFollowOpensTheirProfileAndASystemRowDoesNothing() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications(tab: FeedAPI.notificationsFollows)
        let follow = try XCTUnwrap(rowIndex(notes) { $0.kind == FeedNotification.kindFollow })
        notes.tableView(notes.notificationsTableView, didSelectRowAt: IndexPath(row: follow, section: 0))
        XCTAssertTrue(harness.navigation.topViewController is FeedProfileViewController)
        // 推主页是 animated：转场没走完时 pop 会被忽略，等它走完再 pop
        try await Task.sleep(nanoseconds: 700_000_000)
        harness.navigation.popViewController(animated: false)
        await waitUntil { harness.navigation.topViewController === notes }

        notes.store.selectTab(FeedAPI.notificationsSystem)
        await notes.store.waitForTasks()
        harness.window.layoutIfNeeded()
        let taken = try XCTUnwrap(rowIndex(notes) { $0.systemType == FeedNotification.systemTakenDown })
        notes.tableView(notes.notificationsTableView, didSelectRowAt: IndexPath(row: taken, section: 0))
        XCTAssertTrue(harness.navigation.topViewController === notes, "被下架的通知不能点")
        let close = try XCTUnwrap(rowIndex(notes) { $0.systemType == FeedNotification.systemClosePersonRequest })
        var opened: FeedPersonSummary?
        notes.onOpenPerson = { opened = $0 }
        notes.tableView(notes.notificationsTableView, didSelectRowAt: IndexPath(row: close, section: 0))
        XCTAssertEqual(opened?.id, "s-1")
    }

    @MainActor
    func testAPostThatCannotBeOpenedGetsAToastAndNoDetail() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()
        harness.feed.store.removeCard(id: "sample-0")
        let row = try XCTUnwrap(rowIndex(notes) { $0.contentId == "sample-0" })
        notes.tableView(notes.notificationsTableView, didSelectRowAt: IndexPath(row: row, section: 0))
        await waitUntil { notes.lastToastText != nil }
        XCTAssertEqual(notes.lastToastText, FeedNotificationsViewController.toastText(for: .postGone))
        XCTAssertTrue(harness.navigation.topViewController === notes)
    }

    // MARK: - 左滑

    @MainActor
    func testSwipeActionsDependOnTheRowAndDeleteAndMuteWork() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()
        let like = try XCTUnwrap(rowIndex(notes) { $0.kind == FeedNotification.kindLike })
        XCTAssertEqual(swipeActions(notes, like).count, 3, "赞：删除 + 这条不再通知 + 只关赞")
        let comment = try XCTUnwrap(rowIndex(notes) { $0.kind == FeedNotification.kindComment })
        XCTAssertEqual(swipeActions(notes, comment).count, 2, "评论：删除 + 这条不再通知")
        XCTAssertEqual(swipeActions(notes, 0).count, 0, "分组头不能滑")

        // 只关赞：sample-0 上的赞（合成的一行）没了，toast 说了
        let muteLikes = try XCTUnwrap(swipeActions(notes, like).last)
        muteLikes.handler(muteLikes, UIView(), { _ in })
        await notes.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertNil(rowIndex(notes) { $0.contentId == "sample-0" && $0.kind == FeedNotification.kindLike })
        await waitUntil { notes.lastToastText == FeedNotificationsViewController.toastText(for: .mutedLikes) }
        XCTAssertEqual(notes.lastToastText, FeedNotificationsViewController.toastText(for: .mutedLikes))

        // 删一条评论
        let target = try XCTUnwrap(rowIndex(notes) { $0.kind == FeedNotification.kindComment })
        guard case .notification(let value) = notes.rows[target] else { return XCTFail("应该是通知行") }
        let delete = try XCTUnwrap(swipeActions(notes, target).first)
        delete.handler(delete, UIView(), { _ in })
        await notes.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertNil(rowIndex(notes) { $0.key == value.key })
        await waitUntil { notes.lastToastText == FeedNotificationsViewController.toastText(for: .deleted) }
        XCTAssertEqual(notes.lastToastText, FeedNotificationsViewController.toastText(for: .deleted))
    }

    @MainActor
    func testFollowRowsOnlyHaveDelete() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications(tab: FeedAPI.notificationsFollows)
        let follow = try XCTUnwrap(rowIndex(notes) { $0.kind == FeedNotification.kindFollow })
        XCTAssertEqual(swipeActions(notes, follow).count, 1)
    }

    @MainActor
    func testADeleteThatFailsPutsTheRowBackAndSaysSo() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()
        harness.source.simulation.failsNotificationActions = true
        let target = try XCTUnwrap(rowIndex(notes) { $0.kind == FeedNotification.kindComment })
        guard case .notification(let value) = notes.rows[target] else { return XCTFail("应该是通知行") }
        let delete = try XCTUnwrap(swipeActions(notes, target).first)
        delete.handler(delete, UIView(), { _ in })
        await notes.store.waitForTasks()
        await waitUntil { notes.lastToastText != nil }
        XCTAssertNotNil(rowIndex(notes) { $0.key == value.key }, "失败放回来")
        XCTAssertEqual(notes.lastToastText, FeedNotificationsViewController.toastText(for: .failed))
    }

    // MARK: - 失败、限速、feed_hidden

    @MainActor
    func testFirstPageFailureShowsRetryAndRetryLoads() async throws {
        let harness = await makeHarness { $0.simulation.failsNotifications = true }
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()
        XCTAssertEqual(notes.rows, [.status(.failed(retryAfterSeconds: nil))])
        let status = try XCTUnwrap(cell(notes, 0, as: FeedStatusRowCell.self))
        harness.source.simulation.failsNotifications = false
        status.retryButton.sendActions(for: .touchUpInside)
        await notes.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertEqual(notes.rows.first, .header(.today))
    }

    @MainActor
    func testThrottledFirstPageSaysHowLongToWait() async throws {
        let harness = await makeHarness { $0.simulation.notificationsThrottledRetryAfterSeconds = 12 }
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()
        XCTAssertEqual(notes.rows, [.status(.failed(retryAfterSeconds: 12))])
        XCTAssertEqual(FeedNotificationsViewController.statusTexts(for: .failed(retryAfterSeconds: 12)).body, FeedProfileViewController.throttledText(12))
    }

    @MainActor
    func testPagingFailureKeepsTheListAndShowsRetryAtTheEnd() async throws {
        let harness = await makeHarness { $0.simulation.failsNotificationsMore = true }
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()
        notes.tableView(notes.notificationsTableView, willDisplay: UITableViewCell(), forRowAt: IndexPath(row: notes.rows.count - 1, section: 0))
        await notes.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertEqual(notes.rows.last, .status(.loadMoreFailed(retryAfterSeconds: nil)))
        XCTAssertEqual(notes.store.state.tab(FeedAPI.notificationsInteractions).items.count, 30, "已有的留着")

        harness.source.simulation.failsNotificationsMore = false
        // 重试行在列表最底下：先滚到底，cellForRow 才拿得到
        notes.notificationsTableView.scrollToRow(at: IndexPath(row: notes.rows.count - 1, section: 0), at: .bottom, animated: false)
        let status = try XCTUnwrap(cell(notes, notes.rows.count - 1, as: FeedStatusRowCell.self))
        status.retryButton.sendActions(for: .touchUpInside)
        await notes.store.waitForTasks()
        XCTAssertEqual(notes.store.state.tab(FeedAPI.notificationsInteractions).items.count, 36)
    }

    @MainActor
    func testFeedHiddenClosesThePage() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.feedHidden = true
        let notes = await harness.openNotifications()
        await waitUntil { notes.didClose }
        XCTAssertTrue(notes.didClose)
        await waitUntil { harness.navigation.topViewController === harness.feed }
        XCTAssertTrue(harness.navigation.topViewController === harness.feed)
    }

    // MARK: - 和信息流同步

    @MainActor
    func testThePageFollowsTheFeedsUnreadAndLetsGoWhenPopped() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()
        XCTAssertTrue(notes.store.isObservingFeed)
        harness.feed.store.setNotificationUnread(FeedUnreadCounts(interactions: 4, follows: 2, system: 2))
        harness.window.layoutIfNeeded()
        XCTAssertEqual(notes.tabControl.titleForSegment(at: 0), FeedNotificationsViewController.tabTitle(FeedAPI.notificationsInteractions, badge: 4))

        harness.navigation.popViewController(animated: false)
        await waitUntil { !notes.store.isObservingFeed }
        XCTAssertFalse(notes.store.isObservingFeed)
        XCTAssertEqual(notes.store.leaseCount, 0)
    }

    @MainActor
    func testNamesFromAProfileLookupAppearOnTheRow() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let notes = await harness.openNotifications()
        let reply = try XCTUnwrap(rowIndex(notes) { $0.kind == FeedNotification.kindReply })
        guard case .notification(let value) = notes.rows[reply] else { return XCTFail("应该是通知行") }
        XCTAssertEqual(notes.presentation.summary(for: value), .replied(name: "夜跑的猫"), "只带 actor_id 的回复，查了主页拿到名字")
    }
}
