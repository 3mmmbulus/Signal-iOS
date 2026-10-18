//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 列表页和帖子详情页共用一个 `FeedStore`（唯一的数据来源）：订阅 / 按 id 取 / 借卡片 / 取回最新卡片的合并、
/// 点赞的乐观更新与回滚、发评论后的评论数、以及评论输入框的外观（`FeedCommentInputPresentation`）。
/// 只有逻辑，不碰 UIKit。

private struct Boom: Error {}

private func card(_ id: String, likes: Int = 3, comments: Int = 0) -> FeedCard {
    return FeedCard(id: id, text: "text \(id)", stats: FeedStats(likes: likes, comments: comments))
}

/// 可以把「点赞」卡在半路（`holdLikes`），测「请求还在路上」的那一段。
private final class SyncSource: FeedSource {
    private let lock = NSLock()
    private var _pages = [FeedTab: FeedTimelinePage]()
    private var _likeCalls = [String]()
    private var _repostCalls = [String]()
    private var _posted = [String]()
    private var _failLikes = false
    private var _failLikeCalls = Set<Int>()
    private var _failComment: Error?
    private var _commentState = FeedCreatePostResponse.statePublished
    private var _fresh: FeedCard?
    private var _held = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    var pages: [FeedTab: FeedTimelinePage] {
        get { lock.withLock { _pages } }
        set { lock.withLock { _pages = newValue } }
    }
    var likeCalls: [String] { lock.withLock { _likeCalls } }
    var repostCalls: [String] { lock.withLock { _repostCalls } }
    var posted: [String] { lock.withLock { _posted } }
    var failLikes: Bool {
        get { lock.withLock { _failLikes } }
        set { lock.withLock { _failLikes = newValue } }
    }
    /// 第几次点赞请求（从 0 数）要失败。
    var failLikeCalls: Set<Int> {
        get { lock.withLock { _failLikeCalls } }
        set { lock.withLock { _failLikeCalls = newValue } }
    }
    var failComment: Error? {
        get { lock.withLock { _failComment } }
        set { lock.withLock { _failComment = newValue } }
    }
    var commentState: String {
        get { lock.withLock { _commentState } }
        set { lock.withLock { _commentState = newValue } }
    }
    var fresh: FeedCard? {
        get { lock.withLock { _fresh } }
        set { lock.withLock { _fresh = newValue } }
    }

    func holdLikes() {
        lock.withLock { _held = true }
    }

    func releaseLikes() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _held = false
            defer { waiters = [] }
            return waiters
        }
        toResume.forEach { $0.resume() }
    }

    func config() async throws -> FeedConfig { FeedConfig() }

    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage {
        return lock.withLock { _pages[tab] ?? FeedTimelinePage() }
    }

    func setLiked(contentId: String, liked: Bool) async throws {
        let index = lock.withLock { () -> Int in
            _likeCalls.append("\(contentId):\(liked)")
            return _likeCalls.count - 1
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if _held {
                    waiters.append(continuation)
                    return false
                }
                return true
            }
            if resumeNow { continuation.resume() }
        }
        if failLikes || failLikeCalls.contains(index) { throw Boom() }
    }

    func setReposted(contentId: String, reposted: Bool) async throws {
        lock.withLock { _repostCalls.append("\(contentId):\(reposted)") }
    }

    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func card(contentId: String) async throws -> FeedCard? {
        return fresh
    }

    func comments(postId: String, cursor: String?) async throws -> FeedCommentsPage {
        return FeedCommentsPage()
    }

    func postComment(postId: String, text: String, parentId: String?) async throws -> String {
        lock.withLock { _posted.append("\(text)|\(parentId ?? "-")") }
        if let error = failComment { throw error }
        return commentState
    }
}

/// 在测试里记下 store 发过的通知。
@MainActor
private final class Recorder {
    var changes = [FeedChange]()
    var subscription: FeedSubscription?

    init(_ feed: FeedStore) {
        subscription = feed.subscribe { [weak self] change in
            self?.changes.append(change)
        }
    }
}

// MARK: - FeedStore：订阅、按 id、借卡片、合并、点赞

@MainActor
final class TellomiFeedStoreSyncTests: XCTestCase {
    private func loadedStore(_ source: SyncSource, cards: [FeedCard]) async -> FeedStore {
        source.pages = [.recommend: FeedTimelinePage(cards: cards)]
        let feed = FeedStore(source: source)
        feed.onTabShown(.recommend)
        await feed.waitForLoad(.recommend)
        return feed
    }

