//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 详情页「···」菜单的逻辑层：错误分类（`FeedActionFailure`）、菜单有哪几项（`FeedDetailMenu`）、删自己的评论、举报、不感兴趣和信息流同步。
/// 界面（UIKit）不在这里测。

private struct MenuBoom: Error {}

private func post(_ id: String = "p", mine: Bool = false, comments: Int = 3) -> FeedCard {
    var card = FeedCard(id: id, kind: "post", author: FeedAuthor(profileId: "p-author", displayName: "A"), text: "t")
    card.viewer.isAuthor = mine
    card.stats.comments = comments
    return card
}

private func remark(_ id: String, mine: Bool = false, held: Bool = false, parent: String? = nil) -> FeedCard {
    var card = FeedCard(id: id, kind: FeedCard.kindComment, author: FeedAuthor(profileId: "p-\(id)", displayName: id), text: id)
    card.rootId = "p"
    card.parentId = parent
    card.viewer.isAuthor = mine
    card.held = held
    return card
}

// MARK: - 错误分类

final class TellomiFeedActionFailureTests: XCTestCase {
    func testThrottlingKeepsTheRetryAfterSeconds() {
        XCTAssertEqual(FeedActionFailure.classify(FeedAPIError(status: 429, code: nil, retryAfterSeconds: 30)), .throttled(retryAfterSeconds: 30))
        XCTAssertEqual(FeedActionFailure.classify(FeedAPIError(status: 429, code: "rate_limited")), .throttled(retryAfterSeconds: nil), "没有 Retry-After 头就是 nil")
        XCTAssertEqual(
            FeedActionFailure.classify(FeedAPIError(status: 429, code: FeedAPI.backoffCode, retryAfterSeconds: 7)),
            .throttled(retryAfterSeconds: 7),
            "本机退避（没发请求）也是限速",
        )
        XCTAssertEqual(FeedActionFailure.classify(FeedAPIError(status: 503, code: nil, retryAfterSeconds: 12)), .throttled(retryAfterSeconds: 12), "带 Retry-After 的 503")
    }

    func testAPlain5xxIsJustFailedAndNeverARetryHint() {
        XCTAssertEqual(FeedActionFailure.classify(FeedAPIError(status: 503, code: nil)), .failed)
        XCTAssertEqual(FeedActionFailure.classify(FeedAPIError(status: 500, code: "internal")), .failed)
        XCTAssertEqual(FeedActionFailure.classify(FeedAPIError(status: 502, code: nil, retryAfterSeconds: nil)), .failed)
    }

    func testFeedHiddenIsNotTheSameAsGone() {
        XCTAssertEqual(FeedActionFailure.classify(FeedAPIError(status: 404, code: "feed_hidden")), .feedHidden)
        XCTAssertEqual(FeedActionFailure.classify(FeedAPIError(status: 404, code: nil)), .gone)
        XCTAssertEqual(FeedActionFailure.classify(FeedAPIError(status: 404, code: "not_found")), .gone)
    }

    func testProfileRequiredAndOtherErrors() {
        XCTAssertEqual(FeedActionFailure.classify(FeedAPIError(status: 409, code: "profile_required")), .profileRequired)
        XCTAssertEqual(FeedActionFailure.classify(FeedAPIError(status: 403, code: "not_author")), .failed)
        XCTAssertEqual(FeedActionFailure.classify(MenuBoom()), .failed, "网络错误等非引擎错误")
    }
}

// MARK: - 菜单有哪几项

final class TellomiFeedDetailMenuTests: XCTestCase {
    func testSomeoneElsesPostHasNotInterestedAndReport() {
        XCTAssertEqual(FeedDetailMenu.items(forPost: post()), [.notInterested, .report])
    }

    func testMyPostHasItsOwnItemsThenDelete() {
        var card = post(mine: true)
        XCTAssertEqual(FeedDetailMenu.items(forPost: card), [.own(.pin), .own(.replySettings), .own(.hideLikes), .own(.insights), .deletePost])
        card.pinned = true
        card.stats.likeCountHidden = true
        XCTAssertEqual(FeedDetailMenu.items(forPost: card), [.own(.unpin), .own(.replySettings), .own(.showLikes), .own(.insights), .deletePost])
        XCTAssertFalse(FeedDetailMenu.items(forPost: card).contains(.report), "自己的帖子不能举报自己")
        XCTAssertFalse(FeedDetailMenu.items(forPost: card).contains(.notInterested))
    }

