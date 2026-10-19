//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

// 发布页剩余的三块：编辑页（15 分钟内）、草稿入口、选人页（只给谁看 / 不给谁看）。

private struct Boom: Error {}

private let t0 = FeedDates.parse("2026-10-18T12:00:00Z")!

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}

private final class CountingCandidates: FeedAudienceCandidateSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _failures: Int
    private let list: [FeedAudienceCandidate]
    init(_ list: [FeedAudienceCandidate], failures: Int = 0) {
        self.list = list
        _failures = failures
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    private func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _calls += 1
        let fail = _failures > 0
        if fail { _failures -= 1 }
        return fail
    }
    func candidates() async throws -> [FeedAudienceCandidate] {
        let fail = take()
        try? await Task.sleep(nanoseconds: 2_000_000)
        if fail { throw Boom() }
        return list
    }
}

private func person(_ id: Int64, _ name: String, aci: String? = nil) -> FeedAudienceCandidate {
    FeedAudienceCandidate(recipientId: id, aci: aci ?? String(format: "00000000-0000-4000-8000-%012d", Int(id)), displayName: name)
}

// MARK: - 选人页

@MainActor
final class TellomiFeedAudiencePickerTests: XCTestCase {
    private func make(
        _ list: [FeedAudienceCandidate],
        visibility: FeedVisibility = .include,
        preselected: [FeedAudienceMember] = [],
        max: Int = FeedDraft.maxAudience
    ) async -> FeedAudiencePickerStore {
        let store = FeedAudiencePickerStore(visibility: visibility, preselected: preselected, source: StaticFeedAudienceCandidates(list), maxMembers: max)
        store.load()
        await store.waitForTasks()
        return store
    }

    func testLoadingDropsBadAndDuplicatePeopleAndFillsBlankNames() async {
        let store = await make([
            person(1, "Alice"),
            person(2, "bad", aci: "not-a-uuid"),
            person(1, "Alice again"),
            person(3, "Dup aci", aci: "00000000-0000-4000-8000-000000000001"),
            person(4, "  ", aci: "ABCDEF01-0000-4000-8000-000000000004"),
        ])
        XCTAssertEqual(store.state.candidates.map(\.recipientId), [1, 4])
        XCTAssertEqual(store.state.candidates[1].displayName, "abcdef01", "名字是空的：显示 ACI 前 8 位")
        XCTAssertEqual(store.state.candidates[1].aci, "abcdef01-0000-4000-8000-000000000004", "ACI 统一小写")
        XCTAssertFalse(store.state.loading)
        XCTAssertFalse(store.state.loadFailed)
    }

    func testTheSameRecipientWithAnotherAciIsOnlyListedOnce() async {
        let store = await make([person(1, "A"), person(1, "A2", aci: "00000000-0000-4000-8000-0000000000aa")])
        XCTAssertEqual(store.state.candidates.map(\.displayName), ["A"], "recipient id 一样就是同一个人")
    }

    func testPreselectedPeopleAreTickedAndOnesNoLongerFriendsAreDropped() async {
        let store = await make(
            [person(1, "A"), person(2, "B"), person(3, "C")],
            preselected: [FeedAudienceMember(recipientId: 3, aci: "x"), FeedAudienceMember(recipientId: 99, aci: "y"), FeedAudienceMember(recipientId: 1, aci: "z"), FeedAudienceMember(recipientId: 3, aci: "x")]
        )
        XCTAssertEqual(store.state.selected, [3, 1], "不在候选里的去掉、重复的只留一个、先后顺序不变")
        XCTAssertTrue(store.isSelected(3))
        XCTAssertFalse(store.isSelected(2))
    }

    func testToggleSelectsAndDeselectsAndIgnoresUnknownPeople() async {
        let store = await make([person(1, "A"), person(2, "B")])
        store.toggle(recipientId: 2)
        store.toggle(recipientId: 1)
        store.toggle(recipientId: 42)
        XCTAssertEqual(store.state.selected, [2, 1])
        store.toggle(recipientId: 2)
        XCTAssertEqual(store.state.selected, [1])
    }

