//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedProfileEditTests.swift (new file)
// I-5 / I-20: FeedProfileEditStore — display name (32) and bio (200) input limit, load, save, error mapping.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

private final class EditLog<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [T]()
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class EditSource: FeedSource, @unchecked Sendable {
    var mine: FeedMyProfile?
    var loadError: Error?
    var saveError: Error?
    let saves = EditLog<FeedProfileUpdate>()

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { FeedCreatePostResponse(id: "x", state: "pending") }
    func myProfile() async throws -> FeedMyProfile? {
        if let loadError { throw loadError }
        return mine
    }
    func saveProfile(_ update: FeedProfileUpdate) async throws -> FeedMyProfile {
        saves.append(update)
        if let saveError { throw saveError }
        var next = mine ?? FeedMyProfile(id: "me", displayName: update.displayName ?? "")
        if let name = update.displayName { next.displayName = name }
        if let bio = update.bio { next.bio = bio }
        mine = next
        return next
    }
}

@MainActor
final class TellomiFeedProfileEditTests: XCTestCase {
    private func make(_ source: EditSource) async -> FeedProfileEditStore {
        let store = FeedProfileEditStore(source: source)
        store.start()
        await store.waitForTasks()
        return store
    }

    private func existing(_ name: String = "Ann", bio: String? = "hi") -> EditSource {
        let source = EditSource()
        var profile = FeedMyProfile(id: "me", displayName: name)
        profile.bio = bio
        source.mine = profile
        return source
    }

    func testTheFourLimitsAreTheEnginesNumbers() {
        XCTAssertEqual(FeedInputLimit.profileName, 32)
        XCTAssertEqual(FeedInputLimit.profileBio, 200)
        XCTAssertEqual(FeedMyProfile.maxNameChars, 32)
        XCTAssertEqual(FeedMyProfile.maxBioChars, 200)
    }

    func testLoadFillsTheFieldsAndAFailedLoadCannotSave() async {
        let store = await make(existing())
        XCTAssertFalse(store.state.loading)
        XCTAssertFalse(store.state.isNew)
        XCTAssertEqual(store.state.name, "Ann")
        XCTAssertEqual(store.state.bio, "hi")
        XCTAssertFalse(store.state.canSave, "没改动不能存")

        let broken = EditSource()
        broken.loadError = FeedAPIError(status: 503, code: nil, retryAfterSeconds: nil)
        let bad = await make(broken)
        XCTAssertTrue(bad.state.loadFailed)
        bad.onNameChanged("X")
        XCTAssertFalse(bad.state.canSave, "读不到自己的主页时不让存")
    }

    func testTheNameBlocksTypingAtThirtyTwoAndCountsDown() async {
        let store = await make(EditSource())
        XCTAssertTrue(store.state.isNew)
        XCTAssertEqual(store.state.nameRemaining, 32)
        store.onNameChanged(String(repeating: "n", count: 31))
        XCTAssertEqual(store.state.nameRemaining, 1)
        let last = store.onNameEdit(range: NSRange(location: 31, length: 0), replacement: "z")
        XCTAssertTrue(last.accepted)
        XCTAssertEqual(store.state.nameRemaining, 0)
        XCTAssertFalse(store.state.nameLimitHit)
        let blocked = store.onNameEdit(range: NSRange(location: 32, length: 0), replacement: "q")
        XCTAssertTrue(blocked.blocked)
        XCTAssertEqual(store.state.name.count, 32)
        XCTAssertTrue(store.state.nameLimitHit)
        let del = store.onNameEdit(range: NSRange(location: 31, length: 1), replacement: "")
        XCTAssertTrue(del.accepted)
        XCTAssertEqual(store.state.nameRemaining, 1)
        XCTAssertFalse(store.state.nameLimitHit)
    }

    func testAPastedNameIsClippedByCodePointNeverSplittingACharacter() async {
        let store = await make(EditSource())
        store.onNameChanged(String(repeating: "a", count: 29))
        let paste = store.onNameEdit(range: NSRange(location: 29, length: 0), replacement: "🇨🇳🇨🇳")   // 4 个码点，只剩 3
        XCTAssertTrue(paste.clipped)
        XCTAssertEqual(store.state.name, String(repeating: "a", count: 29) + "🇨🇳", "放不下的第二面旗整个不要")
        XCTAssertEqual(store.state.nameRemaining, 1)
        store.onNameChanged(String(repeating: "👨‍👩‍👧‍👦", count: 5))   // 每个 7 个码点
        XCTAssertEqual(store.state.name, String(repeating: "👨‍👩‍👧‍👦", count: 4), "4×7=28，第 5 个放不下")
        // 选中一段替换：腾出的位置可以用
        store.onNameChanged(String(repeating: "b", count: 32))
        let swap = store.onNameEdit(range: NSRange(location: 0, length: 5), replacement: "12345678")
        XCTAssertTrue(swap.clipped)
        XCTAssertEqual(store.state.name, "12345" + String(repeating: "b", count: 27))
    }

