//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 帖子详情页的界面检查（UIKit）：在测试进程里放一个真的 `FeedViewController`（样例数据）+ 导航栏，点开一条帖子，看详情页和列表是不是共用同一个 `FeedStore`。
/// 真 App 在无签名模拟器里起不来（App Group），所以界面都在测试进程里渲染、检查；截图的写法见 `docs`/报告里的「截图方法」。
final class TellomiFeedDetailUITests: XCTestCase {

    /// 一个放着真 `FeedViewController` 的窗口。
    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow

        var store: FeedStore { feed.store }

        /// 和用户点一行一样：走列表的 `didSelectRowAt`，所以走的是真的接线（`onOpenPost` → `openPost` → push）。
        func openPost(row: Int) -> FeedPostDetailViewController? {
            let table = feed.pages[0].tableView
            table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: row, section: 0))
            window.layoutIfNeeded()
            let detail = navigation.topViewController as? FeedPostDetailViewController
            detail?.loadViewIfNeeded()
            window.layoutIfNeeded()
            return detail
        }

        func pop() {
            navigation.popViewController(animated: false)
            window.layoutIfNeeded()
        }
    }

    @MainActor
    private func makeHarness(source: SampleFeedSource) async -> Harness {
        let feed = FeedViewController(source: source)
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

    private func quickSource() -> SampleFeedSource {
        return SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
    }

    // MARK: - (a) 详情页和列表共用一个 FeedStore

    /// 点开一条帖子：详情页拿到的是列表的 store；列表页和详情页各订一个。
    @MainActor
    func testTheDetailPageSharesTheListsStoreAndBothSubscribe() async throws {
        let harness = await makeHarness(source: quickSource())
        defer { harness.window.isHidden = true }
        XCTAssertEqual(harness.store.subscriberCount, 1, "只有列表订着")
        let cards = harness.store.tab(.recommend).cards
        let detail = try XCTUnwrap(harness.openPost(row: 1))
        XCTAssertEqual(detail.detailStore.state.post.id, cards[1].id)
        XCTAssertTrue(detail.detailStore.isObservingFeed)
        XCTAssertEqual(harness.store.subscriberCount, 2, "列表 + 详情")
        harness.pop()
        harness.window.isHidden = true
    }

    /// 详情页退出（弹出）后放掉订阅和借着的卡片，列表还订着。
    @MainActor
    func testPoppingTheDetailReleasesItsSubscriptionAndBorrowedCard() async throws {
        let harness = await makeHarness(source: quickSource())
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 2))
        XCTAssertEqual(harness.store.subscriberCount, 2)
        harness.pop()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(detail.detailStore.isObservingFeed)
        XCTAssertEqual(harness.store.subscriberCount, 1)
    }

    /// 详情页里改了点赞（走和点按钮一样的 `toggleLike`），列表那一行马上跟着变；两边读到的是 store 里同一张卡片。
    @MainActor
    func testALikeChangedInTheDetailUpdatesTheListRow() async throws {
        let harness = await makeHarness(source: quickSource())
        defer { harness.window.isHidden = true }
        let before = harness.store.tab(.recommend).cards[3]
        XCTAssertFalse(before.viewer.liked)
        let detail = try XCTUnwrap(harness.openPost(row: 3))
        detail.detailStore.toggleLike()
        XCTAssertTrue(detail.detailStore.state.post.viewer.liked)
        XCTAssertTrue(harness.feed.pages[0].rows[3].card.viewer.liked, "列表那一行已经画成点过赞")
        XCTAssertEqual(harness.feed.pages[0].rows[3].card.stats.likes, before.stats.likes + 1)
        XCTAssertEqual(harness.store.card(id: before.id), detail.detailStore.state.post)
        await detail.detailStore.waitForTasks()
        harness.pop()
        harness.window.isHidden = true
    }

    /// 列表里点的赞，已经打开着的详情页也跟着变（详情只是从 store 重读）。
    @MainActor
    func testALikeChangedInTheListUpdatesTheOpenDetail() async throws {
        let harness = await makeHarness(source: quickSource())
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 3))
        let card = harness.store.tab(.recommend).cards[3]
        harness.store.toggleLike(card)
        XCTAssertTrue(detail.detailStore.state.post.viewer.liked)
        await harness.store.waitForActions()
        harness.pop()
        harness.window.isHidden = true
    }

    /// 详情页的帖子那一格在行没变时就地更新（不整表重载）：点赞后那一格上的数字变了。
    @MainActor
    func testTheDetailPostCellUpdatesInPlaceWhenTheLikeChanges() async throws {
        let harness = await makeHarness(source: quickSource())
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 3))
        try await Task.sleep(nanoseconds: 100_000_000)
        let cell = try XCTUnwrap(detail.postCell)
        let likes = cell.card?.stats.likes
        detail.detailStore.toggleLike()
        XCTAssertTrue(cell === detail.postCell, "还是同一个格子")
        XCTAssertEqual(detail.postCell?.card?.stats.likes, (likes ?? 0) + 1)
        await detail.detailStore.waitForTasks()
        harness.pop()
        harness.window.isHidden = true
    }

    // MARK: - 给截图用的中间状态

    /// 样例的「已不可见」可以拖慢：先显示帖子，Card API 回来才变成「已不可见」。
    @MainActor
    func testSample7ShowsThePostFirstThenGoneWhenTheCardLatencyIsSet() async throws {
        let source = quickSource()
        source.simulation.cardLatencyNanos = 800_000_000
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 7))
        XCTAssertEqual(detail.detailStore.state.post.id, "sample-7")
        XCTAssertFalse(detail.detailTableView.isHidden, "Card API 还没回来：显示帖子")
        await detail.detailStore.waitForTasks()
        detail.view.layoutIfNeeded()
        XCTAssertTrue(detail.detailTableView.isHidden, "回来了：已不可见")
        harness.pop()
        harness.window.isHidden = true
    }
}
