//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 帖子详情页画什么（`FeedPostDetailPresentation`，纯逻辑）、样例来源里的详情数据（`SampleFeedSource` 的 `card` / `comments`），
/// 以及两者接在 `FeedPostDetailStore` 上的整条路径。页面本身（UIKit）不在这里测。

private func comment(_ id: String, parent: String? = nil, author: String? = nil, text: String? = nil) -> FeedCard {
    var card = FeedCard(id: id, kind: FeedCard.kindComment, author: author.map { FeedAuthor(profileId: "p-\($0)", displayName: $0) }, text: text ?? id)
    card.rootId = "p"
    card.parentId = parent
    return card
}

private func state(
    comments: [FeedCard] = [],
    cursor: String? = nil,
    loading: Bool = false,
    loadedOnce: Bool = true,
    failed: Bool = false,
    postGone: Bool = false,
) -> FeedPostDetailState {
    var state = FeedPostDetailState(post: FeedCard(id: "p"))
    state.comments = comments
    state.cursor = cursor
    state.loading = loading
    state.loadedOnce = loadedOnce
    state.failed = failed
    state.postGone = postGone
    return state
}

// MARK: - 纯逻辑

final class TellomiFeedDetailPresentationTests: XCTestCase {
    typealias P = FeedPostDetailPresentation

    func testTheFreshStateIsLoading() {
        XCTAssertEqual(P.commentsPhase(for: FeedPostDetailState(post: FeedCard(id: "p"))), .loading)
    }

    func testNotLoadedYetIsLoadingEvenWhenNothingIsInFlight() {
        XCTAssertEqual(P.commentsPhase(for: state(loading: false, loadedOnce: false)), .loading)
    }

    func testLoadedWithNoCommentsIsEmpty() {
        XCTAssertEqual(P.commentsPhase(for: state()), .empty)
    }

    func testFailedWithNoCommentsIsFailed() {
        XCTAssertEqual(P.commentsPhase(for: state(failed: true)), .failed)
    }

    func testRetryingAfterAFailureIsLoadingAgain() {
        // `refreshComments()` 开头：loading = true、failed = false；之前已经 loadedOnce
        XCTAssertEqual(P.commentsPhase(for: state(loading: true, loadedOnce: true, failed: false)), .loading)
    }

    func testCommentsAlreadyShownStayShownWhileRefreshingOrAfterAFailedRefresh() {
        let comments = [comment("a")]
        XCTAssertEqual(P.commentsPhase(for: state(comments: comments, loading: true)), .content)
        XCTAssertEqual(P.commentsPhase(for: state(comments: comments, failed: true)), .content)
        XCTAssertEqual(P.commentsPhase(for: state(comments: comments)), .content)
    }

    func testThePageIsGoneOnlyWhenTheCardApiSaidSo() {
        XCTAssertEqual(P.page(for: state()), .post)
        XCTAssertEqual(P.page(for: state(postGone: true)), .postGone)
    }

    func testRowsFollowTheThreadsAndMarkRepliesAndWhoTheyAnswer() {
        let comments = [
            comment("a", author: "Ann"),
            comment("b", author: "Bo"),
            comment("a1", parent: "a", author: "Cy"),
            comment("a2", parent: "a1", author: "Di"),
        ]
        let rows = P.commentRows(for: state(comments: comments))
        XCTAssertEqual(rows.map(\.comment.id), ["a", "a1", "a2", "b"])
        XCTAssertEqual(rows.map(\.isReply), [false, true, true, false])
        // 回的是楼主（a1 → a）不写「回复」；回的是楼里别人（a2 → a1）写被回复的人
        XCTAssertEqual(rows.map(\.replyToName), [nil, nil, "Cy", nil])
    }

    func testABlankAuthorNameIsNotShownAsAReplyTarget() {
        let comments = [comment("a"), comment("a1", parent: "a", author: "  "), comment("a2", parent: "a1")]
        let rows = P.commentRows(for: state(comments: comments))
        XCTAssertEqual(rows.map(\.replyToName), [nil, nil, nil])
    }

    func testNoCommentsNoRows() {
        XCTAssertEqual(P.commentRows(for: state()), [])
    }

    func testMoreCommentsNeedsACursorAndAtLeastOneComment() {
        XCTAssertTrue(P.hasMoreComments(for: state(comments: [comment("a")], cursor: "5")))
        XCTAssertFalse(P.hasMoreComments(for: state(comments: [comment("a")], cursor: nil)))
        XCTAssertFalse(P.hasMoreComments(for: state(comments: [], cursor: "5")))
    }

