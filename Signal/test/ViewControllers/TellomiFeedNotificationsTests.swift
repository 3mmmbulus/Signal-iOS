//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedNotificationsTests.swift (new file)
// I-7: notification models / grouping / API wire / list store / notification-settings store.
// Mirrors Android FeedNotificationRowsTest, FeedNotificationsViewModelTest, FeedNotificationSettingsViewModelTest.
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

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private let now = FeedDates.parse("2026-10-13T12:00:00Z")!

private func n(_ id: String, _ kind: String, _ actor: String?, _ content: String?, _ at: String, read: Bool = true, detail: FeedNotificationDetail? = nil) -> FeedNotification {
    FeedNotification(id: id, kind: kind, createdAt: at, actorId: actor, contentId: content, detail: detail, read: read)
}

final class TellomiFeedNotificationGroupingTests: XCTestCase {
    func testLikesOnTheSamePostMergeIntoTheNewestRow() {
        let items = [
            n("1", "like", "a", "post", "2026-10-13T11:00:00Z"),
            n("2", "comment", "b", "post", "2026-10-13T10:00:00Z"),
            n("3", "like", "c", "post", "2026-10-13T09:00:00Z", read: false),
            n("4", "like", "a", "post", "2026-10-13T08:00:00Z"),
            n("5", "like", "d", "other", "2026-10-13T07:00:00Z"),
        ]
        let sections = FeedNotificationGrouping.group(items, now: now, calendar: utc)
        XCTAssertEqual(sections.count, 1)
        let rows = sections[0].rows
        XCTAssertEqual(rows.map(\.key), ["1", "2", "5"])
        XCTAssertEqual(rows[0].ids, ["1", "3", "4"])
        XCTAssertEqual(rows[0].actorIds, ["a", "c"], "同一个人只算一次")
        XCTAssertTrue(rows[0].unread, "合并行里有一条没读就算没读")
        XCTAssertFalse(rows[1].unread)
    }

    func testRowsAreGroupedIntoTodayThisWeekAndEarlier() {
        let items = [
            n("1", "follow", "a", nil, "2026-10-13T01:00:00Z"),
            n("2", "follow", "b", nil, "2026-10-08T01:00:00Z"),
            n("3", "follow", "c", nil, "2026-10-01T01:00:00Z"),
        ]
        let sections = FeedNotificationGrouping.group(items, now: now, calendar: utc)
        XCTAssertEqual(sections.map(\.bucket), [.today, .thisWeek, .earlier])
    }

    func testTheSevenDayEdgeAndAMidnightEdge() {
        let items = [
            n("1", "follow", "a", nil, "2026-10-12T23:59:59Z"),
            n("2", "follow", "b", nil, "2026-10-07T00:00:00Z"),
            n("3", "follow", "c", nil, "2026-10-06T23:59:59Z"),
            n("4", "follow", "d", nil, "2026-10-13T00:00:00Z"),
        ]
        let sections = FeedNotificationGrouping.group(items, now: now, calendar: utc)
        XCTAssertEqual(sections.map(\.bucket), [.today, .thisWeek, .earlier])
        XCTAssertEqual(sections[0].rows.map(\.key), ["4"], "当天 00:00 算今天")
        XCTAssertEqual(sections[1].rows.map(\.key), ["1", "2"], "10-07 还在七天内，10-06 就是更早（day > today-7）")
        XCTAssertEqual(sections[2].rows.map(\.key), ["3"])
    }

    func testLocalTimeZoneDecidesWhatTodayIs() {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 12:00Z = 20:00 上海；10-13T17:00Z 已经是上海的 10-14 01:00（"今天"之后）
        let items = [n("1", "follow", "a", nil, "2026-10-12T17:00:00Z")]   // 上海 10-13 01:00
        XCTAssertEqual(FeedNotificationGrouping.group(items, now: now, calendar: shanghai).map(\.bucket), [.today])
        XCTAssertEqual(FeedNotificationGrouping.group(items, now: now, calendar: utc).map(\.bucket), [.thisWeek])
    }

