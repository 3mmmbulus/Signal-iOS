//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 搜索页和话题页的逻辑层（第二轮）：和信息流共用 `FeedStore`（赞、屏蔽同步、借着不放）、错误分类（5xx / Retry-After / `feed_hidden`）、
/// 翻页失败、停手再搜 / 作废过期请求、搜索词按码点截断、页面要画什么（`FeedSearchPresentation` / `FeedTopicPresentation`）、样例数据。界面（UIKit）不在这里测。

private struct SBoom: Error {}

private actor SGate {
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

private func waitUntil(_ condition: @escaping () async -> Bool) async {
    for _ in 0..<200 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("条件一直没成立")
}

private final class SSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = [String]()
    var calls: [String] { lock.withLock { _calls } }
    private func log(_ call: String) { lock.withLock { _calls.append(call) } }

    var feedCards = [FeedCard]()
    var searchPages = [String: FeedSearchPage]()
    var searchError: Error?
    var searchErrorOnlyForCursor = false
    var topicPages = [String: FeedTopicPage]()
    var topicError: Error?
    var topicErrorOnlyForCursor = false
    var followError: Error?
    var likeError: Error?
    var repostError: Error?
    private var gates = [String: SGate]()
    func hold(_ key: String, _ gate: SGate) { lock.withLock { gates[key] = gate } }
    private func gate(_ key: String) -> SGate? { lock.withLock { gates[key] } }

    static func key(_ query: String, _ scope: String, _ cursor: String?) -> String { "\(scope)|\(query)|\(cursor ?? "-")" }

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage(cards: feedCards) }
    func setLiked(contentId: String, liked: Bool) async throws {
        log("like \(contentId) \(liked)")
        if let likeError { throw likeError }
    }
    func setReposted(contentId: String, reposted: Bool) async throws {
        log("repost \(contentId) \(reposted)")
        if let repostError { throw repostError }
    }
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw SBoom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func search(query: String, scope: String, cursor: String?) async throws -> FeedSearchPage {
        let key = Self.key(query, scope, cursor)
        log("search \(key)")
        if let gate = gate(key) { await gate.wait() }
        if let searchError, !searchErrorOnlyForCursor || cursor != nil { throw searchError }
        return searchPages[key] ?? FeedSearchPage()
    }

    func topicPosts(slug: String, cursor: String?) async throws -> FeedTopicPage {
        log("topic \(slug) \(cursor ?? "-")")
        if let gate = gate("topic|\(cursor ?? "-")") { await gate.wait() }
        if let topicError, !topicErrorOnlyForCursor || cursor != nil { throw topicError }
        return topicPages[cursor ?? ""] ?? FeedTopicPage()
    }

    func setFollowingTopic(slug: String, following: Bool) async throws {
        log("follow \(slug) \(following)")
        if let followError { throw followError }
    }
}

private func card(_ id: String, author: String = "p1", likes: Int = 0, topic: FeedTopic? = nil) -> FeedCard {
    var c = FeedCard(id: id, kind: FeedCard.kindPost, author: FeedAuthor(profileId: author, displayName: author), text: "t \(id)")
    c.stats.likes = likes
    if let topic { c.topics = [topic] }
    return c
}

private func user(_ id: String) -> FeedSearchUser { FeedSearchUser(id: id, displayName: "U\(id)") }

private func throttled(_ seconds: Int? = 20) -> FeedAPIError { FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds) }
private let feedHiddenError = FeedAPIError(status: 404, code: "feed_hidden")

private func key(_ query: String = "x", _ scope: String = "all", _ cursor: String? = nil) -> String { SSource.key(query, scope, cursor) }

// MARK: - 搜索

@MainActor
final class TellomiFeedSearchSyncTests: XCTestCase {
    private func make(_ source: SSource, feed: FeedStore? = nil, history: InMemoryFeedSearchHistory = InMemoryFeedSearchHistory(), debounce: @escaping () async -> Void = {}) -> FeedSearchStore {
        FeedSearchStore(source: source, history: history, feed: feed, debounceNanos: 1, sleep: { _ in await debounce() })
    }

    private func started(_ source: SSource, query: String = "x") async -> (FeedStore, FeedSearchStore) {
        source.searchPages[key(query)] = FeedSearchPage(users: [user("u1")], posts: [card("a1", likes: 3), card("a2")], cursor: "c1")
        source.searchPages[key(query, "all", "c1")] = FeedSearchPage(posts: [card("a3")])
        source.feedCards = [card("a1", likes: 0), card("b1", author: "p2")]
        let feed = FeedStore(source: source)
        feed.onTabShown(.recommend)
        await feed.waitForLoad(.recommend)
        let store = make(source, feed: feed)
        store.onQueryChange(query)
        await store.waitForTasks()
        return (feed, store)
    }