    func testCommentMenus() {
        XCTAssertEqual(FeedDetailMenu.items(forComment: remark("c", mine: true)), [.deleteComment])
        XCTAssertEqual(FeedDetailMenu.items(forComment: remark("c")), [.report])
        XCTAssertEqual(FeedDetailMenu.items(forComment: remark("c", mine: true, held: true)), [.deleteComment], "自己等着批准的评论也能删")
        XCTAssertEqual(FeedDetailMenu.items(forComment: remark("c", held: true)), [], "别人等着批准的评论（作者那边走批准 / 拒绝）不给举报")
        XCTAssertEqual(FeedDetailMenu.items(forComment: post()), [], "不是评论就没有评论菜单")
    }

    func testOnlyTheDeletesNeedAConfirmation() {
        XCTAssertTrue(FeedDetailMenuItem.deleteComment.needsConfirmation)
        XCTAssertTrue(FeedDetailMenuItem.deletePost.needsConfirmation)
        XCTAssertNotNil(FeedDetailMenuItem.deleteComment.confirmationTitleKey)
        XCTAssertNotNil(FeedDetailMenuItem.deletePost.confirmationTitleKey)
        for item in [FeedDetailMenuItem.notInterested, .report, .own(.pin), .own(.insights)] {
            XCTAssertFalse(item.needsConfirmation)
            XCTAssertNil(item.confirmationTitleKey)
            XCTAssertFalse(item.isDestructive)
        }
    }

    func testEveryItemHasADistinctTitleKey() {
        let all: [FeedDetailMenuItem] = [
            .notInterested, .report, .deleteComment, .deletePost,
            .own(.pin), .own(.unpin), .own(.hideLikes), .own(.showLikes), .own(.replySettings), .own(.insights),
        ]
        XCTAssertEqual(Set(all.map(\.titleKey)).count, all.count)
        XCTAssertTrue(all.allSatisfy { $0.titleKey.hasPrefix("TELLOMI_FEED_") })
    }

    @MainActor
    func testTheStateExposesThePostMenuFollowingWhoWroteIt() {
        var state = FeedPostDetailState(post: post())
        XCTAssertEqual(state.postMenu, [.notInterested, .report])
        state.post.viewer.isAuthor = true
        XCTAssertTrue(state.postMenu.contains(.deletePost))
    }
}

// MARK: - store：删评论、举报、不感兴趣

private final class MenuSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _deleteCalls = [String]()
    private var _reportCalls = [FeedReportRequest]()
    private var _notInterestedCalls = [String]()
    private var _undoCalls = [String]()
    private var _failure: Error?
    private var _held = false
    private var waiters = [CheckedContinuation<Void, Never>]()
    var timeline = [FeedCard]()
    var commentsPage = FeedCommentsPage()

    var deleteCalls: [String] { lock.withLock { _deleteCalls } }
    var reportCalls: [FeedReportRequest] { lock.withLock { _reportCalls } }
    var notInterestedCalls: [String] { lock.withLock { _notInterestedCalls } }
    var undoCalls: [String] { lock.withLock { _undoCalls } }
    /// 下一批删除 / 举报 / 不感兴趣都抛这个错（nil = 成功）。
    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    func holdDeletes() { lock.withLock { _held = true } }

    func releaseDeletes() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _held = false
            defer { waiters = [] }
            return waiters
        }
        toResume.forEach { $0.resume() }
    }

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage(cards: timeline) }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw MenuBoom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
    func comments(postId: String, cursor: String?) async throws -> FeedCommentsPage { commentsPage }

    func notInterested(contentId: String) async throws {
        lock.withLock { _notInterestedCalls.append(contentId) }
        if let error = failure { throw error }
    }

    func undoNotInterested(contentId: String) async throws {
        lock.withLock { _undoCalls.append(contentId) }
    }

    func deletePost(contentId: String) async throws {
        lock.withLock { _deleteCalls.append(contentId) }
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
        if let error = failure { throw error }
    }

    func report(_ request: FeedReportRequest) async throws {
        lock.withLock { _reportCalls.append(request) }
        if let error = failure { throw error }
    }
}

