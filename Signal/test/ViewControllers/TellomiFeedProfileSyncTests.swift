//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 作者主页的逻辑层（第二轮）：和信息流共用 `FeedStore`（赞、屏蔽同步）、错误分类（限速 / `feed_hidden`）、
/// 页面要画什么（`FeedProfilePresentation`）、举报作者、样例数据。界面（UIKit）不在这里测。

private struct ProfBoom: Error {}

private final class ProfSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = [String]()
    var calls: [String] { lock.withLock { _calls } }
    private func log(_ call: String) { lock.withLock { _calls.append(call) } }

    var feedCards = [FeedCard]()
    var profileValue: FeedProfilePage? = FeedProfilePage(id: "p1", displayName: "Ann")
    var profileError: Error?
    var pages = [String: FeedProfilePostsPage]()
    var postsError: Error?
    var followError: Error?
    var blockError: Error?
    var hideError: Error?
    var likeError: Error?
    var reports = [FeedReportRequest]()
    var reportError: Error?

    private var held = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    /// 点赞请求先挂着，直到 `releaseLikes()`（看请求是不是一个一个发的）。
    func holdLikes() { lock.withLock { held = true } }

    func releaseLikes() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            held = false
            defer { waiters = [] }
            return waiters
        }
        toResume.forEach { $0.resume() }
    }

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage(cards: feedCards) }
    func setLiked(contentId: String, liked: Bool) async throws {
        log("like \(contentId) \(liked)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if held {
                    waiters.append(continuation)
                    return false
                }
                return true
            }
            if resumeNow { continuation.resume() }
        }
        if let likeError { throw likeError }
    }
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw ProfBoom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func profile(profileId: String) async throws -> FeedProfilePage? {
        log("profile")
        if let profileError { throw profileError }
        return profileValue
    }
    func profilePosts(profileId: String, cursor: String?) async throws -> FeedProfilePostsPage {
        log("posts \(cursor ?? "-")")
        if let postsError { throw postsError }
        return pages[cursor ?? ""] ?? FeedProfilePostsPage()
    }
    func setFollowing(profileId: String, following: Bool) async throws -> String {
        log("follow \(following)")
        if let followError { throw followError }
        return following ? "approved" : "none"
    }
    func setBlocked(profileId: String, blocked: Bool) async throws {
        log("block \(blocked)")
        if let blockError { throw blockError }
    }
    func setHideList(list: String, profileId: String, on: Bool) async throws {
        log("hide \(list) \(on)")
        if let hideError { throw hideError }
    }
    func report(_ request: FeedReportRequest) async throws {
        if let reportError { throw reportError }
        lock.withLock { reports.append(request) }
    }
}

private func card(_ id: String, author: String = "p1", likes: Int = 0, mine: Bool = false) -> FeedCard {
    var c = FeedCard(id: id, kind: "post", author: FeedAuthor(profileId: author, displayName: author), text: "t \(id)")
    c.stats.likes = likes
    c.viewer.isAuthor = mine
    return c
}

private func throttled(_ seconds: Int? = 20) -> FeedAPIError { FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds) }
private let feedHiddenError = FeedAPIError(status: 404, code: "feed_hidden")

@MainActor
final class TellomiFeedProfileSyncTests: XCTestCase {
    private func setUp(_ source: ProfSource) -> (FeedStore, FeedProfilePageStore) {
        source.pages = ["": FeedProfilePostsPage(posts: [card("a1", likes: 1), card("a2")], cursor: "c1"), "c1": FeedProfilePostsPage(posts: [card("a3")], cursor: nil)]
        source.feedCards = [card("a1", likes: 0), card("b1", author: "p2")]
        let feed = FeedStore(source: source)
        let store = FeedProfilePageStore(profileId: "p1", source: source, feed: feed)
        return (feed, store)
    }