    func testTheTextIsTheBodyThenTheTranscriptThenNothing() {
        var voice = comment("v", text: "")
        XCTAssertNil(P.displayText(of: voice))
        voice.transcript = "  \n"
        XCTAssertNil(P.displayText(of: voice))
        voice.transcript = "你好"
        XCTAssertEqual(P.displayText(of: voice), "你好")
        voice.text = "正文"
        XCTAssertEqual(P.displayText(of: voice), "正文")
        voice.text = nil
        voice.transcript = ""
        XCTAssertNil(P.displayText(of: voice))
    }
}

// MARK: - 样例来源里的详情数据

final class TellomiFeedSampleDetailTests: XCTestCase {
    private func sample() -> SampleFeedSource {
        return SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
    }

    private func allComments(_ source: SampleFeedSource, _ postId: String) async throws -> [FeedCard] {
        var result = [FeedCard]()
        var cursor: String?
        repeat {
            let page = try await source.comments(postId: postId, cursor: cursor)
            result += page.comments
            cursor = page.cursor
        } while cursor != nil
        return result
    }

    func testCardLookupFindsSamplePostsAndNotTheGoneOneOrStrangers() async throws {
        let source = sample()
        let found = try await source.card(contentId: "sample-3")
        XCTAssertEqual(found?.id, "sample-3")
        let gone = try await source.card(contentId: "sample-7")
        XCTAssertNil(gone, "sample-7 是样例里「已不可见」的那条")
        let stranger = try await source.card(contentId: "nope")
        XCTAssertNil(stranger)
    }

    func testCardLookupCarriesTheLikeTheListShows() async throws {
        let source = sample()
        let before = try await source.card(contentId: "sample-3")
        try await source.setLiked(contentId: "sample-3", liked: true)
        let after = try await source.card(contentId: "sample-3")
        XCTAssertEqual(before?.viewer.liked, false)
        XCTAssertEqual(after?.viewer.liked, true)
        XCTAssertEqual(after?.stats.likes, (before?.stats.likes ?? 0) + 1)
    }

    func testEverySamplePostHasAsManyCommentsAsItsCardSays() async throws {
        let source = sample()
        for index in 0..<24 where index % 4 != 2 {   // sample-2、6、10…第一次会失败，下面单独测
            let id = "sample-\(index)"
            guard let card = try await source.card(contentId: id) else { continue }   // sample-7 看不到
            let comments = try await allComments(source, id)
            XCTAssertEqual(comments.count, card.stats.comments, id)
            XCTAssertEqual(Set(comments.map(\.id)).count, comments.count, "\(id) 的评论 id 不重复")
            XCTAssertTrue(comments.allSatisfy { $0.rootId == id && $0.kind == FeedCard.kindComment }, id)
        }
    }

    func testCommentsComeInPagesOfFive() async throws {
        let source = sample()
        let first = try await source.comments(postId: "sample-3", cursor: nil)   // 9 条
        XCTAssertEqual(first.comments.count, 5)
        XCTAssertEqual(first.cursor, "5")
        let second = try await source.comments(postId: "sample-3", cursor: first.cursor)
        XCTAssertEqual(second.comments.count, 4)
        XCTAssertNil(second.cursor)
    }

    func testPostsWithoutCommentsGiveAnEmptyPage() async throws {
        let source = sample()
        let page = try await source.comments(postId: "sample-4", cursor: nil)
        XCTAssertEqual(page, FeedCommentsPage())
        let stranger = try await source.comments(postId: "mine-0", cursor: nil)
        XCTAssertEqual(stranger, FeedCommentsPage())
    }

    func testTheFailingSamplesFailTheFirstLoadOnlyOnceAndNotTheNextPage() async throws {
        let source = sample()
        do {
            _ = try await source.comments(postId: "sample-2", cursor: nil)
            XCTFail("第一次应该失败")
        } catch {
            XCTAssertTrue(error is SampleFeedError)
        }
        let retry = try await source.comments(postId: "sample-2", cursor: nil)
        XCTAssertFalse(retry.comments.isEmpty)
        // 别的帖子不受影响，也不是每次都失败
        let other = try await source.comments(postId: "sample-3", cursor: nil)
        XCTAssertFalse(other.comments.isEmpty)
        let again = try await source.comments(postId: "sample-2", cursor: nil)
        XCTAssertFalse(again.comments.isEmpty)
    }

    func testSampleThreadsShowAReplyToAReply() async throws {
        let source = sample()
        let comments = try await allComments(source, "sample-11")   // 9 条：三楼，每楼三条（楼主、回楼主、回上一条回复）
        let rows = FeedPostDetailPresentation.commentRows(for: state(comments: comments))
        XCTAssertEqual(rows.map(\.isReply), [false, true, true, false, true, true, false, true, true])
        XCTAssertEqual(rows.map { $0.replyToName == nil }, [true, true, false, true, true, false, true, true, false])
        XCTAssertEqual(rows[2].replyToName, rows[1].comment.author?.displayName)
    }
}

