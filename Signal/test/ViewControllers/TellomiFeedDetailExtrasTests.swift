//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

// 详情页补全（`TellomiFeed.isDetailExtrasEnabled`）的逻辑：额外的行、等批准的回复、语音播放、媒体地址、「编辑」菜单项、定位到评论、通知点进来的评论 id、样例来源。

private func comment(_ id: String, parent: String? = nil, held: Bool = false) -> FeedCard {
    var card = FeedCard(id: id, kind: FeedCard.kindComment, text: id)
    card.rootId = "p"
    card.parentId = parent
    card.held = held
    return card
}

private func post(author: Bool = false, shareable: Bool = false, poll: Bool = false, kind: String = FeedCard.kindPost) -> FeedCard {
    var card = FeedCard(id: "p", kind: kind, text: "hello", viewer: FeedViewer(isAuthor: author))
    card.shareable = shareable
    if poll { card.poll = FeedPoll(options: ["a", "b"], closesAt: nil, multi: false) }
    return card
}

// MARK: - 额外的行、待批准、语音评论

final class TellomiFeedDetailExtraRowsTests: XCTestCase {
    func testPollThenActionsInThatOrder() {
        XCTAssertEqual(FeedPostDetailPresentation.extraRows(for: post(shareable: true, poll: true), saveAvailable: false), [.poll, .actions])
        XCTAssertEqual(FeedPostDetailPresentation.extraRows(for: post(poll: true), saveAvailable: false), [.poll])
        XCTAssertEqual(FeedPostDetailPresentation.extraRows(for: post(shareable: true), saveAvailable: false), [.actions])
        XCTAssertEqual(FeedPostDetailPresentation.extraRows(for: post(), saveAvailable: false), [])
    }

    func testSaveAloneIsEnoughForTheActionsRowButOnlyWhenItCanWork() {
        XCTAssertEqual(FeedPostDetailPresentation.extraRows(for: post(), saveAvailable: true), [.actions])
        let actions = FeedPostDetailPresentation.actions(for: post(), saveAvailable: true)
        XCTAssertEqual(actions, FeedDetailActions(repost: false, reposted: false, save: true, saved: false))
        XCTAssertNil(FeedPostDetailPresentation.actions(for: post(), saveAvailable: false))
    }

    func testRepostNeedsAShareablePostAndIsNeverOnAComment() {
        XCTAssertEqual(FeedPostDetailPresentation.actions(for: post(shareable: true), saveAvailable: false)?.repost, true)
        var shared = comment("c")
        shared.shareable = true
        shared.poll = FeedPoll(options: ["a"], closesAt: nil, multi: false)
        XCTAssertNil(FeedPostDetailPresentation.actions(for: shared, saveAvailable: false))
        XCTAssertEqual(FeedPostDetailPresentation.extraRows(for: shared, saveAvailable: false), [])
    }

    func testSaveIsOffWhenItCannotWorkEvenWithARepostButton() {
        var card = post(shareable: true)
        card.viewer.saved = true
        let actions = FeedPostDetailPresentation.actions(for: card, saveAvailable: false)
        XCTAssertEqual(actions, FeedDetailActions(repost: true, reposted: false, save: false, saved: true))
    }

    func testRepostedAndSavedAreNotMixedUp() {
        var card = post(shareable: true)
        card.viewer.reposted = true
        XCTAssertEqual(FeedPostDetailPresentation.actions(for: card, saveAvailable: true), FeedDetailActions(repost: true, reposted: true, save: true, saved: false))
        card.viewer.reposted = false
        card.viewer.saved = true
        XCTAssertEqual(FeedPostDetailPresentation.actions(for: card, saveAvailable: true), FeedDetailActions(repost: true, reposted: false, save: true, saved: true))
    }

    func testTheButtonsShowTheViewersState() {
        var card = post(shareable: true)
        card.viewer.reposted = true
        card.viewer.saved = true
        XCTAssertEqual(FeedPostDetailPresentation.actions(for: card, saveAvailable: true), FeedDetailActions(repost: true, reposted: true, save: true, saved: true))
    }

    func testAnArticleGetsTheSameRows() {
        XCTAssertEqual(FeedPostDetailPresentation.extraRows(for: post(shareable: true, kind: FeedCard.kindArticle), saveAvailable: false), [.actions])
    }
}

final class TellomiFeedDetailModerationTests: XCTestCase {
    func testTheAuthorSeesApproveAndDeclineAndTheWriterSeesWaiting() {
        let held = comment("c", held: true)
        XCTAssertEqual(FeedPostDetailPresentation.moderation(of: held, post: post(author: true)), .forYou)
        XCTAssertEqual(FeedPostDetailPresentation.moderation(of: held, post: post(author: false)), .waiting)
    }

    func testAPublicCommentHasNothingEvenForTheAuthor() {
        XCTAssertEqual(FeedPostDetailPresentation.moderation(of: comment("c"), post: post(author: true)), .nothing)
        XCTAssertEqual(FeedPostDetailPresentation.moderation(of: comment("c"), post: post(author: false)), .nothing)
    }

    func testVoiceIsTheFirstAudioAndImagesAreNotVoice() {
        var voice = comment("v")
        var audio = FeedMedia(key: "a.m4a")
        audio.type = FeedMedia.typeAudio
        audio.durationMs = 4000
        voice.media = [FeedMedia(key: "i.jpg"), audio]
        XCTAssertEqual(FeedPostDetailPresentation.voice(of: voice)?.key, "a.m4a")
        voice.media = [FeedMedia(key: "i.jpg")]
        XCTAssertNil(FeedPostDetailPresentation.voice(of: voice))
        XCTAssertNil(FeedPostDetailPresentation.voice(of: comment("t")))
    }

