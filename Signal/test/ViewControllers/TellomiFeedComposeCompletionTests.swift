//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedComposeCompletionTests.swift (new file)
// I-12: poll / reply options / topics / quote in FeedDraft and the publish request, article autosave, FeedComposeStore.
// Mirrors Android FeedDraftTest, FeedComposeViewModelTest, FeedEditTargetTest, FeedQuoteTargetTest.
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

private let limits = FeedLimits()
private let t0 = FeedDates.parse("2026-10-13T12:00:00Z")!

private func json(_ draft: FeedDraft, now: Date = t0) throws -> String {
    String(decoding: try FeedAPI.encoder.encode(draft.makeRequest(clientNonce: "n1", now: now)), as: UTF8.self)
}

// MARK: - draft / request

final class TellomiFeedComposeDraftTests: XCTestCase {
    private func poll(_ options: [String], multi: Bool = false, duration: FeedPollDuration = .oneDay) -> FeedDraftPoll {
        var p = FeedDraftPoll()
        p.options = options
        p.multi = multi
        p.duration = duration
        return p
    }

    func testPollGoesIntoTheRequestWithTrimmedOptionsAndAClosingTimeFromNow() throws {
        var draft = FeedDraft()
        draft.text = "吃什么？"
        draft.poll = poll([" 面 ", "", "饭"], multi: true, duration: .threeDays)
        let request = draft.makeRequest(clientNonce: "n", now: t0)
        XCTAssertEqual(request.poll?.options, ["面", "饭"], "空的去掉、首尾空白去掉")
        XCTAssertEqual(request.poll?.multi, true)
        XCTAssertEqual(request.poll?.closesAt, "2026-10-16T12:00:00Z", "截止时间在点发布的那一刻算：现在 + 72 小时")
        XCTAssertEqual(draft.makeRequest(now: t0.addingTimeInterval(3600)).poll?.closesAt, "2026-10-16T13:00:00Z")
        let encoded = try json(draft)
        XCTAssertTrue(encoded.contains(#""poll":{"#), encoded)
        XCTAssertTrue(encoded.contains(#""closes_at":"2026-10-16T12:00:00Z""#), encoded)
    }

    func testAnArticleNeverCarriesTheKeptPollButTopicsAndRepliesStillGo() throws {
        var draft = FeedDraft()
        draft.kind = .article
        draft.title = "T"
        draft.text = "body"
        draft.poll = poll(["a", "b"])
        draft.topics = ["food", "daily"]
        draft.replies = FeedReplySettings(policy: .following, commentsClosed: true, moderation: true, voiceComments: false)
        let request = draft.makeRequest(now: t0)
        XCTAssertNil(request.poll)
        XCTAssertNil(draft.attachedPoll)
        XCTAssertEqual(request.topics, ["food", "daily"])
        XCTAssertEqual(request.replyPolicy, "following")
        XCTAssertTrue(request.commentsClosed)
        XCTAssertTrue(request.replyModeration)
        draft.kind = .post
        XCTAssertNotNil(draft.makeRequest(now: t0).poll, "切回动态投票还在")
    }

    func testDefaultsAreOmittedSoOldPostsKeepTheirExactJson() throws {
        var draft = FeedDraft()
        draft.text = "hi"
        let encoded = try json(draft)
        XCTAssertFalse(encoded.contains("reply_policy"), encoded)
        XCTAssertFalse(encoded.contains("reply_moderation"), encoded)
        XCTAssertFalse(encoded.contains("poll"), encoded)
        XCTAssertFalse(encoded.contains("topics"), encoded)
        XCTAssertFalse(encoded.contains("quote_of"), encoded)
        XCTAssertTrue(encoded.contains(#""comments_closed":false"#), encoded)
        draft.replies.policy = .friends
        XCTAssertTrue(try json(draft).contains(#""reply_policy":"friends""#))
        draft.quote = FeedQuoteTarget(id: "q1", authorName: "A", snippet: "s")
        XCTAssertTrue(try json(draft).contains(#""quote_of":"q1""#))
    }

    func testProblemsKnowAboutPolls() {
        var draft = FeedDraft()
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .empty)
        draft.poll = poll(["a", "b"])
        XCTAssertNil(draft.problem(limits: limits, minorMode: false), "只有投票、正文空着也能发（照 Android）")
        draft.poll = poll(["a", ""])
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .invalidPoll)
        draft.poll = poll(["a", String(repeating: "字", count: 41)])
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .invalidPoll)
        draft.poll = poll(["a", String(repeating: "字", count: 40)])
        XCTAssertNil(draft.problem(limits: limits, minorMode: false))
        draft.kind = .article
        draft.title = "T"
        draft.poll = poll(["", ""])
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .empty, "长文不带投票：坏投票不拦它，空正文照旧拦")
        draft.text = "x"
        XCTAssertNil(draft.problem(limits: limits, minorMode: false))
        XCTAssertTrue(FeedDraft().isEmpty)
        var onlyPoll = FeedDraft()
        onlyPoll.poll = FeedDraftPoll()
        XCTAssertFalse(onlyPoll.isEmpty)
    }

    func testPollRules() {
        var p = FeedDraftPoll()
        XCTAssertEqual(p.options.count, 2)
        XCTAssertFalse(p.isValid)
        XCTAssertTrue(p.canAddOption)
        p.options = (0..<10).map { "o\($0)" }
        XCTAssertTrue(p.isValid)
        XCTAssertFalse(p.canAddOption)
        p.options.append("o10")
        XCTAssertFalse(p.isValid, "超过 10 个")
        XCTAssertEqual(FeedPollDuration.allCases.map(\.hours), [24, 72, 168])
        XCTAssertEqual(FeedDraftPoll.clip(String(repeating: "字", count: 50)).unicodeScalars.count, 40)
        XCTAssertEqual(FeedDraftPoll.clip("short"), "short")
        let emoji = String(repeating: "😀", count: 41)   // 每个 1 个码点（Kotlin 里是 2 个 UTF-16 单位）
        XCTAssertEqual(FeedDraftPoll.clip(emoji), String(repeating: "😀", count: 40))
        // 只在字的边界上截：38 个 a + 一个 7 个码点的家庭 emoji = 45 > 40，整个 emoji 去掉，不留半个（以前会留 2 个码点 = 半个 emoji）
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        XCTAssertEqual(FeedDraftPoll.clip(String(repeating: "a", count: 38) + family), String(repeating: "a", count: 38))
        XCTAssertEqual(FeedDraftPoll.clip(String(repeating: "a", count: 33) + family), String(repeating: "a", count: 33) + family, "刚好 40")
    }

    func testQuoteTargetOnlyForShareablePostsAndArticles() {
        func card(_ kind: String, shareable: Bool = true, title: String? = nil, text: String? = "hello") -> FeedCard {
            var c = FeedCard(id: "c1", kind: kind, author: FeedAuthor(profileId: "p", displayName: "Ann"), text: text ?? "")
            c.text = text
            c.title = title
            c.shareable = shareable
            return c
        }
        XCTAssertEqual(FeedQuoteTarget.of(card("post")), FeedQuoteTarget(id: "c1", authorName: "Ann", snippet: "hello"))
        XCTAssertNil(FeedQuoteTarget.of(card("post", shareable: false)), "私密账号的不能引用")
        XCTAssertNil(FeedQuoteTarget.of(card("comment")))
        XCTAssertEqual(FeedQuoteTarget.of(card("article", title: " 标题 ", text: "正文"))?.snippet, " 标题 ".trimmingCharacters(in: .whitespaces), "有标题用标题，去首尾空白")
        XCTAssertEqual(FeedQuoteTarget.of(card("article", title: "   ", text: "正文"))?.snippet, "正文", "标题全是空白就用正文")
        XCTAssertEqual(FeedQuoteTarget.of(card("post", text: nil))?.snippet, "")
        let long = String(repeating: "字", count: 130)
        XCTAssertEqual(FeedQuoteTarget.of(card("post", text: long))?.snippet, String(repeating: "字", count: 120) + "…")
        let exact = String(repeating: "字", count: 120)
        XCTAssertEqual(FeedQuoteTarget.of(card("post", text: exact))?.snippet, exact)
        var anonymous = card("post")
        anonymous.author = nil
        XCTAssertEqual(FeedQuoteTarget.of(anonymous)?.authorName, "")
    }

    func testReplySettingsDefaultsAndTopicCatalog() {
        XCTAssertTrue(FeedReplySettings().isDefault)
        XCTAssertTrue(FeedReplySettings().voiceComments)
        var s = FeedReplySettings()
        s.moderation = true
        XCTAssertFalse(s.isDefault)
        XCTAssertEqual(FeedReplyPolicy.allCases.map(\.apiName), ["everyone", "friends", "following"])
        XCTAssertEqual(FeedTopicCatalog.slugs.count, 36)
        XCTAssertEqual(Set(FeedTopicCatalog.slugs).count, 36)
        XCTAssertEqual(FeedTopicCatalog.slugs.first, "ai")
        XCTAssertEqual(FeedTopicCatalog.slugs.last, "news")
    }
}

final class TellomiFeedArticleDraftsTests: XCTestCase {
    func testInMemory() {
        let drafts = InMemoryFeedArticleDrafts()
        XCTAssertNil(drafts.load())
        drafts.save(FeedSavedArticle(title: "a", text: "b"))
        XCTAssertEqual(drafts.load(), FeedSavedArticle(title: "a", text: "b"))
        drafts.clear()
        XCTAssertNil(drafts.load())
    }

    func testStoredSurvivesARestartAndToleratesBadData() throws {
        let storage = InMemoryFeedStorage()
        let first = StoredFeedArticleDrafts(storage: storage)
        XCTAssertNil(first.load())
        first.save(FeedSavedArticle(title: "标题", text: "正文\n第二行"))
        XCTAssertEqual(StoredFeedArticleDrafts(storage: storage).load(), FeedSavedArticle(title: "标题", text: "正文\n第二行"))
        first.clear()
        XCTAssertNil(storage.data(forKey: StoredFeedArticleDrafts.key))
        storage.set(Data("nope".utf8), forKey: StoredFeedArticleDrafts.key)
        XCTAssertNil(StoredFeedArticleDrafts(storage: storage).load(), "存坏了当没有")
        storage.set(Data(#"{"title":"only"}"#.utf8), forKey: StoredFeedArticleDrafts.key)
        XCTAssertEqual(StoredFeedArticleDrafts(storage: storage).load(), FeedSavedArticle(title: "only", text: ""), "缺字段补空")
    }
}

// MARK: - store

private final class ComposeSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _publishError: Error?
    private var _gate: Gate?
    var configValue = FeedConfig()
    var configError: Error?
    var publishError: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _publishError }
        set { lock.lock(); _publishError = newValue; lock.unlock() }
    }
    var gate: Gate? {
        get { lock.lock(); defer { lock.unlock() }; return _gate }
        set { lock.lock(); _gate = newValue; lock.unlock() }
    }
    let published = CallLog<FeedDraft>()
    let nonces = CallLog<String>()
    let edited = CallLog<String>()
    let editedDrafts = CallLog<FeedDraft>()

    func config() async throws -> FeedConfig {
        if let configError { throw configError }
        return configValue
    }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        published.append(draft)
        nonces.append(clientNonce)
        if let gate { await gate.wait() }
        if let publishError { throw publishError }
        return FeedCreatePostResponse(id: "new", state: "pending")
    }
    func editPost(contentId: String, draft: FeedDraft) async throws -> FeedCreatePostResponse {
        edited.append(contentId)
        editedDrafts.append(draft)
        if let gate { await gate.wait() }
        if let publishError { throw publishError }
        return FeedCreatePostResponse(id: contentId, state: "published")
    }
}

@MainActor
final class TellomiFeedComposeStoreTests: XCTestCase {
    private func make(_ source: ComposeSource = ComposeSource(), drafts: FeedArticleDrafts = InMemoryFeedArticleDrafts(), edit: FeedEditTarget? = nil, quote: FeedQuoteTarget? = nil) async -> FeedComposeStore {
        let store = FeedComposeStore(editTarget: edit, quoteTarget: quote, source: source, articleDrafts: drafts, clientNonce: "nonce-1")
        store.start()
        await store.waitForTasks()
        return store
    }

    private func api(_ status: Int, _ code: String?) -> FeedAPIError {
        FeedAPIError(status: status, code: code, retryAfterSeconds: nil)
    }

    func testConfigSetsLimitsAndTheMinorModeDefaultVisibility() async {
        let source = ComposeSource()
        source.configValue.limits.postTextChars = 100
        source.configValue.limits.postImages = 2
        source.configValue.minorMode = true
        let store = await make(source)
        XCTAssertEqual(store.state.limits.postTextChars, 100)
        XCTAssertEqual(store.state.textLimit, 100)
        XCTAssertTrue(store.state.minorMode)
        XCTAssertEqual(store.state.draft.visibility, .friends)
        store.onVisibilityChanged(.public)
        XCTAssertEqual(store.state.draft.visibility, .friends, "未成年人不能选公开")
        store.onVisibilityChanged(.include)
        XCTAssertEqual(store.state.draft.visibility, .friends, "要选人的两档这里不能直接选")
        store.onVisibilityChanged(.onlyMe)
        XCTAssertEqual(store.state.draft.visibility, .onlyMe)

        let adult = await make()
        XCTAssertEqual(adult.state.draft.visibility, .public)
        adult.onVisibilityChanged(.friends)
        XCTAssertEqual(adult.state.draft.visibility, .friends)
    }

    func testConfigFailureKeepsDefaults() async {
        let source = ComposeSource()
        source.configError = Boom()
        let store = await make(source)
        XCTAssertEqual(store.state.limits, FeedLimits())
        XCTAssertEqual(store.state.draft.visibility, .public)
    }

    func testARestoredArticleIsKeptUnlessItsVisibilityIsNotAllowedInMinorMode() async {
        var saved = FeedDraft()
        saved.visibility = .public
        let drafts = InMemoryFeedArticleDrafts(saved: FeedSavedArticle(title: "T", text: "body"))
        let source = ComposeSource()
        let store = await make(source, drafts: drafts)
        XCTAssertEqual(store.state.draft.kind, .article)
        XCTAssertEqual(store.state.draft.title, "T")
        XCTAssertTrue(store.state.restoredArticle)
        XCTAssertEqual(store.state.draft.visibility, .public, "成年人保持原档（恢复出来的本来就是默认档）")
        store.onRestoredArticleShown()
        XCTAssertFalse(store.state.restoredArticle)

        source.configValue.minorMode = true
        let minor = await make(source, drafts: drafts)
        XCTAssertEqual(minor.state.draft.visibility, .friends)
        XCTAssertEqual(minor.state.draft.text, "body", "只换档位，文字还在")

        let blank = await make(drafts: InMemoryFeedArticleDrafts(saved: FeedSavedArticle(title: " ", text: "\n")))
        XCTAssertFalse(blank.state.restoredArticle)
        XCTAssertEqual(blank.state.draft.kind, .post)

        let editing = await make(drafts: drafts, edit: FeedEditTarget(id: "e", kind: "post", title: nil, text: "x", publishedAt: nil))
        XCTAssertFalse(editing.state.restoredArticle, "编辑时不恢复长文")
        let quoting = await make(drafts: drafts, quote: FeedQuoteTarget(id: "q", authorName: "A", snippet: "s"))
        XCTAssertFalse(quoting.state.restoredArticle)
        XCTAssertEqual(quoting.state.draft.quote?.id, "q")
        XCTAssertEqual(quoting.state.draft.kind, .post)
    }

    func testKindCannotChangeWhileEditingOrQuoting() async {
        let store = await make()
        store.onKindChanged(.article)
        XCTAssertEqual(store.state.draft.kind, .article)
        let quoting = await make(quote: FeedQuoteTarget(id: "q", authorName: "A", snippet: "s"))
        quoting.onKindChanged(.article)
        XCTAssertEqual(quoting.state.draft.kind, .post)
        let editing = await make(edit: FeedEditTarget(id: "e", kind: "article", title: "T", text: "x", publishedAt: nil))
        XCTAssertEqual(editing.state.draft.kind, .article)
        editing.onKindChanged(.post)
        XCTAssertEqual(editing.state.draft.kind, .article)
    }

    func testArticlesAutosaveAndEverythingElseAsksBeforeClosing() async {
        let drafts = InMemoryFeedArticleDrafts()
        let store = await make(drafts: drafts)
        store.onTextChanged("a post")
        XCTAssertNil(drafts.load(), "动态不存")
        XCTAssertTrue(store.state.hasUnsavedChanges)
        store.onKindChanged(.article)
        store.onTitleChanged("T")
        XCTAssertEqual(drafts.load(), FeedSavedArticle(title: "T", text: "a post"))
        XCTAssertFalse(store.state.hasUnsavedChanges, "自动保存的长文关页面不问")
        store.onTextChanged("")
        store.onTitleChanged("  ")
        XCTAssertNil(drafts.load(), "写空了就清掉")
        store.onTitleChanged("T2")
        store.onPollAdded()   // 长文里不能加投票
        XCTAssertNil(store.state.draft.poll)
        store.onKindChanged(.post)
        store.onPollAdded()
        store.onKindChanged(.article)
        XCTAssertNotNil(store.state.draft.poll, "切到长文，投票留着")
        XCTAssertFalse(store.state.autosavesArticle, "带着投票的不自动保存")
        XCTAssertTrue(store.state.hasUnsavedChanges)
    }

    func testTopicsAreCappedAtThreeAndCannotChangeWhileEditing() async {
        let store = await make()
        store.onTopicToggled("a")
        store.onTopicToggled("b")
        store.onTopicToggled("c")
        store.onTopicToggled("d")
        XCTAssertEqual(store.state.draft.topics, ["a", "b", "c"])
        store.onTopicToggled("b")
        XCTAssertEqual(store.state.draft.topics, ["a", "c"])
        store.onTopicToggled("d")
        XCTAssertEqual(store.state.draft.topics, ["a", "c", "d"])
        let editing = await make(edit: FeedEditTarget(id: "e", kind: "post", title: nil, text: "x", publishedAt: nil))
        editing.onTopicToggled("a")
        XCTAssertEqual(editing.state.draft.topics, [])
        editing.onReplySettingsChanged(FeedReplySettings(policy: .friends))
        XCTAssertTrue(editing.state.draft.replies.isDefault)
        store.onReplySettingsChanged(FeedReplySettings(policy: .friends, commentsClosed: true))
        XCTAssertEqual(store.state.draft.replies.policy, .friends)
    }

    func testPollEditing() async {
        let store = await make()
        store.onPollOptionChanged(0, "ignored")   // 还没有投票
        XCTAssertNil(store.state.draft.poll)
        store.onPollAdded()
        store.onPollAdded()   // 已经有了
        XCTAssertEqual(store.state.draft.poll?.options, ["", ""])
        XCTAssertFalse(store.state.canAddPoll)
        store.onPollOptionChanged(0, String(repeating: "字", count: 60))
        XCTAssertEqual(store.state.draft.poll?.options[0].unicodeScalars.count, 40)
        store.onPollOptionChanged(9, "out of range")
        store.onPollOptionChanged(-1, "out of range")
        XCTAssertEqual(store.state.draft.poll?.options.count, 2)
        for _ in 0..<12 { store.onPollOptionAdded() }
        XCTAssertEqual(store.state.draft.poll?.options.count, 10)
        for _ in 0..<12 { store.onPollOptionRemoved(1) }
        XCTAssertEqual(store.state.draft.poll?.options.count, 2, "至少留两个格子")
        store.onPollOptionRemoved(5)
        XCTAssertEqual(store.state.draft.poll?.options.count, 2)
        store.onPollMultiChanged(true)
        store.onPollDurationChanged(.sevenDays)
        XCTAssertEqual(store.state.draft.poll?.multi, true)
        XCTAssertEqual(store.state.draft.poll?.duration, .sevenDays)
        store.onPollRemoved()
        XCTAssertNil(store.state.draft.poll)
        XCTAssertTrue(store.state.canAddPoll)
        let editing = await make(edit: FeedEditTarget(id: "e", kind: "post", title: nil, text: "x", publishedAt: nil))
        editing.onPollAdded()
        XCTAssertNil(editing.state.draft.poll, "编辑时不能加投票")
    }

    func testImagesAreCappedAndDeduplicated() async {
        let source = ComposeSource()
        source.configValue.limits.postImages = 3
        let store = await make(source)
        let a = FeedDraftImage(id: "a", image: UIImage())
        let b = FeedDraftImage(id: "b", image: UIImage())
        let c = FeedDraftImage(id: "c", image: UIImage())
        let d = FeedDraftImage(id: "d", image: UIImage())
        store.onImagesPicked([a, a, b])
        XCTAssertEqual(store.state.draft.images.map(\.id), ["a", "b"])
        store.onImagesPicked([b, c, d])
        XCTAssertEqual(store.state.draft.images.map(\.id), ["a", "b", "c"], "超出上限的不要")
        XCTAssertFalse(store.state.canAddImages)
        store.onImageRemoved(id: "b")
        XCTAssertEqual(store.state.draft.images.map(\.id), ["a", "c"])
        XCTAssertTrue(store.state.canAddImages)
        store.onKindChanged(.article)
        XCTAssertFalse(store.state.canAddImages)
    }

    func testPublishSendsTheDraftAndOnlyOnceAtATime() async {
        let source = ComposeSource()
        let drafts = InMemoryFeedArticleDrafts(saved: nil)
        let store = await make(source, drafts: drafts)
        store.publish()
        XCTAssertEqual(source.published.all.count, 0, "空的发不出去")
        store.onKindChanged(.article)
        store.onTitleChanged("T")
        store.onTextChanged("body")
        XCTAssertNotNil(drafts.load())
        let gate = Gate()
        source.gate = gate
        store.publish()
        store.publish()
        XCTAssertTrue(store.state.publishing)
        await eventually("请求发出") { await gate.arrivals == 1 }
        store.publish()
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(source.published.all.count, 1)
        XCTAssertEqual(source.nonces.all, ["nonce-1"])
        XCTAssertEqual(store.state.publishedState, "pending")
        XCTAssertFalse(store.state.publishing)
        XCTAssertNil(drafts.load(), "发出去就清掉自动保存的长文")
    }

    func testARetryAfterAFailureReusesTheNonceAndKeepsTheArticle() async {
        let source = ComposeSource()
        let drafts = InMemoryFeedArticleDrafts()
        let store = await make(source, drafts: drafts)
        store.onKindChanged(.article)
        store.onTitleChanged("T")
        store.onTextChanged("body")
        source.publishError = Boom()
        store.publish()
        await store.waitForTasks()
        XCTAssertTrue(store.state.failed)
        XCTAssertNil(store.state.publishedState)
        XCTAssertNotNil(drafts.load(), "没发出去，长文还在")
        store.onFailureShown()
        XCTAssertFalse(store.state.failed)
        source.publishError = nil
        store.publish()
        await store.waitForTasks()
        XCTAssertEqual(source.nonces.all, ["nonce-1", "nonce-1"], "重试用同一个去重号，引擎只收一次")
        XCTAssertEqual(store.state.publishedState, "pending")
    }

    func testPublishErrorsAreTranslated() async {
        let source = ComposeSource()
        let store = await make(source, quote: FeedQuoteTarget(id: "q", authorName: "A", snippet: "s"))
        store.onTextChanged("my thoughts")
        source.publishError = api(400, "quote_unavailable")
        store.publish()
        await store.waitForTasks()
        XCTAssertTrue(store.state.quoteUnavailable)
        XCTAssertFalse(store.state.failed)
        XCTAssertNil(store.state.draft.quote, "引用去掉，正文留着")
        XCTAssertEqual(store.state.draft.text, "my thoughts")
        source.publishError = api(400, "quote_unavailable")   // 没有引用时再收到：当普通失败
        store.publish()
        await store.waitForTasks()
        XCTAssertTrue(store.state.failed)
        XCTAssertFalse(store.state.quoteUnavailable)

        source.publishError = api(409, "profile_required")
        store.publish()
        await store.waitForTasks()
        XCTAssertTrue(store.state.profileRequired)
        XCTAssertFalse(store.state.failed)
        store.onProfileRequiredShown()
        XCTAssertFalse(store.state.profileRequired)

        source.publishError = api(500, nil)
        store.publish()
        await store.waitForTasks()
        XCTAssertTrue(store.state.failed)
        XCTAssertFalse(store.state.profileRequired)
        XCTAssertFalse(store.state.publishing)
    }

    func testEditingOnlyAllowsAChangeAndGoesThroughEditPost() async {
        let source = ComposeSource()
        let drafts = InMemoryFeedArticleDrafts(saved: FeedSavedArticle(title: "keep", text: "keep"))
        let target = FeedEditTarget(id: "e1", kind: "article", title: "Old", text: "old text", publishedAt: nil)
        let store = await make(source, drafts: drafts, edit: target)
        XCTAssertEqual(store.state.problem, .unchanged)
        XCTAssertFalse(store.state.hasUnsavedChanges)
        store.publish()
        XCTAssertEqual(source.edited.all, [], "没改不发")
        store.onTextChanged("old text  ")
        XCTAssertEqual(store.state.problem, .unchanged, "只多了空白不算改")
        store.onTitleChanged("New")
        XCTAssertNil(store.state.problem)
        XCTAssertTrue(store.state.hasUnsavedChanges)
        XCTAssertNotNil(drafts.load(), "编辑时不碰自动保存")
        store.publish()
        await store.waitForTasks()
        XCTAssertEqual(source.edited.all, ["e1"])
        XCTAssertEqual(source.published.all.count, 0)
        XCTAssertEqual(store.state.publishedState, "published")
        XCTAssertNotNil(drafts.load(), "编辑成功也不清掉另一篇没写完的长文")
        XCTAssertEqual(source.editedDrafts.all.first?.title, "New")
    }

    func testEditingIgnoresTheVisibilityChecksButNotOtherProblems() async {
        let source = ComposeSource()
        source.configValue.minorMode = true
        let target = FeedEditTarget(id: "e1", kind: "post", title: nil, text: "x", publishedAt: nil)
        let store = await make(source, edit: target)
        XCTAssertEqual(store.state.draft.visibility, .public, "编辑不动可见范围；未成年人模式也不换档")
        XCTAssertEqual(store.state.problem, .unchanged, "编辑时不查可见范围")
        store.onTextChanged("y")
        XCTAssertNil(store.state.problem)
        store.onTextChanged(String(repeating: "字", count: 501))
        XCTAssertEqual(store.state.problem, .tooLong)
        store.onTextChanged("  ")
        XCTAssertEqual(store.state.problem, .empty)
    }

    func testEditWindowClosedIsNotAFailure() async {
        let source = ComposeSource()
        let store = await make(source, edit: FeedEditTarget(id: "e1", kind: "post", title: nil, text: "x", publishedAt: nil))
        store.onTextChanged("changed")
        for code in ["edit_window_closed", "not_editable"] {
            source.publishError = api(409, code)
            store.publish()
            await store.waitForTasks()
            XCTAssertTrue(store.state.editWindowClosed, code)
            XCTAssertFalse(store.state.failed, code)
            store.onFailureShown()
            XCTAssertFalse(store.state.editWindowClosed)
        }
        source.publishError = api(409, "something_else")
        store.publish()
        await store.waitForTasks()
        XCTAssertTrue(store.state.failed)
        XCTAssertFalse(store.state.editWindowClosed)
    }

    // MARK: I-20 标题上限 100（码点）：到了就挡住、粘贴剪短、显示还剩几个

    func testTheArticleTitleBlocksTypingAtTheLimitAndCountsDown() async {
        let store = await make()
        store.onKindChanged(.article)
        XCTAssertEqual(store.state.titleRemaining, FeedInputLimit.articleTitle)
        XCTAssertEqual(FeedInputLimit.articleTitle, 100)
        store.onTitleChanged(String(repeating: "a", count: 99))
        XCTAssertEqual(store.state.titleRemaining, 1)
        let last = store.onTitleEdit(range: NSRange(location: 99, length: 0), replacement: "b")
        XCTAssertTrue(last.accepted)
        XCTAssertEqual(store.state.draft.title.count, 100)
        XCTAssertEqual(store.state.titleRemaining, 0)
        XCTAssertFalse(store.state.titleLimitHit, "刚好打满还不算碰到")
        let extra = store.onTitleEdit(range: NSRange(location: 100, length: 0), replacement: "c")
        XCTAssertTrue(extra.blocked)
        XCTAssertFalse(extra.accepted)
        XCTAssertEqual(store.state.draft.title.count, 100, "满了再打不进去")
        XCTAssertTrue(store.state.titleLimitHit)
        // 删掉就能再打
        let del = store.onTitleEdit(range: NSRange(location: 99, length: 1), replacement: "")
        XCTAssertTrue(del.accepted)
        XCTAssertEqual(store.state.titleRemaining, 1)
        XCTAssertFalse(store.state.titleLimitHit)
    }

    func testAPastedTitleIsClippedByCodePointAndAReplacedSelectionMakesRoom() async {
        let store = await make()
        store.onKindChanged(.article)
        store.onTitleChanged(String(repeating: "x", count: 90))
        let paste = store.onTitleEdit(range: NSRange(location: 90, length: 0), replacement: "🇨🇳🇨🇳🇨🇳🇨🇳🇨🇳🇨🇳")
        XCTAssertTrue(paste.clipped, "还剩 10 个码点：5 面旗刚好")
        XCTAssertEqual(store.state.draft.title, String(repeating: "x", count: 90) + String(repeating: "🇨🇳", count: 5))
        XCTAssertEqual(store.state.titleRemaining, 0)
        // 选中 10 个字换成 15 个字：腾出的位置可以用，多的剪掉
        let swap = store.onTitleEdit(range: NSRange(location: 0, length: 10), replacement: String(repeating: "y", count: 15))
        XCTAssertTrue(swap.clipped)
        XCTAssertEqual(store.state.draft.title.unicodeScalars.count, 100)
        XCTAssertTrue(store.state.draft.title.hasPrefix(String(repeating: "y", count: 10)))
        // 整段设置（恢复草稿/粘贴整段）也一样按码点剪，不拆开一个字
        store.onTitleChanged(String(repeating: "😀", count: 150))
        XCTAssertEqual(store.state.draft.title, String(repeating: "😀", count: 100))
        store.onTitleChanged(String(repeating: "a", count: 99) + "👨‍👩‍👧‍👦")
        XCTAssertEqual(store.state.draft.title, String(repeating: "a", count: 99), "放不下的家庭 emoji 整个不要，不留半个")
    }

    func testComposingTitleTextWaitsToBeClippedAndMeanwhileCannotBePublished() async {
        let source = ComposeSource()
        let store = await make(source)
        store.onKindChanged(.article)
        store.onTextChanged("body")
        store.onTitleChanged(String(repeating: "拼", count: 100))
        XCTAssertNil(store.state.problem)
        let marked = store.onTitleEdit(range: NSRange(location: 100, length: 0), replacement: "pinyin", composing: true)
        XCTAssertTrue(marked.accepted, "拼写中不拦")
        XCTAssertEqual(store.state.titleRemaining, -6)
        XCTAssertEqual(store.state.problem, .tooLong)
        store.publish()
        await store.waitForTasks()
        XCTAssertEqual(source.published.all.count, 0, "拼写中超了的标题发不出去")
        store.onTitleChanged(store.state.draft.title)   // 拼完：剪回 100
        XCTAssertEqual(store.state.titleRemaining, 0)
        XCTAssertNil(store.state.problem)
        XCTAssertTrue(store.state.titleLimitHit)
    }
}
