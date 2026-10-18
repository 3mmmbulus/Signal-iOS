//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedSearchTopicTests.swift (new file)
// I-8: search / topic / followed-topics wire, search history, FeedSearchStore, FeedTopicStore.
// Mirrors Android FeedSearchViewModelTest, FeedSearchHistoryTest, FeedTopicViewModelTest.
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

/// 一道门：`wait()` 停到 `open()`；不理会取消（用来模拟「取消了也照样回来」的网络层）。
private actor Gate {
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

private func eventually(_ message: String = "", _ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<2000 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timed out: \(message)", file: file, line: line)
}

// MARK: - API / models

final class TellomiFeedSearchApiTests: XCTestCase {
    private func make() -> (FeedAPI, ScriptedTransport) {
        let transport = ScriptedTransport()
        return (FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens()), transport)
    }

    func testSearchDecodesLeniently() async throws {
        let (api, transport) = make()
        transport.reply(200, """
        {"users":[{"id":"p1","handle":"ann","display_name":"Ann","avatar_key":"a/1","badge":"official"},
                  {"handle":"broken"},
                  {"id":"p2","display_name":"Bob"}],
         "items":[{"id":"x"},{"id":"y","reason":"search"}],"cursor":"c2"}
        """)
        let response = try await api.search(query: "ann", scope: "all", cursor: nil)
        XCTAssertEqual(response.users.map(\.id), ["p1", "p2"], "坏的一项跳过，不拖垮整页")
        XCTAssertEqual(response.users[0].badge, "official")
        XCTAssertNil(response.users[1].handle)
        XCTAssertEqual(response.items.map(\.id), ["x", "y"])
        XCTAssertEqual(response.cursor, "c2")
        XCTAssertEqual(response.users[0].asPerson(), FeedPersonSummary(id: "p1", handle: "ann", displayName: "Ann", avatarKey: "a/1"))

        transport.reply(200, "{}")
        let empty = try await api.search(query: "z", scope: "posts", cursor: nil)
        XCTAssertEqual(empty, FeedSearchResponse())
    }

    func testSearchWireEncodesQueryScopeAndCursor() async throws {
        let (api, transport) = make()
        transport.reply(200, "{}")
        transport.reply(200, "{}")
        _ = try await api.search(query: "春 天&x=1", scope: FeedAPI.searchUsers, cursor: nil)
        _ = try await api.search(query: "a", scope: FeedAPI.searchPosts, cursor: "c 1")
        let first = try XCTUnwrap(transport.requests[0].url)
        let items = try XCTUnwrap(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(first.path, "/v1/feed/search")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "春 天&x=1", "特殊字符照原样回到服务端")
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "users")
        XCTAssertNil(items.first { $0.name == "cursor" })
        let second = try XCTUnwrap(URLComponents(url: try XCTUnwrap(transport.requests[1].url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(second.first { $0.name == "cursor" }?.value, "c 1")
        XCTAssertEqual(transport.requests.map { $0.httpMethod }, ["GET", "GET"])
    }

    func testTopicAndFollowedTopicsWire() async throws {
        let (api, transport) = make()
        transport.reply(200, #"{"items":[{"id":"a"}],"cursor":"n","following":true}"#)
        transport.reply(200, "{}")
        transport.reply(404, #"{"error":"not_found"}"#)
        transport.reply(200, #"{"topics":[{"slug":"food","followed_at":"2026-10-13T10:00:00Z"},{"nope":1},{"slug":"daily"}]}"#)
        let page = try await api.topicPosts(slug: "food", cursor: "c1")
        XCTAssertEqual(page.items.map(\.id), ["a"])
        XCTAssertTrue(page.following)
        let empty = try await api.topicPosts(slug: "x", cursor: nil)
        XCTAssertEqual(empty, FeedTopicPostsResponse())
        XCTAssertFalse(empty.following)
        do {
            _ = try await api.topicPosts(slug: "bad slug/..", cursor: nil)
            XCTFail("404 应该抛出")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 404)
        }
        let topics = try await api.followedTopics()
        XCTAssertEqual(topics.topics.map(\.slug), ["food", "daily"])
        XCTAssertEqual(topics.topics[0].followedAt, "2026-10-13T10:00:00Z")
        let r = transport.requests
        XCTAssertEqual(r[0].url?.absoluteString, "https://feed.example.test/v1/feed/topics/food/posts?cursor=c1")
        XCTAssertEqual(r[1].url?.absoluteString, "https://feed.example.test/v1/feed/topics/x/posts")
        XCTAssertEqual(r[2].url?.absoluteString, "https://feed.example.test/v1/feed/topics/bad%20slug%2F../posts", "slug 里的斜杠必须转义，不能多出一级路径")
        XCTAssertEqual(r[3].url?.path, "/v1/feed/me/followed-topics")
    }

    func testFollowingATopicUsesTheTopicTargetAndRemoteSourceMapsPages() async throws {
        let (api, transport) = make()
        transport.reply(200, #"{"state":"approved"}"#)
        transport.reply(200, #"{"state":"none"}"#)
        let source = RemoteFeedSource(api: api)
        try await source.setFollowingTopic(slug: "food", following: true)
        try await source.setFollowingTopic(slug: "food", following: false)
        XCTAssertEqual(transport.requests.map { $0.httpMethod }, ["PUT", "DELETE"])
        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/v1/feed/follow/topic/food", "/v1/feed/follow/topic/food"])

        let (api2, transport2) = make()
        transport2.reply(200, #"{"users":[{"id":"p1","display_name":"Ann"}],"items":[{"id":"b"},{"id":"a"},{"id":"gone"}],"cursor":"c"}"#)
        transport2.reply(200, #"{"cards":[\#(card("a")),\#(card("b"))]}"#)
        transport2.reply(200, #"{"topics":[{"slug":"x"},{"slug":"y"}]}"#)
        transport2.reply(200, #"{"items":[{"id":"a"}],"following":true}"#)
        transport2.reply(200, #"{"cards":[\#(card("a"))]}"#)
        let remote = RemoteFeedSource(api: api2)
        let page = try await remote.search(query: "q", scope: "all", cursor: nil)
        XCTAssertEqual(page.users.map(\.id), ["p1"])
        XCTAssertEqual(page.posts.map(\.id), ["b", "a"], "按搜索给的顺序，不按 Card API 的；取不到卡片的丢掉")
        XCTAssertEqual(page.cursor, "c")
        let followed = try await remote.followedTopics()
        XCTAssertEqual(followed, ["x", "y"])
        let topic = try await remote.topicPosts(slug: "x", cursor: nil)
        XCTAssertEqual(topic.posts.map(\.id), ["a"])
        XCTAssertTrue(topic.following)
    }

    private func card(_ id: String) -> String {
        #"{"id":"\#(id)","state":"ok","card":{"kind":"post","text":"t \#(id)","author":{"id":"p-\#(id)","display_name":"A"}}}"#
    }

    func testDefaultsDegradeWhenTheEngineIsNotThere() async {
        final class Bare: FeedSource {
            func config() async throws -> FeedConfig { FeedConfig() }
            func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
            func setLiked(contentId: String, liked: Bool) async throws {}
            func notInterested(contentId: String) async throws {}
            func undoNotInterested(contentId: String) async throws {}
            func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
            func reportEvents(_ events: [FeedEventPayload]) async throws {}
        }
        let bare = Bare()
        let page = try? await bare.search(query: "a", scope: "all", cursor: nil)
        XCTAssertEqual(page, FeedSearchPage())
        let followed = try? await bare.followedTopics()
        XCTAssertEqual(followed, [])
        let topic = try? await bare.topicPosts(slug: "a", cursor: nil)
        XCTAssertEqual(topic, FeedTopicPage())
        do {
            try await bare.setFollowingTopic(slug: "a", following: true)
            XCTFail("没有引擎时不能装作关注成功")
        } catch {}
    }
}

// MARK: - history

final class TellomiFeedSearchHistoryTests: XCTestCase {
    private func person(_ id: String) -> FeedPersonSummary {
        FeedPersonSummary(id: id, handle: "h\(id)", displayName: "N\(id)", avatarKey: nil)
    }

    func testQueriesAreTrimmedDedupedCaseInsensitivelyAndCapped() {
        let history = InMemoryFeedSearchHistory()
        history.addQuery("  ")
        history.addQuery("")
        XCTAssertEqual(history.queries(), [])
        history.addQuery(" Swift ")
        history.addQuery("go")
        history.addQuery("SWIFT")
        XCTAssertEqual(history.queries(), ["SWIFT", "go"], "同一个词只留最新的、排最前")
        for i in 0..<30 { history.addQuery("q\(i)") }
        XCTAssertEqual(history.queries().count, 20)
        XCTAssertEqual(history.queries().first, "q29")
        XCTAssertEqual(history.queries().last, "q10")
        history.removeQuery("q29")
        history.removeQuery("Q28")   // 删除按原样匹配，不分大小写不适用
        XCTAssertEqual(history.queries().first, "q28")
        XCTAssertEqual(history.queries().count, 19)
        history.clearQueries()
        XCTAssertEqual(history.queries(), [])
    }

    func testPeopleAreDedupedByIdNewestFirstAndCapped() {
        let history = InMemoryFeedSearchHistory()
        history.addPerson(person("1"))
        history.addPerson(person("2"))
        history.addPerson(FeedPersonSummary(id: "1", handle: "new", displayName: "Renamed", avatarKey: nil))
        XCTAssertEqual(history.people().map(\.id), ["1", "2"])
        XCTAssertEqual(history.people()[0].displayName, "Renamed")
        for i in 3..<20 { history.addPerson(person("\(i)")) }
        XCTAssertEqual(history.people().count, 10)
        XCTAssertEqual(history.people().first?.id, "19")
        history.clearPeople()
        XCTAssertEqual(history.people(), [])
    }

    func testStoredHistorySurvivesARestartAndToleratesBadData() throws {
        let storage = InMemoryFeedStorage()
        let first = StoredFeedSearchHistory(storage: storage)
        first.addQuery("春天")
        first.addQuery("food")
        first.addPerson(FeedPersonSummary(id: "1", handle: "ann", displayName: "Ann", avatarKey: "a/1"))
        let second = StoredFeedSearchHistory(storage: storage)
        XCTAssertEqual(second.queries(), ["food", "春天"])
        XCTAssertEqual(second.people(), [FeedPersonSummary(id: "1", handle: "ann", displayName: "Ann", avatarKey: "a/1")])

        second.clearQueries()
        second.clearPeople()
        XCTAssertNil(storage.data(forKey: StoredFeedSearchHistory.queriesKey), "清空就把键删掉")
        XCTAssertNil(storage.data(forKey: StoredFeedSearchHistory.peopleKey))

        storage.set(Data("not json".utf8), forKey: StoredFeedSearchHistory.queriesKey)
        storage.set(Data("{".utf8), forKey: StoredFeedSearchHistory.peopleKey)
        let broken = StoredFeedSearchHistory(storage: storage)
        XCTAssertEqual(broken.queries(), [])
        XCTAssertEqual(broken.people(), [])
        broken.addQuery("ok")
        XCTAssertEqual(StoredFeedSearchHistory(storage: storage).queries(), ["ok"], "存坏了之后还能正常写")
    }
}

// MARK: - search store

private final class SearchSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _pages = [String: FeedSearchPage]()
    private var _error: Error?
    private var _gates = [String: Gate]()
    var pages: [String: FeedSearchPage] {
        get { lock.lock(); defer { lock.unlock() }; return _pages }
        set { lock.lock(); _pages = newValue; lock.unlock() }
    }
    var searchError: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _error }
        set { lock.lock(); _error = newValue; lock.unlock() }
    }
    func hold(_ key: String, _ gate: Gate) { lock.lock(); _gates[key] = gate; lock.unlock() }
    private func gate(_ key: String) -> Gate? { lock.lock(); defer { lock.unlock() }; return _gates[key] }
    var likeError: Error?
    var repostError: Error?
    let calls = CallLog<String>()

    static func key(_ query: String, _ scope: String, _ cursor: String?) -> String { "\(scope)|\(query)|\(cursor ?? "-")" }

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {
        calls.append("like \(contentId) \(liked)")
        if let likeError { throw likeError }
    }
    func setReposted(contentId: String, reposted: Bool) async throws {
        calls.append("repost \(contentId) \(reposted)")
        if let repostError { throw repostError }
    }
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func search(query: String, scope: String, cursor: String?) async throws -> FeedSearchPage {
        let key = Self.key(query, scope, cursor)
        calls.append("search \(key)")
        if let gate = gate(key) { await gate.wait() }
        if let searchError { throw searchError }
        return pages[key] ?? FeedSearchPage()
    }
}

private actor Sleeper {
    private(set) var count = 0
    private var waiters = [CheckedContinuation<Void, Never>]()
    private var released = false

    func sleep() async {
        count += 1
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        released = true
        let all = waiters
        waiters = []
        all.forEach { $0.resume() }
    }
}

private func card(_ id: String) -> FeedCard {
    FeedCard(id: id, kind: FeedCard.kindPost, author: FeedAuthor(profileId: "p1", displayName: "Ann"), text: "t \(id)")
}

private func user(_ id: String) -> FeedSearchUser { FeedSearchUser(id: id, displayName: "U\(id)") }

@MainActor
final class TellomiFeedSearchStoreTests: XCTestCase {
    private func make(_ source: SearchSource, history: InMemoryFeedSearchHistory = InMemoryFeedSearchHistory(), sleeper: Sleeper? = nil) -> FeedSearchStore {
        FeedSearchStore(source: source, history: history, savedMessages: nil, debounceNanos: 1, sleep: { _ in
            if let sleeper { await sleeper.sleep() }
        })
    }

    func testTypingWaitsForTheDebounceAndOnlyTheLastQueryIsSearched() async {
        let source = SearchSource()
        source.pages[SearchSource.key("abc", "all", nil)] = FeedSearchPage(users: [user("1")], posts: [card("a")], cursor: "c")
        let sleeper = Sleeper()
        let store = make(source, sleeper: sleeper)
        store.onQueryChange("a")
        store.onQueryChange("ab")
        store.onQueryChange("abc")
        XCTAssertTrue(store.state.loading)
        XCTAssertEqual(store.state.query, "abc")
        await eventually("三次都在等") { await sleeper.count == 3 }
        XCTAssertEqual(source.calls.all, [], "还在等，没有发请求")
        await sleeper.releaseAll()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all, ["search all|abc|-"], "前两次被后一次顶掉")
        XCTAssertFalse(store.state.loading)
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a"])
        XCTAssertEqual(store.state.results?.users.map(\.id), ["1"])
        XCTAssertEqual(store.state.results?.cursor, "c")
        XCTAssertEqual(store.state.recentQueries, [], "边打边搜不记历史")
    }

    func testClearingTheQueryDropsResultsAndAStaleResponseCannotComeBack() async {
        let source = SearchSource()
        source.pages[SearchSource.key("abc", "all", nil)] = FeedSearchPage(posts: [card("a")])
        let gate = Gate()
        source.hold(SearchSource.key("abc", "all", nil), gate)
        let store = make(source)
        store.onQueryChange("abc")
        await eventually("请求发出") { await gate.arrivals == 1 }
        store.onQueryChange("   ")
        XCTAssertNil(store.state.results)
        XCTAssertFalse(store.state.loading)
        XCTAssertFalse(store.state.failed)
        await gate.open()
        await store.waitForTasks()
        XCTAssertNil(store.state.results, "清空以后迟到的结果不再显示")
        XCTAssertFalse(store.state.loading)
    }

    /// 引擎 `MaxSearchChars = 50` 数码点。以前这里断言「60 个 👨‍👩‍👧 留 50 个」——那是 250 个码点，引擎会 400 `invalid_query`。
    func testTheQueryIsClippedToFiftyCodePointsWithoutSplittingAnEmoji() {
        let store = make(SearchSource())
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"   // 👨‍👩‍👧：1 个字、5 个码点
        store.onQueryChange(String(repeating: family, count: 60))
        XCTAssertEqual(store.state.query, String(repeating: family, count: 10))
        XCTAssertEqual(store.state.query.unicodeScalars.count, 50)
        store.onQueryChange(String(repeating: "字", count: 60))
        XCTAssertEqual(store.state.query.unicodeScalars.count, 50)
        store.onQueryChange(String(repeating: "a", count: 49) + "\u{1F1E8}\u{1F1F3}")
        XCTAssertEqual(store.state.query, String(repeating: "a", count: 49), "国旗放不下就整个去掉")
    }

    func testSubmitSearchesAtOnceAndRemembersTheQueryOnlyThen() async {
        let source = SearchSource()
        let history = InMemoryFeedSearchHistory()
        let sleeper = Sleeper()
        let store = make(source, history: history, sleeper: sleeper)
        store.submit()
        XCTAssertEqual(source.calls.all, [], "空词不搜")
        store.onQueryChange(" 春天 ")
        store.submit()
        await eventually("边打边搜那次在等") { await sleeper.count == 1 }
        await sleeper.releaseAll()   // 放开被顶掉的那次（模拟网络层不理会取消）
        await store.waitForTasks()
        let sleeps = await sleeper.count
        XCTAssertEqual(sleeps, 1, "只有边打边搜那一次等了；回车不等")
        XCTAssertEqual(source.calls.all, ["search all|春天|-"], "搜索词去掉首尾空白；回车那次顶掉了还在等的")
        XCTAssertEqual(history.queries(), ["春天"])
        XCTAssertEqual(store.state.recentQueries, ["春天"])
    }

    func testRecentQueryRunsAndRemoveAndClearUpdateTheList() async {
        let source = SearchSource()
        let history = InMemoryFeedSearchHistory()
        history.addQuery("a")
        history.addQuery("b")
        let store = make(source, history: history)
        XCTAssertEqual(store.state.recentQueries, ["b", "a"])
        store.useRecentQuery("a")
        await store.waitForTasks()
        XCTAssertEqual(store.state.query, "a")
        XCTAssertEqual(source.calls.all, ["search all|a|-"])
        XCTAssertEqual(store.state.recentQueries, ["a", "b"], "用过的挪到最前")
        store.removeRecentQuery("b")
        XCTAssertEqual(store.state.recentQueries, ["a"])
        store.clearRecentQueries()
        XCTAssertEqual(store.state.recentQueries, [])
        XCTAssertEqual(history.queries(), [])
    }

    func testScopeChangeSearchesAgainOnlyWhenThereIsAQuery() async {
        let source = SearchSource()
        let store = make(source)
        store.selectScope(FeedAPI.searchUsers)
        XCTAssertEqual(store.state.scope, "users")
        XCTAssertEqual(source.calls.all, [], "没有词不搜")
        store.selectScope(FeedAPI.searchUsers)
        store.onQueryChange("x")
        await store.waitForTasks()
        store.selectScope(FeedAPI.searchUsers)   // 没变
        store.selectScope(FeedAPI.searchPosts)
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all, ["search users|x|-", "search posts|x|-"])
        XCTAssertEqual(store.state.results?.scope, "posts")
    }

    func testFailureIsShownAndRetryWorks() async {
        let source = SearchSource()
        source.searchError = Boom()
        let store = make(source)
        store.onQueryChange("x")
        await store.waitForTasks()
        XCTAssertTrue(store.state.failed)
        XCTAssertFalse(store.state.loading)
        XCTAssertNil(store.state.results)
        source.searchError = nil
        source.pages[SearchSource.key("x", "all", nil)] = FeedSearchPage(posts: [card("a")])
        store.retry()
        XCTAssertFalse(store.state.failed)
        XCTAssertTrue(store.state.loading)
        await store.waitForTasks()
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a"])
    }

    func testLoadMoreAppendsDedupedAndIsSingleFlight() async {
        let source = SearchSource()
        source.pages[SearchSource.key("x", "all", nil)] = FeedSearchPage(posts: [card("a"), card("b")], cursor: "c1")
        source.pages[SearchSource.key("x", "all", "c1")] = FeedSearchPage(posts: [card("b"), card("c")], cursor: nil)
        let store = make(source)
        store.onQueryChange("x")
        await store.waitForTasks()
        store.loadMore()
        store.loadMore()
        XCTAssertTrue(store.state.loadingMore)
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0.contains("c1") }.count, 1)
        XCTAssertEqual(store.state.results?.posts.map(\.id), ["a", "b", "c"])
        XCTAssertNil(store.state.results?.cursor)
        XCTAssertFalse(store.state.loadingMore)
        store.loadMore()   // 没有下一页
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.count, 2)
    }

    func testAPageThatArrivesAfterANewSearchIsNotMixedIntoTheNewResults() async {
        let source = SearchSource()
        source.pages[SearchSource.key("x", "all", nil)] = FeedSearchPage(posts: [card("a")], cursor: "c1")
        source.pages[SearchSource.key("x", "all", "c1")] = FeedSearchPage(posts: [card("old")], cursor: "c2")
        source.pages[SearchSource.key("x", "users", nil)] = FeedSearchPage(users: [user("1")])
        let store = make(source)
        store.onQueryChange("x")
        await store.waitForTasks()
        let gate = Gate()
        source.hold(SearchSource.key("x", "all", "c1"), gate)
        store.loadMore()
        await eventually("下一页请求发出") { await gate.arrivals == 1 }
        store.selectScope(FeedAPI.searchUsers)
        XCTAssertFalse(store.state.loadingMore, "新搜索把「加载更多」收掉")
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(store.state.results?.scope, "users")
        XCTAssertEqual(store.state.results?.posts.map(\.id), [])
        XCTAssertEqual(store.state.results?.users.map(\.id), ["1"])
        XCTAssertNil(store.state.results?.cursor)
    }

    func testOpeningAPersonOrPostRemembersThemAndTheQuery() {
        let history = InMemoryFeedSearchHistory()
        let store = make(SearchSource(), history: history)
        store.onPersonOpened(FeedPersonSummary(id: "1", handle: nil, displayName: "Ann", avatarKey: nil))
        XCTAssertEqual(store.state.recentPeople.map(\.id), ["1"])
        XCTAssertEqual(history.queries(), [], "没有搜索词就不记词")
        store.onQueryChange("an")
        store.onPostOpened()
        XCTAssertEqual(history.queries(), ["an"])
        store.onPersonOpened(FeedPersonSummary(id: "2", handle: nil, displayName: "Bob", avatarKey: nil))
        XCTAssertEqual(store.state.recentPeople.map(\.id), ["2", "1"])
        store.clearRecentPeople()
        XCTAssertEqual(store.state.recentPeople, [])
        XCTAssertEqual(history.people(), [])
    }

    func testLikeAndRepostAreOptimisticAndRolledBack() async {
        let source = SearchSource()
        source.pages[SearchSource.key("x", "all", nil)] = FeedSearchPage(posts: [card("a"), card("b")])
        let store = make(source)
        store.onQueryChange("x")
        await store.waitForTasks()
        store.toggleLike(store.state.results!.posts[0])
        XCTAssertTrue(store.state.results!.posts[0].viewer.liked)
        XCTAssertFalse(store.state.results!.posts[1].viewer.liked)
        await store.waitForTasks()
        XCTAssertTrue(store.state.results!.posts[0].viewer.liked)

        source.likeError = Boom()
        store.toggleLike(store.state.results!.posts[1])
        await store.waitForTasks()
        XCTAssertFalse(store.state.results!.posts[1].viewer.liked, "失败改回去（Android 不提示）")
        XCTAssertNil(store.state.notice)

        store.toggleRepost(store.state.results!.posts[0])
        store.toggleRepost(store.state.results!.posts[0])   // 在途，忽略
        XCTAssertTrue(store.state.results!.posts[0].viewer.reposted)
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .reposted)
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("repost") }, ["repost a true"])
        store.onNoticeShown()
        source.repostError = Boom()
        store.toggleRepost(store.state.results!.posts[1])
        await store.waitForTasks()
        XCTAssertFalse(store.state.results!.posts[1].viewer.reposted)
        XCTAssertEqual(store.state.notice, .failed)

        store.toggleSave(store.state.results!.posts[1])
        XCTAssertTrue(store.state.results!.posts[1].viewer.saved)
        await store.waitForTasks()
        XCTAssertFalse(store.state.results!.posts[1].viewer.saved, "没有收藏实现：改回去并提示")
        XCTAssertEqual(store.state.notice, .failed)
    }
}