    private func started(_ source: ProfSource) async -> (FeedStore, FeedProfilePageStore) {
        let (feed, store) = setUp(source)
        feed.onTabShown(.recommend)
        await feed.waitForLoad(.recommend)
        store.start()
        await store.waitForTasks()
        return (feed, store)
    }

    // MARK: 和信息流同步

    func testLoadedPostsRefreshTheFeedCopyAndShowTheFeedsCurrentCard() async {
        let source = ProfSource()
        let (feed, store) = await started(source)
        XCTAssertEqual(store.state.posts.map(\.id), ["a1", "a2"])
        XCTAssertEqual(feed.card(id: "a1")?.stats.likes, 1, "主页取到的更新的赞数换到了信息流里")
        XCTAssertEqual(store.leaseCount, 2)
        XCTAssertTrue(store.isObservingFeed)
        store.loadMorePosts()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a1", "a2", "a3"])
        XCTAssertEqual(store.leaseCount, 3)
    }

    func testLikingOnTheProfileChangesTheFeedAndLikingInTheFeedChangesTheProfile() async {
        let source = ProfSource()
        let (feed, store) = await started(source)
        store.toggleLike(store.state.posts[0])
        XCTAssertTrue(feed.card(id: "a1")?.viewer.liked ?? false, "信息流里那张同时点亮")
        XCTAssertTrue(store.state.posts[0].viewer.liked)
        XCTAssertEqual(store.state.posts[0].stats.likes, 2)
        await store.waitForTasks()
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("like") }, ["like a1 true"])

        feed.toggleLike(id: "a2")
        XCTAssertTrue(store.state.posts[1].viewer.liked, "信息流（或详情页）点的，主页跟着变")
        await feed.waitForActions()
    }

    /// 同一条帖子连点两下：请求一个一个发（后一个等前一个回来），最后落在服务器上的是最后一次点的（`FeedStore` 的点赞队列）。
    func testTwoQuickLikesGoOutOneAfterTheOther() async {
        let source = ProfSource()
        let (feed, store) = await started(source)
        source.holdLikes()
        store.toggleLike(store.state.posts[0])
        store.toggleLike(store.state.posts[0])
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("like") }, ["like a1 true"], "第二个要等第一个回来")
        source.releaseLikes()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("like") }, ["like a1 true", "like a1 false"])
        XCTAssertFalse(feed.card(id: "a1")?.viewer.liked ?? true)
    }

    func testALikeThatFailsIsRevertedEverywhereAndTheProfileShowsAFailedNotice() async {
        let source = ProfSource()
        let (feed, store) = await started(source)
        source.likeError = ProfBoom()
        store.toggleLike(store.state.posts[0])
        await store.waitForTasks()
        XCTAssertFalse(store.state.posts[0].viewer.liked)
        XCTAssertFalse(feed.card(id: "a1")?.viewer.liked ?? true)
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testDetachStopsFollowingTheFeedAndReleasesTheCards() async {
        let source = ProfSource()
        let (feed, store) = await started(source)
        let before = feed.subscriberCount
        store.detach()
        XCTAssertFalse(store.isObservingFeed)
        XCTAssertEqual(store.leaseCount, 0)
        XCTAssertEqual(feed.subscriberCount, before - 1)
        feed.toggleLike(id: "a1")
        XCTAssertFalse(store.state.posts[0].viewer.liked, "放手之后不再跟着变")
        await feed.waitForActions()
        store.detach()
    }

    func testBlockingTakesTheAuthorsCardsOutOfTheFeedAndOnlyTheirs() async {
        let source = ProfSource()
        source.profileValue = FeedProfilePage(id: "p1", displayName: "Ann")
        let (feed, store) = await started(source)
        XCTAssertNotNil(feed.card(id: "b1"))
        store.setBlocked(true)
        await store.waitForTasks()
        XCTAssertTrue(store.state.posts.isEmpty)
        XCTAssertEqual(store.leaseCount, 0)
        XCTAssertEqual(feed.tab(.recommend).cards.map(\.id), ["b1"], "p1 的帖子没了，别人的还在")
    }

    func testFailedBlockKeepsTheFeedAsItWas() async {
        let source = ProfSource()
        let (feed, store) = await started(source)
        source.blockError = ProfBoom()
        store.setBlocked(true)
        await store.waitForTasks()
        XCTAssertNotNil(feed.card(id: "a1"))
        XCTAssertEqual(store.state.notice, .failed)
        XCTAssertFalse(store.state.followBusy)
    }

    func testRemoveCardsByAuthorNotifiesOnlyWhenSomethingChanged() async {
        let source = ProfSource()
        let (feed, _) = await started(source)
        var changes = 0
        let subscription = feed.subscribe { _ in changes += 1 }
        feed.removeCards(byAuthor: "nobody")
        XCTAssertEqual(changes, 0)
        feed.removeCards(byAuthor: "p2")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(feed.tab(.recommend).cards.map(\.id), ["a1"])
        subscription.cancel()
    }

    // MARK: 错误分类

    func testFollowThrottledRollsBackWithTheSecondsAndFeedHiddenClosesThePage() async {
        let source = ProfSource()
        let (_, store) = await started(source)
        source.followError = throttled(20)
        store.follow()
        XCTAssertEqual(store.state.profile?.me.follow, "approved", "先乐观")
        await store.waitForTasks()
        XCTAssertEqual(store.state.profile?.me.follow, "none")
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 20)
        XCTAssertFalse(store.state.followBusy)
        store.onNoticeShown()
        XCTAssertNil(store.state.retryAfterSeconds)

        source.followError = throttled(nil)
        store.follow()
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertNil(store.state.retryAfterSeconds, "没有 Retry-After")

        source.followError = feedHiddenError
        store.follow()
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertFalse(store.state.gone, "feed_hidden 不是「看不到」")
        XCTAssertEqual(store.state.profile?.me.follow, "none")
    }

    func testFollowOnA404NotFoundIsGoneButProfileRequiredIsANotice() async {
        let source = ProfSource()
        let (_, store) = await started(source)
        source.followError = FeedAPIError(status: 409, code: "profile_required")
        store.follow()
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .profileRequired)
        XCTAssertFalse(store.state.gone)
        source.followError = FeedAPIError(status: 404, code: "not_found")
        store.follow()
        await store.waitForTasks()
        XCTAssertTrue(store.state.gone)
        XCTAssertTrue(store.state.posts.isEmpty)
        XCTAssertEqual(store.leaseCount, 0)
    }

    func testUnfollowBlockAndHideListsAreToldApartToo() async {
        let source = ProfSource()
        var p = FeedProfilePage(id: "p1", displayName: "Ann")
        p.me.follow = "approved"
        source.profileValue = p
        let (_, store) = await started(source)

        source.followError = throttled(7)
        store.unfollow()
        await store.waitForTasks()
        XCTAssertEqual(store.state.profile?.me.follow, "approved", "改回来")
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 7)
        store.onNoticeShown()

        source.followError = nil
        source.blockError = throttled(9)
        store.setBlocked(true)
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 9)
        XCTAssertFalse(store.state.profile?.me.blocked ?? true)
        store.onNoticeShown()

        source.blockError = nil
        source.hideError = throttled(11)
        store.setHidden(list: FeedAPI.hideMute, on: true)
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 11)
        XCTAssertEqual(store.state.hideState, FeedHideState(muted: false, hiddenFrom: false))
        store.onNoticeShown()

        source.hideError = feedHiddenError
        store.setHidden(list: FeedAPI.hideMute, on: true)
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertNil(store.state.notice)
    }

    func testProfileLoadFailuresAreToldApart() async {
        let source = ProfSource()
        source.profileError = FeedAPIError(status: 503, code: "unavailable", retryAfterSeconds: 30)
        let (_, store) = setUp(source)
        store.start()
        await store.waitForTasks()
        XCTAssertTrue(store.state.failed)
        XCTAssertEqual(store.state.retryAfterSeconds, 30)
        XCTAssertFalse(store.state.feedHidden)

        source.profileError = ProfBoom()
        store.refresh()
        await store.waitForTasks()
        XCTAssertTrue(store.state.failed)
        XCTAssertNil(store.state.retryAfterSeconds, "刷新时先清掉旧的秒数")

        source.profileError = feedHiddenError
        store.refresh()
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertFalse(store.state.failed)
    }

    func testPostsFailuresAreToldApart() async {
        let source = ProfSource()
        source.postsError = FeedAPIError(status: 404, code: "feed_hidden")
        let (_, store) = setUp(source)
        store.start()
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertFalse(store.state.gone, "feed_hidden 不是「看不到」")

        let second = ProfSource()
        second.postsError = throttled(5)
        let (_, other) = setUp(second)
        other.start()
        await other.waitForTasks()
        XCTAssertTrue(other.state.postsFailed)
        XCTAssertEqual(other.state.retryAfterSeconds, 5)
        XCTAssertFalse(other.state.gone)
    }

    // MARK: 回到页面、举报作者

    func testReappearingReloadsTheFirstPageAndDropsDeletedPosts() async {
        let source = ProfSource()
        let (_, store) = await started(source)
        XCTAssertEqual(store.state.posts.map(\.id), ["a1", "a2"])
        source.pages[""] = FeedProfilePostsPage(posts: [card("a2")], cursor: nil)
        store.onReappeared()
        XCTAssertEqual(store.state.posts.map(\.id), ["a1", "a2"], "回来的路上旧列表先留着")
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a2"])
        XCTAssertEqual(store.leaseCount, 1)
    }

    func testReappearingDoesNothingBeforeTheFirstLoadOrForAHiddenList() async {
        let source = ProfSource()
        let (_, store) = setUp(source)
        store.onReappeared()
        await store.waitForTasks()
        XCTAssertTrue(source.calls.isEmpty)

        var p = FeedProfilePage(id: "p1", displayName: "Ann")
        p.isPrivate = true
        source.profileValue = p
        store.start()
        await store.waitForTasks()
        let calls = source.calls.count
        store.onReappeared()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.count, calls, "私密且没关注：没有帖子可刷新")
    }

    func testReportingTheAuthorTargetsTheAuthorAndNoticesWhenSent() async throws {
        let source = ProfSource()
        let (_, store) = await started(source)
        let report = store.reportStore()
        report.pick(try XCTUnwrap(report.state.groups.first?.reasons.first))
        report.submit()
        await report.waitForTasks()
        XCTAssertTrue(report.state.sent)
        let sent = try XCTUnwrap(source.reports.first)
        XCTAssertEqual(sent.targetType, FeedReportRequest.targetAuthor)
        XCTAssertEqual(sent.targetId, "p1")
        store.onReported()
        XCTAssertEqual(store.state.notice, .reported)
        store.onFeedHidden()
        XCTAssertTrue(store.state.feedHidden)
    }
}

