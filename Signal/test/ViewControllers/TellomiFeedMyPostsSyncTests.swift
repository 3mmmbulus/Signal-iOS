//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 「我的动态」的逻辑层（第四轮）：删除和 `FeedStore` 同步（单一数据源）、点开已发布的帖子走 `FeedCardMirror`、
/// 错误分类（5xx / Retry-After / `feed_hidden`）、翻页失败和首页失败分开、申诉只给「未通过且能申诉」的（已撤回的引擎当前不收）、
/// 页面要画什么（`FeedMyPostsPresentation`）、样例数据。界面（UIKit）不在这里测。

private struct MBoom: Error {}

private actor MGate {
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let all = waiters
        waiters = []
        all.forEach { $0.resume() }
    }
}

private final class MSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = [String]()
    var calls: [String] { lock.withLock { _calls } }
    func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
    private func log(_ call: String) { lock.withLock { _calls.append(call) } }

    var pages = [String: FeedMyPostsPage]()
    var listError: Error?
    var listErrorOnlyForBefore = false
    var deleteError: Error?
    var appealError: Error?
    var cards = [String: FeedCard]()
    var cardError: Error?
    private var gates = [String: MGate]()
    func hold(_ key: String, _ gate: MGate) { lock.withLock { gates[key] = gate } }
    private func gate(_ key: String) -> MGate? { lock.withLock { gates[key] } }

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage(cards: []) }
    func setLiked(contentId: String, liked: Bool) async throws { log("like \(contentId) \(liked)") }
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw MBoom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func myPosts(before: String?) async throws -> FeedMyPostsPage {
        log("list \(before ?? "-")")
        if let gate = gate("list \(before ?? "-")") { await gate.wait() }
        if let listError, !listErrorOnlyForBefore || before != nil { throw listError }
        return pages[before ?? ""] ?? FeedMyPostsPage()
    }

    func deletePost(contentId: String) async throws {
        log("delete \(contentId)")
        if let gate = gate("delete \(contentId)") { await gate.wait() }
        if let deleteError { throw deleteError }
    }

    func appeal(contentId: String, text: String) async throws {
        log("appeal \(contentId) \(text)")
        if let appealError { throw appealError }
    }

    func card(contentId: String) async throws -> FeedCard? {
        log("card \(contentId)")
        if let cardError { throw cardError }
        return cards[contentId]
    }
}

private let t0 = FeedDates.parse("2026-10-18T12:00:00Z")!

private func throttled(_ seconds: Int? = 20) -> FeedAPIError { FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds) }
private let hidden = FeedAPIError(status: 404, code: "feed_hidden")
private let serverError = FeedAPIError(status: 503, code: "unavailable")

private func mine(_ id: String, state: String = "published", kind: String = "post", appealable: Bool = false, appealState: String? = nil) -> FeedMyPost {
    FeedMyPost(id: id, state: state, kind: kind, text: "t \(id)", createdAt: FeedDates.format(t0), appealable: appealable, appealState: appealState)
}

private func postCard(_ id: String, author: String = "me", likes: Int = 0) -> FeedCard {
    var c = FeedCard(id: id, kind: FeedCard.kindPost, author: FeedAuthor(profileId: author, displayName: author), text: "t \(id)")
    c.stats.likes = likes
    return c
}

private func waitForArrival(_ gate: MGate) async {
    for _ in 0..<200 where await gate.arrivals == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
}

// MARK: - 删除和信息流同步

@MainActor
final class TellomiFeedMyPostsFeedSyncTests: XCTestCase {
    private func started(_ source: MSource, posts: [FeedMyPost]? = nil) async -> (FeedStore, FeedMyPostsStore) {
        source.pages[""] = FeedMyPostsPage(posts: posts ?? [mine("a"), mine("b"), mine("c")], nextBefore: nil)
        let feed = FeedStore(source: source, now: { t0 }, jitter: { 0 })
        let store = FeedMyPostsStore(source: source, feed: feed)
        store.start()
        await store.waitForTasks()
        return (feed, store)
    }