    // MARK: 和信息流同步

    func testResultsRefreshTheFeedCopyAreLeasedAndShowTheFeedsCard() async {
        let source = SSource()
        let (feed, store) = await started(source)
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a1", "a2"])
        XCTAssertEqual(feed.card(id: "a1")?.stats.likes, 3, "搜到的更新的赞数换到了信息流里")
        XCTAssertEqual(store.leaseCount, 2)
        XCTAssertTrue(store.isObservingFeed)
        store.loadMore()
        await store.waitForTasks()
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a1", "a2", "a3"])
        XCTAssertEqual(store.leaseCount, 3)
    }

    func testANewSearchReleasesTheOldLeasesAndClearingReleasesAll() async {
        let source = SSource()
        let (_, store) = await started(source)
        source.searchPages[key("y")] = FeedSearchPage(posts: [card("z1")])
        store.onQueryChange("y")
        await store.waitForTasks()
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["z1"])
        XCTAssertEqual(store.leaseCount, 1)
        store.onQueryChange("")
        XCTAssertEqual(store.leaseCount, 0)
    }

    func testLikingInSearchChangesTheFeedAndLikingInTheFeedChangesSearch() async {
        let source = SSource()
        let (feed, store) = await started(source)
        store.toggleLike(store.state.results!.posts[0])
        XCTAssertTrue(feed.card(id: "a1")?.viewer.liked ?? false)
        XCTAssertTrue(store.state.results?.posts[0].viewer.liked ?? false)
        XCTAssertEqual(store.state.results?.posts[0].stats.likes, 4)
        await store.waitForTasks()
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("like") }, ["like a1 true"])

        feed.toggleLike(id: "a2")
        XCTAssertTrue(store.state.results?.posts[1].viewer.liked ?? false, "信息流（或详情页）点的，搜索结果跟着变")
        await feed.waitForActions()
    }

    func testALikeThatFailsIsRolledBackAndToldOnTheSearchPage() async {
        let source = SSource()
        let (_, store) = await started(source)
        source.likeError = SBoom()
        store.toggleLike(store.state.results!.posts[0])
        await store.waitForTasks()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(store.state.results?.posts[0].viewer.liked ?? true)
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testBlockingAnAuthorInTheFeedRemovesTheirPostsFromTheResults() async {
        let source = SSource()
        source.searchPages[key()] = FeedSearchPage(posts: [card("a1", author: "p1"), card("a2", author: "p2")])
        source.feedCards = []
        let feed = FeedStore(source: source)
        let store = make(source, feed: feed)
        store.onQueryChange("x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a1", "a2"])
        feed.removeCards(byAuthor: "p1")
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a2"])
    }

    func testADeletedPostDisappearsFromTheResultsAndAnUnblockedAuthorCanComeBack() async {
        let source = SSource()
        source.searchPages[key()] = FeedSearchPage(posts: [card("a1", author: "p1"), card("a2", author: "p2")])
        let feed = FeedStore(source: source)
        let store = make(source, feed: feed)
        store.onQueryChange("x")
        await store.waitForTasks()
        feed.removeCard(id: "a2")
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a1"], "帖子删了：搜索结果里也没了")

        feed.removeCards(byAuthor: "p1")
        XCTAssertEqual(store.state.results?.posts, [])
        feed.allowCards(byAuthor: "p1")
        XCTAssertFalse(feed.isRemoved(card("a1", author: "p1")), "取消屏蔽后不再算被去掉的")
        XCTAssertTrue(feed.isRemoved(card("a2", author: "p2")), "删掉的帖子永远算")
        source.searchPages[key("y")] = FeedSearchPage(posts: [card("a1", author: "p1")])
        store.onQueryChange("y")
        await store.waitForTasks()
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a1"], "取消屏蔽后他的帖子能再搜到")
    }

    func testBlockingSomeoneWhoseCardsNobodyHoldsDoesNotNotify() async {
        let source = SSource()
        let feed = FeedStore(source: source)
        let store = make(source, feed: feed)
        var changes = 0
        store.onChange = { _ in changes += 1 }
        feed.removeCards(byAuthor: "nobody")
        feed.removeCard(id: "ghost")
        XCTAssertEqual(changes, 0)
    }

    func testDetachStopsObservingAndDropsTheLeases() async {
        let source = SSource()
        let (feed, store) = await started(source)
        store.detach()
        XCTAssertFalse(store.isObservingFeed)
        XCTAssertEqual(store.leaseCount, 0)
        feed.toggleLike(id: "a1")
        XCTAssertFalse(store.state.results?.posts[0].viewer.liked ?? true, "放手以后不再跟着变")
        await feed.waitForActions()
        store.detach()
    }

    // MARK: 错误

    func testFirstPageErrorsAreToldApart() async {
        func run(_ error: Error) async -> FeedSearchState {
            let source = SSource()
            source.searchError = error
            let store = make(source)
            store.onQueryChange("x")
            await store.waitForTasks()
            return store.state
        }
        var state = await run(SBoom())
        XCTAssertTrue(state.failed)
        XCTAssertNil(state.retryAfterSeconds)
        XCTAssertNil(state.results)

        state = await run(FeedAPIError(status: 500, code: nil, retryAfterSeconds: nil))
        XCTAssertTrue(state.failed)
        XCTAssertNil(state.retryAfterSeconds, "5xx 没有 Retry-After：不编秒数")

        state = await run(FeedAPIError(status: 503, code: nil, retryAfterSeconds: 12))
        XCTAssertTrue(state.failed)
        XCTAssertEqual(state.retryAfterSeconds, 12, "带 Retry-After 的 503 当限速")

        state = await run(throttled(30))
        XCTAssertTrue(state.failed)
        XCTAssertEqual(state.retryAfterSeconds, 30)

        state = await run(throttled(nil))
        XCTAssertTrue(state.failed)
        XCTAssertNil(state.retryAfterSeconds)

        state = await run(feedHiddenError)
        XCTAssertTrue(state.feedHidden)
        XCTAssertFalse(state.failed, "feed_hidden 不是「搜索失败」")
        XCTAssertFalse(state.loading)
    }

    func testRetryAfterAFailureClearsTheSecondsAndFeedHidden() async {
        let source = SSource()
        source.searchError = throttled(25)
        let store = make(source)
        store.onQueryChange("x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.retryAfterSeconds, 25)
        source.searchError = nil
        source.searchPages[key()] = FeedSearchPage(posts: [card("a")])
        store.retry()
        XCTAssertNil(store.state.retryAfterSeconds)
        XCTAssertTrue(store.state.loading)
        await store.waitForTasks()
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a"])
    }

    func testAFailedLoadMoreKeepsTheResultsAndCursorAndRetryWorks() async {
        let source = SSource()
        let (_, store) = await started(source)
        source.searchError = throttled(9)
        source.searchErrorOnlyForCursor = true
        store.loadMore()
        await store.waitForTasks()
        XCTAssertFalse(store.state.failed, "翻页失败不是整页失败")
        XCTAssertTrue(store.state.loadMoreFailed)
        XCTAssertEqual(store.state.retryAfterSeconds, 9)
        XCTAssertNil(store.state.notice, "末尾那一行说话，不再弹提示")
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a1", "a2"])
        XCTAssertEqual(store.state.results?.cursor, "c1")
        XCTAssertFalse(FeedSearchPresentation(state: store.state).canLoadMore, "失败后不再自动翻")

        source.searchError = nil
        store.loadMore()
        XCTAssertFalse(store.state.loadMoreFailed, "重试时先收掉失败行")
        await store.waitForTasks()
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a1", "a2", "a3"])
        XCTAssertNil(store.state.retryAfterSeconds)
    }

    func testRepostThrottledAndFeedHiddenAreToldApart() async {
        let source = SSource()
        let (_, store) = await started(source)
        source.repostError = throttled(14)
        store.toggleRepost(store.state.results!.posts[0])
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 14)
        XCTAssertFalse(store.state.results?.posts[0].viewer.reposted ?? true, "失败改回来")
        store.onNoticeShown()
        XCTAssertNil(store.state.notice)
        XCTAssertNil(store.state.retryAfterSeconds)

        source.repostError = feedHiddenError
        store.toggleRepost(store.state.results!.posts[0])
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
    }

    // MARK: 停手再搜 / 作废

    func testClearingTheQueryWhileLoadingMoreResetsEverythingAndALateMoreIsDropped() async {
        let source = SSource()
        let (_, store) = await started(source)
        let gate = SGate()
        source.hold(key("x", "all", "c1"), gate)
        store.loadMore()
        await waitUntil { await gate.arrivals == 1 }
        XCTAssertTrue(store.state.loadingMore)
        store.onQueryChange("")
        XCTAssertFalse(store.state.loadingMore, "清空：翻页收掉")
        XCTAssertFalse(store.state.loadMoreFailed)
        XCTAssertNil(store.state.results)
        await gate.open()
        await store.waitForTasks()
        XCTAssertNil(store.state.results, "过期的下一页回来了也不盖回去")
        XCTAssertFalse(store.state.loadingMore)
    }

    func testChangingTheScopeCancelsTheSearchWaitingForTheDebounce() async {
        let source = SSource()
        source.searchPages[key("x", "users")] = FeedSearchPage(users: [user("1")])
        let gate = SGate()
        let store = make(source, debounce: { await gate.wait() })
        store.onQueryChange("x")
        await waitUntil { await gate.arrivals == 1 }
        store.selectScope(FeedAPI.searchUsers)
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("search") }, ["search \(key("x", "users"))"], "等着的那次（全部）作废，只搜了新范围")
        XCTAssertEqual(store.state.results?.scope, "users")
    }

    func testAnOlderSlowSearchCannotOverwriteANewerOne() async {
        let source = SSource()
        source.searchPages[key("a")] = FeedSearchPage(posts: [card("old")])
        source.searchPages[key("ab")] = FeedSearchPage(posts: [card("new")])
        let gate = SGate()
        source.hold(key("a"), gate)
        let store = make(source)
        store.onQueryChange("a")
        await waitUntil { await gate.arrivals == 1 }
        store.onQueryChange("ab")
        await waitUntil { source.calls.contains("search \(key("ab"))") }
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(store.state.results?.query, "ab")
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["new"])
        XCTAssertFalse(store.state.loading)
    }

    func testTheQueryIsCutAtFiftyCodePointsAndThatIsWhatIsSent() async {
        let source = SSource()
        let store = make(source)
        let flags = String(repeating: "🇨🇳", count: 30)   // 每个 2 个码点
        store.onQueryChange(flags)
        XCTAssertEqual(FeedTextCap.count(store.state.query), 50)
        XCTAssertEqual(store.state.query.count, 25, "按码点截，不劈开一个国旗")
        await store.waitForTasks()
        let sent = source.calls.first { $0.hasPrefix("search") } ?? ""
        XCTAssertEqual(FeedTextCap.count(String(sent.dropFirst("search all|".count).dropLast("|-".count))), 50)

        store.useRecentQuery(String(repeating: "字", count: 80))
        XCTAssertEqual(FeedTextCap.count(store.state.query), 50, "点最近搜索也按 50 截")
        await store.waitForTasks()
    }
}