    func testRowIndexOfAComment() {
        var state = FeedPostDetailState(post: post())
        state.comments = [comment("a"), comment("b"), comment("a1", parent: "a")]
        let rows = FeedPostDetailPresentation.commentRows(for: state)
        XCTAssertEqual(rows.map(\.comment.id), ["a", "a1", "b"])
        XCTAssertEqual(FeedPostDetailPresentation.index(ofComment: "a1", in: rows), 1)
        XCTAssertEqual(FeedPostDetailPresentation.index(ofComment: "b", in: rows), 2)
        XCTAssertNil(FeedPostDetailPresentation.index(ofComment: "zzz", in: rows))
    }

    func testExtrasInstantiatedFromAComment() {
        var voice = comment("v", held: true)
        var audio = FeedMedia(key: "a.m4a")
        audio.type = FeedMedia.typeAudio
        voice.media = [audio]
        let extras = FeedCommentExtras(comment: voice, post: post(author: true), highlighted: true)
        XCTAssertEqual(extras.moderation, .forYou)
        XCTAssertEqual(extras.voice?.key, "a.m4a")
        XCTAssertTrue(extras.highlighted)
    }

    func testBodyAndTranscriptOfAVoiceComment() {
        var voice = FeedCard(id: "v", kind: FeedCard.kindComment, text: nil)
        voice.transcript = "  said this "
        // 有语音那一行：转写放在语音下面，正文不再用转写顶替；没有语音那一行（补全关着）：转写顶替正文，和以前一样
        XCTAssertNil(FeedCommentExtras.bodyText(of: voice, hasVoiceRow: true))
        XCTAssertEqual(FeedCommentExtras.bodyText(of: voice, hasVoiceRow: false), "  said this ")
        XCTAssertEqual(FeedCommentExtras.transcript(of: voice), "  said this ")
        voice.text = "typed"
        XCTAssertEqual(FeedCommentExtras.bodyText(of: voice, hasVoiceRow: true), "typed")
        voice.transcript = "   "
        XCTAssertNil(FeedCommentExtras.transcript(of: voice))
        voice.text = "  "
        XCTAssertNil(FeedCommentExtras.bodyText(of: voice, hasVoiceRow: true))
    }
}

// MARK: - 媒体地址、时长

final class TellomiFeedMediaURLTests: XCTestCase {
    func testAKeyIsAppendedToAnHttpsBaseThatEndsWithASlash() {
        XCTAssertEqual(FeedMediaURL.remote(key: "v/1.m4a", baseUrl: "https://m.example/")?.absoluteString, "https://m.example/v/1.m4a")
    }

    func testTheBaseMustBeHttpsAndEndWithASlash() {
        XCTAssertNil(FeedMediaURL.remote(key: "a", baseUrl: nil))
        XCTAssertNil(FeedMediaURL.remote(key: "a", baseUrl: "http://m.example/"))
        XCTAssertNil(FeedMediaURL.remote(key: "a", baseUrl: "https://m.example"))
    }

    func testAKeyThatCouldLeaveTheBaseIsRefused() {
        let base = "https://m.example/"
        XCTAssertNil(FeedMediaURL.remote(key: "", baseUrl: base))
        XCTAssertNil(FeedMediaURL.remote(key: "   ", baseUrl: base))
        XCTAssertNil(FeedMediaURL.remote(key: "https://evil.example/a", baseUrl: base))
        XCTAssertNil(FeedMediaURL.remote(key: "/abs", baseUrl: base))
        XCTAssertNil(FeedMediaURL.remote(key: "a/../b", baseUrl: base))
        XCTAssertNil(FeedMediaURL.remote(key: "..", baseUrl: base))
        XCTAssertNotNil(FeedMediaURL.remote(key: "a/..b/c", baseUrl: base), "两个点只在整段是 .. 时才算")
    }

    func testOnlyFileUrlsPlayStraightFromTheKey() {
        for key in ["http://evil.example/a.m4a", "https://evil.example/a.m4a", "ftp://x/a"] {
            var media = FeedMedia(key: key)
            media.type = FeedMedia.typeAudio
            XCTAssertNil(FeedMediaURL.playback(for: media, baseUrl: "https://m.example/"), key)
            XCTAssertNil(FeedMediaURL.playback(for: media, baseUrl: nil), key)
        }
    }

    func testALocalFileKeyPlaysFromTheFile() {
        var local = FeedMedia(key: "file:///tmp/a.m4a")
        local.type = FeedMedia.typeAudio
        XCTAssertEqual(FeedMediaURL.playback(for: local, baseUrl: nil)?.path, "/tmp/a.m4a")
        let remote = FeedMedia(key: "v/1.m4a")
        XCTAssertEqual(FeedMediaURL.playback(for: remote, baseUrl: "https://m.example/")?.absoluteString, "https://m.example/v/1.m4a")
        XCTAssertNil(FeedMediaURL.playback(for: remote, baseUrl: nil))
    }
}

final class TellomiFeedVoicePlaybackStateTests: XCTestCase {
    private func media(_ key: String = "k", ms: Int = 4000) -> FeedMedia {
        var media = FeedMedia(key: key)
        media.type = FeedMedia.typeAudio
        media.durationMs = ms
        return media
    }