    func testTheLimitStopsTheNextPersonAndFlagsItOnce() async {
        let store = await make((1...5).map { person(Int64($0), "P\($0)") }, max: 3)
        (1...3).forEach { store.toggle(recipientId: Int64($0)) }
        XCTAssertFalse(store.state.limitHit)
        store.toggle(recipientId: 4)
        XCTAssertEqual(store.state.selected, [1, 2, 3])
        XCTAssertTrue(store.state.limitHit)
        store.onLimitShown()
        XCTAssertFalse(store.state.limitHit)
        store.toggle(recipientId: 1)
        store.toggle(recipientId: 4)
        XCTAssertEqual(store.state.selected, [2, 3, 4], "取消一个之后又能选")
        XCTAssertFalse(store.state.limitHit)
    }

    func testPreselectedListIsCutAtTheLimit() async {
        let store = await make((1...5).map { person(Int64($0), "P\($0)") }, preselected: (1...5).map { FeedAudienceMember(recipientId: Int64($0), aci: "a") }, max: 2)
        XCTAssertEqual(store.state.selected, [1, 2])
    }

    func testDefaultLimitIsTheDraftAudienceLimit() async {
        let store = await make([person(1, "A")])
        XCTAssertEqual(store.maximum, FeedDraft.maxAudience)
        XCTAssertEqual(FeedDraft.maxAudience, 500)
    }

    func testSearchMatchesNamesIgnoringCaseAndAccents() async {
        let store = await make([person(1, "Alice Chen"), person(2, "bob"), person(3, "陈小明"), person(4, "José")])
        store.setQuery("ALI")
        XCTAssertEqual(store.visibleCandidates.map(\.recipientId), [1])
        store.setQuery("jose")
        XCTAssertEqual(store.visibleCandidates.map(\.recipientId), [4])
        store.setQuery(" 小明 ")
        XCTAssertEqual(store.visibleCandidates.map(\.recipientId), [3])
        store.setQuery("zzz")
        XCTAssertEqual(store.visibleCandidates, [])
        store.setQuery("   ")
        XCTAssertEqual(store.visibleCandidates.count, 4, "只有空格：等于没搜")
    }

    func testSelectionSurvivesASearchThatHidesThePerson() async {
        let store = await make([person(1, "Alice"), person(2, "Bob")])
        store.toggle(recipientId: 1)
        store.setQuery("bob")
        XCTAssertEqual(store.state.selected, [1])
        XCTAssertEqual(store.result.map(\.recipientId), [1])
    }

    func testConfirmNeedsAtLeastOnePersonAndAFinishedLoad() async {
        let store = FeedAudiencePickerStore(visibility: .exclude, preselected: [], source: StaticFeedAudienceCandidates([person(1, "A")]))
        XCTAssertFalse(store.canConfirm, "还在读，什么也没选")
        store.load()
        await store.waitForTasks()
        XCTAssertFalse(store.canConfirm, "一个都没选")
        store.toggle(recipientId: 1)
        XCTAssertTrue(store.canConfirm)
    }

    func testResultKeepsPickOrderAndCarriesTheAci() async {
        let store = await make([person(1, "A"), person(2, "B"), person(3, "C")])
        store.toggle(recipientId: 3)
        store.toggle(recipientId: 1)
        XCTAssertEqual(store.result, [
            FeedAudienceMember(recipientId: 3, aci: "00000000-0000-4000-8000-000000000003"),
            FeedAudienceMember(recipientId: 1, aci: "00000000-0000-4000-8000-000000000001"),
        ])
    }

    func testLoadFailureCanBeRetriedAndLoadDoesNotRunTwice() async {
        let source = CountingCandidates([person(1, "A")], failures: 1)
        let store = FeedAudiencePickerStore(visibility: .include, preselected: [], source: source)
        store.load()
        store.load()
        await store.waitForTasks()
        XCTAssertEqual(source.calls, 1, "读的时候再调不重复读")
        XCTAssertTrue(store.state.loadFailed)
        XCTAssertFalse(store.state.loading)
        XCTAssertFalse(store.canConfirm)
        store.load()
        XCTAssertTrue(store.state.loading, "点重试：回到加载中")
        XCTAssertFalse(store.state.loadFailed)
        await store.waitForTasks()
        XCTAssertEqual(source.calls, 2)
        XCTAssertEqual(store.state.candidates.count, 1)
        store.load()
        await store.waitForTasks()
        XCTAssertEqual(source.calls, 2, "读成功之后不再读")
    }