// MARK: - 话题

@MainActor
final class TellomiFeedTopicSyncTests: XCTestCase {
    private func setUp(_ source: SSource) -> (FeedStore, FeedTopicStore) {
        let t = FeedTopic(slug: "food", label: "美食")
        source.topicPages = ["": FeedTopicPage(posts: [card("a1", likes: 3, topic: t), card("a2", topic: t)], cursor: "c1", following: true), "c1": FeedTopicPage(posts: [card("a3", topic: t)])]
        source.feedCards = [card("a1", likes: 0), card("b1", author: "p2")]
        let feed = FeedStore(source: source)
        return (feed, FeedTopicStore(slug: "food", source: source, feed: feed))
    }

    private func started(_ source: SSource) async -> (FeedStore, FeedTopicStore) {
        let (feed, store) = setUp(source)
        feed.onTabShown(.recommend)
        await feed.waitForLoad(.recommend)
        store.start()
        await store.waitForTasks()
        return (feed, store)
    }

    func testLoadedPostsRefreshTheFeedCopyAreLeasedAndPaged() async {
        let source = SSource()
        let (feed, store) = await started(source)
        XCTAssertEqual(store.state.posts.map(\.id), ["a1", "a2"])
        XCTAssertEqual(feed.card(id: "a1")?.stats.likes, 3)
        XCTAssertEqual(store.leaseCount, 2)
        XCTAssertTrue(store.state.following)
        store.loadMore()
        XCTAssertTrue(store.state.loadingMore)
        await store.waitForTasks()
        XCTAssertFalse(store.state.loadingMore)
        XCTAssertEqual(store.state.posts.map(\.id), ["a1", "a2", "a3"])
        XCTAssertEqual(store.leaseCount, 3)
        store.refresh()
        XCTAssertFalse(store.state.loadingMore, "刷新不是翻页")
        await store.waitForTasks()
        XCTAssertEqual(store.leaseCount, 2, "刷新放掉旧的借用")
    }