    func testEverySubscriberHearsACardChangeAndTheOldOnChangeStillWorks() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a")])
        let first = Recorder(feed), second = Recorder(feed)
        var legacy = [FeedTab?]()
        feed.onChange = { legacy.append($0) }

        feed.toggleLike(id: "a")
        XCTAssertEqual(first.changes, [.cards(["a"])])
        XCTAssertEqual(second.changes, [.cards(["a"])])
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(feed.subscriberCount, 2)
        await feed.waitForActions()
        XCTAssertEqual(first.changes, [.cards(["a"])], "成功了不再通知")
    }

    func testACancelledOrReleasedSubscriberHearsNothingMore() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a")])
        let cancelled = Recorder(feed)
        var released: Recorder? = Recorder(feed)
        let kept = Recorder(feed)
        XCTAssertEqual(feed.subscriberCount, 3)

        cancelled.subscription?.cancel()
        let weakReleased = released.map { WeakBox($0) }
        released = nil
        XCTAssertNil(weakReleased?.value, "放掉回执就是取消订阅，store 没有强引用它")

        feed.toggleLike(id: "a")
        await feed.waitForActions()
        XCTAssertEqual(cancelled.changes, [])
        XCTAssertEqual(kept.changes, [.cards(["a"])])
        XCTAssertEqual(feed.subscriberCount, 1)
    }

    func testASubscriberMayCancelItselfInsideTheCallback() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a")])
        var calls = 0
        var selfCancelling: FeedSubscription?
        selfCancelling = feed.subscribe { _ in
            calls += 1
            selfCancelling?.cancel()
        }
        let other = Recorder(feed)
        feed.toggleLike(id: "a")
        feed.toggleLike(id: "a")
        await feed.waitForActions()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(other.changes.count, 2)
    }

    func testLikeByIdIsOptimisticOnEveryCopyAndSurvivesSuccess() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        feed.toggleLike(id: "a")
        XCTAssertEqual(feed.card(id: "a")?.viewer.liked, true)
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 4)
        XCTAssertEqual(feed.tab(.recommend).cards[0].stats.likes, 4)
        await feed.waitForActions()
        XCTAssertEqual(source.likeCalls, ["a:true"])
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 4)
    }

    func testAFailedLikeRollsBackTellsSubscribersAndKeepsTheOldTransientError() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        let recorder = Recorder(feed)
        var errors = [FeedStore.TransientError]()
        feed.onTransientError = { errors.append($0) }
        source.failLikes = true

        feed.toggleLike(id: "a")
        await feed.waitForActions()
        XCTAssertEqual(feed.card(id: "a")?.viewer.liked, false)
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 3)
        XCTAssertEqual(recorder.changes, [.cards(["a"]), .cards(["a"]), .actionFailed(cardId: "a")])
        XCTAssertEqual(errors, [.actionFailed])
    }

    func testLikeByIdAlwaysStartsFromTheStoresCurrentCardSoQuickTapsAlternate() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        feed.toggleLike(id: "a")
        feed.toggleLike(id: "a")
        feed.toggleLike(id: "a")
        XCTAssertEqual(feed.card(id: "a")?.viewer.liked, true)
        await feed.waitForActions()
        XCTAssertEqual(source.likeCalls, ["a:true", "a:false", "a:true"])
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 4)
    }

    func testQuickTapsOnOneCardAreSentOneAtATimeInOrder() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        source.holdLikes()
        feed.toggleLike(id: "a")
        feed.toggleLike(id: "a")
        feed.toggleLike(id: "a")
        await Task.yield()
        for _ in 0..<50 where source.likeCalls.isEmpty { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(source.likeCalls, ["a:true"], "第一个还没回来，后面的不发")
        XCTAssertEqual(feed.card(id: "a")?.viewer.liked, true, "界面照样马上变")
        source.releaseLikes()
        for _ in 0..<200 where source.likeCalls.count < 3 { try? await Task.sleep(nanoseconds: 5_000_000); source.releaseLikes() }
        await feed.waitForActions()
        XCTAssertEqual(source.likeCalls, ["a:true", "a:false", "a:true"])
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 4)
    }

    func testLikesOnDifferentCardsDoNotWaitForEachOther() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a"), card("b")])
        source.holdLikes()
        feed.toggleLike(id: "a")
        feed.toggleLike(id: "b")
        for _ in 0..<200 where source.likeCalls.count < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(Set(source.likeCalls), ["a:true", "b:true"])
        source.releaseLikes()
        await feed.waitForActions()
    }

    func testWhenTheLastOfSeveralQuickTapsFailsTheCardGoesBackToTheLastConfirmedState() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        let recorder = Recorder(feed)
        source.failLikeCalls = [1]   // true 成功，false 失败
        feed.toggleLike(id: "a")
        feed.toggleLike(id: "a")
        XCTAssertEqual(feed.card(id: "a")?.viewer.liked, false)
        await feed.waitForActions()
        XCTAssertEqual(source.likeCalls, ["a:true", "a:false"])
        XCTAssertEqual(feed.card(id: "a")?.viewer.liked, true, "服务器上是赞过的")
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 4)
        XCTAssertEqual(recorder.changes.filter { $0 == .actionFailed(cardId: "a") }.count, 1)
    }

    func testAnEarlierFailureIsSettledByTheLaterRequestAndDoesNotFlicker() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        let recorder = Recorder(feed)
        var errors = [FeedStore.TransientError]()
        feed.onTransientError = { errors.append($0) }
        source.failLikeCalls = [0]   // true 失败，false 成功，true 成功
        feed.toggleLike(id: "a")
        feed.toggleLike(id: "a")
        feed.toggleLike(id: "a")
        await feed.waitForActions()
        XCTAssertEqual(source.likeCalls, ["a:true", "a:false", "a:true"])
        XCTAssertEqual(feed.card(id: "a")?.viewer.liked, true)
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 4)
        XCTAssertEqual(errors, [])
        XCTAssertFalse(recorder.changes.contains(.actionFailed(cardId: "a")))
    }

    func testEveryQuickTapFailingGoesBackToTheOriginalState() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        source.failLikes = true
        feed.toggleLike(id: "a")
        feed.toggleLike(id: "a")
        feed.toggleLike(id: "a")
        await feed.waitForActions()
        XCTAssertEqual(feed.card(id: "a")?.viewer.liked, false)
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 3)
    }

    func testTwoQuickTapsBothFailingGoBackToTheOriginalNotTheInverseOfTheLastTap() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        source.failLikes = true
        feed.toggleLike(id: "a")   // true
        feed.toggleLike(id: "a")   // false（界面上和原来一样）
        await feed.waitForActions()
        XCTAssertEqual(source.likeCalls, ["a:true", "a:false"])
        XCTAssertEqual(feed.card(id: "a")?.viewer.liked, false)
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 3)
    }

    func testCancelledAndReleasedSubscriptionsAreSweptOutAfterTheNextNotification() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a")])
        var kept: FeedSubscription? = feed.subscribe { _ in }
        let cancelled = feed.subscribe { _ in }
        var released: FeedSubscription? = feed.subscribe { _ in }
        XCTAssertEqual(feed.subscriptionSlotCount, 3)
        cancelled.cancel()
        released = nil
        feed.updateCard("a") { $0.stats.likes += 1 }
        XCTAssertEqual(feed.subscriptionSlotCount, 1)
        XCTAssertEqual(feed.subscriberCount, 1)
        XCTAssertNil(released)
        XCTAssertNotNil(kept)
        kept = nil
    }

    func testLikingACardTheStoreDoesNotHaveDoesNothing() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a")])
        let recorder = Recorder(feed)
        feed.toggleLike(id: "nope")
        await feed.waitForActions()
        XCTAssertEqual(source.likeCalls, [])
        XCTAssertEqual(recorder.changes, [])
    }

    func testARetainedCardAndTheListCopyAreChangedTogetherAndTheListKeepsWorkingAfterRelease() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3), card("b")])
        var lease: FeedCardLease? = feed.retain(feed.card(id: "a")!)
        XCTAssertEqual(lease?.id, "a")

        feed.toggleLike(id: "a")
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 4)
        XCTAssertEqual(feed.tab(.recommend).cards[0].stats.likes, 4, "借着的那份和列表里的是同时改的")
        await feed.waitForActions()

        lease = nil
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 4, "放手后读的是列表里的那份，一样")
        XCTAssertEqual(feed.card(id: "b")?.stats.likes, 3)
    }

    func testACardThatIsNotInAnyListIsHeldOnlyWhileSomeoneHoldsIt() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a")])
        var lease: FeedCardLease? = feed.retain(card("z", likes: 5))
        XCTAssertEqual(feed.card(id: "z")?.stats.likes, 5)
        feed.toggleLike(id: "z")
        XCTAssertEqual(feed.card(id: "z")?.viewer.liked, true)
        await feed.waitForActions()
        XCTAssertEqual(source.likeCalls, ["z:true"])

        lease = nil
        XCTAssertNil(feed.card(id: "z"), "借的人放手了，不在列表里的卡片从 store 清掉")
        XCTAssertNotNil(feed.card(id: "a"))
        _ = lease
    }

    func testRetainingACardTheListAlreadyHasUsesTheStoresCurrentCopy() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        feed.toggleLike(id: "a")
        let stale = card("a", likes: 3)   // 调用方手上过期的那份
        let lease = feed.retain(stale)
        XCTAssertEqual(feed.card(id: "a")?.viewer.liked, true)
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 4)
        _ = lease
        await feed.waitForActions()
    }

    func testIngestUpdatesEveryCopyKeepsWhoRepostedAndTellsSubscribersOnlyWhenSomethingChanged() async {
        let source = SyncSource()
        var listCard = card("a", likes: 3, comments: 1)
        listCard.repostedBy = FeedRepostedBy(profileId: "r", displayName: "R")
        let feed = await loadedStore(source, cards: [listCard])
        let lease = feed.retain(listCard)
        let recorder = Recorder(feed)

        feed.ingest(card("a", likes: 9, comments: 5))
        XCTAssertEqual(feed.tab(.recommend).cards[0].stats.likes, 9)
        XCTAssertEqual(feed.tab(.recommend).cards[0].stats.comments, 5)
        XCTAssertEqual(feed.card(id: "a")?.stats.comments, 5)
        XCTAssertEqual(feed.tab(.recommend).cards[0].repostedBy?.profileId, "r", "Card API 不带「谁转发了」，列表专有的不丢")
        XCTAssertEqual(recorder.changes, [.cards(["a"])])

        feed.ingest(card("a", likes: 9, comments: 5))
        XCTAssertEqual(recorder.changes.count, 1, "没有变化不通知")
        _ = lease
    }

    func testIngestAndRefreshDoNotOverwriteALikeThatIsStillOnItsWay() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        let lease = feed.retain(card("a", likes: 3))
        source.holdLikes()
        feed.toggleLike(id: "a")   // 请求卡在半路

        feed.ingest(card("a", likes: 3, comments: 7))   // 取回来的是服务端还没点赞的旧值
        XCTAssertEqual(feed.card(id: "a")?.viewer.liked, true)
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 4)
        XCTAssertEqual(feed.card(id: "a")?.stats.comments, 7, "别的字段照常换成新的")

        source.pages = [.recommend: FeedTimelinePage(cards: [card("a", likes: 3)])]
        feed.refresh(.recommend)
        await feed.waitForLoad(.recommend)
        XCTAssertEqual(feed.tab(.recommend).cards[0].viewer.liked, true, "刷新列表也不把还在路上的赞盖掉")
        XCTAssertEqual(feed.tab(.recommend).cards[0].stats.likes, 4)

        source.releaseLikes()
        await feed.waitForActions()
        feed.ingest(card("a", likes: 4))   // 路上的请求回来之后，以服务端为准
        XCTAssertEqual(feed.card(id: "a")?.stats.likes, 4)
        _ = lease
    }
}