    func testADeleteThatSucceedsRemovesTheCardFromTheFeedToo() async {
        let source = MSource()
        let (feed, store) = await started(source)
        XCTAssertFalse(feed.isRemoved(id: "b"))
        store.delete(mine("b"))
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "c"], "马上少一行")
        XCTAssertFalse(feed.isRemoved(id: "b"), "引擎还没说成，信息流里的先不动")
        await store.waitForTasks()
        XCTAssertTrue(feed.isRemoved(id: "b"))
        XCTAssertNil(store.state.notice)
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "c"])
    }

    func testAFailedDeleteLeavesTheFeedAloneAndPutsTheRowBack() async {
        let source = MSource()
        source.deleteError = FeedAPIError(status: 403, code: "not_author")
        let (feed, store) = await started(source)
        store.delete(mine("b"))
        await store.waitForTasks()
        XCTAssertFalse(feed.isRemoved(id: "b"))
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b", "c"], "放回原位")
        XCTAssertEqual(store.state.notice, .deleteFailed)
        XCTAssertTrue(store.state.deleteFailed)
        store.onDeleteFailureShown()
        XCTAssertNil(store.state.notice)
    }

    func testAnAlreadyDeletedPostIsTreatedAsDeletedNotAsAFailure() async {
        let source = MSource()
        source.deleteError = FeedAPIError(status: 404, code: "not_found")
        let (feed, store) = await started(source)
        store.delete(mine("b"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "c"])
        XCTAssertNil(store.state.notice)
        XCTAssertTrue(feed.isRemoved(id: "b"))
    }

    func testDeleteErrorsAreClassified() async {
        let source = MSource()
        source.deleteError = throttled(42)
        let (feed, store) = await started(source)
        store.delete(mine("a"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .throttled(retryAfterSeconds: 42))
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b", "c"])
        store.onNoticeShown()

        source.deleteError = FeedAPIError(status: 503, code: "unavailable", retryAfterSeconds: 30)
        store.delete(mine("a"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .throttled(retryAfterSeconds: 30), "带 Retry-After 的 503 = 限速")
        store.onNoticeShown()

        source.deleteError = serverError
        store.delete(mine("a"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .deleteFailed, "不带 Retry-After 的 5xx 就是失败")
        store.onNoticeShown()

        source.deleteError = hidden
        store.delete(mine("a"))
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden, "feed_hidden：页面收起")
        XCTAssertNil(store.state.notice)
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(feed.isRemoved(id: "a"))
    }

    func testARefreshWhileADeleteIsInFlightDoesNotBringTheRowBack() async {
        let source = MSource()
        let gate = MGate()
        source.hold("delete b", gate)
        let (feed, store) = await started(source)
        store.delete(mine("b"))
        await waitForArrival(gate)
        store.refresh()
        await Task.yield()
        for _ in 0..<50 where store.state.loading { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "c"], "引擎的列表里还有 b，但正在删")
        await gate.open()
        await store.waitForTasks()
        XCTAssertTrue(feed.isRemoved(id: "b"))
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "c"])
    }

    func testAFailedDeleteWhileRefreshedStillRestoresTheRow() async {
        let source = MSource()
        let gate = MGate()
        source.hold("delete b", gate)
        source.deleteError = MBoom()
        let (_, store) = await started(source)
        store.delete(mine("b"))
        await waitForArrival(gate)
        store.refresh()
        for _ in 0..<50 where store.state.loading { try? await Task.sleep(nanoseconds: 10_000_000) }
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id).sorted(), ["a", "b", "c"])
        XCTAssertEqual(store.state.notice, .deleteFailed)
        store.refresh()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b", "c"], "删失败了，后面的刷新里 b 又正常出现")
    }

    func testDoubleDeleteOfTheSameRowSendsOneRequest() async {
        let source = MSource()
        let gate = MGate()
        source.hold("delete b", gate)
        let (_, store) = await started(source)
        store.delete(mine("b"))
        store.delete(mine("b"))
        await waitForArrival(gate)
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(source.count("delete"), 1)
    }

    func testAPostDeletedElsewhereDisappearsFromTheList() async {
        let source = MSource()
        let (feed, store) = await started(source)
        feed.ingest(postCard("b"))
        feed.removeCard(id: "b")   // 详情页里删的
        store.syncWithFeed()
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "c"])
        XCTAssertTrue(store.isObservingFeed)
    }

    func testAPostDeletedFromTheDetailWhileOpenedPrunesTheRowThroughTheSubscription() async {
        let source = MSource()
        source.cards["b"] = postCard("b")
        let (feed, store) = await started(source)
        store.openPost(mine("b"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.openCard?.id, "b")
        feed.removeCard(id: "b")   // 借着的那份不会被清，但会通知
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "c"], "订阅到删除，这一行马上去掉")
    }

    func testRefreshAndLoadMoreNeverShowARowTheFeedKnowsIsDeleted() async {
        let source = MSource()
        let (feed, store) = await started(source)
        feed.removeCard(id: "c")
        source.pages[""] = FeedMyPostsPage(posts: [mine("a"), mine("c")], nextBefore: "c")
        source.pages["c"] = FeedMyPostsPage(posts: [mine("c"), mine("d")], nextBefore: nil)
        store.refresh()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a"])
        store.loadMore()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "d"])
    }

    func testDetachStopsObservingAndDropsTheLeases() async {
        let source = MSource()
        source.cards["b"] = postCard("b")
        let (feed, store) = await started(source)
        store.openPost(mine("b"))
        await store.waitForTasks()
        XCTAssertEqual(store.leaseCount, 1)
        store.detach()
        store.detach()
        XCTAssertFalse(store.isObservingFeed)
        XCTAssertEqual(store.leaseCount, 0)
        feed.removeCard(id: "a")
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b", "c"], "不再订阅：不会因为信息流变化改动")
    }

    func testWithoutAFeedStoreThePageStillWorksAlone() async {
        let source = MSource()
        source.pages[""] = FeedMyPostsPage(posts: [mine("a")], nextBefore: nil)
        source.cards["a"] = postCard("a")
        let store = FeedMyPostsStore(source: source)
        store.start()
        await store.waitForTasks()
        store.openPost(mine("a"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.openCard?.id, "a")
        XCTAssertFalse(store.isObservingFeed)
        store.delete(mine("a"))
        await store.waitForTasks()
        XCTAssertTrue(store.state.posts.isEmpty)
    }
}