    func testLikeBlockAndDetachStayInSyncWithTheFeed() async {
        let source = SSource()
        let (feed, store) = await started(source)
        store.toggleLike(store.state.posts[0])
        XCTAssertTrue(feed.card(id: "a1")?.viewer.liked ?? false)
        XCTAssertTrue(store.state.posts[0].viewer.liked)
        await store.waitForTasks()
        feed.toggleLike(id: "a2")
        XCTAssertTrue(store.state.posts[1].viewer.liked)
        await feed.waitForActions()

        feed.removeCards(byAuthor: "p1")
        XCTAssertEqual(store.state.posts, [], "屏蔽了作者：话题页里他的帖子也没了")
        store.detach()
        XCTAssertFalse(store.isObservingFeed)
        XCTAssertEqual(store.leaseCount, 0)
    }

    func testAFailedLikeIsRolledBackAndToldOnTheTopicPage() async {
        let source = SSource()
        let (_, store) = await started(source)
        source.likeError = SBoom()
        store.toggleLike(store.state.posts[0])
        await store.waitForTasks()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(store.state.posts[0].viewer.liked)
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testFirstPageErrorsAreToldApart() async {
        func run(_ error: Error) async -> FeedTopicState {
            let source = SSource()
            source.topicError = error
            let store = FeedTopicStore(slug: "food", source: source)
            store.start()
            await store.waitForTasks()
            return store.state
        }
        var state = await run(FeedAPIError(status: 500, code: nil, retryAfterSeconds: nil))
        XCTAssertTrue(state.failed)
        XCTAssertNil(state.retryAfterSeconds)
        XCTAssertFalse(state.gone)

        state = await run(FeedAPIError(status: 503, code: nil, retryAfterSeconds: 7))
        XCTAssertTrue(state.failed)
        XCTAssertEqual(state.retryAfterSeconds, 7)

        state = await run(throttled(40))
        XCTAssertTrue(state.failed)
        XCTAssertEqual(state.retryAfterSeconds, 40)

        state = await run(FeedAPIError(status: 404, code: "not_found", retryAfterSeconds: nil))
        XCTAssertTrue(state.gone)
        XCTAssertFalse(state.failed)

        state = await run(feedHiddenError)
        XCTAssertTrue(state.feedHidden)
        XCTAssertFalse(state.gone, "feed_hidden 不是「找不到这个话题」")
        XCTAssertFalse(state.failed)
    }

    func testAFailedLoadMoreIsNotAPageFailureAndA404ThereIsNotGone() async {
        let source = SSource()
        let (_, store) = await started(source)
        source.topicError = FeedAPIError(status: 404, code: "not_found", retryAfterSeconds: nil)
        source.topicErrorOnlyForCursor = true
        store.loadMore()
        await store.waitForTasks()
        XCTAssertFalse(store.state.gone)
        XCTAssertFalse(store.state.failed)
        XCTAssertTrue(store.state.loadMoreFailed)
        XCTAssertEqual(store.state.posts.map(\.id), ["a1", "a2"])
        XCTAssertEqual(store.state.cursor, "c1")
        XCTAssertFalse(FeedTopicPresentation(state: store.state, slug: "food").canLoadMore)

        source.topicError = nil
        store.loadMore()
        await store.waitForTasks()
        XCTAssertFalse(store.state.loadMoreFailed)
        XCTAssertEqual(store.state.posts.map(\.id), ["a1", "a2", "a3"])
    }

    func testFollowFailuresAreRolledBackAndToldApart() async {
        let source = SSource()
        let (_, store) = await started(source)
        XCTAssertTrue(store.state.following)
        source.followError = throttled(11)
        store.toggleFollow()
        XCTAssertFalse(store.state.following, "乐观：先改按钮")
        await store.waitForTasks()
        XCTAssertTrue(store.state.following, "失败改回来")
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 11)
        store.onNoticeShown()

        source.followError = FeedAPIError(status: 409, code: "profile_required", retryAfterSeconds: nil)
        store.toggleFollow()
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .profileRequired)
        store.onNoticeShown()