@MainActor
final class TellomiFeedDetailMenuStoreTests: XCTestCase {
    /// 信息流里有帖子 `p`（3 条评论），详情页打开并取到两条评论：`mine` 是自己的，`other` 是别人的。
    private func open(_ source: MenuSource, extra: [FeedCard] = []) async -> (FeedStore, FeedPostDetailStore) {
        source.timeline = [post()]
        source.commentsPage = FeedCommentsPage(comments: [remark("mine", mine: true), remark("other"), remark("reply", parent: "mine")] + extra, cursor: nil)
        let feed = FeedStore(source: source)
        feed.onTabShown(.recommend)
        await feed.waitForLoad(.recommend)
        let detail = FeedPostDetailStore(initial: feed.card(id: "p") ?? post(), source: source, feed: feed)
        detail.refreshComments()
        await detail.waitForTasks()
        XCTAssertEqual(detail.state.comments.count, 3 + extra.count)
        return (feed, detail)
    }

    // MARK: 删自己的评论

    func testDeletingMyCommentRemovesItDropsTheCountEverywhereAndNotices() async {
        let source = MenuSource()
        let (feed, detail) = await open(source)
        detail.deleteComment(detail.state.comments[0])
        XCTAssertEqual(detail.state.comments.count, 3, "引擎说删了之前还在")
        await detail.waitForTasks()
        XCTAssertEqual(source.deleteCalls, ["mine"])
        XCTAssertEqual(detail.state.comments.map(\.id), ["other", "reply"])
        XCTAssertEqual(detail.state.post.stats.comments, 2)
        XCTAssertEqual(feed.card(id: "p")?.stats.comments, 2, "信息流里的数也同步")
        XCTAssertEqual(detail.state.notice, .commentDeleted)
        XCTAssertEqual(detail.state.threads.map(\.root.id), ["other", "reply"], "它下面的回复找不到楼主，自己成一楼，不丢")
    }

    func testAFailedDeleteKeepsTheCommentAndNoticesFailedWithoutRetrying() async {
        let source = MenuSource()
        let (feed, detail) = await open(source)
        source.failure = MenuBoom()
        detail.deleteComment(detail.state.comments[0])
        await detail.waitForTasks()
        XCTAssertEqual(detail.state.comments.count, 3)
        XCTAssertEqual(detail.state.post.stats.comments, 3)
        XCTAssertEqual(feed.card(id: "p")?.stats.comments, 3)
        XCTAssertEqual(detail.state.notice, .failed)
        XCTAssertEqual(source.deleteCalls, ["mine"], "不自动重试")

        detail.onNoticeShown()
        source.failure = nil
        detail.deleteComment(detail.state.comments[0])
        await detail.waitForTasks()
        XCTAssertEqual(source.deleteCalls, ["mine", "mine"], "用户再点一次才发")
        XCTAssertEqual(detail.state.comments.count, 2)
    }

    func testThrottledDeleteTellsHowLongToWait() async {
        let source = MenuSource()
        let (_, detail) = await open(source)
        source.failure = FeedAPIError(status: 429, code: nil, retryAfterSeconds: 45)
        detail.deleteComment(detail.state.comments[0])
        await detail.waitForTasks()
        XCTAssertEqual(detail.state.notice, .throttled)
        XCTAssertEqual(detail.state.retryAfterSeconds, 45)
        XCTAssertEqual(detail.state.comments.count, 3)
        XCTAssertEqual(source.deleteCalls.count, 1)

        detail.onNoticeShown()
        source.failure = FeedAPIError(status: 503, code: nil)
        detail.deleteComment(detail.state.comments[0])
        await detail.waitForTasks()
        XCTAssertEqual(detail.state.notice, .failed, "没有 Retry-After 的 503 只是失败")
    }

