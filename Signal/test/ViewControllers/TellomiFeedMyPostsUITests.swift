//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 「我的动态」页的界面检查（UIKit）：在测试进程里放一个真的 `FeedViewController`（样例数据）+ 导航栏，推一个我的动态页。
/// 样例（`SampleFeedSource+MyPosts.swift`）：共 40 条，第一页 30 条（能看到翻页）：最前面 `mine-seed-p1` 审核中、`r1`…`r4` 未通过（几种原因、申诉进度）、`w1` 已撤回，
/// 后面是 `mine-seed-1`… 已发布（五档可见范围轮着来）。慢 / 失败 / 限速 / `feed_hidden` 用 `source.simulation` 的 `myPosts…` / `appeal…` 开关切，截图方法见报告。
final class TellomiFeedMyPostsUITests: XCTestCase {

    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow
        let source: SampleFeedSource

        func openMyPosts() async -> FeedMyPostsViewController {
            let page = FeedMyPostsViewController(source: source, feed: feed.store)
            navigation.pushViewController(page, animated: false)
            page.loadViewIfNeeded()
            await page.store.waitForTasks()
            window.layoutIfNeeded()
            return page
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
    private func rowIndex(_ page: FeedMyPostsViewController, id: String) -> Int? {
        return page.rows.firstIndex { row in
            if case .post(let value) = row { return value.id == id }
            return false
        }
    }

    @MainActor
    private func postRow(_ page: FeedMyPostsViewController, id: String) throws -> FeedMyPostRow {
        let index = try XCTUnwrap(rowIndex(page, id: id), "\(id) 应该在列表里")
        guard case .post(let row) = page.rows[index] else { throw XCTSkip("not a post row") }
        return row
    }

    @MainActor
    private func cell<T: UITableViewCell>(_ page: FeedMyPostsViewController, _ row: Int, as type: T.Type) -> T? {
        page.postsTableView.layoutIfNeeded()
        return page.postsTableView.cellForRow(at: IndexPath(row: row, section: 0)) as? T
    }

    @MainActor
    private func swipeActions(_ page: FeedMyPostsViewController, id: String) throws -> [UIContextualAction] {
        let index = try XCTUnwrap(rowIndex(page, id: id))
        return page.tableView(page.postsTableView, trailingSwipeActionsConfigurationForRowAt: IndexPath(row: index, section: 0))?.actions ?? []
    }

    // MARK: - 页面

    @MainActor
    func testEveryStateShowsItsChipVisibilityNotesAndOnlyAppealableRowsHaveTheButton() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        XCTAssertEqual(page.navigationItem.title, FeedMyPostsViewController.title)
        XCTAssertEqual(page.rows.count, 30)

        func check(_ id: String, status: FeedMyPostStatus, notes: Int, appeal: Bool) throws {
            let index = try XCTUnwrap(rowIndex(page, id: id))
            let cell = try XCTUnwrap(self.cell(page, index, as: FeedMyPostCell.self))
            XCTAssertEqual(cell.statusLabel.text, FeedMyPostsViewController.statusTitle(status), id)
            XCTAssertEqual(cell.notesStack.arrangedSubviews.count, notes, id)
            XCTAssertEqual(cell.appealButton.isHidden, !appeal, id)
        }
        try check("mine-seed-p1", status: .pending, notes: 1, appeal: false)
        try check("mine-seed-r1", status: .rejected, notes: 1, appeal: true)
        try check("mine-seed-r2", status: .rejected, notes: 1, appeal: true)
        try check("mine-seed-r3", status: .rejected, notes: 2, appeal: false)
        try check("mine-seed-r4", status: .rejected, notes: 2, appeal: false)
        try check("mine-seed-w1", status: .withdrawn, notes: 0, appeal: false)
        try check("mine-seed-1", status: .published, notes: 0, appeal: false)

        let p1 = try XCTUnwrap(cell(page, try XCTUnwrap(rowIndex(page, id: "mine-seed-p1")), as: FeedMyPostCell.self))
        XCTAssertEqual(p1.visibilityLabel.text, FeedVisibility.friends.title)
        XCTAssertFalse(p1.visibilityLabel.isHidden)
        let r2 = try XCTUnwrap(cell(page, try XCTUnwrap(rowIndex(page, id: "mine-seed-r2")), as: FeedMyPostCell.self))
        XCTAssertEqual(r2.visibilityLabel.text, FeedVisibility.onlyMe.title)
        let (rejected, isError) = FeedMyPostsViewController.noteText(.rejected(reasons: [.reviewUnavailable]))
        XCTAssertTrue(isError)
        XCTAssertEqual((r2.notesStack.arrangedSubviews.first as? UILabel)?.text, rejected)
        let r3 = try XCTUnwrap(cell(page, try XCTUnwrap(rowIndex(page, id: "mine-seed-r3")), as: FeedMyPostCell.self))
        XCTAssertEqual((r3.notesStack.arrangedSubviews.last as? UILabel)?.text, FeedMyPostsViewController.noteText(.appealReceived).text)
        XCTAssertTrue(r3.accessibilityLabel?.contains(FeedMyPostsViewController.statusTitle(.rejected)) ?? false)
    }

