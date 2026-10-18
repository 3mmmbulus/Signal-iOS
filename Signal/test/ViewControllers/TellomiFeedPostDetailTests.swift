//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedPostDetailTests.swift (new file)
// I-4: comment threads, comments API wire shape, RemoteFeedSource comments / voice, and FeedPostDetailStore.
// Mirrors Android FeedCommentThreadsTest and FeedPostDetailViewModelTest.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

private func comment(_ id: String, parent: String? = nil, held: Bool = false) -> FeedCard {
    var card = FeedCard(id: id, kind: FeedCard.kindComment, text: id)
    card.rootId = "p"
    card.parentId = parent
    card.held = held
    return card
}

// MARK: - threads

final class TellomiFeedCommentThreadsTests: XCTestCase {
    func testRepliesAtAnyDepthHangUnderTheirTopLevelCommentInTimeOrder() {
        let threads = FeedCommentThreads.build([comment("a"), comment("b"), comment("a1", parent: "a"), comment("c"), comment("a2", parent: "a1"), comment("b1", parent: "b")])
        XCTAssertEqual(threads.map(\.root.id), ["a", "b", "c"])
        XCTAssertEqual(threads[0].replies.map(\.id), ["a1", "a2"])
        XCTAssertEqual(threads[1].replies.map(\.id), ["b1"])
        XCTAssertEqual(threads[2].replies, [])
    }

    func testAReplyToAReplyRemembersWhoItAnswersAReplyToTheTopDoesNot() {
        let threads = FeedCommentThreads.build([comment("a"), comment("a1", parent: "a"), comment("a2", parent: "a1")])
        XCTAssertEqual(Array(threads[0].replyTo.keys), ["a2"])
        XCTAssertEqual(threads[0].replyTo["a2"]?.id, "a1")
    }

    func testAReplyWhoseParentIsMissingBecomesItsOwnThread() {
        let threads = FeedCommentThreads.build([comment("a"), comment("x1", parent: "gone")])
        XCTAssertEqual(threads.map(\.root.id), ["a", "x1"])
    }

    func testAParentCycleDoesNotLoop() {
        let threads = FeedCommentThreads.build([comment("a", parent: "b"), comment("b", parent: "a")])
        let ids = Set(threads.flatMap { [$0.root.id] + $0.replies.map(\.id) })
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testAReplyArrivingBeforeItsParentKeepsTheParentsPlace() {
        // 先出现的是回复，它的楼主在后面：楼主排在回复第一次出现的位置（Android 的 `putIfAbsent`）
        let threads = FeedCommentThreads.build([comment("a1", parent: "a"), comment("z"), comment("a")])
        XCTAssertEqual(threads.map(\.root.id), ["a", "z"])
        XCTAssertEqual(threads[0].replies.map(\.id), ["a1"])
    }

    func testEmpty() {
        XCTAssertEqual(FeedCommentThreads.build([]), [])
    }
}

// MARK: - API + RemoteFeedSource

private final class ScriptedTransport: FeedHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script = [(Int, [String: String], String)]()
    private var _requests = [URLRequest]()