// MARK: - 页面画什么

final class TellomiFeedProfilePresentationTests: XCTestCase {
    func testOnlyNativeAuthorsWithAnIdOpenAProfile() {
        XCTAssertTrue(tellomiFeedCanOpenProfile(of: FeedAuthor(profileId: "p1", displayName: "Ann")))
        var external = FeedAuthor(profileId: "ext", displayName: "X")
        external.isNative = false
        XCTAssertFalse(tellomiFeedCanOpenProfile(of: external))
        XCTAssertFalse(tellomiFeedCanOpenProfile(of: FeedAuthor(profileId: "", displayName: "Nobody")))
        XCTAssertFalse(tellomiFeedCanOpenProfile(of: nil))
    }

    private func state(_ change: (inout FeedProfilePageState, inout FeedProfilePage) -> Void = { _, _ in }) -> FeedProfilePageState {
        var page = FeedProfilePage(id: "p1", displayName: "Ann")
        var state = FeedProfilePageState()
        state.loading = false
        change(&state, &page)
        state.profile = page
        return state
    }

    func testPagePhases() {
        XCTAssertEqual(FeedProfilePresentation(state: FeedProfilePageState()).page, .loading)
        var failed = FeedProfilePageState()
        failed.failed = true
        failed.retryAfterSeconds = 12
        failed.loading = false
        let failedPresentation = FeedProfilePresentation(state: failed)
        XCTAssertEqual(failedPresentation.page, .failed)
        XCTAssertEqual(failedPresentation.failedRetryAfterSeconds, 12)
        var gone = FeedProfilePageState()
        gone.gone = true
        XCTAssertEqual(FeedProfilePresentation(state: gone).page, .gone)
        var hidden = state()
        hidden.feedHidden = true
        hidden.gone = true
        XCTAssertEqual(FeedProfilePresentation(state: hidden).page, .feedHidden, "feed_hidden 优先")
        XCTAssertEqual(FeedProfilePresentation(state: state()).page, .content)
        XCTAssertNil(FeedProfilePresentation(state: state()).failedRetryAfterSeconds)
    }