private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// MARK: - 详情页 store 接在信息流 store 上

@MainActor
final class TellomiFeedDetailSyncTests: XCTestCase {
    private func loadedStore(_ source: SyncSource, cards: [FeedCard]) async -> FeedStore {
        source.pages = [.recommend: FeedTimelinePage(cards: cards)]
        let feed = FeedStore(source: source)
        feed.onTabShown(.recommend)
        await feed.waitForLoad(.recommend)
        return feed
    }

    func testDetailOpenedFromTheListStartsFromTheStoresCurrentCardNotThePassedOne() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        feed.toggleLike(id: "a")
        let detail = FeedPostDetailStore(initial: card("a", likes: 3), source: source, feed: feed)
        XCTAssertTrue(detail.state.post.viewer.liked)
        XCTAssertEqual(detail.state.post.stats.likes, 4)
        await detail.waitForTasks()
    }

    func testALikeInTheDetailChangesTheListAndTheDetailAtOnceAndKeepsNoSeparateCopy() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        let detail = FeedPostDetailStore(initial: feed.tab(.recommend).cards[0], source: source, feed: feed)
        var detailChanges = 0
        detail.onChange = { _ in detailChanges += 1 }
        let list = Recorder(feed)

        detail.toggleLike()
        XCTAssertTrue(feed.tab(.recommend).cards[0].viewer.liked, "列表里的那张立刻变了")
        XCTAssertEqual(feed.tab(.recommend).cards[0].stats.likes, 4)
        XCTAssertTrue(detail.state.post.viewer.liked, "详情里是从同一个 store 读的")
        XCTAssertEqual(detail.state.post, feed.card(id: "a"))
        XCTAssertEqual(detailChanges, 1)
        XCTAssertEqual(list.changes, [.cards(["a"])])

        await detail.waitForTasks()
        XCTAssertEqual(source.likeCalls, ["a:true"], "只发一个请求")
        XCTAssertNil(detail.state.notice)
    }

    func testALikeInTheListChangesTheOpenDetail() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        let detail = FeedPostDetailStore(initial: feed.tab(.recommend).cards[0], source: source, feed: feed)
        var seen = [Bool]()
        detail.onChange = { seen.append($0.post.viewer.liked) }

        feed.toggleLike(feed.tab(.recommend).cards[0])
        XCTAssertTrue(detail.state.post.viewer.liked)
        XCTAssertEqual(seen, [true])
        await feed.waitForActions()

        // 两个方向混着点也一致
        detail.toggleLike()
        XCTAssertFalse(feed.tab(.recommend).cards[0].viewer.liked)
        XCTAssertEqual(detail.state.post, feed.card(id: "a"))
        await detail.waitForTasks()
        XCTAssertEqual(source.likeCalls, ["a:true", "a:false"])
    }

    func testAFailedLikeRollsBackListAndDetailAndOnlyTheDetailShowsTheNotice() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", likes: 3)])
        let detail = FeedPostDetailStore(initial: feed.tab(.recommend).cards[0], source: source, feed: feed)
        var listErrors = [FeedStore.TransientError]()
        feed.onTransientError = { listErrors.append($0) }
        source.failLikes = true

        detail.toggleLike()
        await detail.waitForTasks()
        XCTAssertFalse(detail.state.post.viewer.liked)
        XCTAssertEqual(detail.state.post.stats.likes, 3)
        XCTAssertFalse(feed.tab(.recommend).cards[0].viewer.liked)
        XCTAssertEqual(feed.tab(.recommend).cards[0].stats.likes, 3)
        XCTAssertEqual(detail.state.notice, .failed)
        XCTAssertEqual(listErrors, [.actionFailed], "列表页自己的提示照旧发（它不在屏幕上时界面不弹）")
    }

    func testADetailForAPostThatIsNotInTheListWorksAndLetsGoOfEverything() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a")])
        var detail: FeedPostDetailStore? = FeedPostDetailStore(initial: card("z", likes: 5), source: source, feed: feed)
        XCTAssertEqual(feed.subscriberCount, 1)

        detail?.toggleLike()
        XCTAssertEqual(detail?.state.post.stats.likes, 6)
        XCTAssertEqual(feed.card(id: "z")?.stats.likes, 6)
        await detail?.waitForTasks()

        detail = nil
        XCTAssertNil(feed.card(id: "z"))
        XCTAssertEqual(feed.subscriberCount, 0, "详情页销毁后不再订阅")
        XCTAssertNotNil(feed.card(id: "a"))
    }

    func testTheFreshCardFromTheDetailRefreshesTheListCopyAndKeepsWhoReposted() async {
        let source = SyncSource()
        var listCard = card("a", likes: 3, comments: 1)
        listCard.repostedBy = FeedRepostedBy(profileId: "r", displayName: nil)
        let feed = await loadedStore(source, cards: [listCard])
        source.fresh = card("a", likes: 9, comments: 5)
        let detail = FeedPostDetailStore(initial: listCard, source: source, feed: feed)

        detail.start()
        await detail.waitForTasks()
        XCTAssertEqual(feed.tab(.recommend).cards[0].stats.likes, 9)
        XCTAssertEqual(feed.tab(.recommend).cards[0].stats.comments, 5)
        XCTAssertEqual(feed.tab(.recommend).cards[0].repostedBy?.profileId, "r")
        XCTAssertEqual(detail.state.post, feed.card(id: "a"))
        XCTAssertFalse(detail.state.postGone)
    }

    func testAPostTheCardApiSaysIsGoneStaysInTheListUntilItRefreshesButTheDetailShowsGone() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a")])
        source.fresh = nil
        let detail = FeedPostDetailStore(initial: card("a"), source: source, feed: feed)
        detail.start()
        await detail.waitForTasks()
        XCTAssertTrue(detail.state.postGone)
        XCTAssertNotNil(feed.card(id: "a"), "详情不替列表删卡片")
    }

    func testAPublishedCommentBumpsTheCountEverywhereAndAPendingOneDoesNot() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a", comments: 2)])
        let detail = FeedPostDetailStore(initial: feed.tab(.recommend).cards[0], source: source, feed: feed)

        source.commentState = FeedCreatePostResponse.statePublished
        detail.onDraftChanged("hello")
        detail.send()
        await detail.waitForTasks()
        XCTAssertEqual(feed.tab(.recommend).cards[0].stats.comments, 3)
        XCTAssertEqual(detail.state.post.stats.comments, 3)
        XCTAssertEqual(detail.state.notice, .published)

        source.commentState = FeedCreatePostResponse.statePending
        detail.onDraftChanged("again")
        detail.send()
        await detail.waitForTasks()
        XCTAssertEqual(feed.tab(.recommend).cards[0].stats.comments, 3, "待审的别人看不到，不算")
        XCTAssertEqual(detail.state.notice, .pending)
    }

    func testRepostFromTheDetailIsSharedWithTheListToo() async {
        let source = SyncSource()
        let feed = await loadedStore(source, cards: [card("a")])
        let detail = FeedPostDetailStore(initial: feed.tab(.recommend).cards[0], source: source, feed: feed)
        detail.toggleRepost()
        XCTAssertTrue(feed.tab(.recommend).cards[0].viewer.reposted)
        await detail.waitForTasks()
        XCTAssertEqual(source.repostCalls, ["a:true"])
        XCTAssertTrue(detail.state.post.viewer.reposted)
        XCTAssertEqual(detail.state.notice, .reposted)
    }

    func testWithoutAFeedStoreTheDetailStillWorksOnItsOwn() async {
        let source = SyncSource()
        let detail = FeedPostDetailStore(initial: card("a", likes: 3), source: source)
        detail.toggleLike()
        XCTAssertTrue(detail.state.post.viewer.liked)
        await detail.waitForTasks()
        XCTAssertEqual(source.likeCalls, ["a:true"])
        source.failLikes = true
        detail.toggleLike()
        await detail.waitForTasks()
        XCTAssertTrue(detail.state.post.viewer.liked, "取消赞失败又改回赞过")
        XCTAssertEqual(detail.state.notice, .failed)
    }
}

