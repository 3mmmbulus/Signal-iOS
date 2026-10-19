//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 话题页的界面检查（UIKit）：在测试进程里放一个真的 `FeedViewController`（样例数据）+ 导航栏，推一个话题页。
/// 样例话题：`daily` 日常、`food` 美食（已关注）、`outdoors` 户外、`reading` 读书；别的 slug 是「找不到」。
/// 各种失败 / 慢 / 限速用 `source.simulation` 的 `topic…` 开关切，截图方法见报告。
final class TellomiFeedTopicUITests: XCTestCase {

    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow
        let source: SampleFeedSource

        func openTopic(_ slug: String, label: String? = nil, wait: Bool = true) async -> FeedTopicViewController {
            let topic = FeedTopicViewController(slug: slug, labelHint: label, source: source, feed: feed.store)
            navigation.pushViewController(topic, animated: false)
            topic.loadViewIfNeeded()
            window.layoutIfNeeded()
            if wait {
                await topic.store.waitForTasks()
                window.layoutIfNeeded()
            }
            return topic
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
    private func header(of topic: FeedTopicViewController) -> FeedTopicHeaderCell? {
        topic.topicTableView.layoutIfNeeded()
        return topic.topicTableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? FeedTopicHeaderCell
    }

    @MainActor
    private func statusCell(of topic: FeedTopicViewController, at row: Int) -> FeedStatusRowCell? {
        topic.topicTableView.layoutIfNeeded()
        return topic.topicTableView.cellForRow(at: IndexPath(row: row, section: 0)) as? FeedStatusRowCell
    }

    /// 等一个条件成立（最多 3 秒）：弹出 / 提示这类在「下一轮主线程」里发生的事。
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<60 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - 显示

    @MainActor
    func testATopicShowsItsNameTheFollowButtonAndThePostsAndPagesOnDemand() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let topic = await harness.openTopic("food", label: "美食")

        XCTAssertEqual(topic.presentation.page, .content)
        XCTAssertEqual(topic.rows.first, .header)
        XCTAssertEqual(topic.rows.count, 1 + SampleFeedSource.topicPostsPageSize)
        XCTAssertEqual(topic.navigationItem.title, "#美食")
        let cell = try XCTUnwrap(header(of: topic))
        XCTAssertEqual(cell.followButton.configuration?.title, FeedTopicViewController.followTitle(for: .following), "样例里 food 已关注")
        XCTAssertTrue(cell.followButton.isEnabled)
        XCTAssertTrue(topic.presentation.posts.allSatisfy { $0.topics.contains { $0.slug == "food" } })
        XCTAssertTrue(topic.presentation.canLoadMore)

        topic.store.loadMore()
        await topic.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertGreaterThan(topic.rows.count, 1 + SampleFeedSource.topicPostsPageSize, "翻页：又来了一页")
    }

    @MainActor
    func testTheTitleFallsBackToTheHintThenTheSlugWhileNothingIsLoaded() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.topicLatencyNanos = 400_000_000
        let hinted = await harness.openTopic("daily", label: "日常", wait: false)
        XCTAssertEqual(hinted.navigationItem.title, "#日常")
        XCTAssertEqual(hinted.rows, [.status(.loading)])
        await hinted.store.waitForTasks()
        harness.navigation.popViewController(animated: false)