    func testIdentityAndHeaderFields() {
        let handle = FeedProfilePresentation(state: state { _, p in p.handle = "ann"; p.tellomiNumber = "123"; p.bio = "  hi  "; p.badge = "official"; p.isPrivate = true; p.followers = 5; p.following = 6 })
        XCTAssertEqual(handle.identity, .handle("ann"))
        XCTAssertEqual(handle.bio, "hi")
        XCTAssertEqual(handle.badge, "official")
        XCTAssertTrue(handle.isPrivate)
        XCTAssertEqual(handle.followers, 5)
        XCTAssertEqual(handle.following, 6)
        XCTAssertEqual(FeedProfilePresentation(state: state { _, p in p.tellomiNumber = "123" }).identity, .tellomiNumber("123"))
        XCTAssertEqual(FeedProfilePresentation(state: state()).identity, .none)
        XCTAssertNil(FeedProfilePresentation(state: state { _, p in p.bio = "   " }).bio)
    }

    func testIpRegionOnlyWhenTheServerSaysSo() {
        XCTAssertNil(FeedProfilePresentation(state: state { _, p in p.ipRegionLabel = "四川" }).ipRegionLabel)
        XCTAssertEqual(FeedProfilePresentation(state: state { s, p in s.showIpRegion = true; p.ipRegionLabel = "四川" }).ipRegionLabel, "四川")
    }