    func testANegativeDurationShowsZero() {
        XCTAssertEqual(FeedVoiceDuration.format(-1000), "0:00")
        XCTAssertEqual(FeedVoiceDuration.format(-61_000), "0:00")
    }

    func testDurationFormat() {
        XCTAssertEqual(FeedVoiceDuration.format(0), "0:00")
        XCTAssertEqual(FeedVoiceDuration.format(999), "0:00")
        XCTAssertEqual(FeedVoiceDuration.format(4000), "0:04")
        XCTAssertEqual(FeedVoiceDuration.format(60_000), "1:00")
        XCTAssertEqual(FeedVoiceDuration.format(754_000), "12:34")
        XCTAssertEqual(FeedVoiceDuration.format(-5), "0:00")
    }

    func testProgressIsOnlyForTheActiveOneAndClamped() {
        let state = FeedVoicePlayback(key: "k", playing: true, positionMs: 1000)
        XCTAssertEqual(state.progress(for: media("k")), 0.25, accuracy: 0.0001)
        XCTAssertEqual(state.progress(for: media("other")), 0)
        XCTAssertEqual(state.progress(for: media("k", ms: 0)), 0)
        XCTAssertEqual(FeedVoicePlayback(key: "k", positionMs: 9999).progress(for: media("k")), 1)
        XCTAssertEqual(FeedVoicePlayback(key: "k", positionMs: -5).progress(for: media("k")), 0)
    }

    func testShownTimeIsTheTotalUntilItStartsThenThePosition() {
        XCTAssertEqual(FeedVoicePlayback().shownMs(for: media()), 4000)
        XCTAssertEqual(FeedVoicePlayback(key: "k", loading: true).shownMs(for: media()), 4000)
        XCTAssertEqual(FeedVoicePlayback(key: "k", playing: true, positionMs: 1500).shownMs(for: media()), 1500)
        XCTAssertEqual(FeedVoicePlayback(key: "x", playing: true, positionMs: 1500).shownMs(for: media()), 4000)
    }
}

// MARK: - 语音播放器（假的 loader / clip）

@MainActor
private final class FakeClip: FeedVoiceClip {
    var onPosition: ((Int) -> Void)?
    var onFinished: (() -> Void)?
    private(set) var plays = 0
    private(set) var pauses = 0
    private(set) var stops = 0
    func play() { plays += 1 }
    func pause() { pauses += 1 }
    func stop() { stops += 1 }
}

private struct VoiceBoom: Error {}

/// 每次 `load` 都等外面放行（`release(url)`）或失败（`fail(url)`），这样能卡在「加载中」。
@MainActor
private final class FakeLoader: FeedVoiceLoader {
    private(set) var requested = [URL]()
    private(set) var clips = [FakeClip]()
    private var waiting = [URL: CheckedContinuation<FeedVoiceClip, Error>]()
    var immediate = false
    var failImmediately = false

    func load(url: URL) async throws -> FeedVoiceClip {
        requested.append(url)
        if failImmediately { throw VoiceBoom() }
        if immediate {
            let clip = FakeClip()
            clips.append(clip)
            return clip
        }
        return try await withCheckedThrowingContinuation { waiting[url] = $0 }
    }

    func finishLoading(_ url: URL) {
        let clip = FakeClip()
        clips.append(clip)
        waiting.removeValue(forKey: url)?.resume(returning: clip)
    }

    func failLoading(_ url: URL) {
        waiting.removeValue(forKey: url)?.resume(throwing: VoiceBoom())
    }
}

@MainActor
final class TellomiFeedVoicePlayerTests: XCTestCase {
    private let base = "https://m.example/"

    private func media(_ key: String, ms: Int = 4000) -> FeedMedia {
        var media = FeedMedia(key: key)
        media.type = FeedMedia.typeAudio
        media.durationMs = ms
        return media
    }

    private func url(_ key: String) -> URL { URL(string: base + key)! }

    private func make(_ loader: FakeLoader) -> FeedVoicePlayer {
        return FeedVoicePlayer(loader: loader, baseUrl: { "https://m.example/" })
    }