// MARK: - 评论输入框的外观

final class TellomiFeedCommentInputTests: XCTestCase {
    typealias Input = FeedCommentInputPresentation

    private func state(draft: String = "", canComment: Bool = true, sending: Bool = false, reply: FeedCard? = nil) -> FeedPostDetailState {
        var state = FeedPostDetailState(post: FeedCard(id: "p"))
        state.draft = draft
        state.canComment = canComment
        state.sending = sending
        state.replyTarget = reply
        return state
    }

    private func reply(_ name: String?) -> FeedCard {
        return FeedCard(id: "c", kind: FeedCard.kindComment, author: name.map { FeedAuthor(profileId: "x", displayName: $0) })
    }

    func testThePlaceholderFollowsCommentReplyAndClosed() {
        XCTAssertEqual(Input(state: state()).placeholder, .comment)
        XCTAssertEqual(Input(state: state(reply: reply("小满"))).placeholder, .reply(name: "小满"))
        XCTAssertEqual(Input(state: state(reply: reply("  "))).placeholder, .reply(name: nil))
        XCTAssertEqual(Input(state: state(reply: reply(nil))).placeholder, .reply(name: nil))
        XCTAssertEqual(Input(state: state(canComment: false, reply: reply("小满"))).placeholder, .closed)
    }