    func testFollowButtonStates() {
        XCTAssertEqual(FeedProfilePresentation(state: state()).followButton, .follow)
        XCTAssertEqual(FeedProfilePresentation(state: state { _, p in p.me.follow = "pending" }).followButton, .requested)
        XCTAssertEqual(FeedProfilePresentation(state: state { _, p in p.me.follow = "approved" }).followButton, .following)
        XCTAssertEqual(FeedProfilePresentation(state: state { _, p in p.me.isSelf = true }).followButton, .hidden)
        XCTAssertEqual(FeedProfilePresentation(state: state { _, p in p.me.blocked = true }).followButton, .unblock)
        XCTAssertEqual(FeedProfilePresentation(state: state { _, p in p.me.blocked = true; p.me.follow = "approved" }).followButton, .unblock, "屏蔽优先")
        XCTAssertTrue(FeedProfilePresentation(state: state()).isFollowEnabled)
        XCTAssertFalse(FeedProfilePresentation(state: state { s, _ in s.followBusy = true }).isFollowEnabled, "在路上不响应第二下")
    }

    func testMenuItems() {
        XCTAssertEqual(FeedProfilePresentation(state: state { _, p in p.me.isSelf = true }).menu, [])
        XCTAssertEqual(FeedProfilePresentation(state: state()).menu, [.block, .report], "还没查到不看 / 不让看")
        XCTAssertEqual(FeedProfilePresentation(state: state { s, _ in s.hideState = FeedHideState(muted: false, hiddenFrom: false) }).menu, [.mute(on: true), .hideFrom(on: true), .block, .report])
        XCTAssertEqual(FeedProfilePresentation(state: state { s, _ in s.hideState = FeedHideState(muted: true, hiddenFrom: true) }).menu, [.mute(on: false), .hideFrom(on: false), .block, .report])
        XCTAssertEqual(FeedProfilePresentation(state: state { _, p in p.me.blocked = true }).menu, [.unblock, .report])
        XCTAssertEqual(FeedProfilePresentation(state: FeedProfilePageState()).menu, [], "还没加载出来没有菜单")
    }