// MARK: - 接在 FeedPostDetailStore 上

@MainActor
final class TellomiFeedSampleDetailStoreTests: XCTestCase {
    private func store(_ id: String) async throws -> FeedPostDetailStore {
        let source = SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
        let card = try await source.card(contentId: id) ?? FeedCard(id: id)
        return FeedPostDetailStore(initial: card, source: source)
    }

    func testAPostWithCommentsEndsInContentAndPagesToTheEnd() async throws {
        let store = try await store("sample-3")
        XCTAssertEqual(FeedPostDetailPresentation.commentsPhase(for: store.state), .loading)
        store.start()
        await store.waitForTasks()
        XCTAssertEqual(FeedPostDetailPresentation.page(for: store.state), .post)
        XCTAssertEqual(FeedPostDetailPresentation.commentsPhase(for: store.state), .content)
        XCTAssertEqual(store.state.comments.count, 5)
        XCTAssertTrue(FeedPostDetailPresentation.hasMoreComments(for: store.state))
        store.loadMoreComments()
        await store.waitForTasks()
        XCTAssertEqual(store.state.comments.count, 9)
        XCTAssertFalse(FeedPostDetailPresentation.hasMoreComments(for: store.state))
    }

    func testTheCardLatencyKnobDelaysTheGoneStateAndDefaultsToNone() async throws {
        let source = SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
        XCTAssertEqual(source.simulation.cardLatencyNanos, 0, "默认不等")
        source.simulation.cardLatencyNanos = 400_000_000
        let store = FeedPostDetailStore(initial: FeedCard(id: "sample-7"), source: source)
        store.start()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(store.state.postGone, "还在等 Card API：先显示帖子")
        await store.waitForTasks()
        XCTAssertTrue(store.state.postGone)
    }

    func testTheLikeKnobsDelayAndFailTheSampleLikeAndTheStoreRollsBack() async throws {
        let source = SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
        XCTAssertEqual(source.simulation.likeLatencyNanos, 0)
        XCTAssertFalse(source.simulation.failsLikes)
        let feed = FeedStore(source: source)
        feed.onTabShown(.recommend)
        await feed.waitForLoad(.recommend)
        let before = try XCTUnwrap(feed.card(id: "sample-3"))

        source.simulation.likeLatencyNanos = 200_000_000
        feed.toggleLike(id: "sample-3")
        XCTAssertEqual(feed.card(id: "sample-3")?.viewer.liked, true, "请求在路上：界面已经点亮")
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(feed.card(id: "sample-3")?.viewer.liked, true, "还在路上")
        let started = Date()
        await feed.waitForActions()
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.1, "样例真的等了一会儿才回")
        XCTAssertEqual(feed.card(id: "sample-3")?.stats.likes, before.stats.likes + 1)

        source.simulation.likeLatencyNanos = 0
        source.simulation.failsLikes = true
        feed.toggleLike(id: "sample-3")
        XCTAssertEqual(feed.card(id: "sample-3")?.viewer.liked, false)
        await feed.waitForActions()
        XCTAssertEqual(feed.card(id: "sample-3")?.viewer.liked, true, "失败：改回点过赞")
        XCTAssertEqual(feed.card(id: "sample-3")?.stats.likes, before.stats.likes + 1)
    }

    func testAPostWithoutCommentsEndsInEmpty() async throws {
        let store = try await store("sample-4")
        store.start()
        await store.waitForTasks()
        XCTAssertEqual(FeedPostDetailPresentation.commentsPhase(for: store.state), .empty)
    }

    func testAFailedLoadShowsFailedAndRetryGoesThroughLoadingToContent() async throws {
        let store = try await store("sample-2")
        store.start()
        await store.waitForTasks()
        XCTAssertEqual(FeedPostDetailPresentation.commentsPhase(for: store.state), .failed)
        store.refreshComments()
        XCTAssertEqual(FeedPostDetailPresentation.commentsPhase(for: store.state), .loading, "点重试：马上回到加载中")
        await store.waitForTasks()
        XCTAssertEqual(FeedPostDetailPresentation.commentsPhase(for: store.state), .content)
    }

    func testThePostThatCannotBeSeenAnymoreEndsInPostGone() async throws {
        let store = try await store("sample-7")
        XCTAssertEqual(FeedPostDetailPresentation.page(for: store.state), .post, "刚打开时先用信息流里的那张卡")
        store.start()
        await store.waitForTasks()
        XCTAssertEqual(FeedPostDetailPresentation.page(for: store.state), .postGone)
    }
}