    func testAnEmptyFriendListIsALoadedEmptyPageNotAFailure() async {
        let source = CountingCandidates([])
        let store = FeedAudiencePickerStore(visibility: .include, preselected: [], source: source)
        store.load()
        await store.waitForTasks()
        store.load()
        await store.waitForTasks()
        XCTAssertEqual(source.calls, 1)
        XCTAssertFalse(store.state.loadFailed)
        XCTAssertFalse(store.state.loading)
        XCTAssertEqual(store.state.candidates, [])
    }

    func testPickedPeopleGoIntoTheComposeDraftAndPassTheDraftCheck() async {
        let picker = await make([person(1, "A"), person(2, "B")], visibility: .exclude)
        picker.toggle(recipientId: 2)
        let compose = FeedComposeStore(source: NoopSource(), articleDrafts: InMemoryFeedArticleDrafts(), clientNonce: "n")
        compose.refreshFeatures(StaticFeedFeatureGate([FeedFeature.audienceTokens]))
        await compose.waitForTasks()
        compose.onTextChanged("hello")
        compose.onAudiencePicked(.exclude, picker.result)
        XCTAssertEqual(compose.state.draft.visibility, .exclude)
        XCTAssertEqual(compose.state.draft.audience.map(\.recipientId), [2])
        XCTAssertNil(compose.state.problem)
    }

    func testSampleCandidatesAllSurviveCleaning() async {
        let sample = FeedAudienceSamples.candidates()
        XCTAssertEqual(sample.count, 12)
        XCTAssertEqual(FeedAudiencePickerStore.clean(sample), sample)
        XCTAssertEqual(FeedAudiencePickerStore.clean(FeedAudienceSamples.candidates(count: 600)).count, 600)
    }
}

private final class NoopSource: FeedSource, @unchecked Sendable {
    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { FeedCreatePostResponse(id: "x", state: "published") }
    func editPost(contentId: String, draft: FeedDraft) async throws -> FeedCreatePostResponse { FeedCreatePostResponse(id: contentId, state: "published") }
}

// MARK: - 发布页的样子 / 放弃草稿 / 草稿入口

@MainActor
final class TellomiFeedComposeLayoutTests: XCTestCase {
    private func store(edit: FeedEditTarget? = nil, quote: FeedQuoteTarget? = nil, drafts: FeedArticleDrafts = InMemoryFeedArticleDrafts()) -> FeedComposeStore {
        FeedComposeStore(editTarget: edit, quoteTarget: quote, source: NoopSource(), articleDrafts: drafts, clientNonce: "n")
    }

    private func layout(_ store: FeedComposeStore, picker: Bool = true, audience: Bool = true) -> FeedComposeLayout {
        var state = store.state
        state.audienceAvailable = audience
        return FeedComposeLayout.make(state, pickerAvailable: picker)
    }

    func testNewPostShowsTheKindSwitchPhotoAndVisibilityButtons() async {
        let result = layout(store())
        XCTAssertEqual(result.title, .kindSwitch)
        XCTAssertTrue(result.showsKindSwitch)
        XCTAssertTrue(result.showsPhotoButton)
        XCTAssertTrue(result.showsVisibilityButton)
        XCTAssertFalse(result.showsTitleField)
        XCTAssertEqual(result.publishButton, .publish)
    }

    func testAnArticleHasATitleFieldButNoPhotoButton() async {
        let compose = store()
        compose.onKindChanged(.article)
        let result = layout(compose)
        XCTAssertTrue(result.showsTitleField)
        XCTAssertFalse(result.showsPhotoButton)
        XCTAssertEqual(result.title, .kindSwitch)
    }