    func testBodyDecision() {
        func body(_ change: @escaping (inout FeedProfilePageState, inout FeedProfilePage) -> Void) -> FeedProfilePresentation.Body {
            FeedProfilePresentation(state: state(change)).body
        }
        XCTAssertEqual(body { _, _ in }, .none, "帖子还没取回来")
        XCTAssertEqual(body { s, _ in s.postsLoadedOnce = true }, .empty)
        XCTAssertEqual(body { s, _ in s.posts = [card("a")]; s.postsLoadedOnce = true }, .posts)
        XCTAssertEqual(body { s, _ in s.postsFailed = true; s.postsLoadedOnce = true }, .postsFailed)
        XCTAssertEqual(body { s, _ in s.posts = [card("a")]; s.postsFailed = true }, .posts, "翻页失败：列表还在")
        XCTAssertEqual(body { _, p in p.isPrivate = true }, .privateLocked)
        XCTAssertEqual(body { _, p in p.isPrivate = true; p.me.follow = "approved" }, .none)
        XCTAssertEqual(body { _, p in p.isPrivate = true; p.me.friend = true }, .none)
        XCTAssertEqual(body { _, p in p.me.blocked = true; p.isPrivate = true }, .blockedByMe, "屏蔽优先")
        XCTAssertEqual(body { _, p in p.regionUnavailable = true }, .regionUnavailable)
        XCTAssertEqual(body { _, p in p.isPrivate = true; p.me.isSelf = true; p.regionUnavailable = false }, .none, "自己的私密账号照样看得到")
    }

    func testRowsForEachPageAndBody() {
        typealias Row = FeedProfilePresentation.Row
        func rows(_ change: @escaping (inout FeedProfilePageState, inout FeedProfilePage) -> Void = { _, _ in }) -> [Row] {
            FeedProfilePresentation(state: state(change)).rows
        }
        XCTAssertEqual(FeedProfilePresentation(state: FeedProfilePageState()).rows, [.status(.loading)])
        var failed = FeedProfilePageState()
        failed.failed = true
        failed.loading = false
        failed.retryAfterSeconds = 9
        XCTAssertEqual(FeedProfilePresentation(state: failed).rows, [.status(.failed(retryAfterSeconds: 9))])
        var gone = FeedProfilePageState()
        gone.gone = true
        XCTAssertEqual(FeedProfilePresentation(state: gone).rows, [.status(.gone)])
        var hidden = FeedProfilePageState()
        hidden.feedHidden = true
        XCTAssertEqual(FeedProfilePresentation(state: hidden).rows, [])

        XCTAssertEqual(rows(), [.header], "帖子还没取回来、也没在取")
        XCTAssertEqual(rows { s, _ in s.postsLoading = true }, [.header, .status(.loading)])
        XCTAssertEqual(rows { s, _ in s.postsLoadedOnce = true }, [.header, .status(.empty(isSelf: false))])
        XCTAssertEqual(rows { s, p in s.postsLoadedOnce = true; p.me.isSelf = true }, [.header, .status(.empty(isSelf: true))])
        XCTAssertEqual(rows { s, _ in s.postsFailed = true; s.postsLoadedOnce = true }, [.header, .status(.postsFailed)])
        XCTAssertEqual(rows { _, p in p.isPrivate = true }, [.header, .status(.privateLocked)])
        XCTAssertEqual(rows { _, p in p.me.blocked = true }, [.header, .status(.blocked)])
        XCTAssertEqual(rows { _, p in p.regionUnavailable = true }, [.header, .status(.regionUnavailable)])
        XCTAssertEqual(rows { s, _ in s.posts = [card("a"), card("b")] }, [.header, .post("a"), .post("b")])
        XCTAssertEqual(rows { s, _ in s.posts = [card("a")]; s.postsLoading = true }, [.header, .post("a"), .status(.loadingMore)])
        XCTAssertEqual(rows { s, _ in s.posts = [card("a")]; s.postsFailed = true }, [.header, .post("a"), .status(.loadMoreFailed)])
    }