    func testTheReplyBannerShowsOnlyWhileReplyingAndCommentingIsOpen() {
        XCTAssertNil(Input(state: state()).replyBanner)
        XCTAssertEqual(Input(state: state(reply: reply("小满"))).replyBanner, .init(name: "小满"))
        XCTAssertNil(Input(state: state(canComment: false, reply: reply("小满"))).replyBanner)
    }

    func testSubmitStepsHavePriorities() {
        XCTAssertEqual(Input(state: state()).submit, .empty)
        XCTAssertEqual(Input(state: state(draft: " \n ")).submit, .empty)
        XCTAssertEqual(Input(state: state(draft: "hi")).submit, .ready)
        XCTAssertEqual(Input(state: state(draft: "hi", sending: true)).submit, .sending)
        XCTAssertEqual(Input(state: state(draft: "hi", canComment: false)).submit, .cannotComment)
        XCTAssertEqual(Input(state: state(draft: "hi", canComment: false, sending: true)).submit, .cannotComment, "评论关了比正在发优先")
        let over = String(repeating: "a", count: FeedInputLimit.commentText + 1)
        XCTAssertEqual(Input(state: state(draft: over)).submit, .overLimit)
        XCTAssertEqual(Input(state: state(draft: over, sending: true)).submit, .sending)
    }