    func testDetailFieldsHeldAndSystemTypeAndUnreadableTimesAreDropped() {
        let items = [
            n("1", "reply", "a", "post", "2026-10-13T11:00:00Z", detail: FeedNotificationDetail(held: true)),
            n("2", "system", nil, "post", "2026-10-13T10:00:00Z", detail: FeedNotificationDetail(type: "taken_down")),
            n("3", "system", nil, nil, "not a time", detail: nil),
            n("4", "system", nil, nil, "2026-10-13T09:00:00Z", detail: FeedNotificationDetail(type: "close_person_request", profileId: "p9")),
        ]
        let rows = FeedNotificationGrouping.group(items, now: now, calendar: utc)[0].rows
        XCTAssertEqual(rows.map(\.key), ["1", "2", "4"])
        XCTAssertTrue(rows[0].held)
        XCTAssertFalse(rows[1].held)
        XCTAssertEqual(rows[1].systemType, "taken_down")
        XCTAssertEqual(rows[2].profileId, "p9")
        XCTAssertEqual(FeedNotificationGrouping.group([], now: now, calendar: utc), [])
    }

    func testLikeWithoutContentIdIsNeverMerged() {
        let items = [n("1", "like", "a", nil, "2026-10-13T11:00:00Z"), n("2", "like", "b", nil, "2026-10-13T10:00:00Z")]
        XCTAssertEqual(FeedNotificationGrouping.group(items, now: now, calendar: utc)[0].rows.count, 2)
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

final class TellomiFeedNotificationsApiTests: XCTestCase {
    func testDecodingToleratesOddDetailAndMissingFields() async throws {
        let transport = ScriptedTransport()
        let api = FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens())
        transport.reply(200, """
        {"notifications":[
          {"id":"1","kind":"reply","actor_id":"a","content_id":"c","created_at":"2026-10-13T11:00:00Z","detail":{"held":true,"parent_id":"m1"}},
          {"id":"2","kind":"system","created_at":"2026-10-13T10:00:00Z","detail":"just text"},
          {"id":"3","kind":"system","created_at":"2026-10-13T09:00:00Z","detail":{"type":5,"held":"yes","profile_id":"p"}},
          {"id":"4","kind":"follow","created_at":"2026-10-13T08:00:00Z","read":true,"actor":{"id":"a","display_name":"Ann"}}],
         "unread":{"interactions":3,"system":1}}
        """)
        let response = try await api.notifications(tab: "interactions", before: "2026-10-13T00:00:00Z")
        XCTAssertEqual(response.unread, FeedUnreadCounts(interactions: 3, follows: 0, system: 1))
        XCTAssertEqual(response.notifications[0].detail?.held, true)
        XCTAssertFalse(response.notifications[0].read)
        XCTAssertNil(response.notifications[1].detail?.type, "detail 不是对象：当没有")
        XCTAssertNil(response.notifications[2].detail?.type, "类型不对的字段当没有")
        XCTAssertNil(response.notifications[2].detail?.held)
        XCTAssertEqual(response.notifications[2].detail?.profileId, "p")
        XCTAssertEqual(response.notifications[3].actor?.displayName, "Ann")
        XCTAssertEqual(response.notifications.count, 4)
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://feed.example.test/v1/feed/me/notifications?tab=interactions&before=2026-10-13T00:00:00Z")
    }

    func testReadDeleteMuteWire() async throws {
        let transport = ScriptedTransport()
        let api = FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens())
        transport.reply(200, "{}")
        let empty = try await api.notifications(tab: "system", before: nil)
        XCTAssertEqual(empty, FeedNotificationsResponse())
        try await api.markNotificationsRead(tab: "follows")
        try await api.deleteNotification(id: "n/1")
        try await api.muteNotifications(contentId: "c1", likesOnly: true)
        try await api.muteNotifications(contentId: "c1", likesOnly: false)
        let r = transport.requests
        XCTAssertEqual(r.map { $0.httpMethod }, ["GET", "POST", "DELETE", "PUT", "PUT"])
        XCTAssertEqual(r[0].url?.absoluteString, "https://feed.example.test/v1/feed/me/notifications?tab=system")
        XCTAssertEqual(r[1].url?.path, "/v1/feed/me/notifications/read")
        XCTAssertEqual(String(data: r[1].httpBody!, encoding: .utf8), #"{"tab":"follows"}"#)
        XCTAssertEqual(r[2].url?.absoluteString, "https://feed.example.test/v1/feed/me/notifications/n%2F1")
        XCTAssertEqual(r[3].url?.path, "/v1/feed/me/notification-mutes/c1")
        XCTAssertEqual(String(data: r[3].httpBody!, encoding: .utf8), #"{"likes_only":true}"#)
        XCTAssertEqual(String(data: r[4].httpBody!, encoding: .utf8), #"{"likes_only":false}"#, "false 也要发")
    }

    func testUnreadCountsPerTab() {
        let u = FeedUnreadCounts(interactions: 3, follows: 2, system: 1)
        XCTAssertEqual(u.of(tab: "interactions"), 3)
        XCTAssertEqual(u.of(tab: "follows"), 2)
        XCTAssertEqual(u.of(tab: "system"), 1)
        XCTAssertEqual(u.of(tab: "whatever"), 3)
        XCTAssertEqual(u.without(tab: "follows"), FeedUnreadCounts(interactions: 3, follows: 0, system: 1))
        XCTAssertEqual(u.without(tab: "system"), FeedUnreadCounts(interactions: 3, follows: 2, system: 0))
        XCTAssertEqual(u.without(tab: "interactions"), FeedUnreadCounts(interactions: 0, follows: 2, system: 1))
    }
}

private final class NotificationSource: FeedSource {
    var responses = [String: [String: FeedNotificationsResponse]]()   // tab → before ?? "" → response
    var listError: Error?
    var readError: Error?
    var deleteError: Error?
    var muteError: Error?
    var cardValue: FeedCard?
    var cardError: Error?
    var profiles = [String: FeedProfilePage]()
    var profileError: Error?
    var settings = FeedNotificationSettings()
    var settingsError: Error?
    var saveError: Error?
    let calls = CallLog<String>()

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func notifications(tab: String, before: String?) async throws -> FeedNotificationsResponse {
        calls.append("list \(tab) \(before ?? "-")")
        if let listError { throw listError }
        return responses[tab]?[before ?? ""] ?? FeedNotificationsResponse()
    }
    func markNotificationsRead(tab: String) async throws {
        calls.append("read \(tab)")
        if let readError { throw readError }
    }
    func deleteNotification(id: String) async throws {
        calls.append("delete \(id)")
        if let deleteError { throw deleteError }
    }
    func muteNotifications(contentId: String, likesOnly: Bool) async throws {
        calls.append("mute \(contentId) \(likesOnly)")
        if let muteError { throw muteError }
    }
    func card(contentId: String) async throws -> FeedCard? {
        calls.append("card \(contentId)")
        if let cardError { throw cardError }
        return cardValue
    }
    func profile(profileId: String) async throws -> FeedProfilePage? {
        calls.append("profile \(profileId)")
        if let profileError { throw profileError }
        return profiles[profileId]
    }
    func notificationSettings() async throws -> FeedNotificationSettings {
        calls.append("settings load")
        if let settingsError { throw settingsError }
        return settings
    }
    func saveNotificationSettings(_ settings: FeedNotificationSettings) async throws -> FeedNotificationSettings {
        calls.append("settings save \(settings.fromWhom) \(settings.likes) \(settings.comments) \(settings.follows)")
        if let saveError { throw saveError }
        return settings
    }
}

private func response(_ items: [FeedNotification], unread: FeedUnreadCounts = FeedUnreadCounts()) -> FeedNotificationsResponse {
    var r = FeedNotificationsResponse()
    r.notifications = items
    r.unread = unread
    return r
}

@MainActor
final class TellomiFeedNotificationsStoreTests: XCTestCase {
    private func started(_ source: NotificationSource, tab: String = "interactions") async -> FeedNotificationsStore {
        let store = FeedNotificationsStore(initialTab: tab, source: source)
        store.start()
        await store.waitForTasks()
        return store
    }

    func testFirstLoadMarksTheTabReadOnceAndClearsItsUnreadCount() async {
        let source = NotificationSource()
        source.responses["interactions"] = ["": response([n("1", "like", "a", "p", "2026-10-13T11:00:00Z", read: false)], unread: FeedUnreadCounts(interactions: 2, follows: 1, system: 0))]
        let store = await started(source)
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["1"])
        XCTAssertTrue(store.state.tab("interactions").loadedOnce)
        XCTAssertFalse(store.state.tab("interactions").loading)
        XCTAssertEqual(store.state.unread, FeedUnreadCounts(interactions: 0, follows: 1, system: 0))
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("read") }, ["read interactions"])

        store.refresh()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("read") }.count, 1, "不是第一次加载：不再标已读")
    }

    func testNoReadCallWhenNothingIsUnreadAndAReadFailureIsOnlyLogged() async {
        let quiet = NotificationSource()
        quiet.responses["interactions"] = ["": response([n("1", "like", "a", "p", "2026-10-13T11:00:00Z")])]
        _ = await started(quiet)
        XCTAssertEqual(quiet.calls.all.filter { $0.hasPrefix("read") }, [])

        let failing = NotificationSource()
        failing.readError = Boom()
        failing.responses["interactions"] = ["": response([n("1", "like", "a", "p", "2026-10-13T11:00:00Z", read: false)], unread: FeedUnreadCounts(interactions: 1))]
        let store = await started(failing)
        XCTAssertEqual(store.state.unread.interactions, 1, "标已读失败：数字留着")
        XCTAssertNil(store.state.notice)
    }

    func testPagingUsesTheLastCreatedAtAndStopsOnAShortPage() async {
        let source = NotificationSource()
        let full = (0..<30).map { n("n\($0)", "follow", "a", nil, String(format: "2026-10-13T10:%02d:00Z", 59 - $0)) }
        source.responses["interactions"] = [
            "": response(full),
            full.last!.createdAt: response([full.last!, n("tail", "follow", "b", nil, "2026-10-12T00:00:00Z")]),
        ]
        let store = await started(source)
        XCTAssertTrue(store.state.tab("interactions").hasMore)
        store.loadMore()
        store.loadMore()   // 在途不重复
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").items.count, 31, "重复的那条不加两次")
        XCTAssertEqual(store.state.tab("interactions").items.last?.id, "tail")
        XCTAssertFalse(store.state.tab("interactions").hasMore, "不满一页就到底")
        store.loadMore()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("list") }.count, 2)
    }

    func testFailureThenSelectingATabLoadsItOnlyOnce() async {
        let source = NotificationSource()
        source.listError = Boom()
        let store = await started(source)
        XCTAssertTrue(store.state.tab("interactions").failed)
        XCTAssertFalse(store.state.tab("interactions").loading)
        XCTAssertFalse(store.state.tab("interactions").loadedOnce)

        source.listError = nil
        source.responses["follows"] = ["": response([n("f", "follow", "a", nil, "2026-10-13T11:00:00Z")])]
        store.selectTab("follows")
        store.selectTab("follows")
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0 == "list follows -" }.count, 1)
        store.selectTab("follows")
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0 == "list follows -" }.count, 1, "加载过的栏不再自动加载")
        XCTAssertEqual(store.state.selectedTab, "follows")
    }

    func testActorsAreLookedUpOnceAndEmbeddedOnesAreUsed() async {
        let source = NotificationSource()
        var ann = FeedProfilePage(id: "a", displayName: "Ann")
        ann.handle = "ann"
        source.profiles = ["a": ann, "p9": FeedProfilePage(id: "p9", displayName: "Pat")]
        let embedded = FeedPersonSummary(id: "e", handle: nil, displayName: "Eve", avatarKey: nil)
        var withActor = n("3", "follow", "e", nil, "2026-10-13T09:00:00Z")
        withActor.actor = embedded
        source.responses["interactions"] = ["": response([
            n("1", "like", "a", "p", "2026-10-13T11:00:00Z"),
            n("2", "comment", "a", "p", "2026-10-13T10:00:00Z"),
            withActor,
            n("4", "system", nil, nil, "2026-10-13T08:00:00Z", detail: FeedNotificationDetail(type: "close_person_request", profileId: "p9")),
        ])]
        let store = await started(source)
        XCTAssertEqual(store.state.people["a"], FeedPersonSummary(id: "a", handle: "ann", displayName: "Ann", avatarKey: nil))
        XCTAssertEqual(store.state.people["e"], embedded)
        XCTAssertEqual(store.state.people["p9"]?.displayName, "Pat")
        XCTAssertEqual(Set(source.calls.all.filter { $0.hasPrefix("profile") }), ["profile a", "profile p9"], "同一个人只查一次，带了 actor 的不查")
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("profile") }.count, 2)

        store.refresh()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("profile") }.count, 2, "刷新也不重复查")
    }

    func testAFailedLookupIsRetriedNextTimeButAMissingProfileIsNot() async {
        let source = NotificationSource()
        source.profileError = Boom()
        source.responses["interactions"] = ["": response([n("1", "follow", "a", nil, "2026-10-13T11:00:00Z"), n("2", "follow", "gone", nil, "2026-10-13T10:00:00Z")])]
        let store = await started(source)
        XCTAssertEqual(store.state.people, [:])
        source.profileError = nil
        source.profiles = ["a": FeedProfilePage(id: "a", displayName: "Ann")]
        store.refresh()
        await store.waitForTasks()
        XCTAssertEqual(store.state.people["a"]?.displayName, "Ann", "上次失败的下次再查")
        XCTAssertNil(store.state.people["gone"])
        store.refresh()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0 == "profile gone" }.count, 2, "失败过的 gone 重试一次后查到 nil，之后不再查")
    }

    func testDeleteRemovesAllMergedIdsAndRestoresOnFailure() async {
        let source = NotificationSource()
        let items = [n("1", "like", "a", "p", "2026-10-13T11:00:00Z"), n("2", "like", "b", "p", "2026-10-13T10:00:00Z"), n("3", "follow", "c", nil, "2026-10-13T09:00:00Z")]
        source.responses["interactions"] = ["": response(items)]
        let store = await started(source)
        let row = FeedNotificationGrouping.group(store.state.tab("interactions").items, now: now, calendar: utc)[0].rows[0]
        XCTAssertEqual(row.ids, ["1", "2"])
        store.delete(row)
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["3"])
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .deleted)
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("delete") }, ["delete 1", "delete 2"])

        source.deleteError = Boom()
        let last = FeedNotificationGrouping.group(store.state.tab("interactions").items, now: now, calendar: utc)[0].rows[0]
        store.delete(last)
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["3"])
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testMuteRemovesThePostsRowsAndLikesOnlyKeepsTheComments() async {
        let source = NotificationSource()
        let items = [n("1", "like", "a", "p", "2026-10-13T11:00:00Z"), n("2", "comment", "b", "p", "2026-10-13T10:00:00Z"), n("3", "like", "c", "q", "2026-10-13T09:00:00Z")]
        source.responses["interactions"] = ["": response(items)]
        let store = await started(source)
        let row = FeedNotificationGrouping.group(store.state.tab("interactions").items, now: now, calendar: utc)[0].rows[0]
        store.mute(row, likesOnly: true)
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["2", "3"])
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .mutedLikes)
        store.onNoticeShown()

        let comment = FeedNotificationGrouping.group(store.state.tab("interactions").items, now: now, calendar: utc)[0].rows[0]
        store.mute(comment, likesOnly: false)
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["3"])
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .muted)

        source.muteError = Boom()
        let remaining = FeedNotificationGrouping.group(store.state.tab("interactions").items, now: now, calendar: utc)[0].rows[0]
        store.mute(remaining, likesOnly: false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["3"])
        XCTAssertEqual(store.state.notice, .failed)

        let noContent = FeedNotificationRow(key: "x", kind: "follow", ids: ["x"], actorIds: [], contentId: nil, subjectId: nil, systemType: nil, held: false, profileId: nil, createdAt: now, unread: false)
        store.mute(noContent, likesOnly: false)
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("mute") }.count, 3, "没有 contentId 的不发")
    }

    func testOpenPostGivesTheCardOrAGoneNoticeOrAFailure() async {
        let source = NotificationSource()
        let store = await started(source)
        source.cardValue = FeedCard(id: "p", kind: "post")
        store.openPost("p")
        await store.waitForTasks()
        XCTAssertEqual(store.state.openCard?.id, "p")
        store.onCardOpened()
        XCTAssertNil(store.state.openCard)

        source.cardValue = nil
        store.openPost("p")
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .postGone)
        store.onNoticeShown()
        source.cardError = Boom()
        store.openPost("p")
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .failed)
        XCTAssertNil(store.state.openCard)
    }
}