    func enqueue(_ status: Int, headers: [String: String] = [:], _ body: String = "") {
        lock.lock(); script.append((status, headers, body)); lock.unlock()
    }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    private func next(_ request: URLRequest) -> (Int, [String: String], String) {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        return script.isEmpty ? (500, [:], "") : script.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, headers, body) = next(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private struct FixedTokens: FeedTokenSource {
    func token(forceRefresh: Bool) async throws -> String { "t" }
}

private func body(_ request: URLRequest) -> String {
    return request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

private let commentCard = #"{"id":"c1","state":"ok","version":1,"card":{"kind":"comment","text":"hi","root_id":"p","parent_id":"c0","author":{"id":"u1","display_name":"山风"}},"stats":{"likes":2},"me":{"liked":true},"held":true}"#

final class TellomiFeedCommentsApiTests: XCTestCase {
    private func make() -> (FeedAPI, ScriptedTransport) {
        let transport = ScriptedTransport()
        return (FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens()), transport)
    }

    func testCommentsAreReadWithTheCursorAndABrokenOneIsDropped() async throws {
        let (api, transport) = make()
        transport.enqueue(200, #"{"comments":[\#(commentCard),{"id":"bad","card":"nope"}, 7],"cursor":"next"}"#)
        transport.enqueue(200, "{}")

        let first = try await api.comments(postId: "p", cursor: nil)
        let second = try await api.comments(postId: "p", cursor: "a b&c")

        XCTAssertEqual(first.cursor, "next")
        XCTAssertEqual(first.comments.map(\.id), ["c1", "bad"], "结构不对的那项按不可用留着 id，不整页失败")
        XCTAssertEqual(first.comments.compactMap { $0.toCard() }.map(\.id), ["c1"])
        let card = first.comments[0].toCard()!
        XCTAssertEqual(card.parentId, "c0")
        XCTAssertTrue(card.held)
        XCTAssertTrue(card.viewer.liked)
        XCTAssertNil(second.cursor)
        XCTAssertEqual(transport.requests.map { $0.httpMethod }, ["GET", "GET"])
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://feed.example.test/v1/feed/posts/p/comments")
        XCTAssertEqual(transport.requests[1].url?.query, "cursor=a%20b%26c")
    }

    func testCreateCommentBodies() async throws {
        let (api, transport) = make()
        for _ in 0..<3 { transport.enqueue(201, #"{"id":"n","state":"pending"}"#) }
        let direct = try await api.createComment(postId: "p", request: FeedCreateCommentRequest(text: "hi"))
        _ = try await api.createComment(postId: "p", request: FeedCreateCommentRequest(text: "re", parentId: "c0"))
        _ = try await api.createComment(postId: "p", request: FeedCreateCommentRequest(text: "", parentId: nil, mediaKeys: ["m/k.m4a"]))
        XCTAssertEqual(direct, FeedCreateCommentResponse(id: "n", state: "pending"))
        let requests = transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, Array(repeating: "/v1/feed/posts/p/comments", count: 3))
        XCTAssertEqual(requests.map { $0.httpMethod }, ["POST", "POST", "POST"])
        XCTAssertEqual(body(requests[0]), #"{"text":"hi"}"#, "直接评论不带 parent_id / media_keys")
        XCTAssertEqual(body(requests[1]), #"{"parent_id":"c0","text":"re"}"#)
        XCTAssertEqual(body(requests[2]), #"{"media_keys":["m\/k.m4a"],"text":""}"#.replacingOccurrences(of: "\\/", with: "/"))
    }

    func testApproveIsAPostWithoutABody() async throws {
        let (api, transport) = make()
        transport.enqueue(204)
        try await api.approveComment(postId: "p", commentId: "c1")
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertEqual(transport.requests[0].url?.path, "/v1/feed/posts/p/comments/c1/approve")
        XCTAssertNil(transport.requests[0].httpBody)
    }

    func testRemoteSourceMapsCardsCommentsAndSendsAVoiceCommentAfterTheUpload() async throws {
        let (api, transport) = make()
        let source = RemoteFeedSource(api: api)

        transport.enqueue(200, #"{"cards":[{"id":"p","state":"ok","card":{"kind":"post","text":"x"}}]}"#)
        transport.enqueue(200, #"{"cards":[{"id":"gone","state":"unavailable"}]}"#)
        let fresh = try await source.card(contentId: "p")
        let gone = try await source.card(contentId: "gone")
        XCTAssertEqual(fresh?.id, "p")
        XCTAssertNil(gone)

        transport.enqueue(200, #"{"comments":[\#(commentCard)],"cursor":"n"}"#)
        let page = try await source.comments(postId: "p", cursor: nil)
        XCTAssertEqual(page.comments.map(\.id), ["c1"])
        XCTAssertEqual(page.cursor, "n")

        transport.enqueue(201, #"{"id":"n","state":"published"}"#)
        let publishState = try await source.postComment(postId: "p", text: "  thanks \n", parentId: "c1")
        XCTAssertEqual(publishState, "published")
        XCTAssertEqual(body(transport.requests.last!), #"{"parent_id":"c1","text":"thanks"}"#, "发之前去掉首尾空白（Android `text.trim()`）")

        // 语音：tus 创建 → 传一块 → 带 media_keys 发评论（text 是空串）
        transport.enqueue(201, headers: ["Media-Key": "m/v1"], #"{"id":"u1","key":"m/v1"}"#)
        transport.enqueue(204, headers: ["Upload-Offset": "5"])
        transport.enqueue(201, #"{"id":"n2","state":"pending"}"#)
        let before = transport.requests.count
        let voiceState = try await source.postVoiceComment(postId: "p", audio: Data("audio".utf8), parentId: nil)
        XCTAssertEqual(voiceState, "pending")
        let voiceRequests = Array(transport.requests[before...])
        XCTAssertEqual(voiceRequests.map { $0.httpMethod }, ["POST", "PATCH", "POST"])
        XCTAssertEqual(voiceRequests[0].url?.path, "/v1/feed/media/uploads")
        XCTAssertEqual(voiceRequests[2].url?.path, "/v1/feed/posts/p/comments")
        XCTAssertEqual(body(voiceRequests[2]), #"{"media_keys":["m/v1"],"text":""}"#.replacingOccurrences(of: "\\/", with: "/"))
    }
}

// MARK: - store

private struct Boom: Error {}

/// 测试替身的方法在 `FeedStore` 的任务里并发地跑（不在主线程上），记录要加锁。
private final class CallLog<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [T]()
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}


private final class DetailSource: FeedSource {
    var fresh: FeedCard?
    var freshError: Error?
    var pages = [String: FeedCommentsPage]()   // cursor ("" = first) → page
    var commentsError: Error?
    var postResult: () throws -> String = { FeedCreatePostResponse.statePending }
    var voiceResult: () throws -> String = { FeedCreatePostResponse.statePending }
    var failing = Set<String>()
    private let postedLog = CallLog<String>(), voicesLog = CallLog<String>(), callLog = CallLog<String>(), cursorLog = CallLog<String?>()
    var posted: [String] { postedLog.all }
    var voices: [String] { voicesLog.all }
    var calls: [String] { callLog.all }
    var cursors: [String?] { cursorLog.all }

    func config() async throws -> FeedConfig {
        var config = FeedConfig()
        config.mediaBaseUrl = "https://media.example/"
        config.ipRegionVisible = true
        config.limits.editWindowSeconds = 123
        config.limits.voiceCommentMaxSeconds = 30
        return config
    }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {
        callLog.append("like \(contentId) \(liked)")
        if failing.contains("like") { throw Boom() }
    }
    func notInterested(contentId: String) async throws {
        callLog.append("notInterested \(contentId)")
        if failing.contains("notInterested") { throw FeedAPIError(status: 409, code: "profile_required", retryAfterSeconds: nil) }
    }
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func card(contentId: String) async throws -> FeedCard? {
        if let freshError { throw freshError }
        return fresh
    }
    func comments(postId: String, cursor: String?) async throws -> FeedCommentsPage {
        cursorLog.append(cursor)
        if let commentsError { throw commentsError }
        return pages[cursor ?? ""] ?? FeedCommentsPage()
    }
    func postComment(postId: String, text: String, parentId: String?) async throws -> String {
        postedLog.append("\(text)|\(parentId ?? "-")")
        return try postResult()
    }
    func postVoiceComment(postId: String, audio: Data, parentId: String?) async throws -> String {
        voicesLog.append("\(String(decoding: audio, as: UTF8.self))|\(parentId ?? "-")")
        return try voiceResult()
    }
    func approveComment(postId: String, commentId: String) async throws {
        callLog.append("approve \(commentId)")
        if failing.contains("approve") { throw Boom() }
    }
    func deletePost(contentId: String) async throws {
        callLog.append("delete \(contentId)")
        if failing.contains("delete") { throw Boom() }
    }
    func setSaved(contentId: String, saved: Bool) async throws { callLog.append("save \(contentId) \(saved)") }
    func setReposted(contentId: String, reposted: Bool) async throws {
        callLog.append("repost \(contentId) \(reposted)")
        if failing.contains("repost") { throw Boom() }
    }
    func vote(contentId: String, options: [Int]) async throws -> FeedPollState {
        callLog.append("vote \(contentId) \(options)")
        if failing.contains("vote") { throw Boom() }
        return FeedPollState(counts: [3, 1], voted: options)
    }
    func updatePostSettings(contentId: String, update: FeedPostSettingsUpdate) async throws {
        callLog.append("settings \(contentId)")
        if failing.contains("settings") { throw FeedAPIError(status: 409, code: "too_many_pinned", retryAfterSeconds: nil) }
    }
    func postInsights(contentId: String) async throws -> FeedPostInsights { FeedPostInsights(opens: 7) }
}

private final class FakeSaved: FeedSavedMessages {
    var fail = false
    func add(_ card: FeedCard) async throws { if fail { throw Boom() } }
    func remove(contentId: String) async throws { if fail { throw Boom() } }
}

@MainActor
final class TellomiFeedPostDetailStoreTests: XCTestCase {
    private let post = FeedCard(id: "p", text: "hello", viewer: FeedViewer(isAuthor: false))

    private func tempAudio(_ text: String = "audio") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func store(_ source: DetailSource, initial: FeedCard? = nil, saved: FeedSavedMessages? = nil) -> FeedPostDetailStore {
        return FeedPostDetailStore(initial: initial ?? post, source: source, savedMessages: saved)
    }

    func testStartRefreshesTheCardTakesTheConfigAndPagesTheComments() async {
        let source = DetailSource()
        var fresh = post
        fresh.stats.likes = 9
        source.fresh = fresh
        source.pages = [
            "": FeedCommentsPage(comments: [comment("a"), comment("b")], cursor: "c1"),
            "c1": FeedCommentsPage(comments: [comment("b"), comment("c")], cursor: nil),
        ]
        let store = store(source)
        XCTAssertTrue(store.state.loading)
        store.start()
        await store.waitForTasks()
        XCTAssertEqual(store.state.post.stats.likes, 9)
        XCTAssertEqual(store.state.mediaBaseUrl, "https://media.example/")
        XCTAssertTrue(store.state.showIpRegion)
        XCTAssertEqual(store.state.editWindowSeconds, 123)
        XCTAssertEqual(store.state.voiceMaxSeconds, 30)
        XCTAssertEqual(store.state.comments.map(\.id), ["a", "b"])
        XCTAssertEqual(store.state.cursor, "c1")
        XCTAssertFalse(store.state.loading)
        XCTAssertTrue(store.state.loadedOnce)

        store.loadMoreComments()
        await store.waitForTasks()
        XCTAssertEqual(store.state.comments.map(\.id), ["a", "b", "c"], "翻页按 id 去重")
        XCTAssertNil(store.state.cursor)
        store.loadMoreComments()
        await store.waitForTasks()
        XCTAssertEqual(source.cursors, [nil, "c1"], "没有下一页就不再取")
    }

    func testAPostThatIsGoneSaysSoAndAFailedRefreshKeepsTheFeedCopy() async {
        let gone = DetailSource()
        let first = store(gone)
        first.start()
        await first.waitForTasks()
        XCTAssertTrue(first.state.postGone)

        let failing = DetailSource()
        failing.freshError = Boom()
        failing.commentsError = Boom()
        let second = store(failing)
        second.start()
        await second.waitForTasks()
        XCTAssertFalse(second.state.postGone)
        XCTAssertEqual(second.state.post, post)
        XCTAssertTrue(second.state.failed)
        XCTAssertFalse(second.state.loading)
        XCTAssertTrue(second.state.loadedOnce)
    }

    func testSendingAReplyClearsTheBoxAndSaysItIsInReview() async {
        let source = DetailSource()
        let store = store(source)
        store.replyTo(comment("a"))
        store.onDraftChanged("  thanks  ")
        XCTAssertTrue(store.state.canSend)
        store.send()
        XCTAssertTrue(store.state.sending)
        XCTAssertFalse(store.state.canSend)
        await store.waitForTasks()
        XCTAssertEqual(source.posted, ["thanks|a"])
        XCTAssertEqual(store.state.draft, "")
        XCTAssertNil(store.state.replyTarget)
        XCTAssertFalse(store.state.sending)
        XCTAssertEqual(store.state.notice, .pending)
        XCTAssertEqual(source.cursors, [], "待审的不立刻刷新列表")
    }

    // MARK: - 评论框字数上限（引擎 500 个码点；到上限不让再输入，显示剩余数，I-20）

    func testTheCommentBoxBlocksTypingAtTheLimitAndCountsDown() {
        let store = store(DetailSource())
        XCTAssertEqual(store.state.draftRemaining, 500)
        store.onDraftChanged(String(repeating: "字", count: 499))
        XCTAssertEqual(store.state.draftRemaining, 1)
        let last = store.onDraftEdit(range: NSRange(location: 499, length: 0), replacement: "x")
        XCTAssertTrue(last.accepted)
        XCTAssertEqual(store.state.draftRemaining, 0)
        XCTAssertFalse(store.state.draftLimitHit)
        let blocked = store.onDraftEdit(range: NSRange(location: 500, length: 0), replacement: "y")
        XCTAssertTrue(blocked.blocked)
        XCTAssertEqual(store.state.draft.unicodeScalars.count, 500)
        XCTAssertFalse(store.state.draft.hasSuffix("y"))
        XCTAssertTrue(store.state.draftLimitHit)
        // 删一个字之后又能输入，提示清掉
        store.onDraftEdit(range: NSRange(location: 499, length: 1), replacement: "")
        XCTAssertFalse(store.state.draftLimitHit)
        XCTAssertEqual(store.state.draftRemaining, 1)
    }

    func testAPastedCommentIsClippedByCodePointWithoutSplittingACharacter() {
        let store = store(DetailSource())
        let flag = "\u{1F1E8}\u{1F1F3}"
        store.onDraftChanged("a")
        let edit = store.onDraftEdit(range: NSRange(location: 1, length: 0), replacement: String(repeating: flag, count: 400))
        XCTAssertTrue(edit.clipped)
        XCTAssertFalse(edit.accepted)
        XCTAssertEqual(store.state.draft, "a" + String(repeating: flag, count: 249), "1 + 249 × 2 = 499；第 250 面旗放不下")
        XCTAssertEqual(store.state.draftRemaining, 1)
        XCTAssertTrue(store.state.draftLimitHit)
        // 整段设置（没走钩子的输入框）同样按码点截
        store.onDraftChanged(String(repeating: "😀", count: 600))
        XCTAssertEqual(store.state.draft, String(repeating: "😀", count: 500))
    }

    func testComposingCommentTextIsLetThroughAndSendingWaitsUntilItIsClipped() async {
        let source = DetailSource()
        let store = store(source)
        store.onDraftChanged(String(repeating: "a", count: 500))
        let edit = store.onDraftEdit(range: NSRange(location: 500, length: 0), replacement: "nihao", composing: true)
        XCTAssertTrue(edit.accepted)
        XCTAssertEqual(store.state.draftRemaining, -5)
        XCTAssertFalse(store.state.canSend, "超了不能发")
        store.send()
        await store.waitForTasks()
        XCTAssertEqual(source.posted, [], "组字中超了：send() 也不发")
        XCTAssertFalse(store.state.sending)
        store.onDraftChanged(store.state.draft)            // 组字结束
        XCTAssertEqual(store.state.draftRemaining, 0)
        XCTAssertTrue(store.state.canSend)
    }

    func testAPublishedCommentRefreshesTheList() async {
        let source = DetailSource()
        source.postResult = { FeedCreatePostResponse.statePublished }
        source.pages = ["": FeedCommentsPage(comments: [comment("new")])]
        let store = store(source)
        store.onDraftChanged("hi")
        store.send()
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .published)
        XCTAssertEqual(store.state.comments.map(\.id), ["new"])
    }

    func testBlankDraftsAreNotSentAndOnlyOneSendIsInFlight() async {
        let source = DetailSource()
        let store = store(source)
        store.onDraftChanged("   ")
        store.send()
        XCTAssertEqual(source.posted, [])
        store.onDraftChanged("x")
        store.send()
        store.send()
        await store.waitForTasks()
        XCTAssertEqual(source.posted, ["x|-"])
    }

    func testCommentErrorsMapToTheirNotices() async {
        func attempt(_ error: Error) async -> FeedPostDetailStore {
            let source = DetailSource()
            source.postResult = { throw error }
            let store = FeedPostDetailStore(initial: self.post, source: source)
            store.replyTo(comment("a"))
            store.onDraftChanged("hello")
            store.send()
            await store.waitForTasks()
            return store
        }
        let closed = await attempt(FeedAPIError(status: 403, code: "comments_closed", retryAfterSeconds: nil))
        XCTAssertFalse(closed.state.canComment)
        XCTAssertEqual(closed.state.draft, "hello", "关了评论：输入框关掉，草稿留着")
        XCTAssertEqual(closed.state.notice, .closed)
        XCTAssertFalse(closed.state.sending)

        let notCommentable = await attempt(FeedAPIError(status: 403, code: "not_commentable", retryAfterSeconds: nil))
        XCTAssertEqual(notCommentable.state.notice, .closed)

        let denied = await attempt(FeedAPIError(status: 403, code: "reply_not_allowed", retryAfterSeconds: nil))
        XCTAssertEqual(denied.state.notice, .replyNotAllowed)
        XCTAssertTrue(denied.state.canComment)

        let profile = await attempt(FeedAPIError(status: 409, code: "profile_required", retryAfterSeconds: nil))
        XCTAssertEqual(profile.state.notice, .profileRequired, "没有主页单独说，不是笼统的失败")
        XCTAssertTrue(profile.state.canComment)

        let parent = await attempt(FeedAPIError(status: 400, code: "invalid_parent", retryAfterSeconds: nil))
        XCTAssertEqual(parent.state.notice, .parentGone)
        XCTAssertNil(parent.state.replyTarget)

        let voiceOffOnText = await attempt(FeedAPIError(status: 403, code: "voice_comments_off", retryAfterSeconds: nil))
        XCTAssertEqual(voiceOffOnText.state.notice, .failed, "文字评论遇到这个代码不算语音关闭")
        XCTAssertTrue(voiceOffOnText.state.voiceAllowed)

        let network = await attempt(URLError(.notConnectedToInternet))
        XCTAssertEqual(network.state.notice, .failed)
        XCTAssertEqual(network.state.draft, "hello")
    }

    func testAVoiceCommentIsSentWithTheReplyTargetAndTheFileIsDeleted() async throws {
        let source = DetailSource()
        let store = store(source)
        let audio = try tempAudio()
        store.replyTo(comment("a"))
        store.sendVoice(file: audio)
        await store.waitForTasks()
        XCTAssertEqual(source.voices, ["audio|a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertNil(store.state.replyTarget)
        XCTAssertFalse(store.state.sending)
        XCTAssertEqual(store.state.notice, .voicePending, "语音一律人工复核")
    }

    func testVoiceOffHidesTheMicAndOtherFailuresJustFail() async throws {
        let source = DetailSource()
        source.voiceResult = { throw FeedAPIError(status: 403, code: "voice_comments_off", retryAfterSeconds: nil) }
        let store = store(source)
        store.sendVoice(file: try tempAudio())
        await store.waitForTasks()
        XCTAssertFalse(store.state.voiceAllowed)
        XCTAssertEqual(store.state.notice, .voiceOff)

        let later = try tempAudio()
        store.sendVoice(file: later)
        await store.waitForTasks()
        XCTAssertFalse(FileManager.default.fileExists(atPath: later.path), "不让发也要删录音")
        XCTAssertEqual(source.voices.count, 1)

        let other = DetailSource()
        other.voiceResult = { throw FeedAPIError(status: 415, code: "unsupported_media", retryAfterSeconds: nil) }
        let second = FeedPostDetailStore(initial: post, source: other)
        let audio = try tempAudio()
        second.sendVoice(file: audio)
        await second.waitForTasks()
        XCTAssertEqual(second.state.notice, .failed)
        XCTAssertTrue(second.state.voiceAllowed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testATapOnTheMicSaysToHoldIt() {
        let store = store(DetailSource())
        store.onVoiceTooShort()
        XCTAssertEqual(store.state.notice, .holdToRecord)
        store.onNoticeShown()
        XCTAssertNil(store.state.notice)
    }

    func testVotingShowsTheCountsTheEngineReturnsAndARefusedVoteLeavesThePoll() async {
        let source = DetailSource()
        let store = store(source)
        store.vote([])
        store.vote([1])
        store.vote([0])
        await store.waitForTasks()
        XCTAssertEqual(source.calls, ["vote p [1]"])
        XCTAssertEqual(store.state.post.pollState, FeedPollState(counts: [3, 1], voted: [1]))

        let refusing = DetailSource()
        refusing.failing = ["vote"]
        let second = FeedPostDetailStore(initial: post, source: refusing)
        second.vote([0])
        await second.waitForTasks()
        XCTAssertNil(second.state.post.pollState)
        XCTAssertEqual(second.state.notice, .failed)
    }

    func testLikeRepostAndSaveFollowTheFeedRules() async {
        let source = DetailSource()
        let saved = FakeSaved()
        let store = store(source, saved: saved)

        store.toggleLike()
        XCTAssertTrue(store.state.post.viewer.liked)
        store.toggleSave()
        XCTAssertTrue(store.state.post.viewer.saved)
        await store.waitForTasks()
        XCTAssertTrue(store.state.post.viewer.liked)
        XCTAssertTrue(store.state.post.viewer.saved)
        XCTAssertEqual(store.state.notice, .saved)
        XCTAssertEqual(source.calls.sorted(), ["like p true", "save p true"])
        store.onNoticeShown()

        // 转发失败：改回来，提示「失败」
        source.failing = ["repost"]
        store.toggleRepost()
        XCTAssertTrue(store.state.post.viewer.reposted)
        await store.waitForTasks()
        XCTAssertFalse(store.state.post.viewer.reposted, "转发失败改回来")
        XCTAssertEqual(store.state.notice, .failed)
        store.onNoticeShown()

        // 转发成功：提示「已转发」
        source.failing = []
        store.toggleRepost()
        await store.waitForTasks()
        XCTAssertTrue(store.state.post.viewer.reposted)
        XCTAssertEqual(store.state.notice, .reposted)

        // 存不进「我的收藏」才改回来：取消收藏失败 → 仍是已收藏
        saved.fail = true
        store.toggleSave()
        await store.waitForTasks()
        XCTAssertTrue(store.state.post.viewer.saved)
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testApprovingShowsTheReplyDecliningRemovesItOnlyHeldOnes() async {
        let source = DetailSource()
        source.pages = ["": FeedCommentsPage(comments: [comment("a", held: true), comment("b", held: true), comment("c")])]
        let store = store(source)
        store.refreshComments()
        await store.waitForTasks()

        store.approveComment(store.state.comments[0])
        store.declineComment(store.state.comments[1])
        store.approveComment(store.state.comments[2])   // 不是等批准的：不发
        await store.waitForTasks()
        XCTAssertEqual(source.calls.sorted(), ["approve a", "delete b"], "两条各发各的（并发，顺序不定）")
        XCTAssertEqual(store.state.comments.map(\.id), ["a", "c"])
        XCTAssertFalse(store.state.comments[0].held)
    }

    func testAFailedApprovalKeepsTheReplyWaiting() async {
        let source = DetailSource()
        source.failing = ["approve"]
        source.pages = ["": FeedCommentsPage(comments: [comment("a", held: true)])]
        let store = store(source)
        store.refreshComments()
        await store.waitForTasks()
        store.approveComment(store.state.comments[0])
        await store.waitForTasks()
        XCTAssertTrue(store.state.comments[0].held)
        XCTAssertEqual(store.state.notice, .failed)
        // 失败后可以再来一次
        store.approveComment(store.state.comments[0])
        await store.waitForTasks()
        XCTAssertEqual(source.calls, ["approve a", "approve a"])
    }

    func testPinAndInsightsWorkFromTheDetailPageAndAFourthPinTurnsBack() async {
        let source = DetailSource()
        let mine = FeedCard(id: "p", viewer: FeedViewer(isAuthor: true))
        let store = store(source, initial: mine)
        store.onOwnPostAction(.pin)
        XCTAssertTrue(store.state.post.pinned)
        await store.waitForTasks()
        XCTAssertTrue(store.state.post.pinned)

        source.failing = ["settings"]
        store.onOwnPostAction(.unpin)
        XCTAssertFalse(store.state.post.pinned)
        await store.waitForTasks()
        XCTAssertTrue(store.state.post.pinned, "失败改回来")
        XCTAssertEqual(store.state.notice, .pinLimit)

        store.onOwnPostAction(.insights)
        XCTAssertEqual(store.state.insights, .loading)
        await store.waitForTasks()
        XCTAssertEqual(store.state.insights, .ready(FeedPostInsights(opens: 7)))
        store.onInsightsDismissed()
        XCTAssertNil(store.state.insights)
    }

    func testDeletingMyPostClosesThePageAndAFailedDeleteStays() async {
        let source = DetailSource()
        let store = store(source)
        store.deletePost()
        await store.waitForTasks()
        XCTAssertTrue(store.state.deleted)

        let failing = DetailSource()
        failing.failing = ["delete"]
        let second = FeedPostDetailStore(initial: post, source: failing)
        second.deletePost()
        await second.waitForTasks()
        XCTAssertFalse(second.state.deleted)
        XCTAssertEqual(second.state.notice, .failed)
    }

    func testNotInterestedLeavesAndAProfileRequiredFailureIsSaidSeparately() async {
        let source = DetailSource()
        let store = store(source)
        store.notInterested()
        store.notInterested()
        await store.waitForTasks()
        XCTAssertEqual(source.calls, ["notInterested p"])
        XCTAssertEqual(store.state.leaving, .notInterested)

        let failing = DetailSource()
        failing.failing = ["notInterested"]
        let second = FeedPostDetailStore(initial: post, source: failing)
        second.notInterested()
        await second.waitForTasks()
        XCTAssertNil(second.state.leaving)
        XCTAssertEqual(second.state.notice, .hideProfileRequired)
        second.notInterested()   // 失败后能再试
        await second.waitForTasks()
        XCTAssertEqual(failing.calls.count, 2)
    }

    func testOnEditedSaysWhetherItIsBackInReview() async {
        let source = DetailSource()
        source.fresh = post
        let store = store(source)
        store.onEdited(publishState: FeedCreatePostResponse.statePending)
        XCTAssertEqual(store.state.notice, .editedPending)
        store.onEdited(publishState: FeedCreatePostResponse.statePublished)
        XCTAssertEqual(store.state.notice, .edited)
        await store.waitForTasks()
    }
}