        source.followError = feedHiddenError
        store.toggleFollow()
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
    }

    func testTheTitleUsesThePostsTopicLabelThenTheHintThenTheSlug() async {
        let source = SSource()
        let (_, store) = await started(source)
        XCTAssertEqual(FeedTopicPresentation(state: store.state, slug: "food", labelHint: "别的").title, "#美食")
        let empty = FeedTopicState()
        XCTAssertEqual(FeedTopicPresentation(state: empty, slug: "food", labelHint: "美食").title, "#美食")
        XCTAssertEqual(FeedTopicPresentation(state: empty, slug: "food").title, "#food")
        XCTAssertEqual(FeedTopicPresentation(state: empty, slug: "food", labelHint: "").title, "#food")
    }
}

// MARK: - 要画什么

final class TellomiFeedSearchPresentationTests: XCTestCase {
    private func state(_ query: String = "x", scope: String = FeedAPI.searchAll, _ change: (inout FeedSearchState) -> Void = { _ in }) -> FeedSearchState {
        var s = FeedSearchState()
        s.query = query
        s.scope = scope
        change(&s)
        return s
    }

    private func results(_ scope: String = FeedAPI.searchAll, users: [FeedSearchUser] = [], posts: [FeedCard] = [], cursor: String? = nil) -> FeedSearchResults {
        FeedSearchResults(query: "x", scope: scope, users: users, posts: posts, cursor: cursor)
    }

