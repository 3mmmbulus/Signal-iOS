//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedMyPostsTests.swift (new file)
// I-6: my posts / edit / appeal models, API wire shapes, FeedMyPostsStore. Mirrors Android FeedMyPostsViewModelTest / FeedEditTargetTest.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

private struct Boom: Error {}

private final class CallLog<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [T]()
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

private let t0 = Date(timeIntervalSince1970: 1_791_889_200)   // 2026-10-13T11:00:00Z

final class TellomiFeedEditTargetTests: XCTestCase {
    func testOnlyPostsAndArticlesThatAreNotRejectedOrWithdrawnCanBeEdited() {
        XCTAssertNotNil(FeedEditTarget.of(FeedMyPost(id: "1", state: "published")))
        XCTAssertNotNil(FeedEditTarget.of(FeedMyPost(id: "2", state: "pending", kind: "article", title: "T", text: "x")))
        XCTAssertNil(FeedEditTarget.of(FeedMyPost(id: "3", state: "rejected")))
        XCTAssertNil(FeedEditTarget.of(FeedMyPost(id: "4", state: "withdrawn")))
        XCTAssertNil(FeedEditTarget.of(FeedMyPost(id: "5", state: "published", kind: "comment")))
        XCTAssertNil(FeedEditTarget.of(FeedCard(id: "c", kind: FeedCard.kindComment)))
        let card = FeedCard(id: "p", kind: FeedCard.kindArticle, title: "Title", text: nil)
        XCTAssertEqual(FeedEditTarget.of(card), FeedEditTarget(id: "p", kind: "article", title: "Title", text: "", publishedAt: nil))
        XCTAssertEqual(FeedEditTarget.of(card)?.draftKind, .article)
        XCTAssertEqual(FeedEditTarget(id: "x", kind: "weird", title: nil, text: "", publishedAt: nil).draftKind, .post)
    }

    func testEditWindowBoundaryAndUnreadableTime() {
        let target = FeedEditTarget(id: "p", kind: "post", title: nil, text: "x", publishedAt: "2026-10-13T11:00:00Z")
        XCTAssertTrue(target.isWithinWindow(now: t0.addingTimeInterval(900), windowSeconds: 900), "正好 15 分钟还能改（Android: <=）")
        XCTAssertFalse(target.isWithinWindow(now: t0.addingTimeInterval(901), windowSeconds: 900))
        XCTAssertTrue(target.isWithinWindow(now: t0.addingTimeInterval(61), windowSeconds: 60 * 60))
        for bad in [nil, "yesterday", ""] as [String?] {
            XCTAssertTrue(FeedEditTarget(id: "p", kind: "post", title: nil, text: "x", publishedAt: bad).isWithinWindow(now: t0.addingTimeInterval(99_999), windowSeconds: 900), "读不懂就给入口，引擎判")
        }
        let fractional = FeedEditTarget(id: "p", kind: "post", title: nil, text: "x", publishedAt: "2026-10-13T11:00:00.250Z")
        XCTAssertTrue(fractional.isWithinWindow(now: t0.addingTimeInterval(900), windowSeconds: 900))
    }

    func testEditRequestCarriesTitleOnlyForArticles() {
        var draft = FeedDraft()
        draft.title = "  T "
        draft.text = "  body \n"
        XCTAssertEqual(draft.toEditRequest(), FeedEditPostRequest(text: "body", title: nil))
        draft.kind = .article
        XCTAssertEqual(draft.toEditRequest(), FeedEditPostRequest(text: "body", title: "T"))
    }
}

private final class ScriptedTransport: FeedHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests = [URLRequest]()
    private var replies = [(Int, String)]()
    func reply(_ status: Int, _ body: String) { lock.lock(); replies.append((status, body)); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.locked {
            _requests.append(request)
            return replies.isEmpty ? (204, "") : replies.removeFirst()
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }
}

private struct FixedTokens: FeedTokenSource {
    func token(forceRefresh: Bool) async throws -> String { "t" }
}