    func testTheSendButtonIsOnlyEnabledWhenTheStoreWouldActuallySend() {
        let over = String(repeating: "a", count: FeedInputLimit.commentText + 1)
        for draft in ["", "  ", "hi", over, String(repeating: "a", count: FeedInputLimit.commentText)] {
            for canComment in [true, false] {
                for sending in [true, false] {
                    let s = state(draft: draft, canComment: canComment, sending: sending)
                    XCTAssertEqual(Input(state: s).canSend, s.canSend, "draft \(draft.count) canComment \(canComment) sending \(sending)")
                }
            }
        }
    }

    func testTheCounterAppearsInTheLast50CodePointsAndCountsCodePointsNotCharacters() {
        XCTAssertNil(Input(state: state(draft: String(repeating: "字", count: 449))).counterRemaining)
        XCTAssertEqual(Input(state: state(draft: String(repeating: "字", count: 450))).counterRemaining, 50)
        XCTAssertEqual(Input(state: state(draft: String(repeating: "字", count: 500))).counterRemaining, 0)
        XCTAssertTrue(Input(state: state(draft: String(repeating: "字", count: 500))).canSend)
        // 一个家庭 emoji 是 5 个码点：100 个正好 500
        let family = String(repeating: "👨‍👩‍👧", count: 100)
        XCTAssertEqual(Input(state: state(draft: family)).counterRemaining, 0)
        XCTAssertTrue(Input(state: state(draft: family)).canSend)
        XCTAssertEqual(Input(state: state(draft: family + "a")).counterRemaining, -1)
        XCTAssertNil(Input(state: state(draft: "hi", canComment: false)).counterRemaining)
    }