    func testEditingPostAndArticleChangeTheTitleAndSaveButtonAndHideTheRest() async {
        let post = layout(store(edit: FeedEditTarget(id: "p", kind: "post", title: nil, text: "hi", publishedAt: nil)))
        XCTAssertEqual(post.title, .editPost)
        XCTAssertEqual(post.publishButton, .save)
        XCTAssertFalse(post.showsKindSwitch)
        XCTAssertFalse(post.showsPhotoButton)
        XCTAssertFalse(post.showsVisibilityButton)
        XCTAssertFalse(post.showsTitleField)
        let article = layout(store(edit: FeedEditTarget(id: "a", kind: "article", title: "T", text: "body", publishedAt: nil)))
        XCTAssertEqual(article.title, .editArticle)
        XCTAssertTrue(article.showsTitleField)
        XCTAssertFalse(article.showsDiscardDraft, "编辑没有草稿")
    }

    func testPeopleOptionsAreComingSoonUntilBothTheEngineAndASourceExist() async {
        let compose = store()
        func availabilities(_ result: FeedComposeLayout) -> [FeedComposeLayout.Availability] { result.visibilityOptions.map(\.availability) }
        XCTAssertEqual(availabilities(layout(compose, picker: true, audience: false)), [.available, .available, .comingSoon, .comingSoon, .available])
        XCTAssertEqual(availabilities(layout(compose, picker: false, audience: true)), [.available, .available, .comingSoon, .comingSoon, .available])
        XCTAssertEqual(availabilities(layout(compose, picker: true, audience: true)), [.available, .available, .picksPeople(count: 0), .picksPeople(count: 0), .available])
        XCTAssertEqual(layout(compose).visibilityOptions.map(\.visibility), FeedVisibility.allCases)
    }

    func testOnlyTheChosenPeopleOptionShowsItsCount() async {
        let compose = store()
        compose.refreshFeatures(StaticFeedFeatureGate([FeedFeature.audienceTokens]))
        await compose.waitForTasks()
        compose.onAudiencePicked(.exclude, [FeedAudienceMember(recipientId: 1, aci: "a"), FeedAudienceMember(recipientId: 2, aci: "b")])
        let result = FeedComposeLayout.make(compose.state, pickerAvailable: true)
        let byVisibility = Dictionary(uniqueKeysWithValues: result.visibilityOptions.map { ($0.visibility, $0) })
        XCTAssertEqual(byVisibility[.exclude]?.availability, .picksPeople(count: 2))
        XCTAssertEqual(byVisibility[.exclude]?.selected, true)
        XCTAssertEqual(byVisibility[.include]?.availability, .picksPeople(count: 0))
        XCTAssertEqual(byVisibility[.include]?.selected, false)
        XCTAssertEqual(result.visibilityOptions.filter(\.selected).count, 1)
    }

    func testMinorModeOnlyOffersFriendsAndOnlyMe() async {
        let source = ConfigSource(minor: true)
        let compose = FeedComposeStore(source: source, articleDrafts: InMemoryFeedArticleDrafts(), clientNonce: "n")
        compose.start()
        await compose.waitForTasks()
        let result = layout(compose)
        XCTAssertEqual(result.visibilityOptions.map(\.visibility), [.friends, .onlyMe])
        XCTAssertEqual(result.visibilityOptions.first(where: \.selected)?.visibility, .friends)
    }

    func testDiscardDraftEntryAppearsOnlyForAnArticleWithContent() async {
        let compose = store()
        compose.onKindChanged(.article)
        XCTAssertFalse(layout(compose).showsDiscardDraft, "空的没什么可放弃")
        compose.onTitleChanged("T")
        XCTAssertTrue(layout(compose).showsDiscardDraft)
        let post = store()
        post.onTextChanged("hello")
        XCTAssertFalse(layout(post).showsDiscardDraft, "动态不自动存，关页面时会问")
        let quoted = store(quote: FeedQuoteTarget(id: "q", authorName: "A", snippet: "x"))
        quoted.onTextChanged("hello")
        XCTAssertFalse(layout(quoted).showsDiscardDraft)
    }