    func testFeedHiddenDuringADeleteClosesThePageInsteadOfToasting() async {
        let source = MenuSource()
        let (_, detail) = await open(source)
        source.failure = FeedAPIError(status: 404, code: "feed_hidden")
        detail.deleteComment(detail.state.comments[0])
        await detail.waitForTasks()
        XCTAssertTrue(detail.state.feedHidden)
        XCTAssertNil(detail.state.notice)
        XCTAssertEqual(detail.state.comments.count, 3, "没删成")
    }

    func testAnAlreadyDeletedCommentCountsAsDeleted() async {
        let source = MenuSource()
        let (_, detail) = await open(source)
        source.failure = FeedAPIError(status: 404, code: "not_found")
        detail.deleteComment(detail.state.comments[0])
        await detail.waitForTasks()
        XCTAssertEqual(detail.state.comments.map(\.id), ["other", "reply"])
        XCTAssertEqual(detail.state.notice, .commentDeleted)
        XCTAssertEqual(detail.state.post.stats.comments, 2)
    }

    func testSomeoneElsesCommentCannotBeDeletedHere() async {
        let source = MenuSource()
        let (_, detail) = await open(source)
        detail.deleteComment(detail.state.comments[1])
        detail.deleteComment(post())
        await detail.waitForTasks()
        XCTAssertEqual(source.deleteCalls, [])
        XCTAssertEqual(detail.state.comments.count, 3)
        XCTAssertNil(detail.state.notice)
    }

    func testTwoTapsOnDeleteSendOneRequestAndDropTheCountOnce() async {
        let source = MenuSource()
        let (_, detail) = await open(source)
        source.holdDeletes()
        let target = detail.state.comments[0]
        detail.deleteComment(target)
        detail.deleteComment(target)
        source.releaseDeletes()
        await detail.waitForTasks()
        XCTAssertEqual(source.deleteCalls, ["mine"])
        XCTAssertEqual(detail.state.post.stats.comments, 2)
        detail.deleteComment(target)
        await detail.waitForTasks()
        XCTAssertEqual(source.deleteCalls, ["mine"], "已经不在列表里的评论不再发")
    }

    func testDeletingTheCommentBeingRepliedToCancelsTheReply() async {
        let source = MenuSource()
        let (_, detail) = await open(source)
        detail.replyTo(detail.state.comments[0])
        XCTAssertEqual(detail.state.replyTarget?.id, "mine")
        detail.deleteComment(detail.state.comments[0])
        await detail.waitForTasks()
        XCTAssertNil(detail.state.replyTarget)
    }

    func testDeletingMyCommentThatWaitsForApprovalDoesNotChangeTheCount() async {
        let source = MenuSource()
        let (_, detail) = await open(source, extra: [remark("held-mine", mine: true, held: true)])
        let held = detail.state.comments[3]
        detail.deleteComment(held)
        await detail.waitForTasks()
        XCTAssertEqual(source.deleteCalls, ["held-mine"])
        XCTAssertEqual(detail.state.comments.count, 3)
        XCTAssertEqual(detail.state.post.stats.comments, 3, "待审的评论本来就没算进评论数")
    }

    func testTheCountNeverGoesBelowZero() async {
        let source = MenuSource()
        source.timeline = [post(comments: 0)]
        source.commentsPage = FeedCommentsPage(comments: [remark("mine", mine: true)], cursor: nil)
        let detail = FeedPostDetailStore(initial: post(comments: 0), source: source)
        detail.refreshComments()
        await detail.waitForTasks()
        detail.deleteComment(detail.state.comments[0])
        await detail.waitForTasks()
        XCTAssertEqual(detail.state.post.stats.comments, 0)
        XCTAssertEqual(detail.state.comments.count, 0)
    }

    // MARK: 不感兴趣