// MARK: - topic store

private final class TopicSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _pages = [String: FeedTopicPage]()
    private var _topicError: Error?
    private var _followGate: Gate?
    var pages: [String: FeedTopicPage] {
        get { lock.lock(); defer { lock.unlock() }; return _pages }
        set { lock.lock(); _pages = newValue; lock.unlock() }
    }
    var topicError: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _topicError }
        set { lock.lock(); _topicError = newValue; lock.unlock() }
    }
    var followGate: Gate? {
        get { lock.lock(); defer { lock.unlock() }; return _followGate }
        set { lock.lock(); _followGate = newValue; lock.unlock() }
    }
    var followError: Error?
    var likeError: Error?
    var repostError: Error?
    let calls = CallLog<String>()

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {
        calls.append("like \(contentId) \(liked)")
        if let likeError { throw likeError }
    }
    func setReposted(contentId: String, reposted: Bool) async throws {
        calls.append("repost \(contentId) \(reposted)")
        if let repostError { throw repostError }
    }
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func topicPosts(slug: String, cursor: String?) async throws -> FeedTopicPage {
        calls.append("topic \(slug) \(cursor ?? "-")")
        if let topicError { throw topicError }
        return pages[cursor ?? ""] ?? FeedTopicPage()
    }
    func setFollowingTopic(slug: String, following: Bool) async throws {
        calls.append("follow \(slug) \(following)")
        if let gate = followGate { await gate.wait() }
        if let followError { throw followError }
    }
}