    private func spin() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testTappingPlaysAfterLoadingAndReportsEachStep() async {
        let loader = FakeLoader()
        let player = make(loader)
        var seen = [FeedVoicePlayback]()
        player.onChange = { seen.append($0) }

        player.toggle(media("a"))
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "a", loading: true))
        await spin()
        XCTAssertEqual(loader.requested, [url("a")])
        loader.finishLoading(url("a"))
        await player.waitForLoad()

        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "a", playing: true))
        XCTAssertEqual(loader.clips[0].plays, 1)
        XCTAssertEqual(seen, [FeedVoicePlayback(key: "a", loading: true), FeedVoicePlayback(key: "a", playing: true)])
    }

    func testTappingThePlayingOneAgainPausesAndAgainResumesWithoutReloading() async {
        let loader = FakeLoader()
        loader.immediate = true
        let player = make(loader)
        player.toggle(media("a"))
        await player.waitForLoad()

        player.toggle(media("a"))
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "a", playing: false))
        XCTAssertEqual(loader.clips[0].pauses, 1)
        player.toggle(media("a"))
        XCTAssertEqual(player.playback.playing, true)
        XCTAssertEqual(loader.clips[0].plays, 2)
        XCTAssertEqual(loader.requested.count, 1)
    }

    func testTappingWhileItIsStillLoadingDoesNothing() async {
        let loader = FakeLoader()
        let player = make(loader)
        player.toggle(media("a"))
        await spin()
        player.toggle(media("a"))
        await spin()
        XCTAssertEqual(loader.requested.count, 1)
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "a", loading: true))
        loader.finishLoading(url("a"))
        await player.waitForLoad()
        XCTAssertTrue(player.playback.playing)
    }

    func testTappingAnotherOneStopsTheCurrentOne() async {
        let loader = FakeLoader()
        loader.immediate = true
        let player = make(loader)
        player.toggle(media("a"))
        await player.waitForLoad()
        player.toggle(media("b"))
        XCTAssertEqual(loader.clips[0].stops, 1)
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "b", loading: true))
        await player.waitForLoad()
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "b", playing: true))
        XCTAssertEqual(loader.clips[1].plays, 1)
    }

    func testAnOlderSlowLoadNeverTakesOverFromANewerTap() async {
        let loader = FakeLoader()
        let player = make(loader)
        player.toggle(media("a"))
        await spin()
        player.toggle(media("b"))
        await spin()
        loader.finishLoading(url("b"))
        await player.waitForLoad()
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "b", playing: true))
        // a 这时才下完：不能出声，也不能改状态；它的 clip 被放掉
        loader.finishLoading(url("a"))
        await spin()
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "b", playing: true))
        let staleClip = loader.clips[1]
        XCTAssertEqual(staleClip.plays, 0)
        XCTAssertEqual(staleClip.stops, 1)
    }

    func testAnOlderLoadThatFailsLateDoesNotMarkItselfFailedOrDisturbTheNewerOne() async {
        let loader = FakeLoader()
        let player = make(loader)
        player.toggle(media("a"))
        await spin()
        player.toggle(media("b"))
        await spin()
        loader.failLoading(url("a"))
        await spin()
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "b", loading: true))
        loader.finishLoading(url("b"))
        await player.waitForLoad()
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "b", playing: true))
        XCTAssertNil(player.playback.failedKey)
    }

    func testPositionUpdatesAreForwardedAndFinishingGoesBackToIdle() async {
        let loader = FakeLoader()
        loader.immediate = true
        let player = make(loader)
        player.toggle(media("a"))
        await player.waitForLoad()
        loader.clips[0].onPosition?(1200)
        XCTAssertEqual(player.playback.positionMs, 1200)
        loader.clips[0].onFinished?()
        XCTAssertEqual(player.playback, FeedVoicePlayback())
        XCTAssertEqual(loader.clips[0].stops, 1)
    }

    func testAFinishedClipThatWasReplacedDoesNotResetTheNewOne() async {
        let loader = FakeLoader()
        loader.immediate = true
        let player = make(loader)
        player.toggle(media("a"))
        await player.waitForLoad()
        let first = loader.clips[0]
        player.toggle(media("b"))
        await player.waitForLoad()
        first.onFinished?()
        first.onPosition?(777)
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "b", playing: true))
    }

    func testALoadFailureMarksThatOneFailedAndATapTriesAgain() async {
        let loader = FakeLoader()
        loader.failImmediately = true
        let player = make(loader)
        player.toggle(media("a"))
        await player.waitForLoad()
        XCTAssertEqual(player.playback, FeedVoicePlayback(failedKey: "a"))
        loader.failImmediately = false
        loader.immediate = true
        player.toggle(media("a"))
        await player.waitForLoad()
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "a", playing: true))
        XCTAssertEqual(loader.requested.count, 2)
    }

    func testNoUsableAddressFailsWithoutLoading() async {
        let loader = FakeLoader()
        let player = FeedVoicePlayer(loader: loader, baseUrl: { nil })
        player.toggle(media("a"))
        XCTAssertEqual(player.playback, FeedVoicePlayback(failedKey: "a"))
        XCTAssertEqual(loader.requested, [])
        let bad = FeedVoicePlayer(loader: loader, baseUrl: { "https://m.example/" })
        bad.toggle(media("../x"))
        XCTAssertEqual(bad.playback, FeedVoicePlayback(failedKey: "../x"))
    }

    func testPauseOnlyPausesAPlayingClipAndKeepsItForResume() async {
        let loader = FakeLoader()
        loader.immediate = true
        let player = make(loader)
        player.pause()
        XCTAssertEqual(player.playback, FeedVoicePlayback())
        player.toggle(media("a"))
        await player.waitForLoad()
        player.pause()
        XCTAssertEqual(player.playback, FeedVoicePlayback(key: "a", playing: false))
        XCTAssertEqual(loader.clips[0].pauses, 1)
        player.pause()
        XCTAssertEqual(loader.clips[0].pauses, 1, "已经暂停了不再暂停")
        XCTAssertEqual(loader.clips[0].stops, 0)
    }

    func testReleaseStopsEverythingAndALateLoadStaysSilent() async {
        let loader = FakeLoader()
        let player = make(loader)
        player.toggle(media("a"))
        await spin()
        player.release()
        XCTAssertEqual(player.playback, FeedVoicePlayback())
        loader.finishLoading(url("a"))
        await spin()
        XCTAssertEqual(player.playback, FeedVoicePlayback())
        XCTAssertEqual(loader.clips[0].plays, 0)
        XCTAssertEqual(loader.clips[0].stops, 1)

        loader.immediate = true
        player.toggle(media("b"))
        await player.waitForLoad()
        player.release()
        XCTAssertEqual(loader.clips[1].stops, 1)
        XCTAssertEqual(player.playback, FeedVoicePlayback())
    }
}