    func testNothingTypedShowsHistoryOrAHint() {
        XCTAssertEqual(FeedSearchPresentation(state: state("")).rows, [.status(.hint)])
        XCTAssertFalse(FeedSearchPresentation(state: state("")).showsScopeBar)
        XCTAssertFalse(FeedSearchPresentation(state: state("   ")).showsScopeBar, "只有空格也算没输入")
        let withHistory = FeedSearchPresentation(state: state("") {
            $0.recentQueries = ["猫", "云"]
            $0.recentPeople = [FeedPersonSummary(id: "u1", handle: nil, displayName: "A", avatarKey: nil)]
        })
        XCTAssertEqual(withHistory.rows, [.recentQueriesHeader, .recentQuery("猫"), .recentQuery("云"), .recentPeopleHeader, .recentPerson(id: "u1")])
        let onlyPeople = FeedSearchPresentation(state: state("") { $0.recentPeople = [FeedPersonSummary(id: "u1", handle: nil, displayName: "A", avatarKey: nil)] })
        XCTAssertEqual(onlyPeople.rows, [.recentPeopleHeader, .recentPerson(id: "u1")])
    }

    func testLoadingFailedAndFeedHiddenPages() {
        XCTAssertEqual(FeedSearchPresentation(state: state { $0.loading = true }).rows, [.status(.loading)])
        XCTAssertTrue(FeedSearchPresentation(state: state { $0.loading = true }).showsScopeBar)
        XCTAssertEqual(FeedSearchPresentation(state: state { $0.failed = true }).rows, [.status(.failed(retryAfterSeconds: nil))])
        XCTAssertEqual(FeedSearchPresentation(state: state { $0.failed = true; $0.retryAfterSeconds = 30 }).rows, [.status(.failed(retryAfterSeconds: 30))])
        let hidden = FeedSearchPresentation(state: state { $0.feedHidden = true; $0.failed = true })
        XCTAssertTrue(hidden.feedHidden)
        XCTAssertEqual(hidden.rows, [])
    }

    func testResultsInAllAreTitledByTheTwoSectionsAndOtherScopesAreNot() {
        let posts = [card("a"), card("b")]
        let all = FeedSearchPresentation(state: state { $0.results = results(users: [user("1")], posts: posts) })
        XCTAssertEqual(all.rows, [.usersHeader, .user(id: "1"), .postsHeader, .post(id: "a"), .post(id: "b")])
        let onlyPostsInAll = FeedSearchPresentation(state: state { $0.results = results(posts: posts) })
        XCTAssertEqual(onlyPostsInAll.rows, [.post(id: "a"), .post(id: "b")], "只有一种时不加标题")
        let users = FeedSearchPresentation(state: state(scope: FeedAPI.searchUsers) { $0.results = results(FeedAPI.searchUsers, users: [user("1"), user("2")]) })
        XCTAssertEqual(users.rows, [.user(id: "1"), .user(id: "2")])
        let postsScope = FeedSearchPresentation(state: state(scope: FeedAPI.searchPosts) { $0.results = results(FeedAPI.searchPosts, posts: posts) })
        XCTAssertEqual(postsScope.rows, [.post(id: "a"), .post(id: "b")])
    }

    func testNoResultsAndTheTail() {
        XCTAssertEqual(FeedSearchPresentation(state: state { $0.results = results() }).rows, [.status(.noResults(query: "x"))])
        let posts = [card("a")]
        let more = FeedSearchPresentation(state: state { $0.results = results(posts: posts, cursor: "c"); $0.loadingMore = true })
        XCTAssertEqual(more.rows.last, .status(.loadingMore))
        XCTAssertFalse(more.canLoadMore)
        let failedMore = FeedSearchPresentation(state: state { $0.results = results(posts: posts, cursor: "c"); $0.loadMoreFailed = true; $0.retryAfterSeconds = 5 })
        XCTAssertEqual(failedMore.rows.last, .status(.loadMoreFailed(retryAfterSeconds: 5)))
        XCTAssertFalse(failedMore.canLoadMore)
    }