    func testSpinnersAndPaging() {
        let first = FeedProfilePresentation(state: state { s, _ in s.postsLoading = true })
        XCTAssertTrue(first.showsPostsSpinner)
        XCTAssertFalse(first.showsLoadingMore)
        let more = FeedProfilePresentation(state: state { s, _ in s.posts = [card("a")]; s.postsLoading = true; s.cursor = "c" })
        XCTAssertFalse(more.showsPostsSpinner)
        XCTAssertTrue(more.showsLoadingMore)
        XCTAssertFalse(more.canLoadMore, "在取的时候不再取")
        let idle = FeedProfilePresentation(state: state { s, _ in s.posts = [card("a")]; s.cursor = "c" })
        XCTAssertTrue(idle.canLoadMore)
        XCTAssertFalse(FeedProfilePresentation(state: state { s, _ in s.posts = [card("a")] }).canLoadMore, "没有 cursor")
        let failedMore = FeedProfilePresentation(state: state { s, _ in s.posts = [card("a")]; s.postsFailed = true; s.cursor = "c" })
        XCTAssertTrue(failedMore.showsLoadMoreFailed)
        XCTAssertTrue(failedMore.canLoadMore)
        let locked = FeedProfilePresentation(state: state { s, p in p.isPrivate = true; s.postsLoading = true })
        XCTAssertFalse(locked.showsPostsSpinner, "私密的不转圈")
        let blocked = FeedProfilePresentation(state: state { s, p in p.me.blocked = true; s.posts = [card("a")]; s.cursor = "c" })
        XCTAssertFalse(blocked.canLoadMore)
    }
}

// MARK: - 样例数据

final class TellomiFeedSampleProfileTests: XCTestCase {
    private func source() -> SampleFeedSource {
        SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
    }

    private func page(_ source: SampleFeedSource, _ id: String) async throws -> FeedProfilePage {
        let value = try await source.profile(profileId: id)
        return try XCTUnwrap(value)
    }

    func testSampleProfilesCoverTheStates() async throws {
        let s = source()
        let followed = try await page(s, "s-1")
        XCTAssertEqual(followed.me.follow, "approved")
        XCTAssertEqual(followed.handle, "shanfeng")
        let privateOne = try await page(s, "s-2")
        XCTAssertTrue(privateOne.isPrivate)
        XCTAssertFalse(privateOne.canSeePosts)
        let region = try await page(s, "s-5")
        XCTAssertTrue(region.regionUnavailable)
        let me = try await page(s, "s-me")
        XCTAssertTrue(me.me.isSelf)
        let none = try await s.profile(profileId: "nobody")
        XCTAssertNil(none)
    }