    func testDiscardDraftClearsTheArticleTheSavedCopyAndTheLeftoverFields() async {
        let drafts = InMemoryFeedArticleDrafts()
        let compose = store(drafts: drafts)
        compose.onKindChanged(.article)
        compose.onTitleChanged("Title")
        compose.onTextChanged("Body")
        compose.refreshFeatures(StaticFeedFeatureGate([FeedFeature.audienceTokens]))
        await compose.waitForTasks()
        compose.onAudiencePicked(.include, [FeedAudienceMember(recipientId: 1, aci: "a")])
        XCTAssertEqual(compose.state.draft.audience.count, 1)
        XCTAssertNotNil(drafts.load())
        compose.discardDraft()
        XCTAssertNil(drafts.load(), "本机存的也删了")
        XCTAssertTrue(compose.state.draft.isEmpty)
        XCTAssertEqual(compose.state.draft.visibility, .public)
        XCTAssertEqual(compose.state.draft.audience, [])
        XCTAssertFalse(compose.state.restoredArticle)
        XCTAssertFalse(layout(compose).showsDiscardDraft)
        let reopened = store(drafts: drafts)
        XCTAssertFalse(reopened.state.restoredArticle, "再打开不会接回来")
        XCTAssertEqual(reopened.state.draft.kind, .post)
    }

    func testDiscardDraftKeepsTheQuotedPostAndDoesNothingWhileEditing() async {
        let quote = FeedQuoteTarget(id: "q", authorName: "A", snippet: "x")
        let quoted = store(quote: quote)
        quoted.onTextChanged("hello")
        quoted.discardDraft()
        XCTAssertEqual(quoted.state.draft.quote, quote)
        XCTAssertEqual(quoted.state.draft.text, "")
        let editing = store(edit: FeedEditTarget(id: "p", kind: "post", title: nil, text: "orig", publishedAt: nil))
        editing.onTextChanged("changed")
        editing.discardDraft()
        XCTAssertEqual(editing.state.draft.text, "changed")
        XCTAssertNotNil(editing.state.editing)
    }

    func testDiscardDraftInMinorModeGoesBackToFriends() async {
        let compose = FeedComposeStore(source: ConfigSource(minor: true), articleDrafts: InMemoryFeedArticleDrafts(), clientNonce: "n")
        compose.start()
        await compose.waitForTasks()
        compose.onKindChanged(.article)
        compose.onVisibilityChanged(.onlyMe)
        compose.onTitleChanged("T")
        compose.discardDraft()
        XCTAssertEqual(compose.state.draft.visibility, .friends)
    }

    func testDraftEntryUsesTheTitleThenTheFirstLineAndCountsCharacters() async {
        XCTAssertNil(FeedComposeDraftEntry.make(nil))
        XCTAssertNil(FeedComposeDraftEntry.make(FeedSavedArticle(title: " ", text: "\n ")))
        XCTAssertEqual(FeedComposeDraftEntry.make(FeedSavedArticle(title: " 我的长文 ", text: "正文很长"))?.headline, "我的长文")
        XCTAssertEqual(FeedComposeDraftEntry.make(FeedSavedArticle(title: " 我的长文 ", text: "正文很长"))?.characterCount, 8)
        XCTAssertEqual(FeedComposeDraftEntry.make(FeedSavedArticle(title: "", text: "\n\n  第一行  \n第二行"))?.headline, "第一行")
        XCTAssertEqual(FeedComposeDraftEntry.make(FeedSavedArticle(title: "", text: "只有正文"))?.characterCount, 4)
    }

    func testDraftEntryHeadlineIsCutAtFortyCharacters() async {
        let exact = String(repeating: "字", count: 40)
        XCTAssertEqual(FeedComposeDraftEntry.make(FeedSavedArticle(title: exact, text: ""))?.headline, exact)
        let over = String(repeating: "字", count: 41)
        XCTAssertEqual(FeedComposeDraftEntry.make(FeedSavedArticle(title: over, text: ""))?.headline, exact + "…")
    }
}

private final class ConfigSource: FeedSource, @unchecked Sendable {
    let minor: Bool
    init(minor: Bool) { self.minor = minor }
    func config() async throws -> FeedConfig {
        var config = FeedConfig()
        config.minorMode = minor
        return config
    }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { FeedCreatePostResponse(id: "x", state: "published") }
}