    func testCanLoadMoreOnlyWhenThereIsANextPageAndNothingIsRunning() {
        let posts = [card("a")]
        XCTAssertTrue(FeedSearchPresentation(state: state { $0.results = results(posts: posts, cursor: "c") }).canLoadMore)
        XCTAssertFalse(FeedSearchPresentation(state: state { $0.results = results(posts: posts) }).canLoadMore, "没有下一页")
        XCTAssertFalse(FeedSearchPresentation(state: state { $0.results = results(posts: posts, cursor: "c"); $0.loading = true }).canLoadMore, "在搜新的")
    }

    func testTypingANewWordKeepsTheOldResultsUntilTheNewOnesArrive() {
        let p = FeedSearchPresentation(state: state { $0.results = results(posts: [card("a")]); $0.loading = true })
        XCTAssertTrue(p.isRefreshing)
        XCTAssertEqual(p.rows, [.post(id: "a")])
    }
}

final class TellomiFeedTopicPresentationTests: XCTestCase {
    private func state(_ change: (inout FeedTopicState) -> Void = { _ in }) -> FeedTopicState {
        var s = FeedTopicState()
        s.loading = false
        s.loadedOnce = true
        change(&s)
        return s
    }

    private func present(_ s: FeedTopicState) -> FeedTopicPresentation { FeedTopicPresentation(state: s, slug: "food") }

    func testPagePriority() {
        XCTAssertEqual(present(FeedTopicState()).page, .loading)
        XCTAssertEqual(present(FeedTopicState()).rows, [.status(.loading)])
        XCTAssertEqual(present(state { $0.failed = true; $0.retryAfterSeconds = 8 }).rows, [.status(.failed(retryAfterSeconds: 8))])
        XCTAssertEqual(present(state { $0.gone = true }).rows, [.status(.gone)])
        XCTAssertEqual(present(state { $0.feedHidden = true; $0.gone = true }).page, .feedHidden, "feed_hidden 优先")
        XCTAssertEqual(present(state { $0.feedHidden = true }).rows, [])
    }

    func testFollowButtonOnlyOnContent() {
        XCTAssertEqual(present(state()).followButton, .follow)
        XCTAssertEqual(present(state { $0.following = true }).followButton, .following)
        XCTAssertTrue(present(state()).isFollowEnabled)
        XCTAssertEqual(present(state { $0.failed = true }).followButton, .hidden)
        XCTAssertEqual(present(state { $0.gone = true }).followButton, .hidden)
        XCTAssertEqual(present(FeedTopicState()).followButton, .hidden)
        XCTAssertFalse(present(FeedTopicState()).isFollowEnabled)
    }

    func testContentRows() {
        XCTAssertEqual(present(state()).rows, [.header, .status(.empty)])
        XCTAssertEqual(present(state { $0.posts = [card("a"), card("b")] }).rows, [.header, .post(id: "a"), .post(id: "b")])
        let more = present(state { $0.posts = [card("a")]; $0.cursor = "c"; $0.loading = true; $0.loadingMore = true })
        XCTAssertEqual(more.rows.last, .status(.loadingMore))
        XCTAssertFalse(more.canLoadMore)
        let refreshing = present(state { $0.posts = [card("a")]; $0.cursor = "c"; $0.loading = true })
        XCTAssertEqual(refreshing.rows, [.header, .post(id: "a")], "刷新时末尾不画翻页的转圈")
        let failedMore = present(state { $0.posts = [card("a")]; $0.cursor = "c"; $0.loadMoreFailed = true; $0.retryAfterSeconds = 3 })
        XCTAssertEqual(failedMore.rows.last, .status(.loadMoreFailed(retryAfterSeconds: 3)))
        XCTAssertFalse(failedMore.canLoadMore)
        XCTAssertTrue(present(state { $0.posts = [card("a")]; $0.cursor = "c" }).canLoadMore)
        XCTAssertFalse(present(state { $0.posts = [card("a")] }).canLoadMore, "没有下一页")
    }
}

// MARK: - 样例数据