    func testTextsForEveryStatusReasonNoteAndToast() {
        let statuses: [FeedMyPostStatus] = [.published, .pending, .rejected, .withdrawn]
        XCTAssertEqual(Set(statuses.map(FeedMyPostsViewController.statusTitle)).count, 4)
        let reasons: [FeedRejectionReason] = [.prohibitedWords, .reviewUnavailable, .accountRestricted, .communityGuidelines]
        XCTAssertEqual(Set(reasons.map(FeedMyPostsViewController.reasonText)).count, 4)
        XCTAssertFalse(FeedMyPostsViewController.noteText(.pendingHint).isError)
        XCTAssertFalse(FeedMyPostsViewController.noteText(.appealUpheld).isError)
        let two = FeedMyPostsViewController.noteText(.rejected(reasons: [.prohibitedWords, .accountRestricted])).text
        XCTAssertTrue(two.contains(FeedMyPostsViewController.reasonText(.prohibitedWords)))
        XCTAssertTrue(two.contains(FeedMyPostsViewController.reasonText(.accountRestricted)))
        XCTAssertTrue(FeedMyPostsViewController.statusTexts(for: .loading).spins)
        XCTAssertTrue(FeedMyPostsViewController.statusTexts(for: .loadingMore).spins)
        XCTAssertNotNil(FeedMyPostsViewController.statusTexts(for: .empty).title)
        XCTAssertTrue(FeedMyPostsViewController.statusTexts(for: .failed(retryAfterSeconds: nil)).retry)
        XCTAssertNil(FeedMyPostsViewController.statusTexts(for: .failed(retryAfterSeconds: nil)).body)
        XCTAssertEqual(FeedMyPostsViewController.statusTexts(for: .failed(retryAfterSeconds: 7)).body, FeedProfileViewController.throttledText(7))
        XCTAssertEqual(FeedMyPostsViewController.statusTexts(for: .loadMoreFailed(retryAfterSeconds: 9)).body, FeedProfileViewController.throttledText(9))
        XCTAssertEqual(FeedMyPostsViewController.toastText(for: FeedMyPostsNotice.throttled(retryAfterSeconds: 5)), FeedProfileViewController.throttledText(5))
        XCTAssertEqual(FeedMyPostsViewController.toastText(for: FeedAppealResult.throttled(retryAfterSeconds: nil)), FeedProfileViewController.throttledText(nil))
        let toasts = [
            FeedMyPostsViewController.toastText(for: FeedMyPostsNotice.deleteFailed),
            FeedMyPostsViewController.toastText(for: FeedMyPostsNotice.postGone),
            FeedMyPostsViewController.toastText(for: FeedMyPostsNotice.failed),
            FeedMyPostsViewController.toastText(for: FeedAppealResult.sent),
            FeedMyPostsViewController.toastText(for: FeedAppealResult.already),
            FeedMyPostsViewController.toastText(for: FeedAppealResult.notRejected),
        ]
        XCTAssertEqual(Set(toasts).count, toasts.count)
    }