// MARK: - 我的动态里的「编辑」入口 + 样例源的编辑

final class TellomiFeedEditEntryTests: XCTestCase {
    private func row(_ state: String, minutesAgo: Double, kind: String = "post") -> FeedMyPostRow {
        FeedMyPostRow(post: FeedMyPost(id: "x", state: state, kind: kind, title: nil, text: "t", createdAt: FeedDates.format(t0.addingTimeInterval(-minutesAgo * 60))))
    }

    func testEditIsOfferedOnlyInsideTheWindowForPendingAndPublishedPosts() async {
        XCTAssertTrue(row("published", minutesAgo: 5).canEdit(now: t0, windowSeconds: 900))
        XCTAssertTrue(row("pending", minutesAgo: 14.9).canEdit(now: t0, windowSeconds: 900))
        XCTAssertTrue(row("published", minutesAgo: 15).canEdit(now: t0, windowSeconds: 900), "正好 15 分钟还算")
        XCTAssertFalse(row("published", minutesAgo: 15.02).canEdit(now: t0, windowSeconds: 900))
        XCTAssertFalse(row("published", minutesAgo: 5).canEdit(now: t0, windowSeconds: 60), "窗口按 config 的 edit_window_seconds")
        XCTAssertTrue(row("published", minutesAgo: 5).canEdit(now: t0, windowSeconds: 3600))
    }

    func testRejectedWithdrawnUnknownAndCommentsNeverGetEdit() async {
        XCTAssertFalse(row("rejected", minutesAgo: 1).canEdit(now: t0, windowSeconds: 900))
        XCTAssertFalse(row("withdrawn", minutesAgo: 1).canEdit(now: t0, windowSeconds: 900))
        XCTAssertFalse(row("from_the_future", minutesAgo: 1).canEdit(now: t0, windowSeconds: 900))
        XCTAssertFalse(row("published", minutesAgo: 1, kind: "comment").canEdit(now: t0, windowSeconds: 900))
        XCTAssertNil(row("rejected", minutesAgo: 1).editTarget)
        XCTAssertEqual(row("published", minutesAgo: 1, kind: "article").editTarget?.draftKind, .article)
    }

    func testAnUnreadableTimeStillOffersEditAndTheEngineDecides() async {
        let unknown = FeedMyPostRow(post: FeedMyPost(id: "x", state: "published", kind: "post", title: nil, text: "t", createdAt: "garbage"))
        XCTAssertTrue(unknown.canEdit(now: t0, windowSeconds: 900))
    }
}

final class TellomiFeedSampleEditTests: XCTestCase {
    private let clock = Clock(t0)

    private func make() -> SampleFeedSource {
        let clock = self.clock
        return SampleFeedSource(now: { clock.now }, commentsLatencyNanos: 0)
    }

    private func publishOne(_ source: SampleFeedSource, kind: FeedDraftKind = .post, title: String = "", text: String = "first") async throws -> String {
        var draft = FeedDraft()
        draft.kind = kind
        draft.title = title
        draft.text = text
        return try await source.publish(draft: draft, clientNonce: UUID().uuidString).id
    }

    private func edit(_ text: String, kind: FeedDraftKind = .post, title: String = "") -> FeedDraft {
        var draft = FeedDraft()
        draft.kind = kind
        draft.title = title
        draft.text = text
        return draft
    }

    private func status(_ block: () async throws -> Void) async -> (Int, String?)? {
        do {
            try await block()
            return nil
        } catch let error as FeedAPIError {
            return (error.status, error.code)
        } catch {
            return (-1, "\(error)")
        }
    }

    func testEditingAFreshOwnPostChangesTheTextAndMarksItEdited() async throws {
        let source = make()
        let id = try await publishOne(source)
        clock.advance(5 * 60)
        let response = try await source.editPost(contentId: id, draft: edit("  second  "))
        XCTAssertEqual(response.state, "published")
        let card = source.ownLivePosts().first { $0.id == id }
        XCTAssertEqual(card?.text, "second", "首尾空白去掉")
        XCTAssertEqual(card?.edited, true)
    }