    func testTheInputCannotBeEditedWhenClosedOrSending() {
        XCTAssertTrue(Input(state: state()).isEditable)
        XCTAssertFalse(Input(state: state(sending: true)).isEditable)
        XCTAssertFalse(Input(state: state(canComment: false)).isEditable)
    }

    func testTheLimitHitFlagIsPassedThrough() {
        var s = state()
        XCTAssertFalse(Input(state: s).limitHit)
        s.draftLimitHit = true
        XCTAssertTrue(Input(state: s).limitHit)
    }

    func testLikePresentationHidesZeroAndHiddenCounts() {
        var c = card("a", likes: 0)
        XCTAssertFalse(FeedLikePresentation(card: c).isLiked)
        XCTAssertNil(FeedLikePresentation(card: c).count)
        c.stats.likes = 12
        XCTAssertEqual(FeedLikePresentation(card: c).count, 12)
        c.stats.likeCountHidden = true
        XCTAssertNil(FeedLikePresentation(card: c).count)
        c.viewer.liked = true
        XCTAssertTrue(FeedLikePresentation(card: c).isLiked)
    }
}

// MARK: - 评论输入 + 发送，接在 FeedPostDetailStore 上

@MainActor
final class TellomiFeedCommentSubmitTests: XCTestCase {
    private func detail(_ source: SyncSource) -> FeedPostDetailStore {
        return FeedPostDetailStore(initial: card("p"), source: source)
    }

    func testPastingTooMuchIsCutAtTheCodePointLimitAndTheInputSaysSo() {
        let store = detail(SyncSource())
        let edit = store.onDraftEdit(range: NSRange(location: 0, length: 0), replacement: String(repeating: "字", count: 600))
        XCTAssertTrue(edit.clipped)
        XCTAssertEqual(FeedTextCap.count(store.state.draft), FeedInputLimit.commentText)
        let input = FeedCommentInputPresentation(state: store.state)
        XCTAssertEqual(input.counterRemaining, 0)
        XCTAssertTrue(input.limitHit)
        XCTAssertTrue(input.canSend)
    }

