//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

// 名单页：关注请求、屏蔽名单、不看 TA、不让 TA 看、关心的人（store、样例源、入口）。

private func api(_ status: Int, _ code: String? = nil, retryAfter: Int? = nil) -> FeedAPIError {
    FeedAPIError(status: status, code: code, retryAfterSeconds: retryAfter)
}

private struct Boom: Error {}

private actor Gate {
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()
    func wait() async {
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

private func person(_ id: String, _ name: String = "N", handle: String? = nil) -> FeedPersonSummary {
    FeedPersonSummary(id: id, handle: handle, displayName: name, avatarKey: nil)
}

private final class ListsSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests = [FeedPersonSummary]()
    private var _blocks = [FeedBlockEntry]()
    private var _hide = FeedHideLists()
    private var _close = FeedClosePeopleResponse()
    private var _users = [String: [FeedSearchUser]]()
    private var _readError: Error?
    private var _actionError: Error?
    private var _gate: Gate?
    private var _readGate: [Gate?] = []
    private var _calls = [String]()
    private var _readCalls = 0
    private var _searchCalls = [String]()
    private var _searchDelay = [String: UInt64]()
    private var _addResult = "pending"

    var requests: [FeedPersonSummary] { get { locked { _requests } } set { locked { _requests = newValue } } }
    var blocksValue: [FeedBlockEntry] { get { locked { _blocks } } set { locked { _blocks = newValue } } }
    var hide: FeedHideLists { get { locked { _hide } } set { locked { _hide = newValue } } }
    var close: FeedClosePeopleResponse { get { locked { _close } } set { locked { _close = newValue } } }
    var users: [String: [FeedSearchUser]] { get { locked { _users } } set { locked { _users = newValue } } }
    var readError: Error? { get { locked { _readError } } set { locked { _readError = newValue } } }
    var actionError: Error? { get { locked { _actionError } } set { locked { _actionError = newValue } } }
    var gate: Gate? { get { locked { _gate } } set { locked { _gate = newValue } } }
    var addResult: String { get { locked { _addResult } } set { locked { _addResult = newValue } } }
    var searchDelay: [String: UInt64] { get { locked { _searchDelay } } set { locked { _searchDelay = newValue } } }
    var calls: [String] { locked { _calls } }
    var readCalls: Int { locked { _readCalls } }
    var searchCalls: [String] { locked { _searchCalls } }
    /// 第 n 次读（从 0 数）先等这个 gate。
    func setReadGates(_ gates: [Gate?]) { locked { _readGate = gates } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func read() async throws {
        let (index, gate, error): (Int, Gate?, Error?) = locked {
            let index = _readCalls
            _readCalls += 1
            return (index, index < _readGate.count ? _readGate[index] : nil, _readError)
        }
        if let gate { await gate.wait() }
        if let error { throw error }
        _ = index
    }

    private func write(_ name: String) async throws {
        locked { _calls.append(name) }
        if let gate { await gate.wait() }
        if let error = actionError { throw error }
    }

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { FeedCreatePostResponse(id: "x", state: "published") }

    func followRequests() async throws -> [FeedFollowRequest] {
        try await read()
        return requests.map { FeedFollowRequest(profile: $0, requestedAt: nil) }
    }
    func answerFollowRequest(profileId: String, approve: Bool) async throws { try await write("answer:\(profileId):\(approve)") }
    func blocks() async throws -> [FeedBlockEntry] {
        try await read()
        return blocksValue
    }
    func unblock(_ entry: FeedBlockEntry) async throws { try await write("unblock:\(entry.type)/\(entry.id)") }
    func hideLists() async throws -> FeedHideLists {
        try await read()
        return hide
    }
    func setHideList(list: String, profileId: String, on: Bool) async throws { try await write("hide:\(list):\(profileId):\(on)") }
    func closePeople() async throws -> FeedClosePeopleResponse {
        try await read()
        return close
    }
    func addClosePerson(profileId: String) async throws -> String {
        try await write("add:\(profileId)")
        return addResult
    }
    func removeClosePerson(profileId: String) async throws { try await write("remove:\(profileId)") }
    func answerClosePerson(ownerProfileId: String, accept: Bool) async throws { try await write("close-answer:\(ownerProfileId):\(accept)") }
    func search(query: String, scope: String, cursor: String?) async throws -> FeedSearchPage {
        let delay: UInt64 = locked {
            _searchCalls.append("\(scope):\(query)")
            return _searchDelay[query] ?? 0
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if let error = readError { throw error }
        var page = FeedSearchPage()
        page.users = users[query] ?? []
        return page
    }
}

/// 没有覆盖 `unblock` 的源：走协议的默认实现。
private final class DefaultUnblockSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _blocked = [String]()
    var blockedCalls: [String] { lock.lock(); defer { lock.unlock() }; return _blocked }
    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { FeedCreatePostResponse(id: "x", state: "published") }
    func setBlocked(profileId: String, blocked: Bool) async throws {
        lock.lock()
        _blocked.append("\(profileId):\(blocked)")
        lock.unlock()
    }
}

// MARK: - 四张名单

@MainActor
final class TellomiFeedPeopleStoreTests: XCTestCase {
    private func make(_ mode: FeedPeopleMode, _ source: ListsSource) async -> FeedPeopleStore {
        let store = FeedPeopleStore(mode: mode, source: source)
        store.start()
        await store.waitForTasks()
        return store
    }

    private func requestsSource(_ ids: [String] = ["a", "b", "c"]) -> ListsSource {
        let source = ListsSource()
        source.requests = ids.map { person($0, "P-\($0)", handle: "h-\($0)") }
        return source
    }

    func testFollowRequestsLoadAsRowsKeyedByProfile() async {
        let store = await make(.followRequests, requestsSource())
        XCTAssertEqual(store.state.rows.map(\.key), ["a", "b", "c"])
        XCTAssertTrue(store.state.loadedOnce)
        XCTAssertFalse(store.state.loading)
        XCTAssertFalse(store.state.failed)
        XCTAssertEqual(store.state.rows[0].display, .person(name: "P-a", handle: "h-a", avatarKey: nil))
    }

    func testBlockedRowsShowAuthorsSourcesTopicsAndUnknownTypes() async {
        let source = ListsSource()
        source.blocksValue = [
            FeedBlockEntry(type: "author", id: "u1", createdAt: nil, profile: person("u1", "Alice")),
            FeedBlockEntry(type: "author", id: "u2", createdAt: nil, profile: nil),
            FeedBlockEntry(type: "source", id: "news", createdAt: nil, profile: nil),
            FeedBlockEntry(type: "topic", id: "gossip", createdAt: nil, profile: nil),
            FeedBlockEntry(type: "future", id: "x", createdAt: nil, profile: nil),
        ]
        let store = await make(.blocked, source)
        XCTAssertEqual(store.state.rows.map(\.key), ["author/u1", "author/u2", "source/news", "topic/gossip", "future/x"])
        XCTAssertEqual(store.state.rows.map(\.display), [
            .person(name: "Alice", handle: nil, avatarKey: nil), .other("u2"), .source("news"), .topic("gossip"), .other("x"),
        ])
    }

    func testMutedAndHiddenFromReadTheirOwnLists() async {
        let source = ListsSource()
        var lists = FeedHideLists()
        lists.mute = [person("m1")]
        lists.hideFrom = [person("h1"), person("h2")]
        source.hide = lists
        let muted = await make(.muted, source)
        let hidden = await make(.hiddenFrom, source)
        XCTAssertEqual(muted.state.rows.map(\.key), ["m1"])
        XCTAssertEqual(hidden.state.rows.map(\.key), ["h1", "h2"])
    }

    func testApproveRemovesTheRowAtOnceAndReportsApprovedAfterTheCall() async {
        let source = requestsSource()
        let gate = Gate()
        let store = await make(.followRequests, source)
        source.gate = gate
        let row = store.state.rows[1]
        store.answer(row, approve: true)
        XCTAssertEqual(store.state.rows.map(\.key), ["a", "c"], "先拿掉")
        XCTAssertNil(store.state.notice)
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(source.calls, ["answer:b:true"])
        XCTAssertEqual(store.state.notice, .approved)
        XCTAssertEqual(store.state.rows.map(\.key), ["a", "c"])
    }

    func testDeclineCallsTheEngineWithFalse() async {
        let source = requestsSource()
        let store = await make(.followRequests, source)
        store.answer(store.state.rows[0], approve: false)
        await store.waitForTasks()
        XCTAssertEqual(source.calls, ["answer:a:false"])
        XCTAssertEqual(store.state.notice, .declined)
    }

    func testAFailureRestoresTheRowWhereItWasAndSaysFailed() async {
        let source = requestsSource()
        let store = await make(.followRequests, source)
        source.actionError = Boom()
        store.answer(store.state.rows[1], approve: true)
        await store.waitForTasks()
        XCTAssertEqual(store.state.rows.map(\.key), ["a", "b", "c"])
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testTheRequesterHavingWithdrawnCountsAsDone() async {
        let source = requestsSource()
        let store = await make(.followRequests, source)
        source.actionError = api(404, "not_found")
        store.answer(store.state.rows[0], approve: true)
        await store.waitForTasks()
        XCTAssertEqual(store.state.rows.map(\.key), ["b", "c"])
        XCTAssertEqual(store.state.notice, .approved)
    }

    func testThrottledActionRestoresTheRowWithTheWait() async {
        let source = requestsSource()
        let store = await make(.followRequests, source)
        source.actionError = api(429, "rate_limited", retryAfter: 12)
        store.answer(store.state.rows[2], approve: false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.rows.map(\.key), ["a", "b", "c"])
        XCTAssertEqual(store.state.notice, .throttled(retryAfterSeconds: 12))
    }

    func testFeedHiddenOnAnActionClosesThePageInsteadOfRestoring() async {
        let source = requestsSource()
        let store = await make(.followRequests, source)
        source.actionError = api(404, "feed_hidden")
        store.answer(store.state.rows[0], approve: true)
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertNil(store.state.notice)
    }

    func testTheSameRowCannotBeActedOnTwiceWhileTheCallIsOut() async {
        let source = requestsSource()
        let gate = Gate()
        let store = await make(.followRequests, source)
        source.gate = gate
        let row = store.state.rows[0]
        store.answer(row, approve: true)
        store.answer(row, approve: false)
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(source.calls, ["answer:a:true"])
    }

    func testAnActionsOutOfModeAreIgnored() async {
        let source = requestsSource()
        let store = await make(.followRequests, source)
        let row = store.state.rows[0]
        store.unblock(row)
        store.remove(row)
        await store.waitForTasks()
        XCTAssertEqual(source.calls, [])
        let blocked = await make(.blocked, source)
        blocked.answer(FeedPeopleRow(key: "a", person: person("a"), block: nil), approve: true)
        XCTAssertEqual(source.calls, [])
    }

    func testUnblockAndRemoveGoToTheRightEndpoints() async {
        let source = ListsSource()
        source.blocksValue = [FeedBlockEntry(type: "topic", id: "gossip", createdAt: nil, profile: nil)]
        var lists = FeedHideLists()
        lists.mute = [person("m1")]
        lists.hideFrom = [person("h1")]
        source.hide = lists
        let blocked = await make(.blocked, source)
        blocked.unblock(blocked.state.rows[0])
        await blocked.waitForTasks()
        let muted = await make(.muted, source)
        muted.remove(muted.state.rows[0])
        await muted.waitForTasks()
        let hidden = await make(.hiddenFrom, source)
        hidden.remove(hidden.state.rows[0])
        await hidden.waitForTasks()
        XCTAssertEqual(source.calls, ["unblock:topic/gossip", "hide:mute:m1:false", "hide:hide_from:h1:false"])
        XCTAssertEqual(blocked.state.notice, .unblocked)
        XCTAssertEqual(muted.state.notice, .removed)
    }

    func testLoadFailureCanBeRetriedAndRemembersTheWait() async {
        let source = requestsSource()
        source.readError = api(429, "rate_limited", retryAfter: 30)
        let store = await make(.followRequests, source)
        XCTAssertTrue(store.state.failed)
        XCTAssertEqual(store.state.retryAfterSeconds, 30)
        XCTAssertTrue(store.state.loadedOnce)
        source.readError = nil
        store.refresh()
        XCTAssertTrue(store.state.loading)
        XCTAssertFalse(store.state.failed)
        await store.waitForTasks()
        XCTAssertEqual(store.state.rows.count, 3)
        XCTAssertNil(store.state.retryAfterSeconds)
    }

    func testFeedHiddenOnLoadClosesThePage() async {
        let source = requestsSource()
        source.readError = api(404, "feed_hidden")
        let store = await make(.followRequests, source)
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertFalse(store.state.failed)
    }

    func testRefreshWhileAnActionIsOutDoesNotBringTheRowBack() async {
        let source = requestsSource()
        let gate = Gate()
        let store = await make(.followRequests, source)
        source.gate = gate
        store.answer(store.state.rows[0], approve: true)
        store.refresh()
        for _ in 0..<500 where store.state.loading { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertFalse(store.state.loading)
        XCTAssertEqual(store.state.rows.map(\.key), ["b", "c"], "动作还没回来时重新拉到的名单里还有它，不能又出现")
        await gate.open()
        await store.waitForTasks()
    }

    func testAnOlderSlowRefreshNeverOverwritesANewerOne() async {
        let source = requestsSource(["old"])
        let slow = Gate()
        source.setReadGates([slow, nil])
        let store = FeedPeopleStore(mode: .followRequests, source: source)
        store.refresh()
        source.requests = [person("new")]
        store.refresh()
        await Task.yield()
        for _ in 0..<50 where source.readCalls < 2 { try? await Task.sleep(nanoseconds: 2_000_000) }
        await slow.open()
        await store.waitForTasks()
        XCTAssertEqual(store.state.rows.map(\.key), ["new"])
    }

    func testNoticeIsCleared() async {
        let source = requestsSource()
        let store = await make(.followRequests, source)
        store.answer(store.state.rows[0], approve: true)
        await store.waitForTasks()
        XCTAssertNotNil(store.state.notice)
        store.onNoticeShown()
        XCTAssertNil(store.state.notice)
    }

    func testModesMapToTheEngineLists() {
        XCTAssertNil(FeedPeopleMode.followRequests.hideList)
        XCTAssertNil(FeedPeopleMode.blocked.hideList)
        XCTAssertEqual(FeedPeopleMode.muted.hideList, "mute")
        XCTAssertEqual(FeedPeopleMode.hiddenFrom.hideList, "hide_from")
    }

    func testDefaultUnblockOnlyKnowsAuthors() async throws {
        let source = DefaultUnblockSource()
        try await source.unblock(FeedBlockEntry(type: "author", id: "u1", createdAt: nil, profile: nil))
        XCTAssertEqual(source.blockedCalls, ["u1:false"])
        do {
            try await source.unblock(FeedBlockEntry(type: "topic", id: "t", createdAt: nil, profile: nil))
            XCTFail("topic needs the engine")
        } catch {
            XCTAssertEqual(source.blockedCalls, ["u1:false"])
        }
    }

    func testEntryOrderAndModes() {
        XCTAssertEqual(FeedListsEntry.allCases, [.followRequests, .muted, .hiddenFrom, .blocked, .closePeople])
        XCTAssertEqual(FeedListsEntry.allCases.compactMap(\.peopleMode), [.followRequests, .muted, .hiddenFrom, .blocked])
        XCTAssertNil(FeedListsEntry.closePeople.peopleMode)
    }
}

// MARK: - 关心的人

@MainActor
final class TellomiFeedClosePeopleStoreTests: XCTestCase {
    private func entry(_ id: String, state: String = "pending") -> FeedClosePersonEntry {
        FeedClosePersonEntry(id: id, displayName: "N-\(id)", state: state)
    }

    private func make(_ source: ListsSource, debounce: UInt64 = 0) async -> FeedClosePeopleStore {
        let store = FeedClosePeopleStore(source: source, debounceNanos: debounce)
        store.start()
        await store.waitForTasks()
        return store
    }

    private func user(_ id: String) -> FeedSearchUser {
        FeedSearchUser(id: id, displayName: "U-\(id)")
    }

    func testLoadsMineAndRequestsAndKnowsWhenItIsFull() async {
        let source = ListsSource()
        source.close = {
            var response = FeedClosePeopleResponse()
            response.mine = [entry("a"), entry("b", state: "accepted")]
            response.requests = [entry("r")]
            return response
        }()
        let store = await make(source)
        XCTAssertEqual(store.state.mine.map(\.id), ["a", "b"])
        XCTAssertEqual(store.state.requests.map(\.id), ["r"])
        XCTAssertTrue(store.state.canAdd)
        XCTAssertTrue(store.state.loadedOnce)
        source.close.mine = [entry("a"), entry("b"), entry("c")]
        store.refresh()
        await store.waitForTasks()
        XCTAssertFalse(store.state.canAdd, "最多 3 个（含待同意）")
    }

    func testLoadFailureAndFeedHidden() async {
        let source = ListsSource()
        source.readError = api(503, "unavailable", retryAfter: 9)
        let store = await make(source)
        XCTAssertTrue(store.state.failed)
        XCTAssertEqual(store.state.retryAfterSeconds, 9)
        source.readError = api(404, "feed_hidden")
        store.refresh()
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
    }

    func testSearchIsTrimmedCutAtFiftyAndDebounced() async {
        let source = ListsSource()
        let store = await make(source, debounce: 30_000_000)
        store.onQueryChanged("a")
        store.onQueryChanged("  ab  ")
        XCTAssertTrue(store.state.searching)
        await store.waitForTasks()
        XCTAssertEqual(source.searchCalls, ["users:ab"], "连续输入只搜最后一次")
        let long = String(repeating: "字", count: 60)
        store.onQueryChanged(long)
        await store.waitForTasks()
        XCTAssertEqual(source.searchCalls.last, "users:" + String(repeating: "字", count: 50))
        XCTAssertFalse(store.state.searching)
    }

    func testEmptyQueryClearsResultsWithoutSearching() async {
        let source = ListsSource()
        source.users = ["x": [user("1")]]
        let store = await make(source)
        store.onQueryChanged("x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.results.map(\.id), ["1"])
        store.onQueryChanged("   ")
        XCTAssertEqual(store.state.results, [])
        XCTAssertFalse(store.state.searching)
        await store.waitForTasks()
        XCTAssertEqual(source.searchCalls, ["users:x"])
    }

    func testALateAnswerForAnOlderQueryIsDropped() async {
        let source = ListsSource()
        source.users = ["slow": [user("old")], "fast": [user("new")]]
        source.searchDelay = ["slow": 60_000_000]
        let store = await make(source)
        store.onQueryChanged("slow")
        try? await Task.sleep(nanoseconds: 10_000_000)
        store.onQueryChanged("fast")
        await store.waitForTasks()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(store.state.results.map(\.id), ["new"])
        XCTAssertEqual(store.state.query, "fast")
    }

    func testSearchFailureGivesAnEmptyList() async {
        let source = ListsSource()
        let store = await make(source)
        source.readError = Boom()
        store.onQueryChanged("x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.results, [])
        XCTAssertFalse(store.state.searching)
    }

    func testResultsHideAlreadyPickedPeople() async {
        let source = ListsSource()
        source.close.mine = [entry("1")]
        source.users = ["x": [user("1"), user("2")]]
        let store = await make(source)
        store.onQueryChanged("x")
        await store.waitForTasks()
        XCTAssertEqual(store.state.addableResults.map(\.id), ["2"])
    }

    func testAddAppendsWithTheEngineStateAndClearsTheSearch() async {
        let source = ListsSource()
        source.users = ["x": [user("2")]]
        source.addResult = "accepted"
        let store = await make(source)
        store.onQueryChanged("x")
        await store.waitForTasks()
        store.add(user("2"))
        XCTAssertTrue(store.state.adding)
        await store.waitForTasks()
        XCTAssertEqual(store.state.mine.map(\.id), ["2"])
        XCTAssertEqual(store.state.mine.first?.state, "accepted")
        XCTAssertEqual(store.state.notice, .added)
        XCTAssertEqual(store.state.query, "")
        XCTAssertEqual(store.state.results, [])
        XCTAssertFalse(store.state.adding)
        store.add(user("2"))
        await store.waitForTasks()
        XCTAssertEqual(source.calls, ["add:2"], "已经设了不再发")
    }

    func testAddIsRefusedLocallyWhenFullOrBusy() async {
        let source = ListsSource()
        source.close.mine = [entry("1"), entry("2"), entry("3")]
        let store = await make(source)
        store.add(user("4"))
        await store.waitForTasks()
        XCTAssertEqual(source.calls, [])
        let free = ListsSource()
        let gate = Gate()
        let busy = await make(free)
        free.gate = gate
        busy.add(user("5"))
        busy.add(user("6"))
        await gate.open()
        await busy.waitForTasks()
        XCTAssertEqual(free.calls, ["add:5"], "上一个还没回来时再点不发")
    }

    func testAddFailuresMapToTheirOwnNotices() async {
        let cases: [(Error, FeedClosePeopleNotice?)] = [
            (api(409, "close_people_full"), .full),
            (api(409, "profile_required"), .profileRequired),
            (api(404, "not_found"), .notAllowed),
            (api(429, "rate_limited", retryAfter: 5), .throttled(retryAfterSeconds: 5)),
            (Boom(), .failed),
            (api(500, "boom"), .failed),
        ]
        for (error, expected) in cases {
            let source = ListsSource()
            let store = await make(source)
            source.actionError = error
            store.add(user("9"))
            await store.waitForTasks()
            XCTAssertEqual(store.state.notice, expected, "\(error)")
            XCTAssertEqual(store.state.mine, [], "失败不加")
            XCTAssertFalse(store.state.adding)
        }
        let hidden = ListsSource()
        let store = await make(hidden)
        hidden.actionError = api(404, "feed_hidden")
        store.add(user("9"))
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertNil(store.state.notice)
    }

    func testRemoveIsOptimisticAndRestoresAtTheSamePlaceOnFailure() async {
        let source = ListsSource()
        source.close.mine = [entry("1"), entry("2"), entry("3")]
        let store = await make(source)
        source.actionError = Boom()
        store.remove(entry("2"))
        XCTAssertEqual(store.state.mine.map(\.id), ["1", "3"])
        await store.waitForTasks()
        XCTAssertEqual(store.state.mine.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(store.state.notice, .failed)
        source.actionError = api(404, "not_found")
        store.onNoticeShown()
        store.remove(entry("1"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.mine.map(\.id), ["2", "3"], "已经没了：就是删好了")
        XCTAssertNil(store.state.notice)
    }

    func testAnsweringAcceptsInPlaceAndDeclinesByRemoving() async {
        let source = ListsSource()
        source.close.requests = [entry("a"), entry("b")]
        let store = await make(source)
        store.answer(entry("a"), accept: true)
        XCTAssertEqual(store.state.requests.map(\.state), ["accepted", "pending"])
        store.answer(entry("b"), accept: false)
        XCTAssertEqual(store.state.requests.map(\.id), ["a"])
        await store.waitForTasks()
        XCTAssertEqual(source.calls, ["close-answer:a:true", "close-answer:b:false"])
        store.answer(entry("zzz"), accept: true)
        await store.waitForTasks()
        XCTAssertEqual(source.calls.count, 2, "不在名单里的不发")
    }

    func testAnswerFailureRestoresTheWholeList() async {
        let source = ListsSource()
        source.close.requests = [entry("a"), entry("b")]
        let store = await make(source)
        source.actionError = api(500, "boom")
        store.answer(entry("a"), accept: false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.requests.map(\.id), ["a", "b"])
        XCTAssertEqual(store.state.notice, .failed)
        source.actionError = api(404, "not_found")
        store.onNoticeShown()
        store.answer(entry("a"), accept: false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.requests.map(\.id), ["b"], "设了我的人已经撤回：当处理完了")
        XCTAssertNil(store.state.notice)
    }
}

// MARK: - 样例源

final class TellomiFeedSampleListsTests: XCTestCase {
    private func make() -> SampleFeedSource {
        SampleFeedSource(now: { Date(timeIntervalSince1970: 1_800_000_000) }, commentsLatencyNanos: 0)
    }

    private func code(_ block: () async throws -> Void) async -> Int? {
        do {
            try await block()
            return nil
        } catch let error as FeedAPIError {
            return error.status
        } catch {
            return -1
        }
    }

    func testFollowRequestsCanBeAnsweredOnceAndWithdrawnOnes404() async throws {
        let source = make()
        let before = try await source.followRequests()
        XCTAssertEqual(before.map(\.profile.id), ["req-1", "req-2", "req-3"])
        try await source.answerFollowRequest(profileId: "req-1", approve: true)
        let remaining = try await source.followRequests()
        XCTAssertEqual(remaining.count, 2)
        let again = await code { try await source.answerFollowRequest(profileId: "req-1", approve: true) }
        XCTAssertEqual(again, 404)
        source.simulation.followRequestWithdrawn = true
        let withdrawn = await code { try await source.answerFollowRequest(profileId: "req-2", approve: false) }
        XCTAssertEqual(withdrawn, 404)
    }

    func testBlocksListAuthorsFirstAndUnblockWorksForEveryType() async throws {
        let source = make()
        try await source.setBlocked(profileId: "s-2", blocked: true)
        var entries = try await source.blocks()
        XCTAssertEqual(entries.map(\.id), ["s-2", "sample-news", "gossip"])
        XCTAssertEqual(entries[0].profile?.displayName, "小满")
        try await source.unblock(entries[0])
        try await source.unblock(entries[1])
        entries = try await source.blocks()
        XCTAssertEqual(entries.map(\.id), ["gossip"])
        let missing = await code { try await source.unblock(FeedBlockEntry(type: "source", id: "nope", createdAt: nil, profile: nil)) }
        XCTAssertEqual(missing, 404)
    }

    func testHideListsMergeTheProfileMenuAndTheSeeds() async throws {
        let source = make()
        var lists = try await source.hideLists()
        XCTAssertEqual(lists.mute.map(\.id), ["seed-m1", "seed-m2"])
        XCTAssertEqual(lists.hideFrom.map(\.id), ["seed-h1"])
        try await source.setHideList(list: "mute", profileId: "s-4", on: true)
        try await source.setHideList(list: "hide_from", profileId: "s-5", on: true)
        lists = try await source.hideLists()
        XCTAssertEqual(lists.mute.map(\.id), ["s-4", "seed-m1", "seed-m2"])
        XCTAssertEqual(lists.hideFrom.map(\.id), ["s-5", "seed-h1"])
        try await source.setHideList(list: "mute", profileId: "seed-m1", on: false)
        try await source.setHideList(list: "mute", profileId: "s-4", on: false)
        try await source.setHideList(list: "hide_from", profileId: "seed-h1", on: false)
        lists = try await source.hideLists()
        XCTAssertEqual(lists.mute.map(\.id), ["seed-m2"])
        XCTAssertEqual(lists.hideFrom.map(\.id), ["s-5"])
    }

    func testClosePeopleAddRemoveAnswerAndTheLimits() async throws {
        let source = make()
        var response = try await source.closePeople()
        XCTAssertEqual(response.mine.map(\.id), ["s-1"])
        XCTAssertEqual(response.requests.map(\.id), ["s-4"])
        let state = try await source.addClosePerson(profileId: "s-2")
        XCTAssertEqual(state, "pending")
        let same = try await source.addClosePerson(profileId: "s-2")
        XCTAssertEqual(same, "pending", "重复设同一个人不占名额")
        _ = try await source.addClosePerson(profileId: "s-3")
        let full = await code { _ = try await source.addClosePerson(profileId: "s-5") }
        XCTAssertEqual(full, 409)
        let unknown = await code { _ = try await source.addClosePerson(profileId: "nobody") }
        XCTAssertEqual(unknown, 404)
        let me = await code { _ = try await source.addClosePerson(profileId: "s-me") }
        XCTAssertEqual(me, 404)
        try await source.removeClosePerson(profileId: "s-2")
        response = try await source.closePeople()
        XCTAssertEqual(response.mine.map(\.id), ["s-1", "s-3"])
        try await source.answerClosePerson(ownerProfileId: "s-4", accept: true)
        let accepted = try await source.closePeople()
        XCTAssertEqual(accepted.requests.first?.state, "accepted")
        try await source.answerClosePerson(ownerProfileId: "s-4", accept: false)
        let declined = try await source.closePeople()
        XCTAssertEqual(declined.requests, [])
        let gone = await code { try await source.answerClosePerson(ownerProfileId: "s-4", accept: false) }
        XCTAssertEqual(gone, 404)
    }

    func testSimulationSwitches() async throws {
        let source = make()
        source.simulation.failsListsLoad = true
        let load = await code { _ = try await source.followRequests() }
        XCTAssertEqual(load, -1)
        source.simulation.failsListsLoad = false
        source.simulation.failsListsActions = true
        let action = await code { try await source.removeClosePerson(profileId: "s-1") }
        XCTAssertEqual(action, -1)
        source.simulation.failsListsActions = false
        source.simulation.listsThrottledRetryAfterSeconds = 7
        let throttled = await code { _ = try await source.blocks() }
        XCTAssertEqual(throttled, 429)
        source.simulation.listsThrottledRetryAfterSeconds = nil
        source.simulation.closePeopleProfileRequired = true
        let needsProfile = await code { _ = try await source.addClosePerson(profileId: "s-2") }
        XCTAssertEqual(needsProfile, 409)
        source.simulation.closePeopleProfileRequired = false
        source.simulation.closePeopleFull = true
        let full = await code { _ = try await source.addClosePerson(profileId: "s-2") }
        XCTAssertEqual(full, 409)
        source.simulation.feedHidden = true
        let hidden = await code { _ = try await source.hideLists() }
        XCTAssertEqual(hidden, 404)
    }
}