    func testNotInterestedInTheDetailTurnsTheListRowIntoAFeedbackCard() async {
        let source = MenuSource()
        let (feed, detail) = await open(source)
        var changes = [FeedChange]()
        let subscription = feed.subscribe { changes.append($0) }
        detail.notInterested()
        XCTAssertFalse(feed.hiddenIds.contains("p"), "引擎说成了才换")
        await detail.waitForTasks()
        XCTAssertEqual(source.notInterestedCalls, ["p"])
        XCTAssertTrue(feed.hiddenIds.contains("p"))
        XCTAssertEqual(detail.state.leaving, .notInterested)
        XCTAssertEqual(changes, [.list(nil)])
        subscription.cancel()

        feed.undoNotInterested("p")
        await feed.waitForActions()
        XCTAssertFalse(feed.hiddenIds.contains("p"), "在列表里还能撤销")
    }

    func testAFailedNotInterestedLeavesTheListAlone() async {
        let source = MenuSource()
        let (feed, detail) = await open(source)
        source.failure = MenuBoom()
        detail.notInterested()
        await detail.waitForTasks()
        XCTAssertFalse(feed.hiddenIds.contains("p"))
        XCTAssertNil(detail.state.leaving)
        XCTAssertEqual(detail.state.notice, .failed)

        detail.onNoticeShown()
        source.failure = FeedAPIError(status: 429, code: nil, retryAfterSeconds: 9)
        detail.notInterested()
        await detail.waitForTasks()
        XCTAssertEqual(detail.state.notice, .throttled)
        XCTAssertEqual(detail.state.retryAfterSeconds, 9)

        detail.onNoticeShown()
        source.failure = FeedAPIError(status: 409, code: "profile_required")
        detail.notInterested()
        await detail.waitForTasks()
        XCTAssertEqual(detail.state.notice, .hideProfileRequired, "原来的提示不变")
    }

    func testMarkNotInterestedIsIdempotentAndSendsNothing() async {
        let source = MenuSource()
        let (feed, _) = await open(source)
        var changes = 0
        let subscription = feed.subscribe { _ in changes += 1 }
        feed.markNotInterested(id: "p")
        feed.markNotInterested(id: "p")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(source.notInterestedCalls, [])
        XCTAssertEqual(source.undoCalls, [])
        subscription.cancel()
    }

    func testNotInterestedWithoutASharedFeedStillWorks() async {
        let source = MenuSource()
        let detail = FeedPostDetailStore(initial: post(), source: source)
        detail.notInterested()
        await detail.waitForTasks()
        XCTAssertEqual(detail.state.leaving, .notInterested)
    }

    // MARK: 举报

    func testReportingThePostAndAComment() async throws {
        let source = MenuSource()
        let (_, detail) = await open(source)
        let postReport = detail.reportStore()
        postReport.pick(try XCTUnwrap(postReport.state.groups.first?.reasons.first))
        postReport.submit()
        await postReport.waitForTasks()
        XCTAssertTrue(postReport.state.sent)
        XCTAssertEqual(source.reportCalls.first?.targetType, "content")
        XCTAssertEqual(source.reportCalls.first?.targetId, "p")

        let commentReport = detail.reportStore(forComment: detail.state.comments[1])
        commentReport.pick(try XCTUnwrap(commentReport.state.groups.first?.reasons.first))
        commentReport.submit()
        await commentReport.waitForTasks()
        XCTAssertEqual(source.reportCalls.last?.targetId, "other")
        XCTAssertEqual(source.reportCalls.count, 2)

        XCTAssertNil(detail.state.notice)
        detail.onReported()
        XCTAssertEqual(detail.state.notice, .reported)
    }

    func testReportErrorsAreClassified() async throws {
        let source = MenuSource()
        let (_, detail) = await open(source)
        let cases: [(Error, FeedReportState.ReportError)] = [
            (FeedAPIError(status: 404, code: nil), .gone),
            (FeedAPIError(status: 404, code: "feed_hidden"), .feedHidden),
            (FeedAPIError(status: 429, code: nil, retryAfterSeconds: 12), .throttled(retryAfterSeconds: 12)),
            (FeedAPIError(status: 503, code: nil, retryAfterSeconds: 3), .throttled(retryAfterSeconds: 3)),
            (FeedAPIError(status: 500, code: nil), .failed),
            (MenuBoom(), .failed),
        ]
        for (error, expected) in cases {
            source.failure = error
            let report = detail.reportStore()
            report.pick(try XCTUnwrap(report.state.groups.first?.reasons.first))
            report.submit()
            await report.waitForTasks()
            XCTAssertEqual(report.state.error, expected)
            XCTAssertFalse(report.state.sent)
            XCTAssertFalse(report.state.sending)
            XCTAssertTrue(report.state.canSubmit, "失败后可以再点一次提交；不自动重试")
        }
        XCTAssertEqual(source.reportCalls.count, cases.count, "每个只发一次")
    }
}