    func testIMEOverflowWhileComposingBlocksSendingUntilTheCompositionEndsAndIsCut() {
        let store = detail(SyncSource())
        store.onDraftChanged(String(repeating: "a", count: 503), composing: true)
        var input = FeedCommentInputPresentation(state: store.state)
        XCTAssertEqual(input.counterRemaining, -3)
        XCTAssertEqual(input.submit, .overLimit)
        XCTAssertFalse(input.canSend)
        store.send()
        XCTAssertFalse(store.state.sending, "超了不发")

        store.onDraftChanged(store.state.draft, composing: false)
        input = FeedCommentInputPresentation(state: store.state)
        XCTAssertEqual(input.counterRemaining, 0)
        XCTAssertEqual(input.submit, .ready)
    }

    func testSendingShowsSendingThenClearsTheDraftAndTheReplyTargetOnSuccess() async {
        let source = SyncSource()
        source.commentState = FeedCreatePostResponse.statePublished
        let store = detail(source)
        let target = FeedCard(id: "c1", kind: FeedCard.kindComment, author: FeedAuthor(profileId: "x", displayName: "小满"))
        store.replyTo(target)
        store.onDraftChanged("  hello  ")
        XCTAssertEqual(FeedCommentInputPresentation(state: store.state).submit, .ready)

        store.send()
        let during = FeedCommentInputPresentation(state: store.state)
        XCTAssertEqual(during.submit, .sending)
        XCTAssertFalse(during.isEditable)
        store.send()   // 连点只发一次
        await store.waitForTasks()

        XCTAssertEqual(source.posted, ["hello|c1"])
        let after = FeedCommentInputPresentation(state: store.state)
        XCTAssertEqual(after.submit, .empty)
        XCTAssertTrue(after.isEditable)
        XCTAssertNil(after.replyBanner)
        XCTAssertEqual(after.placeholder, .comment)
        XCTAssertEqual(store.state.notice, .published)
    }

    func testAFailedSendKeepsTheDraftAndTheReplyTargetAndCanBeRetried() async {
        let source = SyncSource()
        source.failComment = Boom()
        let store = detail(source)
        store.replyTo(FeedCard(id: "c1", kind: FeedCard.kindComment))
        store.onDraftChanged("hello")
        store.send()
        await store.waitForTasks()
        let input = FeedCommentInputPresentation(state: store.state)
        XCTAssertEqual(store.state.draft, "hello")
        XCTAssertEqual(input.submit, .ready, "失败后能再点发送")
        XCTAssertNotNil(input.replyBanner)
        XCTAssertEqual(store.state.notice, .failed)

        source.failComment = nil
        store.send()
        await store.waitForTasks()
        XCTAssertEqual(source.posted, ["hello|c1", "hello|c1"])
        XCTAssertEqual(FeedCommentInputPresentation(state: store.state).submit, .empty)
    }

    func testTheEngineClosingCommentsDisablesTheBoxButKeepsTheDraft() async {
        let source = SyncSource()
        source.failComment = FeedAPIError(status: 403, code: "comments_closed", retryAfterSeconds: nil)
        let store = detail(source)
        store.onDraftChanged("hello")
        store.send()
        await store.waitForTasks()
        let input = FeedCommentInputPresentation(state: store.state)
        XCTAssertEqual(input.placeholder, .closed)
        XCTAssertEqual(input.submit, .cannotComment)
        XCTAssertFalse(input.isEditable)
        XCTAssertEqual(store.state.draft, "hello")
        XCTAssertEqual(store.state.notice, .closed)
    }

    func testAnInvalidParentDropsTheReplyTargetButKeepsTheText() async {
        let source = SyncSource()
        source.failComment = FeedAPIError(status: 409, code: "invalid_parent", retryAfterSeconds: nil)
        let store = detail(source)
        store.replyTo(FeedCard(id: "gone", kind: FeedCard.kindComment))
        store.onDraftChanged("hello")
        store.send()
        await store.waitForTasks()
        let input = FeedCommentInputPresentation(state: store.state)
        XCTAssertNil(input.replyBanner)
        XCTAssertEqual(input.placeholder, .comment)
        XCTAssertEqual(input.submit, .ready)
        XCTAssertEqual(store.state.notice, .parentGone)
    }
}