// MARK: - 「编辑」菜单项

final class TellomiFeedDetailEditMenuTests: XCTestCase {
    func testTheAuthorGetsEditFirstAndOthersNeverDo() {
        let mine = post(author: true)
        XCTAssertEqual(FeedDetailMenu.items(forPost: mine, canEdit: true).first, .edit)
        XCTAssertEqual(FeedDetailMenu.items(forPost: mine, canEdit: true).last, .deletePost)
        XCTAssertFalse(FeedDetailMenu.items(forPost: mine, canEdit: false).contains(.edit))
        XCTAssertFalse(FeedDetailMenu.items(forPost: mine).contains(.edit))
        XCTAssertFalse(FeedDetailMenu.items(forPost: post(author: false), canEdit: true).contains(.edit))
    }

    func testEditIsShownAndNeedsNoConfirmation() {
        XCTAssertEqual(FeedDetailMenu.shown([.edit, .deletePost], reportAvailable: false), [.edit, .deletePost])
        XCTAssertFalse(FeedDetailMenuItem.edit.isDestructive)
        XCTAssertFalse(FeedDetailMenuItem.edit.needsConfirmation)
        XCTAssertNil(FeedDetailMenuItem.edit.confirmationTitleKey)
        XCTAssertEqual(FeedDetailMenuItem.edit.titleKey, "TELLOMI_FEED_MINE_EDIT")
    }

    func testEditIsNotOfferedOnComments() {
        var mine = comment("c")
        mine.viewer.isAuthor = true
        XCTAssertEqual(FeedDetailMenu.items(forComment: mine), [.deleteComment])
    }
}

// MARK: - store：能不能编辑、定位到评论

private final class PagedSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _pages = [String: FeedCommentsPage]()
    private var _cursors = [String?]()
    var failFirst = false
    var failCursor: String?
    var pages: [String: FeedCommentsPage] {
        get { lock.lock(); defer { lock.unlock() }; return _pages }
        set { lock.lock(); _pages = newValue; lock.unlock() }
    }
    var cursors: [String?] { lock.lock(); defer { lock.unlock() }; return _cursors }

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw VoiceBoom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
    func card(contentId: String) async throws -> FeedCard? { nil }

    func comments(postId: String, cursor: String?) async throws -> FeedCommentsPage {
        let page = lock.withLock { () -> FeedCommentsPage? in
            _cursors.append(cursor)
            return _pages[cursor ?? ""]
        }
        if cursor == nil, failFirst { throw VoiceBoom() }
        if let failCursor, cursor == failCursor { throw VoiceBoom() }
        return page ?? FeedCommentsPage()
    }
}

@MainActor
final class TellomiFeedDetailEditStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(minutesAgo: Double, author: Bool = true, kind: String = FeedCard.kindPost, text: String? = "hello", enabled: Bool = true, window: Int = 900) -> FeedPostDetailState {
        var card = FeedCard(id: "p", kind: kind, publishedAt: FeedDates.format(now.addingTimeInterval(-minutesAgo * 60)), text: text, viewer: FeedViewer(isAuthor: author))
        card.viewer.isAuthor = author
        var state = FeedPostDetailState(post: card)
        state.editEnabled = enabled
        state.editWindowSeconds = window
        state.now = { [now] in now }
        return state
    }

    func testOnlyInsideTheWindowForTheAuthorWithTheSwitchOn() async {
        XCTAssertTrue(state(minutesAgo: 5).canEditPost)
        XCTAssertTrue(state(minutesAgo: 15).canEditPost, "刚好 15 分钟还能改（和我的动态页同一个判断）")
        XCTAssertFalse(state(minutesAgo: 16).canEditPost)
        XCTAssertFalse(state(minutesAgo: 5, author: false).canEditPost)
        XCTAssertFalse(state(minutesAgo: 5, enabled: false).canEditPost)
    }

    func testTheWindowComesFromTheEngineConfig() async {
        XCTAssertFalse(state(minutesAgo: 5, window: 60).canEditPost)
        XCTAssertTrue(state(minutesAgo: 20, window: 3600).canEditPost)
    }

    func testAnArticleWithoutItsBodyYetCannotBeEdited() async {
        XCTAssertFalse(state(minutesAgo: 1, kind: FeedCard.kindArticle, text: nil).canEditPost)
        XCTAssertFalse(state(minutesAgo: 1, kind: FeedCard.kindArticle, text: "  \n").canEditPost)
        XCTAssertTrue(state(minutesAgo: 1, kind: FeedCard.kindArticle, text: "body").canEditPost)
        XCTAssertTrue(state(minutesAgo: 1, kind: FeedCard.kindPost, text: nil).canEditPost, "只有图片的短帖可以改（正文本来就可以是空的）")
    }

    func testCommentsAndOtherKindsCannotBeEdited() async {
        XCTAssertFalse(state(minutesAgo: 1, kind: FeedCard.kindComment).canEditPost)
    }

    func testThePostMenuFollowsIt() async {
        XCTAssertEqual(state(minutesAgo: 5).postMenu.first, .edit)
        XCTAssertFalse(state(minutesAgo: 50).postMenu.contains(.edit))
    }

    func testTheStoreTakesTheSwitchAndTheClock() async {
        let card = FeedCard(id: "p", publishedAt: FeedDates.format(now.addingTimeInterval(-60)), text: "x", viewer: FeedViewer(isAuthor: true))
        let on = FeedPostDetailStore(initial: card, source: PagedSource(), editEnabled: true, now: { [now] in now })
        XCTAssertTrue(on.state.canEditPost)
        let off = FeedPostDetailStore(initial: card, source: PagedSource(), now: { [now] in now })
        XCTAssertFalse(off.state.canEditPost)
        // 注入的时钟真的用上了：发布在 20 分钟前，按注入的时钟就过了窗口（用系统时钟这条在「未来」，会被当成还在窗口里）
        let old = FeedCard(id: "p", publishedAt: FeedDates.format(now.addingTimeInterval(-20 * 60)), text: "x", viewer: FeedViewer(isAuthor: true))
        let late = FeedPostDetailStore(initial: old, source: PagedSource(), editEnabled: true, now: { [now] in now })
        XCTAssertFalse(late.state.canEditPost)
    }
}