    @MainActor
    func testScrollingToTheEndLoadsTheNextPage() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        XCTAssertTrue(page.presentation.canLoadMore)
        page.tableView(page.postsTableView, willDisplay: UITableViewCell(), forRowAt: IndexPath(row: page.rows.count - 1, section: 0))
        await page.store.waitForTasks()
        XCTAssertEqual(page.store.state.posts.count, 40)
        XCTAssertFalse(page.presentation.canLoadMore)
    }

    // MARK: - 删除

    @MainActor
    func testSwipeActionsDependOnTheRow() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        for id in ["mine-seed-p1", "mine-seed-r3", "mine-seed-w1", "mine-seed-1"] {
            XCTAssertEqual(try swipeActions(page, id: id).map(\.title), [FeedMyPostsViewController.deleteTitle], id)
        }
        let appealable = try swipeActions(page, id: "mine-seed-r1")
        XCTAssertEqual(appealable.map(\.title), [FeedMyPostsViewController.deleteTitle, FeedMyPostsViewController.appealTitle])
        XCTAssertEqual(appealable.first?.style, .destructive)
    }

    @MainActor
    func testDeleteAsksFirstAndOnlyDeletesAfterConfirming() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        let delete = try XCTUnwrap(try swipeActions(page, id: "mine-seed-2").first)
        var completed: Bool?
        delete.handler(delete, UIView(), { completed = $0 })
        XCTAssertEqual(completed, false, "还没确认：行滑回来，不算删了")
        let alert = try XCTUnwrap(page.lastAlert)
        XCTAssertEqual(alert.actions.map(\.style), [.cancel, .destructive])
        XCTAssertEqual(alert.actions.last?.title, FeedMyPostsViewController.deleteTitle)
        XCTAssertNotNil(alert.message)
        await page.store.waitForTasks()
        XCTAssertNotNil(rowIndex(page, id: "mine-seed-2"), "确认之前什么都没发生")
        let before = try await harness.source.myPosts(before: nil).posts.map(\.id)
        XCTAssertTrue(before.contains("mine-seed-2"))

        page.deleteConfirmed(try postRow(page, id: "mine-seed-2"))
        XCTAssertNil(rowIndex(page, id: "mine-seed-2"), "马上少一行")
        await page.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertTrue(harness.feed.store.isRemoved(id: "mine-seed-2"), "信息流 store 里也去掉了")
        let after = try await harness.source.myPosts(before: nil).posts.map(\.id)
        XCTAssertFalse(after.contains("mine-seed-2"))
    }

    @MainActor
    func testAFailedDeletePutsTheRowBackAndSaysSo() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        harness.source.simulation.failsDeletes = true
        let index = try XCTUnwrap(rowIndex(page, id: "mine-seed-2"))
        page.deleteConfirmed(try postRow(page, id: "mine-seed-2"))
        await page.store.waitForTasks()
        await waitUntil { page.lastToastText != nil }
        XCTAssertEqual(rowIndex(page, id: "mine-seed-2"), index, "放回原位")
        XCTAssertEqual(page.lastToastText, FeedMyPostsViewController.toastText(for: .deleteFailed))
        XCTAssertFalse(harness.feed.store.isRemoved(id: "mine-seed-2"))
    }

    @MainActor
    func testAThrottledDeleteSaysHowLongToWait() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        harness.source.simulation.throttledRetryAfterSeconds = 14
        page.deleteConfirmed(try postRow(page, id: "mine-seed-3"))
        await page.store.waitForTasks()
        await waitUntil { page.lastToastText != nil }
        XCTAssertEqual(page.lastToastText, FeedProfileViewController.throttledText(14))
        XCTAssertNotNil(rowIndex(page, id: "mine-seed-3"))
    }

    // MARK: - 申诉

    @MainActor
    func testAppealDialogAsksForAReasonAndSendingMarksTheRow() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        page.presentAppeal(try postRow(page, id: "mine-seed-r1"))
        let alert = try XCTUnwrap(page.lastAlert)
        XCTAssertEqual(alert.textFields?.count, 1)
        XCTAssertNotNil(alert.textFields?.first?.placeholder)
        XCTAssertEqual(alert.actions.map(\.style), [.cancel, .default])

        page.appealSubmitted(try postRow(page, id: "mine-seed-r1"), text: "  please look again  ")
        await page.store.waitForTasks()
        await waitUntil { page.lastToastText != nil }
        XCTAssertEqual(page.lastToastText, FeedMyPostsViewController.toastText(for: FeedAppealResult.sent))
        harness.window.layoutIfNeeded()
        let index = try XCTUnwrap(rowIndex(page, id: "mine-seed-r1"))
        let cell = try XCTUnwrap(self.cell(page, index, as: FeedMyPostCell.self))
        XCTAssertTrue(cell.appealButton.isHidden, "申诉过了：按钮没了")
        XCTAssertEqual(cell.notesStack.arrangedSubviews.count, 2, "多了「复核中」")
        XCTAssertEqual(try swipeActions(page, id: "mine-seed-r1").count, 1)
    }

    @MainActor
    func testNoAppealDialogForRowsThatCannotBeAppealed() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        for id in ["mine-seed-w1", "mine-seed-r3", "mine-seed-p1", "mine-seed-1"] {
            page.presentAppeal(try postRow(page, id: id))
        }
        XCTAssertNil(page.lastAlert, "已撤回的引擎当前不收申诉；复核中 / 审核中 / 已发布的更不用")
        XCTAssertTrue(harness.navigation.topViewController === page)
    }

    @MainActor
    func testAppealErrorsGetTheirOwnToasts() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        harness.source.simulation.appealsAlreadyAppealed = true
        page.appealSubmitted(try postRow(page, id: "mine-seed-r1"), text: "x")
        await page.store.waitForTasks()
        await waitUntil { page.lastToastText != nil }
        XCTAssertEqual(page.lastToastText, FeedMyPostsViewController.toastText(for: FeedAppealResult.already))

        harness.source.simulation.appealsAlreadyAppealed = false
        harness.source.simulation.failsAppeals = true
        page.appealSubmitted(try postRow(page, id: "mine-seed-r2"), text: "x")
        await page.store.waitForTasks()
        await waitUntil { page.lastToastText == FeedMyPostsViewController.toastText(for: FeedAppealResult.failed) }
        XCTAssertEqual(page.lastToastText, FeedMyPostsViewController.toastText(for: FeedAppealResult.failed))
    }

    // MARK: - 点一行

    @MainActor
    func testTappingAPublishedPostOpensTheDetailOnTheFeedsCopy() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        let index = try XCTUnwrap(rowIndex(page, id: "mine-seed-1"))
        page.tableView(page.postsTableView, didSelectRowAt: IndexPath(row: index, section: 0))
        await waitUntil { harness.navigation.topViewController is FeedPostDetailViewController }
        XCTAssertTrue(harness.navigation.topViewController is FeedPostDetailViewController)
        XCTAssertNotNil(harness.feed.store.card(id: "mine-seed-1"), "卡片换进了信息流 store")
        XCTAssertNil(page.store.state.openCard)
        XCTAssertEqual(page.store.leaseCount, 0, "详情页自己借着之后，这边放手")
    }

    @MainActor
    func testTappingAPendingRejectedOrWithdrawnRowDoesNothing() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        for id in ["mine-seed-p1", "mine-seed-r1", "mine-seed-w1"] {
            let index = try XCTUnwrap(rowIndex(page, id: id))
            page.tableView(page.postsTableView, didSelectRowAt: IndexPath(row: index, section: 0))
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(harness.navigation.topViewController === page)
        XCTAssertNil(page.store.state.openCard)
    }

    // MARK: - 失败、限速、feed_hidden

    @MainActor
    func testFirstPageFailureShowsRetryAndRetryLoads() async throws {
        let harness = await makeHarness { $0.simulation.failsMyPosts = true }
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        XCTAssertEqual(page.rows, [.status(.failed(retryAfterSeconds: nil))])
        let status = try XCTUnwrap(cell(page, 0, as: FeedStatusRowCell.self))
        harness.source.simulation.failsMyPosts = false
        status.retryButton.sendActions(for: .touchUpInside)
        await page.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertEqual(page.rows.count, 30)
    }

    @MainActor
    func testThrottledFirstPageSaysHowLongToWait() async throws {
        let harness = await makeHarness { $0.simulation.myPostsThrottledRetryAfterSeconds = 12 }
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        XCTAssertEqual(page.rows, [.status(.failed(retryAfterSeconds: 12))])
    }

    @MainActor
    func testPagingFailureKeepsTheListAndShowsRetryAtTheEnd() async throws {
        let harness = await makeHarness { $0.simulation.failsMyPostsMore = true }
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        page.tableView(page.postsTableView, willDisplay: UITableViewCell(), forRowAt: IndexPath(row: page.rows.count - 1, section: 0))
        await page.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertEqual(page.rows.last, .status(.loadMoreFailed(retryAfterSeconds: nil)))
        XCTAssertEqual(page.store.state.posts.count, 30, "已有的留着")
        XCTAssertFalse(page.presentation.canLoadMore)

        harness.source.simulation.failsMyPostsMore = false
        // 重试行在列表最底下：先滚到底，cellForRow 才拿得到
        page.postsTableView.scrollToRow(at: IndexPath(row: page.rows.count - 1, section: 0), at: .bottom, animated: false)
        let status = try XCTUnwrap(cell(page, page.rows.count - 1, as: FeedStatusRowCell.self))
        status.retryButton.sendActions(for: .touchUpInside)
        await page.store.waitForTasks()
        XCTAssertEqual(page.store.state.posts.count, 40)
    }

    @MainActor
    func testFeedHiddenClosesThePage() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.feedHidden = true
        let page = await harness.openMyPosts()
        await waitUntil { page.didClose }
        XCTAssertTrue(page.didClose)
        await waitUntil { harness.navigation.topViewController === harness.feed }
        XCTAssertTrue(harness.navigation.topViewController === harness.feed)
    }

    // MARK: - 和信息流同步

    @MainActor
    func testAPostDeletedElsewhereDisappearsWhenThePageComesBackAndPoppingLetsGo() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openMyPosts()
        XCTAssertTrue(page.store.isObservingFeed)
        harness.feed.store.removeCard(id: "mine-seed-5")   // 详情页里删的
        page.viewWillAppear(false)
        harness.window.layoutIfNeeded()
        XCTAssertNil(rowIndex(page, id: "mine-seed-5"))

        harness.navigation.popViewController(animated: false)
        await waitUntil { !page.store.isObservingFeed }
        XCTAssertFalse(page.store.isObservingFeed)
        XCTAssertEqual(page.store.leaseCount, 0)
    }
}