@MainActor
final class TellomiFeedTopicStoreTests: XCTestCase {
    private func started(_ source: TopicSource) async -> FeedTopicStore {
        let store = FeedTopicStore(slug: "food", source: source)
        store.start()
        await store.waitForTasks()
        return store
    }

    func testFirstLoadFillsPostsFollowingAndCursor() async {
        let source = TopicSource()
        source.pages[""] = FeedTopicPage(posts: [card("a"), card("b")], cursor: "c1", following: true)
        let store = FeedTopicStore(slug: "food", source: source)
        XCTAssertTrue(store.state.loading, "还没开始读时就是「读取中」")
        store.start()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all, ["topic food -"])
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b"])
        XCTAssertTrue(store.state.following)
        XCTAssertTrue(store.state.loadedOnce)
        XCTAssertFalse(store.state.loading)
        XCTAssertFalse(store.state.failed)
        XCTAssertFalse(store.state.gone)
    }

    func testLoadMoreAppendsDedupedIsSingleFlightAndRefreshReplaces() async {
        let source = TopicSource()
        source.pages[""] = FeedTopicPage(posts: [card("a")], cursor: "c1", following: false)
        source.pages["c1"] = FeedTopicPage(posts: [card("a"), card("b")], cursor: nil, following: false)
        let store = await started(source)
        store.loadMore()
        store.loadMore()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all, ["topic food -", "topic food c1"])
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b"])
        store.loadMore()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.count, 2, "没有下一页")
        source.pages[""] = FeedTopicPage(posts: [card("z")], cursor: nil, following: false)
        store.refresh()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["z"])
    }

    func testAnUnknownTopicIsGoneAndOtherErrorsAreFailures() async {
        let source = TopicSource()
        source.topicError = FeedAPIError(status: 404, code: "not_found", retryAfterSeconds: nil)
        let store = await started(source)
        XCTAssertTrue(store.state.gone)
        XCTAssertFalse(store.state.failed)
        XCTAssertTrue(store.state.loadedOnce)
        XCTAssertFalse(store.state.loading)
        store.toggleFollow()
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("follow") }, [], "不存在的话题不能关注")

        let source2 = TopicSource()
        source2.topicError = FeedAPIError(status: 500, code: nil, retryAfterSeconds: nil)
        let store2 = await started(source2)
        XCTAssertTrue(store2.state.failed)
        XCTAssertFalse(store2.state.gone)

        let source3 = TopicSource()
        source3.topicError = Boom()
        let store3 = await started(source3)
        XCTAssertTrue(store3.state.failed)
        source3.topicError = nil
        source3.pages[""] = FeedTopicPage(posts: [card("a")])
        store3.refresh()
        XCTAssertFalse(store3.state.failed, "重试时先收掉失败提示")
        await store3.waitForTasks()
        XCTAssertEqual(store3.state.posts.map(\.id), ["a"])
    }

    func testAFailedLoadMoreKeepsThePostsAndTheCursor() async {
        let source = TopicSource()
        source.pages[""] = FeedTopicPage(posts: [card("a")], cursor: "c1")
        source.pages["c1"] = FeedTopicPage(posts: [card("b")])
        let store = await started(source)
        source.topicError = Boom()
        store.loadMore()
        await store.waitForTasks()
        XCTAssertTrue(store.state.failed)
        XCTAssertEqual(store.state.posts.map(\.id), ["a"])
        XCTAssertEqual(store.state.cursor, "c1")
        source.topicError = nil
        store.loadMore()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b"])
        XCTAssertFalse(store.state.failed)
    }

    func testFollowIsOptimisticGivesAFollowedNoticeAndRollsBackOnFailure() async {
        let source = TopicSource()
        source.pages[""] = FeedTopicPage(posts: [card("a")], following: false)
        let store = await started(source)
        store.toggleFollow()
        XCTAssertTrue(store.state.following)
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .followed)
        store.onNoticeShown()
        store.toggleFollow()
        XCTAssertFalse(store.state.following)
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .unfollowed)
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("follow") }, ["follow food true", "follow food false"])

        source.followError = Boom()
        store.toggleFollow()
        await store.waitForTasks()
        XCTAssertFalse(store.state.following, "失败改回原来的（取消关注）")
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testFollowIsIgnoredBeforeTheFirstLoadAndWhileOneIsInFlight() async {
        let source = TopicSource()
        source.pages[""] = FeedTopicPage(posts: [card("a")], following: false)
        let early = FeedTopicStore(slug: "food", source: source)
        early.toggleFollow()
        XCTAssertFalse(early.state.following)
        XCTAssertEqual(source.calls.all, [], "还没读到状态时不知道该关注还是取关")

        let store = await started(source)
        let gate = Gate()
        source.followGate = gate
        store.toggleFollow()
        await eventually("请求发出") { await gate.arrivals == 1 }
        store.toggleFollow()   // 在途，忽略
        XCTAssertTrue(store.state.following)
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("follow") }, ["follow food true"])
    }

    func testARefreshThatLandsWhileFollowingIsInFlightDoesNotOverwriteTheButton() async {
        let source = TopicSource()
        source.pages[""] = FeedTopicPage(posts: [card("a")], following: false)
        let store = await started(source)
        let gate = Gate()
        source.followGate = gate
        store.toggleFollow()
        await eventually("请求发出") { await gate.arrivals == 1 }
        store.refresh()   // 回包里还是旧的 following = false
        await eventually("刷新完成") { await MainActor.run { !store.state.loading } }
        XCTAssertTrue(store.state.following, "关注在路上时不拿回包盖掉按钮")
        await gate.open()
        await store.waitForTasks()
        XCTAssertTrue(store.state.following)
        // 关注结束以后刷新才以服务器为准
        source.pages[""] = FeedTopicPage(posts: [card("a")], following: true)
        store.refresh()
        await store.waitForTasks()
        XCTAssertTrue(store.state.following)
    }

    func testCardActionsRollBackAndReport() async {
        let source = TopicSource()
        source.pages[""] = FeedTopicPage(posts: [card("a"), card("b")])
        let store = await started(source)
        store.toggleLike(store.state.posts[0])
        XCTAssertTrue(store.state.posts[0].viewer.liked)
        await store.waitForTasks()
        XCTAssertNil(store.state.notice)
        source.likeError = Boom()
        store.toggleLike(store.state.posts[1])
        await store.waitForTasks()
        XCTAssertFalse(store.state.posts[1].viewer.liked)
        XCTAssertEqual(store.state.notice, .failed, "话题页点赞失败有提示（和搜索页不同，照 Android）")
        store.onNoticeShown()

        store.toggleRepost(store.state.posts[0])
        await store.waitForTasks()
        XCTAssertTrue(store.state.posts[0].viewer.reposted)
        XCTAssertEqual(store.state.notice, .reposted)
        source.repostError = Boom()
        store.toggleRepost(store.state.posts[1])
        await store.waitForTasks()
        XCTAssertFalse(store.state.posts[1].viewer.reposted)
        XCTAssertEqual(store.state.notice, .failed)

        store.toggleSave(store.state.posts[1])
        await store.waitForTasks()
        XCTAssertFalse(store.state.posts[1].viewer.saved)
        XCTAssertEqual(store.state.notice, .failed)
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