@MainActor
final class TellomiFeedDetailLocateCommentTests: XCTestCase {
    private let post = FeedCard(id: "p", text: "hello", viewer: FeedViewer(isAuthor: true))

    private func page(_ ids: [String], next: String?) -> FeedCommentsPage {
        return FeedCommentsPage(comments: ids.map { comment($0) }, cursor: next)
    }

    func testACommentOnTheFirstPageIsFoundWithoutFetchingMore() async {
        let source = PagedSource()
        source.pages = ["": page(["a", "b"], next: "n1"), "n1": page(["c"], next: nil)]
        let store = FeedPostDetailStore(initial: post, source: source)
        store.start()
        store.locateComment("b")
        await store.waitForTasks()
        XCTAssertEqual(store.state.scrollTarget, "b")
        XCTAssertNil(store.state.focusCommentId)
        XCTAssertEqual(source.cursors, [nil], "没有多翻页")
        XCTAssertNil(store.state.notice)
    }

    func testItKeepsTurningPagesUntilTheCommentShowsUp() async {
        let source = PagedSource()
        source.pages = ["": page(["a"], next: "n1"), "n1": page(["b"], next: "n2"), "n2": page(["target", "z"], next: "n3"), "n3": page(["never"], next: nil)]
        let store = FeedPostDetailStore(initial: post, source: source)
        store.start()
        store.locateComment("target")
        await store.waitForTasks()
        XCTAssertEqual(store.state.scrollTarget, "target")
        XCTAssertEqual(source.cursors, [nil, "n1", "n2"], "找到就停，不再翻 n3")
        XCTAssertEqual(store.state.comments.map(\.id), ["a", "b", "target", "z"])
    }

    func testAskingAfterTheFirstPageIsAlreadyThereStillWorks() async {
        let source = PagedSource()
        source.pages = ["": page(["a"], next: "n1"), "n1": page(["target"], next: nil)]
        let store = FeedPostDetailStore(initial: post, source: source)
        store.start()
        await store.waitForTasks()
        store.locateComment("target")
        await store.waitForTasks()
        XCTAssertEqual(store.state.scrollTarget, "target")
        store.locateComment("a")
        XCTAssertEqual(store.state.scrollTarget, "a", "已经加载的立刻定位，不用等")
    }

    func testAMissingCommentEndsWithANoticeWhenThePagesRunOut() async {
        let source = PagedSource()
        source.pages = ["": page(["a"], next: "n1"), "n1": page(["b"], next: nil)]
        let store = FeedPostDetailStore(initial: post, source: source)
        store.start()
        store.locateComment("gone")
        await store.waitForTasks()
        XCTAssertNil(store.state.scrollTarget)
        XCTAssertNil(store.state.focusCommentId)
        XCTAssertEqual(store.state.notice, .commentNotFound)
        XCTAssertEqual(source.cursors, [nil, "n1"])
    }

    func testItGivesUpAfterTheMaximumNumberOfExtraPages() async {
        let source = PagedSource()
        var pages = ["": page(["c0"], next: "n1")]
        for i in 1...30 { pages["n\(i)"] = page(["c\(i)"], next: "n\(i + 1)") }
        source.pages = pages
        let store = FeedPostDetailStore(initial: post, source: source)
        store.start()
        store.locateComment("never")
        await store.waitForTasks()
        XCTAssertEqual(source.cursors.count, 1 + FeedPostDetailStore.maxLocatePages)
        XCTAssertEqual(store.state.notice, .commentNotFound)
        XCTAssertNil(store.state.focusCommentId)
    }

    func testASecondSearchGetsItsOwnPageBudget() async {
        let source = PagedSource()
        var pages = ["": page(["c0"], next: "n1")]
        for i in 1...40 { pages["n\(i)"] = page(["c\(i)"], next: "n\(i + 1)") }
        source.pages = pages
        let store = FeedPostDetailStore(initial: post, source: source)
        store.start()
        store.locateComment("never")
        await store.waitForTasks()
        XCTAssertEqual(source.cursors.count, 1 + FeedPostDetailStore.maxLocatePages)
        store.locateComment("c15")
        await store.waitForTasks()
        XCTAssertEqual(store.state.scrollTarget, "c15", "第二次找有自己的 10 页额度，不是用完了就直接放弃")
    }

    func testAFailedPageStopsTheSearchWithoutANotice() async {
        let source = PagedSource()
        source.pages = ["": page(["a"], next: "n1")]
        source.failCursor = "n1"
        let store = FeedPostDetailStore(initial: post, source: source)
        store.start()
        store.locateComment("target")
        await store.waitForTasks()
        XCTAssertNil(store.state.focusCommentId)
        XCTAssertNil(store.state.scrollTarget)
        XCTAssertNil(store.state.notice)
    }