// MARK: - 样例来源

final class TellomiFeedSampleMenuTests: XCTestCase {
    private func sampleSource() -> SampleFeedSource {
        return SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
    }

    private func commentCount(_ source: SampleFeedSource, _ id: String) async throws -> Int {
        let card = try await source.card(contentId: id)
        return try XCTUnwrap(card).stats.comments
    }

    func testSampleDeleteRemovesMyOwnCommentAndTheCountFollows() async throws {
        let source = sampleSource()
        let before = try await commentCount(source, "sample-1")
        _ = try await source.postComment(postId: "sample-1", text: "hi", parentId: nil)
        let afterPost = try await commentCount(source, "sample-1")
        XCTAssertEqual(afterPost, before + 1)
        try await source.deletePost(contentId: "sample-1-m0")
        let afterDelete = try await commentCount(source, "sample-1")
        XCTAssertEqual(afterDelete, before)
        let page = try await source.comments(postId: "sample-1", cursor: nil)
        XCTAssertFalse(page.comments.contains { $0.id == "sample-1-m0" })
        do {
            try await source.deletePost(contentId: "sample-1-m0")
            XCTFail("已经删了")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 404)
        }
    }

    func testSampleRefusesToDeleteSomeoneElsesComment() async throws {
        let source = sampleSource()
        let page = try await source.comments(postId: "sample-1", cursor: nil)
        let other = try XCTUnwrap(page.comments.first)
        do {
            try await source.deletePost(contentId: other.id)
            XCTFail("不是自己的")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.code, "not_author")
        }
    }

    func testSampleRecordsReportsAndTheKnobsFailThrottleHideAndDelay() async throws {
        let source = sampleSource()
        let request = FeedReportRequest(targetType: "content", targetId: "sample-1", group: "illegal", reason: "spam")
        try await source.report(request)
        XCTAssertEqual(source.reports, [request])

        source.simulation.failsReports = true
        do { try await source.report(request); XCTFail("应该失败") } catch {}
        source.simulation.failsReports = false

        source.simulation.throttledRetryAfterSeconds = 20
        do {
            try await source.report(request)
            XCTFail("应该被限速")
        } catch let error as FeedAPIError {
            XCTAssertEqual(FeedActionFailure.classify(error), .throttled(retryAfterSeconds: 20))
        }
        do { try await source.notInterested(contentId: "sample-1"); XCTFail("应该被限速") } catch {}
        do { try await source.deletePost(contentId: "sample-1-m0"); XCTFail("应该被限速") } catch {}
        source.simulation.throttledRetryAfterSeconds = nil

        source.simulation.feedHidden = true
        do {
            try await source.notInterested(contentId: "sample-1")
            XCTFail("动态关了")
        } catch let error as FeedAPIError {
            XCTAssertTrue(error.isFeedHidden)
        }
        source.simulation.feedHidden = false

        source.simulation.failsNotInterested = true
        do { try await source.notInterested(contentId: "sample-1"); XCTFail("应该失败") } catch {}
        source.simulation.failsNotInterested = false
        source.simulation.failsDeletes = true
        do { try await source.deletePost(contentId: "mine-0"); XCTFail("应该失败") } catch {}
        source.simulation.failsDeletes = false

        source.simulation.deleteLatencyNanos = 200_000_000
        let started = Date()
        _ = try? await source.deletePost(contentId: "mine-0")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.1)
        source.simulation.deleteLatencyNanos = 0

        let startedNow = Date()
        try await source.notInterested(contentId: "sample-1")
        XCTAssertLessThan(Date().timeIntervalSince(startedNow), 0.1, "默认不等")
        XCTAssertEqual(source.reports.count, 1, "失败 / 限速的举报没有记")
    }
}
