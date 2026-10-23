//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedCardActionsTests.swift (new file)
// I-3: post-level API calls (wire shape), poll presentation, own-post actions, media URL, share text, the save flow,
// and the FeedStore actions (repost / vote / save / settings / insights). Mirrors the Android tests
// FeedPollViewTest (percent), FeedRepostTest, FeedSaveTest, FeedOwnPostTest, FeedMediaUrlTest, FeedPostCardTest (share).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

// MARK: - transport

private final class ScriptedTransport: FeedHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script = [(Int, String)]()
    private var _requests = [URLRequest]()

    func enqueue(_ status: Int, _ body: String = "") {
        lock.lock(); script.append((status, body)); lock.unlock()
    }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    private func next(_ request: URLRequest) -> (Int, String) {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        return script.isEmpty ? (500, "") : script.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = next(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }
}

private struct FixedTokens: FeedTokenSource {
    func token(forceRefresh: Bool) async throws -> String { "t" }
}

private func bodyString(_ request: URLRequest) -> String {
    return request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

// MARK: - API wire shape

final class TellomiFeedPostsApiTests: XCTestCase {
    private func make() -> (FeedAPI, ScriptedTransport) {
        let transport = ScriptedTransport()
        return (FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens()), transport)
    }

    func testRepostIsPutAndUndoIsDelete() async throws {
        let (api, transport) = make()
        transport.enqueue(204); transport.enqueue(204)
        try await api.setRepost(contentId: "p1", on: true)
        try await api.setRepost(contentId: "p1", on: false)
        let requests = transport.requests
        XCTAssertEqual(requests.map { $0.httpMethod }, ["PUT", "DELETE"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/feed/posts/p1/repost", "/v1/feed/posts/p1/repost"])
        XCTAssertNil(requests[0].httpBody)
    }

    func testVoteSendsOptionsAndReadsTheCounts() async throws {
        let (api, transport) = make()
        transport.enqueue(200, #"{"counts":[3,0,5],"voted":[0,2]}"#)
        let state = try await api.vote(contentId: "p1", options: [0, 2])
        XCTAssertEqual(state, FeedPollState(counts: [3, 0, 5], voted: [0, 2]))
        let request = transport.requests[0]
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/v1/feed/posts/p1/vote")
        XCTAssertEqual(bodyString(request), #"{"options":[0,2]}"#)
    }

    func testSettingsPatchSendsOnlyTheChangedField() async throws {
        let (api, transport) = make()
        transport.enqueue(204); transport.enqueue(204); transport.enqueue(204)
        try await api.updatePostSettings(contentId: "p1", update: FeedPostSettingsUpdate(pinned: true))
        try await api.updatePostSettings(contentId: "p1", update: FeedPostSettingsUpdate(likeCountHidden: false))
        try await api.updatePostSettings(contentId: "p1", update: FeedPostSettingsUpdate(replyPolicy: "followers", commentsClosed: false, replyModeration: true, voiceComments: false))
        let requests = transport.requests
        XCTAssertEqual(requests.map { $0.httpMethod }, ["PATCH", "PATCH", "PATCH"])
        XCTAssertEqual(requests[0].url?.path, "/v1/feed/posts/p1/settings")
        XCTAssertEqual(bodyString(requests[0]), #"{"pinned":true}"#)
        XCTAssertEqual(bodyString(requests[1]), #"{"like_count_hidden":false}"#)
        XCTAssertEqual(bodyString(requests[2]), #"{"comments_closed":false,"reply_moderation":true,"reply_policy":"followers","voice_comments":false}"#)
    }

    func testSettingsAndInsightsAreReadWithAndroidDefaults() async throws {
        let (api, transport) = make()
        transport.enqueue(200, "{}")
        transport.enqueue(200, #"{"pinned":true,"like_count_hidden":true,"reply_policy":"mutual","comments_closed":true,"reply_moderation":true,"voice_comments":false}"#)
        transport.enqueue(200, #"{"opens":40,"likes":9,"comments":3,"reposts":2,"saves":1}"#)
        transport.enqueue(200, "{}")

        let empty = try await api.postSettings(contentId: "p1")
        XCTAssertEqual(empty, FeedPostSettings(), "缺字段按 Android 的默认值：回复所有人、语音评论开")
        XCTAssertEqual(empty.replyPolicy, "everyone")
        XCTAssertTrue(empty.voiceComments)

        let set = try await api.postSettings(contentId: "p1")
        XCTAssertTrue(set.pinned && set.likeCountHidden && set.commentsClosed && set.replyModeration)
        XCTAssertEqual(set.replyPolicy, "mutual")
        XCTAssertFalse(set.voiceComments)

        let insights = try await api.postInsights(contentId: "p1")
        XCTAssertEqual(insights, FeedPostInsights(opens: 40, likes: 9, comments: 3, reposts: 2, saves: 1))
        let blank = try await api.postInsights(contentId: "p1")
        XCTAssertEqual(blank, FeedPostInsights())
        XCTAssertEqual(transport.requests.map { $0.url?.path }, [
            "/v1/feed/posts/p1/settings", "/v1/feed/posts/p1/settings", "/v1/feed/posts/p1/insights", "/v1/feed/posts/p1/insights",
        ])
        XCTAssertTrue(transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testDeleteAndThePinLimitError() async throws {
        let (api, transport) = make()
        transport.enqueue(204)
        transport.enqueue(409, #"{"error":"too_many_pinned"}"#)
        try await api.deletePost(contentId: "p1")
        XCTAssertEqual(transport.requests[0].httpMethod, "DELETE")
        XCTAssertEqual(transport.requests[0].url?.path, "/v1/feed/posts/p1")
        do {
            try await api.updatePostSettings(contentId: "p1", update: FeedPostSettingsUpdate(pinned: true))
            XCTFail("expected 409")
        } catch {
            XCTAssertEqual(error as? FeedAPIError, FeedAPIError(status: 409, code: "too_many_pinned", retryAfterSeconds: nil))
            XCTAssertTrue(FeedOwnPostAction.isPinLimit(error))
            XCTAssertFalse(FeedOwnPostAction.isPinLimit(FeedAPIError(status: 409, code: "not_editable", retryAfterSeconds: nil)))
            XCTAssertFalse(FeedOwnPostAction.isPinLimit(URLError(.notConnectedToInternet)))
        }
    }
}

// MARK: - pure logic

final class TellomiFeedCardLogicTests: XCTestCase {
    private let now = FeedDates.parse("2026-10-13T08:00:00Z")!

    private func poll(multi: Bool = false, closesInSeconds: TimeInterval? = 2 * 86_400) -> FeedPoll {
        let closes = closesInSeconds.map { FeedDates.format(now.addingTimeInterval($0)) }
        let json = #"{"options":["Hiking","The park","Sleeping in"],"multi":\#(multi)\#(closes.map { #","closes_at":"\#($0)""# } ?? "")}"#
        return try! JSONDecoder().decode(FeedPoll.self, from: Data(json.utf8))
    }

    func testPercentRoundsAndSurvivesNoVotes() {
        XCTAssertEqual(FeedPollPresentation.percent(1, of: 3), 33)
        XCTAssertEqual(FeedPollPresentation.percent(2, of: 3), 67)
        XCTAssertEqual(FeedPollPresentation.percent(0, of: 0), 0)
        XCTAssertEqual(FeedPollPresentation.percent(1, of: 8), 13, "12.5 向上")
        XCTAssertEqual(FeedPollPresentation.percent(5, of: 5), 100)
    }

    func testOpenPollIsVotableAndShowsTimeLeft() {
        let presentation = FeedPollPresentation(poll: poll(), state: nil, interactive: true, now: now)
        XCTAssertTrue(presentation.canVote)
        XCTAssertFalse(presentation.showResults)
        XCTAssertTrue(presentation.showVotes)
        XCTAssertEqual(presentation.remaining, .days(2))
        XCTAssertEqual(presentation.fractions, [0, 0, 0])
    }

    func testVotedPollShowsResultsAndMyChoice() {
        let state = FeedPollState(counts: [1, 0, 3], voted: [2])
        let presentation = FeedPollPresentation(poll: poll(), state: state, interactive: true, now: now)
        XCTAssertFalse(presentation.canVote, "投了不能改")
        XCTAssertTrue(presentation.showResults)
        XCTAssertEqual(presentation.total, 4)
        XCTAssertEqual(presentation.percents, [25, 0, 75])
        XCTAssertEqual(presentation.fractions, [0.25, 0, 0.75])
        XCTAssertEqual(presentation.mine, [false, false, true])
    }

    func testClosedPollShowsFinalResultsEvenWithoutAVote() {
        let state = FeedPollState(counts: [2, 2, 0], voted: [])
        let presentation = FeedPollPresentation(poll: poll(closesInSeconds: -60), state: state, interactive: true, now: now)
        XCTAssertTrue(presentation.showResults)
        XCTAssertFalse(presentation.canVote)
        XCTAssertEqual(presentation.remaining, .closed)
        XCTAssertEqual(presentation.percents, [50, 50, 0])
        // 恰好到点也算截止（Android `closesAt <= now`）
        XCTAssertEqual(FeedPollPresentation(poll: poll(closesInSeconds: 0), state: nil, interactive: true, now: now).remaining, .closed)
    }

    func testReadOnlyPollDoesNotShowVotesBeforeVoting() {
        let presentation = FeedPollPresentation(poll: poll(), state: FeedPollState(counts: [4, 4, 4], voted: []), interactive: false, now: now)
        XCTAssertFalse(presentation.canVote)
        XCTAssertFalse(presentation.showResults, "没投过也没截止：不显示结果")
        XCTAssertFalse(presentation.showVotes)
        XCTAssertEqual(presentation.fractions, [0, 0, 0])
        // …但投过了就能看
        XCTAssertTrue(FeedPollPresentation(poll: poll(), state: FeedPollState(counts: [4, 4, 4], voted: [1]), interactive: false, now: now).showResults)
    }

    func testRemainingBoundaries() {
        func left(_ seconds: TimeInterval) -> FeedPollPresentation.Remaining {
            return FeedPollPresentation.remaining(until: now.addingTimeInterval(seconds), now: now)
        }
        XCTAssertEqual(left(0.0004), .closed, "不足 1 毫秒当到点（Android 用整数毫秒）")
        XCTAssertEqual(left(0.4), .minutes(1), "还剩不到 1 分钟：至少写 1 分钟")
        XCTAssertEqual(left(1), .minutes(1))
        XCTAssertEqual(left(59 * 60 + 59), .minutes(59))
        XCTAssertEqual(left(3600), .hours(1))
        XCTAssertEqual(left(86_400 - 1), .hours(23))
        XCTAssertEqual(left(86_400), .days(1))
        XCTAssertEqual(left(3 * 86_400 + 7200), .days(3))
    }

    func testMultiChoiceVotesOnlyAfterSubmit() {
        var selection = FeedPollSelection()
        XCTAssertNil(selection.tap(2, multi: true))
        XCTAssertNil(selection.tap(0, multi: true))
        XCTAssertTrue(selection.canSubmit)
        XCTAssertEqual(selection.submission, [0, 2], "按下标升序")
        XCTAssertNil(selection.tap(2, multi: true))
        XCTAssertEqual(selection.submission, [0])
        XCTAssertNil(selection.tap(0, multi: true))
        XCTAssertFalse(selection.canSubmit)

        var single = FeedPollSelection()
        XCTAssertEqual(single.tap(1, multi: false), [1], "单选点一下就投")
        XCTAssertFalse(single.canSubmit)
    }

    func testOwnPostActionsOnlyOnMyPostsAndEachOneFlips() {
        var mine = FeedCard(id: "p", viewer: FeedViewer(isAuthor: true))
        XCTAssertEqual(FeedOwnPostAction.available(for: mine), [.pin, .replySettings, .hideLikes, .insights])
        mine.pinned = true
        mine.stats.likeCountHidden = true
        XCTAssertEqual(FeedOwnPostAction.available(for: mine), [.unpin, .replySettings, .showLikes, .insights])
        XCTAssertEqual(FeedOwnPostAction.available(for: FeedCard(id: "x")), [], "别人的帖子没有")
        XCTAssertEqual(FeedOwnPostAction.available(for: FeedCard(id: "c", kind: FeedCard.kindComment, viewer: FeedViewer(isAuthor: true))), [], "评论没有")

        XCTAssertEqual(FeedOwnPostAction.pin.settingsUpdate, FeedPostSettingsUpdate(pinned: true))
        XCTAssertEqual(FeedOwnPostAction.showLikes.settingsUpdate, FeedPostSettingsUpdate(likeCountHidden: false))
        XCTAssertNil(FeedOwnPostAction.insights.settingsUpdate)
        XCTAssertNil(FeedOwnPostAction.replySettings.settingsUpdate)
    }

    func testCardTransformsTouchOnlyWhatTheyShould() {
        let card = FeedCard(id: "p", stats: FeedStats(likes: 5, comments: 2, reposts: 0))
        let reposted = card.withReposted(true)
        XCTAssertTrue(reposted.viewer.reposted)
        XCTAssertEqual(reposted.stats.reposts, 1)
        XCTAssertEqual(reposted.stats.likes, 5)
        XCTAssertEqual(reposted.withReposted(true), reposted, "已经是了就不再加")
        XCTAssertEqual(reposted.withReposted(false).stats.reposts, 0)
        XCTAssertEqual(card.withReposted(false).stats.reposts, 0, "不会减到负数")

        XCTAssertTrue(card.withSaved(true).viewer.saved)
        let voted = card.withPollState(FeedPollState(counts: [1], voted: [0]))
        XCTAssertEqual(voted.pollState?.voted, [0])

        let set = card.withSettings(FeedPostSettingsUpdate(pinned: true))
        XCTAssertTrue(set.pinned)
        XCTAssertFalse(set.stats.likeCountHidden)
        let hidden = set.withSettings(FeedPostSettingsUpdate(likeCountHidden: true))
        XCTAssertTrue(hidden.pinned, "没带的字段不动")
        XCTAssertTrue(hidden.stats.likeCountHidden)
    }

    func testMediaKeyIsAppendedToTheHttpsBaseOnly() {
        let base = "https://media.example/feed/"
        XCTAssertEqual(FeedMedia(key: "p/abc.jpg").remoteURLString(mediaBaseURL: base), "https://media.example/feed/p/abc.jpg")
        XCTAssertNil(FeedMedia(key: "p/abc.jpg").remoteURLString(mediaBaseURL: nil))
        XCTAssertNil(FeedMedia(key: "p/abc.jpg").remoteURLString(mediaBaseURL: "http://media.example/"))
        XCTAssertNil(FeedMedia(key: "p/abc.jpg").remoteURLString(mediaBaseURL: "https://media.example"), "基址要以 / 结尾")
        for key in ["", "  ", "https://evil.example/x.jpg", "/etc/x.jpg", "../x.jpg", "p/../../x.jpg"] {
            XCTAssertNil(FeedMedia(key: key).remoteURLString(mediaBaseURL: base), "key: \(key)")
        }
        XCTAssertNotNil(FeedMedia(key: "p/..a/b.jpg").remoteURLString(mediaBaseURL: base), "..a 不是 .. 这一段")
    }

    func testPostLinkIsLowercasedAndTheSavedMessageReadsAsAuthorSnippetLink() {
        XCTAssertEqual(FeedShare.postLink(contentId: "0A1B2C3D-0000-4000-8000-000000000001"), "https://tell.cc/m#0a1b2c3d-0000-4000-8000-000000000001")

        let link = "https://tell.cc/m#abc"
        var card = FeedCard(id: "abc", author: FeedAuthor(profileId: "u", displayName: " 山风 "), text: "  今天\n去爬山  ")
        XCTAssertEqual(FeedShare.savedMessageBody(for: card, link: link), "山风：今天 去爬山\n\(link)")
        card.title = "长文标题"
        XCTAssertEqual(FeedShare.savedMessageBody(for: card, link: link), "山风：长文标题\n\(link)", "有标题用标题")
        card.title = "   "
        XCTAssertEqual(FeedShare.savedMessageBody(for: card, link: link), "山风：今天 去爬山\n\(link)", "空白标题不算")
        card.author = nil
        XCTAssertEqual(FeedShare.savedMessageBody(for: card, link: link), "今天 去爬山\n\(link)")
        card.text = nil
        card.title = nil
        XCTAssertEqual(FeedShare.savedMessageBody(for: card, link: link), link)

        card.text = String(repeating: "字", count: 61)
        XCTAssertEqual(FeedShare.savedMessageBody(for: card, link: link), String(repeating: "字", count: 60) + "…\n\(link)")
        card.text = String(repeating: "字", count: 60)
        XCTAssertEqual(FeedShare.savedMessageBody(for: card, link: link), String(repeating: "字", count: 60) + "\n\(link)", "正好 60 不截")
        card.text = String(repeating: "😀", count: 61)
        XCTAssertEqual(FeedShare.savedMessageBody(for: card, link: link), String(repeating: "😀", count: 60) + "…\n\(link)", "按字符截，不劈开 emoji")
    }
}

// MARK: - save flow + FeedStore actions

private struct Boom: Error {}

/// 测试替身的方法在 `FeedStore` 的任务里并发地跑（不在主线程上），记录要加锁。
private final class CallLog<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [T]()
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}


private actor Gate {
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class FakeSavedMessages: FeedSavedMessages {
    var fail = false
    private let logged = CallLog<String>()
    var log: [String] { logged.all }
    func add(_ card: FeedCard) async throws {
        logged.append("add \(card.id)")
        if fail { throw Boom() }
    }
    func remove(contentId: String) async throws {
        logged.append("remove \(contentId)")
        if fail { throw Boom() }
    }
}

private final class CardActionSource: FeedSource {
    var cards = [FeedCard]()
    var failing = Set<String>()
    var gate: Gate?
    var pinLimit = false
    private let callLog = CallLog<String>()
    var calls: [String] { callLog.all }

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage(cards: cards, nextCursor: nil) }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    private func record(_ name: String) async throws {
        callLog.append(name)
        if let gate { await gate.wait() }
        if failing.contains(name.split(separator: " ").first.map(String.init) ?? name) { throw Boom() }
    }

    func setSaved(contentId: String, saved: Bool) async throws { try await record("setSaved \(contentId) \(saved)") }
    func setReposted(contentId: String, reposted: Bool) async throws { try await record("setReposted \(contentId) \(reposted)") }
    func vote(contentId: String, options: [Int]) async throws -> FeedPollState {
        try await record("vote \(contentId) \(options)")
        return FeedPollState(counts: [options.count, 9], voted: options)
    }
    func updatePostSettings(contentId: String, update: FeedPostSettingsUpdate) async throws {
        try await record("settings \(contentId) \(update.pinned.map(String.init(describing:)) ?? "-") \(update.likeCountHidden.map(String.init(describing:)) ?? "-")")
        if pinLimit { throw FeedAPIError(status: 409, code: "too_many_pinned", retryAfterSeconds: nil) }
    }
    func postInsights(contentId: String) async throws -> FeedPostInsights {
        try await record("insights \(contentId)")
        return FeedPostInsights(opens: 40, likes: 9, comments: 3, reposts: 2, saves: 1)
    }
}

@MainActor
final class TellomiFeedCardActionsStoreTests: XCTestCase {
    private func loaded(_ source: CardActionSource, savedMessages: FeedSavedMessages? = nil) async -> FeedStore {
        let store = FeedStore(source: source, savedMessages: savedMessages)
        store.onTabShown(.following)
        await store.waitForLoad(.following)
        return store
    }

    private func card(_ store: FeedStore) -> FeedCard {
        return store.tab(.following).cards[0]
    }

    // MARK: save

    func testSaveStoresInSavedMessagesThenReportsAndUnsaveTakesItOut() async throws {
        let source = CardActionSource()
        source.cards = [FeedCard(id: "p", viewer: FeedViewer())]
        let saved = FakeSavedMessages()
        let store = await loaded(source, savedMessages: saved)
        var notices = [FeedStore.Notice]()
        store.onNotice = { notices.append($0) }
        store.toggleSave(self.card(store))
        XCTAssertTrue(self.card(store).viewer.saved, "先改界面")
        await store.waitForActions()
        XCTAssertEqual(saved.log, ["add p"])
        XCTAssertEqual(source.calls, ["setSaved p true"])
        XCTAssertEqual(notices, [.saved])

        store.toggleSave(self.card(store))
        await store.waitForActions()
        XCTAssertEqual(saved.log, ["add p", "remove p"])
        XCTAssertEqual(source.calls, ["setSaved p true", "setSaved p false"])
        let finalSaved = self.card(store).viewer.saved
        XCTAssertFalse(finalSaved)
    }

    func testIfSavedMessagesFailsItTurnsBackButAFailedReportDoesNot() async throws {
        let source = CardActionSource()
        source.cards = [FeedCard(id: "p")]
        let saved = FakeSavedMessages()
        let store = await loaded(source, savedMessages: saved)
        var errors = [FeedStore.TransientError]()
        store.onTransientError = { errors.append($0) }

        saved.fail = true
        store.toggleSave(self.card(store))
        await store.waitForActions()
        var isSaved = self.card(store).viewer.saved
        XCTAssertFalse(isSaved, "存不进「我的收藏」就改回来")
        XCTAssertEqual(source.calls, [], "没存成就不上报")
        XCTAssertEqual(errors, [.actionFailed])

        saved.fail = false
        source.failing = ["setSaved"]
        store.toggleSave(self.card(store))
        await store.waitForActions()
        isSaved = self.card(store).viewer.saved
        XCTAssertTrue(isSaved, "上报失败不影响收藏本身")
        XCTAssertEqual(errors, [.actionFailed])
    }

    func testWithoutASavedMessagesImplementationSavingTurnsBack() async throws {
        let source = CardActionSource()
        source.cards = [FeedCard(id: "p")]
        let store = await loaded(source)
        store.toggleSave(self.card(store))
        await store.waitForActions()
        let isSaved = self.card(store).viewer.saved
        XCTAssertFalse(isSaved)
        XCTAssertEqual(source.calls, [])
    }

    func testSaveFlowOrderAndReportFailureCallback() async throws {
        let source = CardActionSource()
        source.failing = ["setSaved"]
        let saved = FakeSavedMessages()
        var reported = [Error]()
        try await FeedSaveFlow.setSaved(FeedCard(id: "p"), saved: true, savedMessages: saved, source: source) { reported.append($0) }
        XCTAssertEqual(saved.log, ["add p"])
        XCTAssertEqual(reported.count, 1)

        saved.fail = true
        do {
            try await FeedSaveFlow.setSaved(FeedCard(id: "p"), saved: false, savedMessages: saved, source: source)
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    // MARK: repost

    func testRepostIsOptimisticTwiceSendsOnceAndTurnsBackOnFailure() async throws {
        let source = CardActionSource()
        source.cards = [FeedCard(id: "p", stats: FeedStats(likes: 0, comments: 0, reposts: 4))]
        let gate = Gate()
        source.gate = gate
        let store = await loaded(source)
        var notices = [FeedStore.Notice]()
        var errors = [FeedStore.TransientError]()
        store.onNotice = { notices.append($0) }
        store.onTransientError = { errors.append($0) }
        let original = self.card(store)
        store.toggleRepost(original)
        XCTAssertTrue(self.card(store).viewer.reposted)
        XCTAssertEqual(self.card(store).stats.reposts, 5)
        store.toggleRepost(original)   // 连点：在途时不再发
        await gate.release()
        await store.waitForActions()
        XCTAssertEqual(source.calls, ["setReposted p true"])
        XCTAssertEqual(notices, [.reposted])

        source.failing = ["setReposted"]
        store.toggleRepost(self.card(store))   // 取消转发，失败
        await store.waitForActions()
        let after = self.card(store)
        XCTAssertTrue(after.viewer.reposted, "失败改回来")
        XCTAssertEqual(after.stats.reposts, 5)
        XCTAssertEqual(errors, [.actionFailed])
        XCTAssertEqual(notices, [.reposted], "取消转发和失败都不提示「已转发」")
    }

    // MARK: vote

    func testVoteIsNotOptimisticAndTheServerCountsReplaceTheState() async throws {
        let source = CardActionSource()
        source.cards = [FeedCard(id: "p")]
        let gate = Gate()
        source.gate = gate
        let store = await loaded(source)
        let original = self.card(store)
        store.vote(original, options: [])        // 空的不发
        store.vote(original, options: [1, 2])
        store.vote(original, options: [0])        // 在途时不再发
        XCTAssertNil(self.card(store).pollState, "投票不能撤回，不先改界面")
        await gate.release()
        await store.waitForActions()
        XCTAssertEqual(source.calls, ["vote p [1, 2]"])
        let state = self.card(store).pollState
        XCTAssertEqual(state, FeedPollState(counts: [2, 9], voted: [1, 2]))
    }

    func testAFailedVoteLeavesTheCardAndSaysSo() async throws {
        let source = CardActionSource()
        source.cards = [FeedCard(id: "p")]
        source.failing = ["vote"]
        let store = await loaded(source)
        var errors = [FeedStore.TransientError]()
        store.onTransientError = { errors.append($0) }
        store.vote(self.card(store), options: [0])
        await store.waitForActions()
        let state = self.card(store).pollState
        XCTAssertNil(state)
        XCTAssertEqual(errors, [.actionFailed])
        // 失败后这一条可以再投
        source.failing = []
        store.vote(self.card(store), options: [0])
        await store.waitForActions()
        XCTAssertEqual(source.calls.count, 2)
    }

    // MARK: own post

    func testPinAndHideLikesChangeTheCardFirstAndSendOnlyThatField() async throws {
        let source = CardActionSource()
        source.cards = [FeedCard(id: "p", viewer: FeedViewer(isAuthor: true))]
        let store = await loaded(source)
        store.onOwnPostAction(self.card(store), .pin)
        XCTAssertTrue(self.card(store).pinned)
        store.onOwnPostAction(self.card(store), .hideLikes)
        XCTAssertTrue(self.card(store).stats.likeCountHidden)
        store.onOwnPostAction(self.card(store), .replySettings)   // 卡片自己处理，这里什么都不做
        await store.waitForActions()
        XCTAssertEqual(source.calls.sorted(), ["settings p - true", "settings p true -"], "两个设置各发各的字段（并发，顺序不定）")
    }

    func testAFourthPinIsTurnedBackAndSaysTheLimit() async throws {
        let source = CardActionSource()
        source.cards = [FeedCard(id: "p", viewer: FeedViewer(isAuthor: true))]
        source.pinLimit = true
        let store = await loaded(source)
        var notices = [FeedStore.Notice]()
        var errors = [FeedStore.TransientError]()
        store.onNotice = { notices.append($0) }
        store.onTransientError = { errors.append($0) }
        store.onOwnPostAction(self.card(store), .pin)
        await store.waitForActions()
        let pinned = self.card(store).pinned
        XCTAssertFalse(pinned)
        XCTAssertEqual(notices, [.pinLimit])
        XCTAssertEqual(errors, [], "置顶满了单独说，不再说「操作失败」")

        source.pinLimit = false
        source.failing = ["settings"]
        store.onOwnPostAction(self.card(store), .hideLikes)
        await store.waitForActions()
        XCTAssertEqual(errors, [.actionFailed])
        let hidden = self.card(store).stats.likeCountHidden
        XCTAssertFalse(hidden)
    }

    func testInsightsLoadIntoTheDialogAndClosingItWhileLoadingKeepsItClosed() async throws {
        let source = CardActionSource()
        source.cards = [FeedCard(id: "p", viewer: FeedViewer(isAuthor: true))]
        let store = await loaded(source)
        store.onOwnPostAction(self.card(store), .insights)
        await store.waitForActions()
        var insights = store.insights
        XCTAssertEqual(insights, .ready(FeedPostInsights(opens: 40, likes: 9, comments: 3, reposts: 2, saves: 1)))
        store.onInsightsDismissed()

        let gate = Gate()
        source.gate = gate
        store.onOwnPostAction(self.card(store), .insights)
        insights = store.insights
        XCTAssertEqual(insights, .loading)
        store.onInsightsDismissed()
        await gate.release()
        await store.waitForActions()
        insights = store.insights
        XCTAssertNil(insights, "等的时候关掉了弹窗就不再弹")

        source.gate = nil
        source.failing = ["insights"]
        store.onOwnPostAction(self.card(store), .insights)
        await store.waitForActions()
        insights = store.insights
        XCTAssertEqual(insights, .failed)
    }

    func testSourcesWithoutTheNewMethodsDegradeToFeedNotAvailable() async throws {
        final class Bare: FeedSource {
            func config() async throws -> FeedConfig { FeedConfig() }
            func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
            func setLiked(contentId: String, liked: Bool) async throws {}
            func notInterested(contentId: String) async throws {}
            func undoNotInterested(contentId: String) async throws {}
            func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
            func reportEvents(_ events: [FeedEventPayload]) async throws {}
        }
        do {
            _ = try await Bare().vote(contentId: "p", options: [0])
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? FeedPublishError, FeedPublishError.feedNotAvailable)
        }
    }
}

// MARK: - I-3 信息流卡片补全（`FeedCardExtras`）

final class TellomiFeedCardExtrasTests: XCTestCase {
    private func card(shareable: Bool = true, kind: String = FeedCard.kindPost) -> FeedCard {
        var card = FeedCard(id: "p1", author: FeedAuthor(profileId: "u", displayName: "山风"), text: "今天去爬山")
        card.kind = kind
        card.shareable = shareable
        return card
    }

    private func extras(_ card: FeedCard, extras: Bool = true, share: Bool = false, save: Bool = false, posting: Bool = true, polls: Bool = true, readOnly: Bool = false) -> FeedCardExtras {
        return FeedCardExtras.make(card: card, extrasEnabled: extras, shareEnabled: share, saveAvailable: save, postingAllowed: posting, pollsAllowed: polls, isReadOnly: readOnly)
    }

    /// 开关关着（默认）：卡片和之前一样，什么都不多画。
    func testSwitchOffShowsNothingNew() {
        var c = card()
        c.poll = FeedPoll(options: ["a", "b"], closesAt: nil, multi: false)
        c.quoted = FeedQuotedCard(id: "q", card: nil)
        c.repostedBy = FeedRepostedBy(profileId: "r", displayName: "阿明")
        let result = extras(c, extras: false, share: true, save: true)
        XCTAssertNil(result.repostedByText)
        XCTAssertFalse(result.showsPoll)
        XCTAssertFalse(result.showsQuote)
        XCTAssertFalse(result.showsSave)
        XCTAssertEqual(result.shareItems, [])
    }

    /// 分享菜单：能分享的帖子才有；转发 / 引用跟 `posting`；分享 / 复制链接跟分享开关。
    func testShareMenuItems() {
        XCTAssertEqual(extras(card()).shareItems, [.repost(reposted: false), .quote])
        XCTAssertEqual(extras(card(), share: true).shareItems, [.repost(reposted: false), .quote, .share, .copyLink])
        XCTAssertEqual(extras(card(), share: true, posting: false).shareItems, [.share, .copyLink])
        XCTAssertEqual(extras(card(shareable: false), share: true).shareItems, [], "私密 / 非公开没有外链，也不能转发引用")
        XCTAssertEqual(extras(card(), share: true, readOnly: true).shareItems, [])
        var reposted = card()
        reposted.viewer.reposted = true
        XCTAssertEqual(extras(reposted).shareItems.first, .repost(reposted: true))
    }

    func testCommentsGetNothing() {
        XCTAssertEqual(extras(card(kind: FeedCard.kindComment), share: true, save: true).shareItems, [])
        XCTAssertFalse(extras(card(kind: FeedCard.kindComment), save: true).showsSave)
    }

    /// 投票：有选项就画；没部署 `polls` 或只读时只看不能点。
    func testPollInteractiveFollowsCapability() {
        var c = card()
        c.poll = FeedPoll(options: ["a", "b"], closesAt: nil, multi: true)
        XCTAssertTrue(extras(c).showsPoll)
        XCTAssertTrue(extras(c).pollInteractive)
        XCTAssertFalse(extras(c, polls: false).pollInteractive)
        XCTAssertFalse(extras(c, readOnly: true).pollInteractive)
        c.poll = FeedPoll(options: [], closesAt: nil, multi: false)
        XCTAssertFalse(extras(c).showsPoll)
    }

    func testSaveNeedsSavedMessages() {
        XCTAssertFalse(extras(card()).showsSave)
        var saved = card()
        saved.viewer.saved = true
        let result = extras(saved, save: true)
        XCTAssertTrue(result.showsSave)
        XCTAssertTrue(result.saved)
    }

    /// 引用盒：标题优先、否则正文；删了 / 看不到了是灰字（第 41 条）。
    func testQuoteText() {
        var inner = card()
        inner.title = "  "
        let ok = FeedCardExtras.quote(FeedQuotedCard(id: "q", card: inner))
        XCTAssertEqual(ok.authorName, "山风")
        XCTAssertEqual(ok.text, "今天去爬山")
        XCTAssertNil(ok.goneText)
        inner.title = "标题"
        XCTAssertEqual(FeedCardExtras.quote(FeedQuotedCard(id: "q", card: inner)).text, "标题")
        XCTAssertNotNil(FeedCardExtras.quote(FeedQuotedCard(id: "q", card: nil, deleted: true)).goneText)
        XCTAssertNotEqual(
            FeedCardExtras.quote(FeedQuotedCard(id: "q", card: nil, deleted: true)).goneText,
            FeedCardExtras.quote(FeedQuotedCard(id: "q", card: nil, deleted: false)).goneText,
        )
    }

    func testRepostedByLine() {
        var c = card()
        c.repostedBy = FeedRepostedBy(profileId: "r", displayName: "阿明")
        XCTAssertNotNil(extras(c).repostedByText)
        XCTAssertTrue(extras(c).repostedByText?.contains("阿明") ?? false)
        c.repostedBy = FeedRepostedBy(profileId: "r", displayName: " ")
        XCTAssertEqual(extras(c).repostedByText, FeedCardExtras.repostedByText(nil))
        XCTAssertNil(extras(card()).repostedByText)
    }
}