final class TellomiFeedMyPostsApiTests: XCTestCase {
    private func make() -> (FeedAPI, ScriptedTransport) {
        let transport = ScriptedTransport()
        return (FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens()), transport)
    }

    func testMyPostsDecodesStatesReasonsAndAppealFields() async throws {
        let (api, transport) = make()
        transport.reply(200, """
        {"posts":[
          {"id":"a","state":"published","title":null,"text":"hello","visibility":"public","created_at":"2026-10-13T11:00:00Z"},
          {"id":"b","kind":"article","state":"rejected","version":3,"rejection_reasons":["lexicon:x","uncertain"],"appealable":true},
          {"id":"c","state":"rejected","appeal_state":"upheld","edited_at":"2026-10-13T10:00:00Z"}],
         "next_before":"b"}
        """)
        let page = try await api.myPosts(before: "z")
        XCTAssertEqual(page.nextBefore, "b")
        XCTAssertEqual(page.posts.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(page.posts[0].kind, "post")
        XCTAssertEqual(page.posts[0].version, 1)
        XCTAssertFalse(page.posts[0].appealable)
        XCTAssertEqual(page.posts[1].rejectionReasons, ["lexicon:x", "uncertain"])
        XCTAssertTrue(page.posts[1].appealable)
        XCTAssertEqual(page.posts[1].kind, "article")
        XCTAssertEqual(page.posts[2].appealState, "upheld")
        XCTAssertEqual(page.posts[2].editedAt, "2026-10-13T10:00:00Z")
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://feed.example.test/v1/feed/me/posts?before=z")
        transport.reply(200, "{}")
        let empty = try await api.myPosts(before: nil)
        XCTAssertEqual(empty, FeedMyPostsPage())
        XCTAssertEqual(transport.requests[1].url?.absoluteString, "https://feed.example.test/v1/feed/me/posts")
    }

    func testEditAndAppealWire() async throws {
        let (api, transport) = make()
        transport.reply(200, #"{"id":"a","state":"pending","version":2}"#)
        let result = try await api.editPost(contentId: "a/1", request: FeedEditPostRequest(text: "new", title: nil))
        XCTAssertEqual(result, FeedCreatePostResponse(id: "a", state: "pending", version: 2))
        transport.reply(200, #"{"id":"a","state":"published"}"#)
        _ = try await api.editPost(contentId: "a", request: FeedEditPostRequest(text: "new", title: "T"))
        try await api.appeal(contentId: "a", text: "please")
        let r = transport.requests
        XCTAssertEqual(r.map { $0.httpMethod }, ["PATCH", "PATCH", "POST"])
        XCTAssertEqual(r[0].url?.absoluteString, "https://feed.example.test/v1/feed/posts/a%2F1")
        XCTAssertEqual(String(data: r[0].httpBody!, encoding: .utf8), #"{"text":"new"}"#)
        XCTAssertEqual(String(data: r[1].httpBody!, encoding: .utf8), #"{"text":"new","title":"T"}"#)
        XCTAssertEqual(r[2].url?.path, "/v1/feed/posts/a/appeal")
        XCTAssertEqual(String(data: r[2].httpBody!, encoding: .utf8), #"{"text":"please"}"#)

        transport.reply(409, #"{"error":"already_appealed"}"#)
        do {
            try await api.appeal(contentId: "a", text: "again")
            XCTFail()
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.code, "already_appealed")
        }
    }
}

private final class MineSource: FeedSource {
    var pages = [String: FeedMyPostsPage]()   // key = before ?? ""
    var listError: Error?
    var deleteError: Error?
    var appealError: Error?
    var editWindow = 900
    var configFails = false
    let calls = CallLog<String>()

    func config() async throws -> FeedConfig {
        if configFails { throw Boom() }
        var c = FeedConfig()
        c.limits.editWindowSeconds = editWindow
        return c
    }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func myPosts(before: String?) async throws -> FeedMyPostsPage {
        calls.append("list \(before ?? "-")")
        if let listError { throw listError }
        return pages[before ?? ""] ?? FeedMyPostsPage()
    }
    func deletePost(contentId: String) async throws {
        calls.append("delete \(contentId)")
        if let deleteError { throw deleteError }
    }
    func appeal(contentId: String, text: String) async throws {
        calls.append("appeal \(contentId) \(text)")
        if let appealError { throw appealError }
    }
}

@MainActor
final class TellomiFeedMyPostsStoreTests: XCTestCase {
    private func post(_ id: String, state: String = "published", appealable: Bool = false) -> FeedMyPost {
        FeedMyPost(id: id, state: state, text: "t \(id)", appealable: appealable)
    }

    private func started(_ source: MineSource) async -> FeedMyPostsStore {
        let store = FeedMyPostsStore(source: source)
        store.start()
        await store.waitForTasks()
        return store
    }

    func testStartLoadsFirstPageAndTheEditWindowFromConfig() async {
        let source = MineSource()
        source.editWindow = 1800
        source.pages[""] = FeedMyPostsPage(posts: [post("a"), post("b")], nextBefore: "b")
        let store = await started(source)
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b"])
        XCTAssertEqual(store.state.nextBefore, "b")
        XCTAssertFalse(store.state.loading)
        XCTAssertTrue(store.state.loadedOnce)
        XCTAssertEqual(store.state.editWindowSeconds, 1800)

        let noConfig = MineSource()
        noConfig.configFails = true
        let second = await started(noConfig)
        XCTAssertEqual(second.state.editWindowSeconds, 900, "取不到用默认 15 分钟")
    }

    func testFirstLoadFailureAndRefreshFlag() async {
        let source = MineSource()
        source.listError = Boom()
        let store = await started(source)
        XCTAssertTrue(store.state.failed)
        XCTAssertTrue(store.state.loadedOnce)
        XCTAssertFalse(store.state.loading)

        source.listError = nil
        source.pages[""] = FeedMyPostsPage(posts: [post("a")], nextBefore: nil)
        store.refresh()
        XCTAssertTrue(store.state.refreshing, "已经加载过：算下拉刷新")
        XCTAssertFalse(store.state.failed)
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a"])
        XCTAssertFalse(store.state.refreshing)

        let fresh = FeedMyPostsStore(source: MineSource())
        fresh.refresh()
        XCTAssertFalse(fresh.state.refreshing, "第一次不算")
        await fresh.waitForTasks()
    }

    func testLoadMoreAppendsWithoutDuplicatesAndStopsAtTheEnd() async {
        let source = MineSource()
        source.pages[""] = FeedMyPostsPage(posts: [post("a"), post("b")], nextBefore: "b")
        source.pages["b"] = FeedMyPostsPage(posts: [post("b"), post("c")], nextBefore: nil)
        let store = await started(source)
        store.loadMore()
        store.loadMore()   // 在途不重复
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b", "c"])
        XCTAssertNil(store.state.nextBefore)
        store.loadMore()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all, ["list -", "list b"])

        let failing = MineSource()
        failing.pages[""] = FeedMyPostsPage(posts: [post("a")], nextBefore: "a")
        let second = await started(failing)
        failing.listError = Boom()
        second.loadMore()
        await second.waitForTasks()
        XCTAssertEqual(second.state.posts.map(\.id), ["a"], "翻页失败：列表还在")
        XCTAssertFalse(second.state.loading)
        XCTAssertFalse(second.state.failed)
        XCTAssertEqual(second.state.nextBefore, "a", "还能再试")
    }

    func testDeleteRemovesAtOnceAndRestoresAtTheSameIndexOnFailure() async {
        let source = MineSource()
        source.pages[""] = FeedMyPostsPage(posts: [post("a"), post("b"), post("c")], nextBefore: nil)
        let store = await started(source)
        store.delete(post("b"))
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "c"])
        await store.waitForTasks()
        XCTAssertFalse(store.state.deleteFailed)

        source.deleteError = Boom()
        store.delete(post("c"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "c"])
        XCTAssertTrue(store.state.deleteFailed)
        store.onDeleteFailureShown()
        XCTAssertFalse(store.state.deleteFailed)

        store.delete(post("gone"))   // 列表里没有：什么都不做
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("delete") }, ["delete b", "delete c"])

        source.deleteError = Boom()
        store.delete(post("a"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "c"], "放回原来的位置 0")
    }

    /// 引擎按码点数（`MaxAppealChars = 500`）：🇨🇳 是 1 个字、2 个码点。按 Character 截会发出 1000 个码点被 400。
    func testAppealReasonIsCappedByCodePointsLikeTheEngine() async {
        let source = MineSource()
        source.pages[""] = FeedMyPostsPage(posts: [post("a", state: "rejected", appealable: true)], nextBefore: nil)
        let store = await started(source)
        let flag = "\u{1F1E8}\u{1F1F3}"
        store.appeal(store.state.posts[0], text: String(repeating: flag, count: 400))
        await store.waitForTasks()
        let sent = source.calls.all.last { $0.hasPrefix("appeal") }!
        let reason = String(sent.dropFirst("appeal a ".count))
        XCTAssertEqual(reason, String(repeating: flag, count: 250))
        XCTAssertEqual(reason.unicodeScalars.count, 500)
    }

    func testAppealTrimsCapsAtFiveHundredCodePointsAndMarksTheRow() async {
        let source = MineSource()
        source.pages[""] = FeedMyPostsPage(posts: [post("a", state: "rejected", appealable: true), post("b")], nextBefore: nil)
        let store = await started(source)

        store.appeal(store.state.posts[0], text: "   ")
        XCTAssertFalse(store.state.appealing, "空白不发")

        let long = "  " + String(repeating: "😀", count: 600) + "  "
        store.appeal(store.state.posts[0], text: long)
        XCTAssertTrue(store.state.appealing)
        store.appeal(store.state.posts[0], text: "second")   // 在途不重复
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("appeal") }.count, 1)
        let sent = source.calls.all.last { $0.hasPrefix("appeal") }!
        XCTAssertEqual(sent, "appeal a " + String(repeating: "😀", count: 500))
        XCTAssertEqual(store.state.appealNotice, .sent)
        XCTAssertFalse(store.state.appealing)
        XCTAssertFalse(store.state.posts[0].appealable)
        XCTAssertEqual(store.state.posts[0].appealState, "received")
        XCTAssertNil(store.state.posts[1].appealState)
        store.onAppealNoticeShown()
        XCTAssertNil(store.state.appealNotice)
    }

    func testAlreadyAppealedMarksTheRowButOtherFailuresDoNot() async {
        let source = MineSource()
        source.pages[""] = FeedMyPostsPage(posts: [post("a", state: "rejected", appealable: true), post("b", state: "rejected", appealable: true)], nextBefore: nil)
        let store = await started(source)
        source.appealError = FeedAPIError(status: 409, code: "already_appealed", retryAfterSeconds: nil)
        store.appeal(store.state.posts[0], text: "x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.appealNotice, .already)
        XCTAssertEqual(store.state.posts[0].appealState, "received")

        source.appealError = FeedAPIError(status: 400, code: "invalid_text", retryAfterSeconds: nil)
        store.appeal(store.state.posts[1], text: "x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.appealNotice, .failed)
        XCTAssertTrue(store.state.posts[1].appealable)
        XCTAssertNil(store.state.posts[1].appealState)
        XCTAssertFalse(store.state.appealing)

        source.appealError = Boom()
        store.appeal(store.state.posts[1], text: "x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.appealNotice, .failed)
    }

    func testEditedShowsTheStateOnceAndReloads() async {
        let source = MineSource()
        source.pages[""] = FeedMyPostsPage(posts: [post("a")], nextBefore: nil)
        let store = await started(source)
        source.pages[""] = FeedMyPostsPage(posts: [post("a", state: "pending")], nextBefore: nil)
        store.onEdited(publishState: "pending")
        XCTAssertEqual(store.state.editNotice, "pending")
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts[0].state, "pending")
        store.onEditNoticeShown()
        XCTAssertNil(store.state.editNotice)
        XCTAssertEqual(source.calls.all.filter { $0 == "list -" }.count, 2)
    }
}

/// `NSLock.lock()` 在 async 函数里不让直接调（Swift 6）；临界区都不跨 `await`，放进同步闭包里。
private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