    func testEditingAnArticleChangesTheTitleButAPostKeepsItsNil() async throws {
        let source = make()
        let article = try await publishOne(source, kind: .article, title: "Old", text: "body")
        _ = try await source.editPost(contentId: article, draft: edit("new body", kind: .article, title: " New "))
        XCTAssertEqual(source.ownLivePosts().first { $0.id == article }?.title, "New")
        let post = try await publishOne(source)
        _ = try await source.editPost(contentId: post, draft: edit("x", title: "ignored"))
        XCTAssertNil(source.ownLivePosts().first { $0.id == post }?.title)
    }

    func testEditAfterFifteenMinutesIsRefusedWith409AndLeavesThePostAlone() async throws {
        let source = make()
        let id = try await publishOne(source)
        clock.advance(15 * 60)
        _ = try await source.editPost(contentId: id, draft: edit("on time"))
        clock.advance(1)
        let result = await status { _ = try await source.editPost(contentId: id, draft: edit("late")) }
        XCTAssertEqual(result?.0, 409)
        XCTAssertEqual(result?.1, "edit_window_closed")
        XCTAssertEqual(source.ownLivePosts().first { $0.id == id }?.text, "on time")
    }

    func testSeedPendingPostCanBeEditedAndShowsInMyPosts() async throws {
        let source = make()
        _ = try await source.editPost(contentId: "mine-seed-p1", draft: edit("rewritten"))
        let page = try await source.myPosts(before: nil)
        XCTAssertEqual(page.posts.first { $0.id == "mine-seed-p1" }?.text, "rewritten")
        XCTAssertEqual(page.posts.first { $0.id == "mine-seed-p1" }?.state, FeedMyPost.statePending)
    }

    func testSeedRejectedWithdrawnAndOldPublishedPostsCannotBeEdited() async {
        let source = make()
        for (id, code) in [("mine-seed-r1", "not_editable"), ("mine-seed-w1", "not_editable"), ("mine-seed-1", "edit_window_closed")] {
            let result = await status { _ = try await source.editPost(contentId: id, draft: edit("x")) }
            XCTAssertEqual(result?.0, 409, id)
            XCTAssertEqual(result?.1, code, id)
        }
    }

    func testUnknownAndDeletedPostsAre404() async throws {
        let source = make()
        let unknown = await status { _ = try await source.editPost(contentId: "nope", draft: edit("x")) }
        XCTAssertEqual(unknown?.0, 404)
        try await source.deletePost(contentId: "mine-seed-p1")
        let deleted = await status { _ = try await source.editPost(contentId: "mine-seed-p1", draft: edit("x")) }
        XCTAssertEqual(deleted?.0, 404)
    }

    func testEmptyTextAndAnArticleWithoutTitleAre400() async throws {
        let source = make()
        let id = try await publishOne(source, kind: .article, title: "T", text: "b")
        let empty = await status { _ = try await source.editPost(contentId: id, draft: edit("  ", kind: .article, title: "T")) }
        XCTAssertEqual(empty?.0, 400)
        let noTitle = await status { _ = try await source.editPost(contentId: id, draft: edit("b", kind: .article, title: " ")) }
        XCTAssertEqual(noTitle?.1, "invalid_text")
    }

    func testSimulationSwitchesForFailureAndWindowAndNotEditable() async throws {
        let source = make()
        let id = try await publishOne(source)
        source.simulation.failsEdits = true
        let failed = await status { _ = try await source.editPost(contentId: id, draft: edit("x")) }
        XCTAssertEqual(failed?.0, -1)
        source.simulation.failsEdits = false
        source.simulation.editsWindowClosed = true
        let closed = await status { _ = try await source.editPost(contentId: id, draft: edit("x")) }
        XCTAssertEqual(closed?.1, "edit_window_closed")
        source.simulation.editsWindowClosed = false
        source.simulation.editsNotEditable = true
        let notEditable = await status { _ = try await source.editPost(contentId: id, draft: edit("x")) }
        XCTAssertEqual(notEditable?.1, "not_editable")
    }
}