    func testAFailedFirstPageStopsTheSearchWithoutANotice() async {
        let source = PagedSource()
        source.failFirst = true
        let store = FeedPostDetailStore(initial: post, source: source)
        store.start()
        store.locateComment("target")
        await store.waitForTasks()
        XCTAssertTrue(store.state.failed)
        XCTAssertNil(store.state.focusCommentId)
        XCTAssertNil(store.state.notice)
    }

    func testAnEmptyPostEndsWithTheNotice() async {
        let source = PagedSource()
        let store = FeedPostDetailStore(initial: post, source: source)
        store.start()
        store.locateComment("target")
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .commentNotFound)
    }

    func testBlankIdsAreIgnoredAndScrolledClearsTheTarget() async {
        let source = PagedSource()
        source.pages = ["": page(["a"], next: nil)]
        let store = FeedPostDetailStore(initial: post, source: source)
        store.start()
        store.locateComment("   ")
        await store.waitForTasks()
        XCTAssertNil(store.state.focusCommentId)
        XCTAssertNil(store.state.scrollTarget)
        store.locateComment(" a ")
        XCTAssertEqual(store.state.scrollTarget, "a", "前后空白去掉再找")
        store.onScrolled()
        XCTAssertNil(store.state.scrollTarget)
    }

    func testAHeldReplyIsFoundLikeAnyOther() async {
        let source = PagedSource()
        source.pages = ["": FeedCommentsPage(comments: [comment("a"), comment("h", parent: "a", held: true)], cursor: nil)]
        let store = FeedPostDetailStore(initial: post, source: source)
        store.start()
        store.locateComment("h")
        await store.waitForTasks()
        XCTAssertEqual(store.state.scrollTarget, "h")
    }
}

// MARK: - 通知点进来

final class TellomiFeedNotificationFocusTests: XCTestCase {
    private func row(_ kind: String, subject: String?) -> FeedNotificationRow {
        return FeedNotificationRow(key: "k", kind: kind, ids: ["1"], actorIds: ["u"], contentId: "p", subjectId: subject, systemType: nil, held: false, profileId: nil, createdAt: Date(), unread: false)
    }

    func testCommentAndReplyNotificationsPointAtTheNewComment() {
        XCTAssertEqual(FeedNotificationsPresentation.focusCommentId(for: row(FeedNotification.kindComment, subject: "c9")), "c9")
        XCTAssertEqual(FeedNotificationsPresentation.focusCommentId(for: row(FeedNotification.kindReply, subject: " c8 ")), "c8")
    }

    func testOtherKindsAndMissingIdsPointAtNothing() {
        XCTAssertNil(FeedNotificationsPresentation.focusCommentId(for: row(FeedNotification.kindLike, subject: "c9")))
        XCTAssertNil(FeedNotificationsPresentation.focusCommentId(for: row(FeedNotification.kindFollow, subject: "c9")))
        XCTAssertNil(FeedNotificationsPresentation.focusCommentId(for: row(FeedNotification.kindComment, subject: nil)))
        XCTAssertNil(FeedNotificationsPresentation.focusCommentId(for: row(FeedNotification.kindComment, subject: "  ")))
    }
}

@MainActor
final class TellomiFeedNotificationOpenFocusTests: XCTestCase {
    func testTheFocusTravelsWithTheOpenedCardAndIsClearedWithIt() async {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let store = FeedNotificationsStore(initialTab: FeedAPI.notificationsInteractions, source: source, feed: nil)
        store.openPost("mine-seed-2", focusCommentId: "mine-seed-2-held1")
        await store.waitForTasks()
        XCTAssertEqual(store.state.openCard?.id, "mine-seed-2")
        XCTAssertEqual(store.state.openFocusCommentId, "mine-seed-2-held1")
        store.onCardOpened()
        XCTAssertNil(store.state.openCard)
        XCTAssertNil(store.state.openFocusCommentId)
    }

    func testWithoutAFocusNothingIsSet() async {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let store = FeedNotificationsStore(initialTab: FeedAPI.notificationsInteractions, source: source, feed: nil)
        store.openPost("mine-seed-2")
        await store.waitForTasks()
        XCTAssertNotNil(store.state.openCard)
        XCTAssertNil(store.state.openFocusCommentId)
    }
}

// MARK: - 样例来源

@MainActor
final class TellomiFeedDetailExtrasSampleTests: XCTestCase {
    private func source() -> SampleFeedSource {
        return SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
    }

    func testTheSamplePollsComeWithCountsAndAreShareable() async throws {
        let sample = source()
        let single = try await sample.card(contentId: "mine-seed-2")
        let card = try XCTUnwrap(single)
        XCTAssertEqual(card.poll?.options, ["Tea", "Coffee", "Water"])
        XCTAssertEqual(card.pollState, FeedPollState(counts: [12, 7, 3], voted: []))
        XCTAssertTrue(card.shareable)
        let multi = try await sample.card(contentId: "mine-seed-3")
        XCTAssertEqual(multi?.poll?.multi, true)
        let plain = try await sample.card(contentId: "mine-seed-1")
        XCTAssertNil(plain?.poll)
    }