// MARK: - 点开帖子

@MainActor
final class TellomiFeedMyPostsOpenTests: XCTestCase {
    private func started(_ source: MSource) async -> (FeedStore, FeedMyPostsStore) {
        source.pages[""] = FeedMyPostsPage(posts: [mine("a"), mine("p", state: "pending"), mine("r", state: "rejected"), mine("w", state: "withdrawn"), mine("x", kind: "comment")], nextBefore: nil)
        let feed = FeedStore(source: source, now: { t0 }, jitter: { 0 })
        let store = FeedMyPostsStore(source: source, feed: feed)
        store.start()
        await store.waitForTasks()
        return (feed, store)
    }

    func testOpeningAPublishedPostAdoptsTheCardIntoTheFeedAndHandsItOver() async {
        let source = MSource()
        source.cards["a"] = postCard("a", likes: 5)
        let (feed, store) = await started(source)
        store.openPost(mine("a"))
        XCTAssertEqual(store.state.opening, "a")
        await store.waitForTasks()
        XCTAssertNil(store.state.opening)
        XCTAssertEqual(store.state.openCard?.id, "a")
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 5)
        XCTAssertEqual(store.leaseCount, 1)
        feed.toggleLike(id: "a")
        XCTAssertEqual(store.state.openCard?.stats.likes, 6, "画的是信息流里现在的样子")
        await feed.waitForActions()
        store.onCardOpened()
        XCTAssertNil(store.state.openCard)
        XCTAssertEqual(store.leaseCount, 0)
    }

    func testOnlyPublishedPostsAndArticlesOpen() async {
        let source = MSource()
        for id in ["p", "r", "w", "x"] { source.cards[id] = postCard(id) }
        let (_, store) = await started(source)
        for post in store.state.posts where post.id != "a" { store.openPost(post) }
        await store.waitForTasks()
        XCTAssertEqual(source.count("card"), 0)
        XCTAssertNil(store.state.openCard)
        XCTAssertTrue(FeedMyPostRow(post: mine("a")).canOpen)
        XCTAssertTrue(FeedMyPostRow(post: mine("a", kind: "article")).canOpen)
        XCTAssertFalse(FeedMyPostRow(post: mine("x", kind: "comment")).canOpen, "评论没有单独的页面")
    }

    func testTappingTwiceWhileOpeningAsksOnce() async {
        let source = MSource()
        source.cards["a"] = postCard("a")
        let (_, store) = await started(source)
        store.openPost(mine("a"))
        store.openPost(mine("a"))
        await store.waitForTasks()
        XCTAssertEqual(source.count("card"), 1)
    }

    func testAPostTheEngineNoLongerHasIsGoneAndTheListReloads() async {
        let source = MSource()
        let (_, store) = await started(source)
        store.openPost(mine("a"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .postGone)
        XCTAssertNil(store.state.openCard)
        XCTAssertEqual(source.count("list"), 2, "状态过时了：重新拉一遍")
    }

    func testABlockedOrDeletedPostIsGone() async {
        let source = MSource()
        source.cards["a"] = postCard("a")
        let (feed, store) = await started(source)
        feed.removeCard(id: "a")
        store.openPost(mine("a"))
        await store.waitForTasks()
        XCTAssertNil(store.state.openCard)
        XCTAssertEqual(store.state.notice, .postGone)
        XCTAssertEqual(store.leaseCount, 0)
    }

    func testOpenErrorsAreClassified() async {
        let source = MSource()
        source.pages[""] = FeedMyPostsPage(posts: [mine("a")], nextBefore: nil)
        let (_, store) = await started(source)
        source.cardError = throttled(30)
        store.openPost(mine("a"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .throttled(retryAfterSeconds: 30))
        XCTAssertNil(store.state.opening)
        store.onNoticeShown()

        source.cardError = FeedAPIError(status: 503, code: "unavailable", retryAfterSeconds: 9)
        store.openPost(mine("a"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .throttled(retryAfterSeconds: 9))
        store.onNoticeShown()

        source.cardError = serverError
        store.openPost(mine("a"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .failed)
        store.onNoticeShown()

        source.cardError = FeedAPIError(status: 404, code: "not_found")
        store.openPost(mine("a"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .postGone)
        store.onNoticeShown()

        source.cardError = hidden
        store.openPost(mine("a"))
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertNil(store.state.notice)
    }
}

// MARK: - 列表错误

@MainActor
final class TellomiFeedMyPostsListErrorTests: XCTestCase {
    private func started(_ source: MSource) async -> FeedMyPostsStore {
        let feed = FeedStore(source: source, now: { t0 }, jitter: { 0 })
        let store = FeedMyPostsStore(source: source, feed: feed)
        store.start()
        await store.waitForTasks()
        return store
    }

    func testFirstPageFailureCarriesRetryAfterOnlyForThrottles() async {
        let source = MSource()
        source.listError = throttled(33)
        var store = await started(source)
        XCTAssertTrue(store.state.failed)
        XCTAssertEqual(store.state.retryAfterSeconds, 33)
        XCTAssertFalse(store.state.loadMoreFailed)
        XCTAssertFalse(store.state.loading)

        source.listError = FeedAPIError(status: 503, code: "unavailable", retryAfterSeconds: 12)
        store = await started(source)
        XCTAssertEqual(store.state.retryAfterSeconds, 12)

        source.listError = serverError
        store = await started(source)
        XCTAssertTrue(store.state.failed)
        XCTAssertNil(store.state.retryAfterSeconds, "不带 Retry-After 的 5xx：不说等几秒")

        source.listError = MBoom()
        store = await started(source)
        XCTAssertTrue(store.state.failed)
        XCTAssertNil(store.state.retryAfterSeconds)
    }

    func testFeedHiddenCollapsesThePageInsteadOfShowingAFailure() async {
        let source = MSource()
        source.listError = hidden
        let store = await started(source)
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertFalse(store.state.failed)
        XCTAssertFalse(store.state.loading)
        XCTAssertTrue(FeedMyPostsPresentation(state: store.state).rows.isEmpty)
        store.loadMore()
        await store.waitForTasks()
        XCTAssertEqual(source.count("list"), 1)
    }

    func testAPagingFailureKeepsTheListAndIsSeparateFromTheFirstPageFailure() async {
        let source = MSource()
        source.pages[""] = FeedMyPostsPage(posts: [mine("a")], nextBefore: "a")
        source.pages["a"] = FeedMyPostsPage(posts: [mine("b")], nextBefore: nil)
        let store = await started(source)
        source.listError = throttled(15)
        source.listErrorOnlyForBefore = true
        store.loadMore()
        XCTAssertTrue(store.state.loadingMore)
        XCTAssertFalse(store.state.loading, "翻页不把整页换成加载中")
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a"])
        XCTAssertTrue(store.state.loadMoreFailed)
        XCTAssertFalse(store.state.failed)
        XCTAssertFalse(store.state.loadingMore)
        XCTAssertEqual(store.state.retryAfterSeconds, 15)
        XCTAssertEqual(store.state.nextBefore, "a", "还能再试")
        XCTAssertFalse(FeedMyPostsPresentation(state: store.state).canLoadMore, "失败了不自动再翻")

        source.listError = nil
        store.loadMore()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b"])
        XCTAssertFalse(store.state.loadMoreFailed)
        XCTAssertNil(store.state.retryAfterSeconds)
    }

    func testARefreshFailureKeepsWhatIsShown() async {
        let source = MSource()
        source.pages[""] = FeedMyPostsPage(posts: [mine("a")], nextBefore: nil)
        let store = await started(source)
        source.listError = serverError
        store.refresh()
        XCTAssertTrue(store.state.refreshing)
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a"])
        XCTAssertTrue(store.state.failed)
        XCTAssertFalse(store.state.refreshing)
        let rows = FeedMyPostsPresentation(state: store.state).rows
        XCTAssertEqual(rows.first, .status(.failed(retryAfterSeconds: nil)))
        XCTAssertEqual(rows.count, 2)
    }

    func testARefreshCancelsAPagingRequestInFlight() async {
        let source = MSource()
        source.pages[""] = FeedMyPostsPage(posts: [mine("a")], nextBefore: "a")
        source.pages["a"] = FeedMyPostsPage(posts: [mine("b")], nextBefore: nil)
        let store = await started(source)
        let gate = MGate()
        source.hold("list a", gate)
        store.loadMore()
        await waitForArrival(gate)
        source.pages[""] = FeedMyPostsPage(posts: [mine("n"), mine("a")], nextBefore: nil)
        store.refresh()
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["n", "a"], "旧的翻页结果不接在新列表后面")
        XCTAssertNil(store.state.nextBefore)
        XCTAssertFalse(store.state.loadingMore)
    }
}

// MARK: - 申诉

@MainActor
final class TellomiFeedMyPostsAppealTests: XCTestCase {
    private func started(_ source: MSource, _ posts: [FeedMyPost]? = nil) async -> FeedMyPostsStore {
        source.pages[""] = FeedMyPostsPage(posts: posts ?? [mine("r", state: "rejected", appealable: true)], nextBefore: nil)
        let store = FeedMyPostsStore(source: source, feed: FeedStore(source: source, now: { t0 }, jitter: { 0 }))
        store.start()
        await store.waitForTasks()
        return store
    }

    func testOnlyARejectedAppealablePostWithoutAnAppealIsSent() async {
        let source = MSource()
        let posts = [
            mine("pub", state: "published", appealable: true),
            mine("pen", state: "pending", appealable: true),
            mine("wd", state: "withdrawn", appealable: true),
            mine("no", state: "rejected", appealable: false),
            mine("got", state: "rejected", appealable: true, appealState: "received"),
            mine("ok", state: "rejected", appealable: true),
        ]
        let store = await started(source, posts)
        for post in posts { store.appeal(post, text: "please") }
        await store.waitForTasks()
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("appeal") }, ["appeal ok please"])
        XCTAssertEqual(store.state.appealNotice, .sent)
        let canAppeal = posts.map { FeedMyPostRow(post: $0).canAppeal }
        XCTAssertEqual(canAppeal, [false, false, false, false, false, true], "已撤回的引擎当前不收申诉（A-6），不给按钮")
    }

    func testSentMarksTheRowReviewingAndTakesTheButtonAway() async {
        let source = MSource()
        let store = await started(source)
        store.appeal(store.state.posts[0], text: "  reason  ")
        XCTAssertTrue(store.state.appealing)
        XCTAssertTrue(FeedMyPostsPresentation(state: store.state).appealBusy)
        await store.waitForTasks()
        XCTAssertEqual(source.calls.last, "appeal r reason")
        XCTAssertFalse(store.state.appealing)
        let row = FeedMyPostRow(post: store.state.posts[0])
        XCTAssertFalse(row.canAppeal)
        XCTAssertEqual(row.notes, [.rejected(reasons: [.communityGuidelines]), .appealReceived])
        store.onAppealNoticeShown()
        XCTAssertNil(store.state.appealNotice)
    }

    func testAppealErrorsAreClassified() async {
        let source = MSource()
        let store = await started(source)

        source.appealError = throttled(25)
        store.appeal(store.state.posts[0], text: "x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.appealNotice, .throttled(retryAfterSeconds: 25))
        XCTAssertTrue(store.state.posts[0].appealable, "限速了：还能再申诉")
        store.onAppealNoticeShown()

        source.appealError = FeedAPIError(status: 503, code: "unavailable", retryAfterSeconds: 8)
        store.appeal(store.state.posts[0], text: "x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.appealNotice, .throttled(retryAfterSeconds: 8))
        store.onAppealNoticeShown()

        source.appealError = serverError
        store.appeal(store.state.posts[0], text: "x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.appealNotice, .failed)
        XCTAssertTrue(store.state.posts[0].appealable)
        store.onAppealNoticeShown()

        source.appealError = hidden
        store.appeal(store.state.posts[0], text: "x")
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertNil(store.state.appealNotice)
        XCTAssertFalse(store.state.appealing)
    }

    func testNotRejectedMeansTheListIsStaleAndReloads() async {
        let source = MSource()
        let store = await started(source)
        source.pages[""] = FeedMyPostsPage(posts: [mine("r", state: "published")], nextBefore: nil)
        source.appealError = FeedAPIError(status: 409, code: "not_rejected")
        store.appeal(store.state.posts[0], text: "x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.appealNotice, .notRejected)
        XCTAssertEqual(source.count("list"), 2)
        XCTAssertEqual(store.state.posts.map(\.state), ["published"])
    }

    func testAPostThatIsGoneFailsTheAppealAndReloads() async {
        let source = MSource()
        let store = await started(source)
        source.pages[""] = FeedMyPostsPage(posts: [], nextBefore: nil)
        source.appealError = FeedAPIError(status: 404, code: "not_found")
        store.appeal(store.state.posts[0], text: "x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.appealNotice, .failed)
        XCTAssertTrue(store.state.posts.isEmpty)
    }

    func testBlankAndSecondTapsAreIgnored() async {
        let source = MSource()
        let store = await started(source)
        store.appeal(store.state.posts[0], text: "   \n")
        XCTAssertFalse(store.state.appealing)
        store.appeal(store.state.posts[0], text: "a")
        store.appeal(store.state.posts[0], text: "b")
        await store.waitForTasks()
        XCTAssertEqual(source.count("appeal"), 1)
    }
}

// MARK: - 页面要画什么

final class TellomiFeedMyPostsPresentationTests: XCTestCase {
    func testStatusMapping() {
        XCTAssertEqual(FeedMyPostStatus(state: "published"), .published)
        XCTAssertEqual(FeedMyPostStatus(state: "pending"), .pending)
        XCTAssertEqual(FeedMyPostStatus(state: "rejected"), .rejected)
        XCTAssertEqual(FeedMyPostStatus(state: "withdrawn"), .withdrawn)
        XCTAssertEqual(FeedMyPostStatus(state: "from_the_future"), .published, "认不得的当已发布画（和 Android 一样）")
        XCTAssertFalse(FeedMyPostRow(post: mine("z", state: "from_the_future")).canOpen, "但不让点开")
        XCTAssertFalse(FeedMyPostRow(post: mine("z", state: "from_the_future", appealable: true)).canAppeal)
    }

    func testRejectionReasonsMapToFourCodesDedupedWithAFallback() {
        XCTAssertEqual(FeedRejectionReason(code: "prohibited_words"), .prohibitedWords)
        XCTAssertEqual(FeedRejectionReason(code: "review_unavailable"), .reviewUnavailable)
        XCTAssertEqual(FeedRejectionReason(code: "account_restricted"), .accountRestricted)
        XCTAssertEqual(FeedRejectionReason(code: "community_guidelines"), .communityGuidelines)
        XCTAssertEqual(FeedRejectionReason(code: "lexicon:abc"), .communityGuidelines)
        XCTAssertEqual(FeedRejectionReason.list([]), [.communityGuidelines])
        XCTAssertEqual(FeedRejectionReason.list(["prohibited_words", "x", "y", "prohibited_words", "review_unavailable"]), [.prohibitedWords, .communityGuidelines, .reviewUnavailable])
    }

    func testNotesPerState() {
        XCTAssertEqual(FeedMyPostRow(post: mine("a")).notes, [])
        XCTAssertEqual(FeedMyPostRow(post: mine("a", state: "withdrawn")).notes, [])
        XCTAssertEqual(FeedMyPostRow(post: mine("a", state: "pending")).notes, [.pendingHint])
        var rejected = mine("a", state: "rejected", appealable: true)
        rejected.rejectionReasons = ["prohibited_words"]
        XCTAssertEqual(FeedMyPostRow(post: rejected).notes, [.rejected(reasons: [.prohibitedWords])])
        rejected.appealState = "upheld"
        rejected.appealable = false
        XCTAssertEqual(FeedMyPostRow(post: rejected).notes, [.rejected(reasons: [.prohibitedWords]), .appealUpheld])
        rejected.appealState = "overturned"
        XCTAssertEqual(FeedMyPostRow(post: rejected).notes, [.rejected(reasons: [.prohibitedWords])], "改判通过：列表里它会是已发布，不再有申诉说明")
        // 只有未通过的才有「未通过」说明（别的状态带着原因也不显示）
        var other = mine("b", state: "published")
        other.rejectionReasons = ["prohibited_words"]
        XCTAssertEqual(FeedMyPostRow(post: other).notes, [])
    }

    func testVisibilityAndDeleteAndText() {
        var post = mine("a")
        post.visibility = "only_me"
        XCTAssertEqual(FeedMyPostRow(post: post).visibility, .onlyMe)
        for value in FeedVisibility.allCases {
            post.visibility = value.apiName
            XCTAssertEqual(FeedMyPostRow(post: post).visibility, value)
        }
        post.visibility = "something_new"
        XCTAssertNil(FeedMyPostRow(post: post).visibility)
        post.visibility = nil
        XCTAssertNil(FeedMyPostRow(post: post).visibility)
        for state in ["published", "pending", "rejected", "withdrawn"] {
            XCTAssertTrue(FeedMyPostRow(post: mine("a", state: state)).canDelete)
        }
        var article = mine("a", kind: "article")
        article.title = ""
        XCTAssertNil(FeedMyPostRow(post: article).title)
        article.title = "T"
        XCTAssertEqual(FeedMyPostRow(post: article).title, "T")
        article.text = nil
        XCTAssertEqual(FeedMyPostRow(post: article).text, "")
    }

    func testRowsPerStateOfThePage() {
        var state = FeedMyPostsState()
        XCTAssertEqual(FeedMyPostsPresentation(state: state).rows, [.status(.loading)])
        state.loading = false
        XCTAssertEqual(FeedMyPostsPresentation(state: state).rows, [])
        state.failed = true
        state.retryAfterSeconds = 7
        XCTAssertEqual(FeedMyPostsPresentation(state: state).rows, [.status(.failed(retryAfterSeconds: 7))])
        state.failed = false
        state.loadedOnce = true
        XCTAssertEqual(FeedMyPostsPresentation(state: state).rows, [.status(.empty)])
        state.loading = true
        XCTAssertEqual(FeedMyPostsPresentation(state: state).rows, [.status(.loading)])
        state.loading = false
        state.failed = true
        state.retryAfterSeconds = nil
        XCTAssertEqual(FeedMyPostsPresentation(state: state).rows, [.status(.failed(retryAfterSeconds: nil))], "没有内容又失败：只说失败，不叠一行「还没发过」")
        state.failed = false
        state.posts = [mine("a"), mine("b", state: "pending")]
        state.nextBefore = "b"
        var rows = FeedMyPostsPresentation(state: state).rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(FeedMyPostsPresentation(state: state).canLoadMore)
        state.loadingMore = true
        rows = FeedMyPostsPresentation(state: state).rows
        XCTAssertEqual(rows.last, .status(.loadingMore))
        XCTAssertFalse(FeedMyPostsPresentation(state: state).canLoadMore)
        state.loadingMore = false
        state.loadMoreFailed = true
        state.retryAfterSeconds = 5
        rows = FeedMyPostsPresentation(state: state).rows
        XCTAssertEqual(rows.last, .status(.loadMoreFailed(retryAfterSeconds: 5)))
        XCTAssertFalse(FeedMyPostsPresentation(state: state).canLoadMore)
        state.loadMoreFailed = false
        state.nextBefore = nil
        XCTAssertFalse(FeedMyPostsPresentation(state: state).canLoadMore)
        state.nextBefore = "b"
        state.loading = true
        XCTAssertFalse(FeedMyPostsPresentation(state: state).canLoadMore, "刷新中不翻页")
        state.loading = false
        state.failed = true
        XCTAssertFalse(FeedMyPostsPresentation(state: state).canLoadMore, "刷新失败后不自动翻页")
        state.failed = false
        state.feedHidden = true
        XCTAssertTrue(FeedMyPostsPresentation(state: state).rows.isEmpty)
        XCTAssertTrue(FeedMyPostsPresentation(state: state).feedHidden)
        XCTAssertFalse(FeedMyPostsPresentation(state: state).canLoadMore)
    }
}

// MARK: - 样例数据

@MainActor
final class TellomiFeedMyPostsSampleTests: XCTestCase {
    private func make() -> SampleFeedSource { SampleFeedSource(now: { t0 }) }

    func testFirstPageHasEveryStateThenAPagedTail() async throws {
        let source = make()
        let first = try await source.myPosts(before: nil)
        XCTAssertEqual(first.posts.count, 30)
        XCTAssertNotNil(first.nextBefore)
        let states = Set(first.posts.map(\.state))
        XCTAssertEqual(states, ["pending", "rejected", "withdrawn", "published"])
        let dates = first.posts.compactMap { $0.createdAt.flatMap(FeedDates.parse) }
        XCTAssertEqual(dates, dates.sorted(by: >), "新的在前")
        let second = try await source.myPosts(before: first.nextBefore)
        XCTAssertEqual(second.posts.count, 10)
        XCTAssertNil(second.nextBefore)
        XCTAssertTrue(Set(second.posts.map(\.id)).isDisjoint(with: first.posts.map(\.id)))
        let all = first.posts + second.posts
        XCTAssertEqual(Set(all.compactMap(\.visibility)), Set(FeedVisibility.allCases.map(\.apiName)))
        XCTAssertTrue(all.contains { $0.kind == "article" })
        let withdrawn = all.first { $0.state == "withdrawn" }
        XCTAssertEqual(withdrawn?.appealable, false)
        XCTAssertTrue(all.contains { $0.state == "rejected" && $0.appealable })
        XCTAssertTrue(all.contains { $0.appealState == "received" })
        XCTAssertTrue(all.contains { $0.appealState == "upheld" })
    }

    func testDeletingASeededPostRemovesItOnceAndTheSecondTimeIs404() async throws {
        let source = make()
        try await source.deletePost(contentId: "mine-seed-2")
        let all = try await source.myPosts(before: nil).posts
        XCTAssertFalse(all.contains { $0.id == "mine-seed-2" })
        do {
            try await source.deletePost(contentId: "mine-seed-2")
            XCTFail("第二次该 404")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 404)
        }
        let card = try await source.card(contentId: "mine-seed-2")
        XCTAssertNil(card, "删了：详情也取不到")
    }

    func testSeededPublishedPostsOpenAsOwnCards() async throws {
        let source = make()
        let card = try await source.card(contentId: "mine-seed-3")
        XCTAssertEqual(card?.viewer.isAuthor, true)
        XCTAssertEqual(card?.id, "mine-seed-3")
        let pending = try await source.card(contentId: "mine-seed-p1")
        XCTAssertNil(pending, "审核中的别人看不到，也没有详情")
    }

    func testAPostPublishedInTheSampleShowsAtTheTop() async throws {
        let source = make()
        var draft = FeedDraft()
        draft.text = "hello"
        let response = try await source.publish(draft: draft, clientNonce: "n1")
        let first = try await source.myPosts(before: nil).posts.first
        XCTAssertEqual(first?.id, response.id)
        XCTAssertEqual(first?.state, "published")
        try await source.deletePost(contentId: response.id)
        let after = try await source.myPosts(before: nil).posts
        XCTAssertFalse(after.contains { $0.id == response.id })
    }

    func testAppealRulesAndKnobs() async throws {
        let source = make()
        func status(_ id: String, _ text: String = "reason") async -> Int? {
            do { try await source.appeal(contentId: id, text: text); return nil } catch let error as FeedAPIError { return error.status } catch { return -1 }
        }
        let wrongState = await status("mine-seed-w1")
        XCTAssertEqual(wrongState, 409, "已撤回的引擎当前不收（A-6）")
        let published = await status("mine-seed-1")
        XCTAssertEqual(published, 409)
        let unknown = await status("nope")
        XCTAssertEqual(unknown, 404)
        let blank = await status("mine-seed-r1", "  ")
        XCTAssertEqual(blank, 400)
        let tooLong = await status("mine-seed-r1", String(repeating: "🇨🇳", count: 251))
        XCTAssertEqual(tooLong, 400, "按码点数：251 个 🇨🇳 是 502 个码点")
        let ok = await status("mine-seed-r1", String(repeating: "🇨🇳", count: 250))
        XCTAssertNil(ok)
        let again = await status("mine-seed-r1")
        XCTAssertEqual(again, 409)
        let list = try await source.myPosts(before: nil).posts
        XCTAssertEqual(list.first { $0.id == "mine-seed-r1" }?.appealState, "received")
        XCTAssertEqual(list.first { $0.id == "mine-seed-r1" }?.appealable, false)
        let already = await status("mine-seed-r3")
        XCTAssertEqual(already, 409, "样例里本来就在复核")

        source.simulation.failsAppeals = true
        let fails = await status("mine-seed-r2")
        XCTAssertEqual(fails, -1)
        source.simulation.failsAppeals = false
        source.simulation.appealsNotRejected = true
        let notRejected = await status("mine-seed-r2")
        XCTAssertEqual(notRejected, 409)
        source.simulation.appealsNotRejected = false
        source.simulation.myPostsThrottledRetryAfterSeconds = 9
        let limited = await status("mine-seed-r2")
        XCTAssertEqual(limited, 429)
        source.simulation.myPostsThrottledRetryAfterSeconds = nil
        source.simulation.feedHidden = true
        let hiddenStatus = await status("mine-seed-r2")
        XCTAssertEqual(hiddenStatus, 404)
    }

    func testListKnobs() async throws {
        let source = make()
        source.simulation.failsMyPosts = true
        do { _ = try await source.myPosts(before: nil); XCTFail() } catch {}
        source.simulation.failsMyPosts = false
        source.simulation.failsMyPostsMore = true
        let first = try await source.myPosts(before: nil)
        do { _ = try await source.myPosts(before: first.nextBefore); XCTFail() } catch {}
        source.simulation.failsMyPostsMore = false
        source.simulation.myPostsThrottledRetryAfterSeconds = 11
        do { _ = try await source.myPosts(before: nil); XCTFail() } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 429)
            XCTAssertEqual(error.retryAfterSeconds, 11)
        }
        source.simulation.myPostsThrottledRetryAfterSeconds = nil
        source.simulation.feedHidden = true
        do { _ = try await source.myPosts(before: nil); XCTFail() } catch let error as FeedAPIError {
            XCTAssertTrue(error.isFeedHidden)
        }
    }

    func testTheWholeFlowThroughTheStoreOnSampleData() async {
        let source = make()
        let feed = FeedStore(source: source, now: { t0 }, jitter: { 0 })
        let store = FeedMyPostsStore(source: source, feed: feed)
        store.start()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.count, 30)
        store.loadMore()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.count, 40)
        XCTAssertNil(store.state.nextBefore)
        store.openPost(store.state.posts.first { $0.id == "mine-seed-4" }!)
        await store.waitForTasks()
        XCTAssertEqual(store.state.openCard?.id, "mine-seed-4")
        store.onCardOpened()
        store.delete(store.state.posts.first { $0.id == "mine-seed-4" }!)
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.count, 39)
        XCTAssertTrue(feed.isRemoved(id: "mine-seed-4"))
        store.appeal(store.state.posts.first { $0.id == "mine-seed-r2" }!, text: "please")
        await store.waitForTasks()
        XCTAssertEqual(store.state.appealNotice, .sent)
        store.refresh()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.first { $0.id == "mine-seed-r2" }?.appealState, "received")
        XCTAssertFalse(store.state.posts.contains { $0.id == "mine-seed-4" })
    }
}