@MainActor
final class TellomiFeedNotificationSettingsStoreTests: XCTestCase {
    private func loaded(_ source: NotificationSource) async -> FeedNotificationSettingsStore {
        let store = FeedNotificationSettingsStore(source: source)
        store.load()
        await store.waitForTasks()
        return store
    }

    func testLoadOnlyOnceAndFailureCanBeRetried() async {
        let source = NotificationSource()
        source.settings = FeedNotificationSettings(fromWhom: "friends", likes: false, comments: true, follows: true)
        let store = await loaded(source)
        XCTAssertEqual(store.state.settings?.fromWhom, "friends")
        store.load()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0 == "settings load" }.count, 1)

        let failing = NotificationSource()
        failing.settingsError = Boom()
        let second = await loaded(failing)
        XCTAssertTrue(second.state.loadFailed)
        XCTAssertNil(second.state.settings)
        failing.settingsError = nil
        second.load()
        await second.waitForTasks()
        XCTAssertNotNil(second.state.settings)
        XCTAssertFalse(second.state.loadFailed)
    }

    func testChangesAreOptimisticSentWholeAndNoOpsAreSkipped() async {
        let source = NotificationSource()
        let store = await loaded(source)
        store.setLikes(false)
        XCTAssertEqual(store.state.settings?.likes, false)
        await store.waitForTasks()
        store.setLikes(false)   // 没变
        store.setFromWhom("bogus")
        await store.waitForTasks()
        store.setFromWhom("following")
        store.setComments(false)
        store.setFollows(false)
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("settings save") }, [
            "settings save everyone false true true",
            "settings save following false true true",
            "settings save following false false true",
            "settings save following false false false",
        ])
        XCTAssertTrue(store.state.categoriesEnabled)
        store.setFromWhom("none")
        XCTAssertFalse(store.state.categoriesEnabled, "都不接收：三个开关变灰")
        await store.waitForTasks()
    }

    func testFailureRollsBackOnlyIfNothingChangedMeanwhileAndProfileRequiredIsTold() async {
        let source = NotificationSource()
        let store = await loaded(source)
        source.saveError = FeedAPIError(status: 409, code: "profile_required", retryAfterSeconds: nil)
        store.setLikes(false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.settings?.likes, true)
        XCTAssertEqual(store.state.notice, .profileRequired)
        store.onNoticeShown()

        source.saveError = Boom()
        store.setComments(false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.settings?.comments, true)
        XCTAssertEqual(store.state.notice, .saveFailed)
    }

    func testNoSettingsMeansNothingToChange() {
        let store = FeedNotificationSettingsStore(source: NotificationSource())
        store.setLikes(false)
        XCTAssertNil(store.state.settings)
        XCTAssertFalse(store.state.categoriesEnabled)
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