final class TellomiFeedSampleSearchTests: XCTestCase {
    private func make() -> SampleFeedSource { SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0) }

    func testSearchFindsPostsAndPeopleByScopeAndPages() async throws {
        let source = make()
        let all = try await source.search(query: "山", scope: FeedAPI.searchAll, cursor: nil)
        XCTAssertEqual(all.users.map(\.id), ["s-1"])
        XCTAssertFalse(all.posts.isEmpty)
        XCTAssertTrue(all.posts.allSatisfy { ($0.text ?? "").contains("山") })

        let users = try await source.search(query: "山", scope: FeedAPI.searchUsers, cursor: nil)
        XCTAssertEqual(users.users.map(\.id), ["s-1"])
        XCTAssertEqual(users.posts, [])

        let cloud = try await source.search(query: "的", scope: FeedAPI.searchPosts, cursor: nil)
        XCTAssertEqual(cloud.users, [])
        XCTAssertEqual(cloud.posts.count, SampleFeedSource.searchPostsPageSize)
        let next = try XCTUnwrap(cloud.cursor)
        let second = try await source.search(query: "的", scope: FeedAPI.searchPosts, cursor: next)
        XCTAssertTrue(Set(cloud.posts.map(\.id)).isDisjoint(with: second.posts.map(\.id)))
        XCTAssertEqual(second.users, [])

        let none = try await source.search(query: "zzz", scope: FeedAPI.searchAll, cursor: nil)
        XCTAssertEqual(none, FeedSearchPage())
        let blank = try await source.search(query: "   ", scope: FeedAPI.searchAll, cursor: nil)
        XCTAssertEqual(blank, FeedSearchPage())
    }

    func testTopicPostsFollowAndUnknownSlug() async throws {
        let source = make()
        let first = try await source.topicPosts(slug: "food", cursor: nil)
        XCTAssertTrue(first.following, "样例里已经关注了 food")
        XCTAssertFalse(first.posts.isEmpty)
        XCTAssertTrue(first.posts.allSatisfy { $0.topics.contains { $0.slug == "food" } })
        let daily = try await source.topicPosts(slug: "daily", cursor: nil)
        XCTAssertFalse(daily.following)
        XCTAssertEqual(daily.posts.count, SampleFeedSource.topicPostsPageSize)
        let second = try await source.topicPosts(slug: "daily", cursor: try XCTUnwrap(daily.cursor))
        XCTAssertTrue(Set(daily.posts.map(\.id)).isDisjoint(with: second.posts.map(\.id)))

        try await source.setFollowingTopic(slug: "daily", following: true)
        let followedTopics = try await source.followedTopics()
        XCTAssertEqual(followedTopics, ["daily", "food"])
        let again = try await source.topicPosts(slug: "daily", cursor: nil)
        XCTAssertTrue(again.following)
        try await source.setFollowingTopic(slug: "food", following: false)
        let afterUnfollow = try await source.followedTopics()
        XCTAssertEqual(afterUnfollow, ["daily"])

        do {
            _ = try await source.topicPosts(slug: "nope", cursor: nil)
            XCTFail("不认识的话题应该 404")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 404)
            XCTAssertFalse(error.isFeedHidden)
        }
    }

    func testSimulationKnobs() async throws {
        let source = make()
        source.simulation.failsSearch = true
        await assertFails { _ = try await source.search(query: "山", scope: "all", cursor: nil) }
        source.simulation.failsSearch = false

        source.simulation.failsSearchMore = true
        _ = try await source.search(query: "的", scope: FeedAPI.searchPosts, cursor: nil)
        await assertFails { _ = try await source.search(query: "的", scope: FeedAPI.searchPosts, cursor: "3") }
        source.simulation.failsSearchMore = false

        source.simulation.searchThrottledRetryAfterSeconds = 25
        do {
            _ = try await source.search(query: "山", scope: "all", cursor: nil)
            XCTFail()
        } catch {
            XCTAssertEqual(FeedActionFailure.classify(error), .throttled(retryAfterSeconds: 25))
        }
        source.simulation.searchThrottledRetryAfterSeconds = nil

        source.simulation.topicThrottledRetryAfterSeconds = 9
        do {
            _ = try await source.topicPosts(slug: "food", cursor: nil)
            XCTFail()
        } catch {
            XCTAssertEqual(FeedActionFailure.classify(error), .throttled(retryAfterSeconds: 9))
        }
        source.simulation.topicThrottledRetryAfterSeconds = nil

        source.simulation.failsTopicFollow = true
        await assertFails { try await source.setFollowingTopic(slug: "food", following: false) }
        source.simulation.failsTopicFollow = false

        source.simulation.feedHidden = true
        do {
            _ = try await source.topicPosts(slug: "food", cursor: nil)
            XCTFail()
        } catch {
            XCTAssertEqual(FeedActionFailure.classify(error), .feedHidden)
        }
        do {
            _ = try await source.search(query: "山", scope: "all", cursor: nil)
            XCTFail()
        } catch {
            XCTAssertEqual(FeedActionFailure.classify(error), .feedHidden)
        }
    }

    private func assertFails(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("应该失败", file: file, line: line)
        } catch {}
    }
}