    func testSampleFollowPrivateIsPendingAndBlockClearsFollow() async throws {
        let s = source()
        let pending = try await s.setFollowing(profileId: "s-2", following: true)
        XCTAssertEqual(pending, "pending")
        let privateOne = try await page(s, "s-2")
        XCTAssertEqual(privateOne.me.follow, "pending")
        let approved = try await s.setFollowing(profileId: "s-4", following: true)
        XCTAssertEqual(approved, "approved")
        let none = try await s.setFollowing(profileId: "s-4", following: false)
        XCTAssertEqual(none, "none")
        try await s.setBlocked(profileId: "s-1", blocked: true)
        let blocked = try await page(s, "s-1")
        XCTAssertTrue(blocked.me.blocked)
        XCTAssertEqual(blocked.me.follow, "none")
        try await s.setBlocked(profileId: "s-1", blocked: false)
        let unblocked = try await page(s, "s-1")
        XCTAssertFalse(unblocked.me.blocked)
        try await s.setHideList(list: FeedAPI.hideMute, profileId: "s-3", on: true)
        let muted = try await page(s, "s-3")
        XCTAssertTrue(muted.me.muted)
        XCTAssertFalse(muted.me.hiddenFrom)
    }

    func testSamplePostsPageByThreeAndOnlyThisAuthors() async throws {
        let s = source()
        var all = [FeedCard]()
        var cursor: String?
        var pages = 0
        repeat {
            let result = try await s.profilePosts(profileId: "s-1", cursor: cursor)
            XCTAssertLessThanOrEqual(result.posts.count, SampleFeedSource.profilePostsPageSize)
            all += result.posts
            cursor = result.cursor
            pages += 1
        } while cursor != nil && pages < 10
        XCTAssertGreaterThan(pages, 1, "能看到翻页")
        XCTAssertTrue(all.allSatisfy { $0.author?.profileId == "s-1" })
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }

    private func failure(_ body: () async throws -> Void) async -> FeedActionFailure? {
        do {
            try await body()
            return nil
        } catch {
            return FeedActionFailure.classify(error)
        }
    }

    func testSampleSimulationKnobsFailThrottleAndHide() async throws {
        let s = source()
        s.simulation.failsProfile = true
        var result = await failure { _ = try await s.profile(profileId: "s-1") }
        XCTAssertEqual(result, .failed)
        s.simulation.failsProfile = false
        s.simulation.profileThrottledRetryAfterSeconds = 30
        result = await failure { _ = try await s.profile(profileId: "s-1") }
        XCTAssertEqual(result, .throttled(retryAfterSeconds: 30))
        s.simulation.profileThrottledRetryAfterSeconds = nil
        s.simulation.failsProfilePosts = true
        result = await failure { _ = try await s.profilePosts(profileId: "s-1", cursor: nil) }
        XCTAssertEqual(result, .failed)
        s.simulation.failsProfilePosts = false
        s.simulation.failsFollow = true
        result = await failure { _ = try await s.setFollowing(profileId: "s-4", following: true) }
        XCTAssertEqual(result, .failed)
        s.simulation.failsFollow = false
        s.simulation.failsBlock = true
        result = await failure { try await s.setBlocked(profileId: "s-4", blocked: true) }
        XCTAssertEqual(result, .failed)
        s.simulation.failsBlock = false
        s.simulation.failsHideLists = true
        result = await failure { try await s.setHideList(list: FeedAPI.hideMute, profileId: "s-4", on: true) }
        XCTAssertEqual(result, .failed)
        s.simulation.failsHideLists = false
        s.simulation.throttledRetryAfterSeconds = 8
        result = await failure { try await s.setBlocked(profileId: "s-4", blocked: true) }
        XCTAssertEqual(result, .throttled(retryAfterSeconds: 8))
        s.simulation.throttledRetryAfterSeconds = nil
        s.simulation.feedHidden = true
        result = await failure { _ = try await s.profile(profileId: "s-1") }
        XCTAssertEqual(result, .feedHidden)
        result = await failure { try await s.setHideList(list: FeedAPI.hideMute, profileId: "s-1", on: true) }
        XCTAssertEqual(result, .feedHidden)
    }
}