        harness.source.simulation.topicLatencyNanos = 0
        let bare = await harness.openTopic("reading", wait: false)
        XCTAssertEqual(bare.navigationItem.title, "#reading")
        await bare.store.waitForTasks()
        XCTAssertEqual(bare.navigationItem.title, "#读书", "取回来的帖子带着话题名")
    }

    @MainActor
    func testAnUnknownTopicSaysItIsNotFoundWithoutAFollowButton() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let topic = await harness.openTopic("nope")
        XCTAssertEqual(topic.rows, [.status(.gone)])
        XCTAssertEqual(topic.presentation.followButton, .hidden)
        let texts = FeedTopicViewController.statusTexts(for: .gone)
        XCTAssertNotNil(texts.title)
        XCTAssertNotNil(texts.body)
        XCTAssertFalse(texts.retry, "不存在的话题重试也没用")
    }

    // MARK: - 失败 / 限速

    @MainActor
    func testLoadFailureShowsRetryAndThrottleSaysHowLong() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.failsTopic = true
        let topic = await harness.openTopic("daily")
        XCTAssertEqual(topic.rows, [.status(.failed(retryAfterSeconds: nil))])
        XCTAssertEqual(topic.presentation.followButton, .hidden)
        let failedCell = try XCTUnwrap(statusCell(of: topic, at: 0))
        XCTAssertFalse(failedCell.retryButton.isHidden)

        harness.source.simulation.failsTopic = false
        harness.source.simulation.topicThrottledRetryAfterSeconds = 25
        failedCell.retryButton.sendActions(for: .touchUpInside)
        await topic.store.waitForTasks()
        XCTAssertEqual(topic.rows, [.status(.failed(retryAfterSeconds: 25))])
        XCTAssertTrue(FeedTopicViewController.statusTexts(for: .failed(retryAfterSeconds: 25)).body?.contains("25") ?? false)

        harness.source.simulation.topicThrottledRetryAfterSeconds = nil
        topic.store.refresh()
        await topic.store.waitForTasks()
        XCTAssertEqual(topic.presentation.page, .content, "重试成功")
    }

    @MainActor
    func testAFailedLoadMoreKeepsThePostsAndTheRetryRowWorks() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let topic = await harness.openTopic("food")
        let before = topic.presentation.posts.map(\.id)

        harness.source.simulation.failsTopicMore = true
        topic.store.loadMore()
        await topic.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertEqual(topic.presentation.page, .content, "翻页失败不是整页失败")
        XCTAssertEqual(topic.presentation.posts.map(\.id), before)
        XCTAssertEqual(topic.rows.last, .status(.loadMoreFailed(retryAfterSeconds: nil)))
        XCTAssertFalse(topic.presentation.canLoadMore, "失败后不自己一直重试")
        // 重试行在列表最底下：先滚到底，cellForRow 才拿得到
        topic.topicTableView.scrollToRow(at: IndexPath(row: topic.rows.count - 1, section: 0), at: .bottom, animated: false)
        let retryCell = try XCTUnwrap(statusCell(of: topic, at: topic.rows.count - 1))
        XCTAssertFalse(retryCell.retryButton.isHidden)

        harness.source.simulation.failsTopicMore = false
        retryCell.retryButton.sendActions(for: .touchUpInside)
        await topic.store.waitForTasks()
        XCTAssertGreaterThan(topic.presentation.posts.count, before.count)
        XCTAssertFalse(topic.rows.contains(.status(.loadMoreFailed(retryAfterSeconds: nil))))
    }

    @MainActor
    func testFeedHiddenClosesThePage() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let topic = await harness.openTopic("daily")
        XCTAssertTrue(harness.navigation.topViewController === topic)

        harness.source.simulation.feedHidden = true
        topic.store.refresh()
        await topic.store.waitForTasks()
        await waitUntil { harness.navigation.topViewController !== topic }
        XCTAssertTrue(topic.didClose)
        XCTAssertTrue(harness.navigation.topViewController === harness.feed, "回到信息流，不是停在「加载失败」")
    }

    // MARK: - 关注话题

    @MainActor
    func testFollowingAndUnfollowingChangeTheButtonAndSayWhatHappened() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let topic = await harness.openTopic("daily")
        let cell = try XCTUnwrap(header(of: topic))
        XCTAssertEqual(cell.followButton.configuration?.title, FeedTopicViewController.followTitle(for: .follow))

        cell.followButton.sendActions(for: .touchUpInside)
        await topic.store.waitForTasks()
        await waitUntil { topic.lastToastText != nil }
        XCTAssertEqual(topic.presentation.followButton, .following)
        XCTAssertEqual(header(of: topic)?.followButton.configuration?.title, FeedTopicViewController.followTitle(for: .following))
        XCTAssertEqual(topic.lastToastText, FeedTopicViewController.toastText(for: .followed))

        header(of: topic)?.followButton.sendActions(for: .touchUpInside)
        await topic.store.waitForTasks()
        await waitUntil { topic.lastToastText == FeedTopicViewController.toastText(for: .unfollowed) }
        XCTAssertEqual(topic.presentation.followButton, .follow)
        XCTAssertEqual(topic.lastToastText, FeedTopicViewController.toastText(for: .unfollowed))
    }

    @MainActor
    func testAFailedFollowGoesBackAndSaysSo() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.failsTopicFollow = true
        let topic = await harness.openTopic("daily")
        topic.followTapped()
        await topic.store.waitForTasks()
        await waitUntil { topic.lastToastText != nil }
        XCTAssertEqual(topic.presentation.followButton, .follow, "没成功：按钮回到「关注」")
        XCTAssertEqual(topic.lastToastText, FeedTopicViewController.toastText(for: .failed))
    }

    @MainActor
    func testAThrottledFollowSaysHowLong() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let topic = await harness.openTopic("daily")
        harness.source.simulation.throttledRetryAfterSeconds = 40
        topic.followTapped()
        await topic.store.waitForTasks()
        await waitUntil { topic.lastToastText != nil }
        XCTAssertTrue(topic.lastToastText?.contains("40") ?? false)
        XCTAssertEqual(topic.presentation.followButton, .follow)
    }

    // MARK: - 和信息流同步

    @MainActor
    func testALikeHereIsTheSameLikeInTheFeedStoreAndThePageLetsGoWhenPopped() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let topic = await harness.openTopic("food")
        XCTAssertTrue(topic.store.isObservingFeed)
        XCTAssertGreaterThan(topic.store.leaseCount, 0)
        let card = try XCTUnwrap(topic.presentation.posts.first)
        let wasLiked = card.viewer.liked

        topic.store.toggleLike(card)
        await topic.store.waitForTasks()
        XCTAssertEqual(harness.feed.store.card(id: card.id)?.viewer.liked, !wasLiked, "信息流 store 里是同一份")
        XCTAssertEqual(topic.presentation.posts.first?.viewer.liked, !wasLiked)

        harness.navigation.popViewController(animated: false)
        await waitUntil { !topic.store.isObservingFeed }
        XCTAssertFalse(topic.store.isObservingFeed)
        XCTAssertEqual(topic.store.leaseCount, 0)
    }

    @MainActor
    func testTappingAPostOpensItsDetailAndAnAuthorTapIsWiredOnlyWhenGiven() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let topic = await harness.openTopic("food")
        let postIndex = try XCTUnwrap(topic.rows.firstIndex { if case .post = $0 { return true } else { return false } })
        let cell = try XCTUnwrap(topic.topicTableView.cellForRow(at: IndexPath(row: postIndex, section: 0)) as? FeedPostCell)
        XCTAssertNil(cell.onAuthorTap, "没给作者入口就不响应")
        XCTAssertTrue(cell.isReadOnly)

        topic.onOpenAuthor = { _ in }
        topic.topicTableView.reloadData()
        topic.topicTableView.layoutIfNeeded()
        harness.window.layoutIfNeeded()
        // reloadData 之后表格要过一轮 run loop 才把单元格重新取出来
        await waitUntil { topic.topicTableView.cellForRow(at: IndexPath(row: postIndex, section: 0)) is FeedPostCell }
        let again = try XCTUnwrap(topic.topicTableView.cellForRow(at: IndexPath(row: postIndex, section: 0)) as? FeedPostCell, "visible=\(topic.topicTableView.indexPathsForVisibleRows ?? []) rows=\(topic.rows.count) postIndex=\(postIndex)")
        XCTAssertNotNil(again.onAuthorTap)

        var opened: FeedCard?
        topic.onOpenPost = { opened = $0 }
        topic.tableView(topic.topicTableView, didSelectRowAt: IndexPath(row: postIndex, section: 0))
        XCTAssertEqual(opened?.id, topic.presentation.posts.first?.id)

        topic.onOpenPost = nil
        topic.tableView(topic.topicTableView, didSelectRowAt: IndexPath(row: postIndex, section: 0))
        await waitUntil { harness.navigation.topViewController is FeedPostDetailViewController }
        XCTAssertTrue(harness.navigation.topViewController is FeedPostDetailViewController)
    }
}