    func testVotingCountsMineOnceAndTheCardRemembersIt() async throws {
        let sample = source()
        let state = try await sample.vote(contentId: "mine-seed-2", options: [1])
        XCTAssertEqual(state, FeedPollState(counts: [12, 8, 3], voted: [1]))
        let refreshed = try await sample.card(contentId: "mine-seed-2")
        XCTAssertEqual(refreshed?.pollState?.voted, [1])
        do {
            _ = try await sample.vote(contentId: "mine-seed-2", options: [0])
            XCTFail("second vote should be refused")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.code, "already_voted")
        }
    }

    func testAMultiPollTakesSeveralAndASinglePollOnlyOne() async throws {
        let sample = source()
        let multi = try await sample.vote(contentId: "mine-seed-3", options: [2, 0, 2, 9])
        XCTAssertEqual(multi.voted, [0, 2])
        XCTAssertEqual(multi.counts, [6, 9, 5, 2])
        do {
            _ = try await sample.vote(contentId: "mine-seed-2", options: [0, 1])
            XCTFail("a single-choice poll takes one option")
        } catch is FeedAPIError {}
        do {
            _ = try await sample.vote(contentId: "mine-seed-1", options: [0])
            XCTFail("no poll there")
        } catch is FeedAPIError {}
    }

    func testAnEmptyOrOutOfRangeVoteIsNotAVoteAndDoesNotUseUpTheOnePerPersonVote() async throws {
        let sample = source()
        for options in [[Int](), [9, -1]] {
            do {
                _ = try await sample.vote(contentId: "mine-seed-3", options: options)
                XCTFail("\(options) is no vote")
            } catch is FeedAPIError {}
        }
        XCTAssertNil(sample.detailExtras.myVote("mine-seed-3"))
        let ok = try await sample.vote(contentId: "mine-seed-3", options: [1])
        XCTAssertEqual(ok.voted, [1])
    }

    func testTheSampleCommentsHaveAHeldReplyAndAVoiceComment() async throws {
        let sample = source()
        let page = try await sample.comments(postId: "mine-seed-1", cursor: nil)
        XCTAssertEqual(page.comments.map(\.id), ["mine-seed-1-c0", "mine-seed-1-held1", "mine-seed-1-voice"])
        XCTAssertTrue(page.comments[1].held)
        let voice = try XCTUnwrap(FeedPostDetailPresentation.voice(of: page.comments[2]))
        XCTAssertEqual(voice.durationMs, 4000)
        XCTAssertFalse(page.comments[2].transcript.isEmpty)
        let none = try await sample.comments(postId: "unknown", cursor: nil)
        XCTAssertEqual(none.comments.count, 0)
    }

    func testApprovingMakesItPublicAndDecliningDeletesIt() async throws {
        let sample = source()
        try await sample.approveComment(postId: "mine-seed-1", commentId: "mine-seed-1-held1")
        let approved = try await sample.comments(postId: "mine-seed-1", cursor: nil)
        XCTAssertFalse(approved.comments[1].held)

        try await sample.deletePost(contentId: "mine-seed-2-held1")
        let declined = try await sample.comments(postId: "mine-seed-2", cursor: nil)
        XCTAssertEqual(declined.comments.map(\.id), ["mine-seed-2-c0", "mine-seed-2-voice"])
        do {
            try await sample.approveComment(postId: "mine-seed-2", commentId: "mine-seed-2-held1")
            XCTFail("declined reply can't be approved")
        } catch is FeedAPIError {}
        do {
            try await sample.approveComment(postId: "mine-seed-1", commentId: "mine-seed-1-c0")
            XCTFail("only held ones")
        } catch is FeedAPIError {}
    }

    func testRepostAndSaveAreRecorded() async throws {
        let sample = source()
        try await sample.setReposted(contentId: "mine-seed-1", reposted: true)
        try await sample.setSaved(contentId: "mine-seed-1", saved: false)
        XCTAssertEqual(sample.detailExtras.calls, ["repost:mine-seed-1:true", "save:mine-seed-1:false"])
    }

    func testTheStoreWorksEndToEndOnTheSample() async throws {
        let sample = source()
        let initial = try await sample.card(contentId: "mine-seed-2")
        let store = FeedPostDetailStore(initial: try XCTUnwrap(initial), source: sample, editEnabled: true)
        store.start()
        await store.waitForTasks()
        // 投票
        store.vote([2])
        await store.waitForTasks()
        XCTAssertEqual(store.state.post.pollState?.voted, [2])
        XCTAssertEqual(store.state.post.pollState?.counts, [12, 7, 4])
        // 转发（乐观，再确认）
        store.toggleRepost()
        XCTAssertTrue(store.state.post.viewer.reposted)
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .reposted)
        // 批准 / 拒绝
        let held = try XCTUnwrap(store.state.comments.first { $0.held })
        store.approveComment(held)
        await store.waitForTasks()
        XCTAssertFalse(store.state.comments.contains { $0.held })
        XCTAssertEqual(store.state.comments.count, 3)
    }

    func testDecliningRemovesTheReplyFromTheStore() async throws {
        let sample = source()
        let initial = try await sample.card(contentId: "mine-seed-1")
        let store = FeedPostDetailStore(initial: try XCTUnwrap(initial), source: sample)
        store.start()
        await store.waitForTasks()
        let held = try XCTUnwrap(store.state.comments.first { $0.held })
        store.declineComment(held)
        await store.waitForTasks()
        XCTAssertEqual(store.state.comments.map(\.id), ["mine-seed-1-c0", "mine-seed-1-voice"])
        XCTAssertNil(store.state.notice)
    }
}