    func testTheBioBlocksAtTwoHundredAndClipsAPaste() async {
        let store = await make(EditSource())
        XCTAssertEqual(store.state.bioRemaining, 200)
        store.onBioChanged(String(repeating: "x", count: 198))
        let paste = store.onBioEdit(range: NSRange(location: 198, length: 0), replacement: "😀😀😀😀")
        XCTAssertTrue(paste.clipped)
        XCTAssertEqual(store.state.bio, String(repeating: "x", count: 198) + "😀😀")
        XCTAssertEqual(store.state.bioRemaining, 0)
        let blocked = store.onBioEdit(range: NSRange(location: store.state.bio.utf16.count, length: 0), replacement: "y")
        XCTAssertTrue(blocked.blocked)
        XCTAssertTrue(store.state.bioLimitHit)
        store.onBioChanged(String(repeating: "👍🏽", count: 150))   // 每个 2 个码点
        XCTAssertEqual(store.state.bio, String(repeating: "👍🏽", count: 100))
        XCTAssertEqual(store.state.nameRemaining, 32, "两个框互不影响")
    }

    func testComposingTextIsLetThroughAndCannotBeSavedUntilClipped() async {
        let source = existing()
        let store = await make(source)
        store.onNameChanged(String(repeating: "拼", count: 32))
        let marked = store.onNameEdit(range: NSRange(location: 32, length: 0), replacement: "pin", composing: true)
        XCTAssertTrue(marked.accepted)
        XCTAssertEqual(store.state.nameRemaining, -3)
        XCTAssertFalse(store.state.canSave)
        store.save()
        await store.waitForTasks()
        XCTAssertEqual(source.saves.all.count, 0)
        store.onNameChanged(store.state.name)   // 拼完
        XCTAssertEqual(store.state.nameRemaining, 0)
        XCTAssertTrue(store.state.canSave)
        let bioMarked = store.onBioEdit(range: NSRange(location: 2, length: 0), replacement: String(repeating: "p", count: 250), composing: true)
        XCTAssertTrue(bioMarked.accepted)
        XCTAssertFalse(store.state.canSave, "简介拼写中超了也不能存")
    }

    func testSavingANewProfileSendsTheNameAndOnlyTheNameWhenTheBioIsEmpty() async {
        let source = EditSource()
        let store = await make(source)
        XCTAssertFalse(store.state.canSave, "名字必填")
        store.onNameChanged("  Bob  ")
        XCTAssertTrue(store.state.canSave)
        store.save()
        store.save()
        await store.waitForTasks()
        XCTAssertEqual(source.saves.all, [FeedProfileUpdate(displayName: "Bob")])
        XCTAssertTrue(store.state.saved)
        XCTAssertFalse(store.state.isNew)
        XCTAssertFalse(store.state.canSave)
    }

    func testSavingAnExistingProfileSendsOnlyWhatChangedAndAClearedBioIsSentEmpty() async {
        let source = existing()
        let store = await make(source)
        store.onBioChanged("")
        XCTAssertTrue(store.state.canSave)
        store.save()
        await store.waitForTasks()
        XCTAssertEqual(source.saves.all, [FeedProfileUpdate(bio: "")], "名字没改就不发；清空简介要发空串，nil 是不变")
        store.onNameChanged("Anna")
        store.save()
        await store.waitForTasks()
        XCTAssertEqual(source.saves.all.last, FeedProfileUpdate(displayName: "Anna"))
        XCTAssertEqual(store.state.name, "Anna")
    }

    func testEngineErrorsAreMappedAndTypingClearsThem() async {
        let source = existing()
        let store = await make(source)
        store.onNameChanged("Zed")
        source.saveError = FeedAPIError(status: 400, code: "display_name_required", retryAfterSeconds: nil)
        store.save()
        await store.waitForTasks()
        XCTAssertTrue(store.state.nameRequired)
        XCTAssertFalse(store.state.failed)
        XCTAssertFalse(store.state.saving)
        store.onNameChanged("Zee")
        XCTAssertFalse(store.state.nameRequired)
        source.saveError = FeedAPIError(status: 400, code: "invalid_field", retryAfterSeconds: nil)
        store.save()
        await store.waitForTasks()
        XCTAssertTrue(store.state.invalidField)
        source.saveError = FeedAPIError(status: 500, code: nil, retryAfterSeconds: nil)
        store.save()
        await store.waitForTasks()
        XCTAssertTrue(store.state.failed)
        XCTAssertTrue(store.state.hasUnsavedChanges)
    }
}
