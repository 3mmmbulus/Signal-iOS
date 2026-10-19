//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit
@testable import SignalUI

private extension LinkPreviewFetchState.State {
    var isNone: Bool {
        if case .none = self {
            return true
        }
        return false
    }

    var isLoaded: Bool {
        if case .loaded = self {
            return true
        }
        return false
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}

class LinkPreviewFetchStateTest: XCTestCase {

    private var mockLinkPreviewFetcher: MockLinkPreviewFetcher!
    private var mockDB: InMemoryDB!

    override func setUp() {
        super.setUp()

        mockDB = InMemoryDB()
        mockLinkPreviewFetcher = MockLinkPreviewFetcher()
    }

    private func linkPreviewFetchState(
        areLinkPreviewsEnabled: Bool = true,
        onlyParseIfEnabled: Bool = false,
    ) -> LinkPreviewFetchState {
        let linkPreviewSettingStore = LinkPreviewSettingStore.mock()
        mockDB.write { tx in
            linkPreviewSettingStore.setAreLinkPreviewsEnabled(areLinkPreviewsEnabled, tx: tx)
        }
        return LinkPreviewFetchState(
            db: mockDB,
            linkPreviewFetcher: mockLinkPreviewFetcher,
            linkPreviewSettingStore: linkPreviewSettingStore,
            onlyParseIfEnabled: onlyParseIfEnabled,
            linkPreviewDraft: nil,
        )
    }

    func testUpdateLoaded() async throws {
        let linkPreviewFetchState = self.linkPreviewFetchState()

        // Non-URL text shouldn't issue any fetches.
        for textValue in ["a", "ab", "abc"] {
            await linkPreviewFetchState.update(.init(text: textValue, ranges: .empty))?.value
            XCTAssert(linkPreviewFetchState.currentState.isNone)
            XCTAssertNil(linkPreviewFetchState.linkPreviewDraftIfLoaded)
            XCTAssertNil(linkPreviewFetchState.currentUrl)
            XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [])
        }

        // A valid URL should fetch only once, even if the text is modified.
        let validURL = try XCTUnwrap(URL(string: "https://signal.org"))
        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { fetchedURL in
            XCTAssertEqual(fetchedURL, validURL)
            return OWSLinkPreviewDraft(url: fetchedURL, title: "Website Title", isForwarded: false)
        }
        for textValue in ["Check ou https://signal.org", "Check out https://signal.org"] {
            await linkPreviewFetchState.update(.init(text: textValue, ranges: .empty))?.value
            XCTAssert(linkPreviewFetchState.currentState.isLoaded)
            XCTAssertEqual(linkPreviewFetchState.linkPreviewDraftIfLoaded?.url, validURL)
            XCTAssertEqual(linkPreviewFetchState.currentUrl, validURL)
            XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [validURL])
        }

        // An invalid URL should fetch only once, even if the text is modified.
        let invalidURL = try XCTUnwrap(URL(string: "https://signal.org/not_found"))
        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { fetchedURL in
            XCTAssertEqual(fetchedURL, invalidURL)
            throw OWSGenericError("Not found.")
        }
        for textValue in ["Check ou https://signal.org/not_found", "Check out https://signal.org/not_found"] {
            await linkPreviewFetchState.update(.init(text: textValue, ranges: .empty))?.value
            XCTAssert(linkPreviewFetchState.currentState.isFailed)
            XCTAssertNil(linkPreviewFetchState.linkPreviewDraftIfLoaded)
            XCTAssertEqual(linkPreviewFetchState.currentUrl, invalidURL)
            XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [validURL, invalidURL])
        }

        // Removing the URL should clear the link preview.
        for textValue in ["Check out", "Check ou"] {
            await linkPreviewFetchState.update(.init(text: textValue, ranges: .empty))?.value
            XCTAssert(linkPreviewFetchState.currentState.isNone)
            XCTAssertNil(linkPreviewFetchState.linkPreviewDraftIfLoaded)
            XCTAssertNil(linkPreviewFetchState.currentUrl)
            XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [validURL, invalidURL])
        }
    }

    /// Tellomi（ADR-0063 §5.1 铁律 2）：只有群邀请链接确定失效才在输入框提示，其余失败都静默。
    func testOnlyAnInactiveGroupLinkShowsAFailureMessage() async throws {
        let linkPreviewFetchState = self.linkPreviewFetchState()
        let url = try XCTUnwrap(URL(string: "https://tell.cc/g#abc"))

        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { _ in throw LinkPreviewError.groupLinkInactive }
        await linkPreviewFetchState.update(.init(text: "https://tell.cc/g#abc", ranges: .empty))?.value
        XCTAssert(linkPreviewFetchState.currentState.isFailed)
        XCTAssertEqual(linkPreviewFetchState.currentUrl, url)
        XCTAssertNil(linkPreviewFetchState.linkPreviewDraftIfLoaded)
        XCTAssertEqual(linkPreviewFetchState.currentState.failureMessageToShow, "This group link is not active")

        for error in [LinkPreviewError.noPreview, .invalidPreview, .fetchFailure, .featureDisabled] {
            let other = self.linkPreviewFetchState()
            mockLinkPreviewFetcher.fetchLinkPreviewBlock = { _ in throw error }
            await other.update(.init(text: "https://signal.org/x", ranges: .empty))?.value
            XCTAssert(other.currentState.isFailed)
            XCTAssertNil(other.currentState.failureMessageToShow, "\(error)")
        }
        let generic = self.linkPreviewFetchState()
        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { _ in throw OWSGenericError("Not found.") }
        await generic.update(.init(text: "https://signal.org/y", ranges: .empty))?.value
        XCTAssertNil(generic.currentState.failureMessageToShow)
        XCTAssertNil(LinkPreviewFetchState.State.none.failureMessageToShow)
        XCTAssertNil(LinkPreviewFetchState.State.loading.failureMessageToShow)
    }

    private struct PendingFetchState {
        var isReady = false
        var deferredBlocks = [() -> Void]()
        var expectedCount: Int

        mutating func resolveIfReady() {
            guard self.isReady, self.deferredBlocks.count == self.expectedCount else {
                return
            }
            self.deferredBlocks.forEach { $0() }
            self.deferredBlocks.removeAll()
        }
    }

    func testUpdateLoading() async throws {
        let linkPreviewFetchState = self.linkPreviewFetchState()

        let validURL = try XCTUnwrap(URL(string: "https://signal.org"))
        let pendingFetchState = AtomicValue(PendingFetchState(expectedCount: 1), lock: .init())
        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { fetchedURL in
            return try await withCheckedThrowingContinuation { continuation in
                pendingFetchState.update {
                    $0.deferredBlocks.append {
                        continuation.resume(returning: OWSLinkPreviewDraft(url: fetchedURL, title: "Website Title", isForwarded: false))
                    }
                    $0.resolveIfReady()
                }
            }
        }

        let task1 = linkPreviewFetchState.update(.init(text: "https://signal.org is a grea", ranges: .empty))
        XCTAssert(linkPreviewFetchState.currentState.isLoading)

        // If there's a request in flight, we shouldn't send a new request.
        let task2 = linkPreviewFetchState.update(.init(text: "https://signal.org is a great", ranges: .empty))
        XCTAssert(linkPreviewFetchState.currentState.isLoading)

        pendingFetchState.update {
            $0.isReady = true
            $0.resolveIfReady()
        }

        await task1?.value
        await task2?.value

        XCTAssert(linkPreviewFetchState.currentState.isLoaded)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [validURL])
    }

    func testUpdateObsolete() async throws {
        let linkPreviewFetchState = self.linkPreviewFetchState()

        let pendingFetchState = AtomicValue(PendingFetchState(expectedCount: 2), lock: .init())
        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { fetchedURL in
            return try await withCheckedThrowingContinuation { continuation in
                pendingFetchState.update {
                    $0.deferredBlocks.append {
                        continuation.resume(returning: OWSLinkPreviewDraft(url: fetchedURL, title: "Website Title", isForwarded: false))
                    }
                    $0.resolveIfReady()
                }
            }
        }

        let url1 = try XCTUnwrap(URL(string: "https://signal.org/one"))
        let task1 = linkPreviewFetchState.update(.init(text: "https://signal.org/one", ranges: .empty))
        XCTAssert(linkPreviewFetchState.currentState.isLoading)

        // If there's a request in flight & we change the URL, drop the original request.
        let url2 = try XCTUnwrap(URL(string: "https://signal.org/two"))
        let task2 = linkPreviewFetchState.update(.init(text: "https://signal.org/two", ranges: .empty))
        XCTAssert(linkPreviewFetchState.currentState.isLoading)

        pendingFetchState.update {
            $0.isReady = true
            $0.resolveIfReady()
        }

        await task1?.value
        await task2?.value

        XCTAssert(linkPreviewFetchState.currentState.isLoaded)
        XCTAssertEqual(linkPreviewFetchState.linkPreviewDraftIfLoaded?.url, url2)
        XCTAssertEqual(linkPreviewFetchState.currentUrl, url2)
        XCTAssertEqual(Set(mockLinkPreviewFetcher.fetchedURLs), [url1, url2])
    }

    func testUpdatePrependScheme() async throws {
        let linkPreviewFetchState = self.linkPreviewFetchState()

        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { fetchedURL in
            return OWSLinkPreviewDraft(url: fetchedURL, title: "Signal", isForwarded: false)
        }
        await linkPreviewFetchState.update(.init(text: "signal.org", ranges: .empty), prependSchemeIfNeeded: false)?.value
        XCTAssert(linkPreviewFetchState.currentState.isNone)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [])

        // If we should prepend a scheme, prepend "https://".
        await linkPreviewFetchState.update(.init(text: "signal.org", ranges: .empty), prependSchemeIfNeeded: true)?.value
        XCTAssert(linkPreviewFetchState.currentState.isLoaded)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [URL(string: "https://signal.org")!])
        mockLinkPreviewFetcher._fetchedURLs.update { $0.removeAll() }

        // If there's already a scheme, we don't add "https://". (We require
        // "https://", so specify anything other scheme disables link previews.
        await linkPreviewFetchState.update(.init(text: "http://signal.org", ranges: .empty), prependSchemeIfNeeded: true)?.value
        XCTAssert(linkPreviewFetchState.currentState.isNone)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [])
    }

    func testOnStateChange() async throws {
        let linkPreviewFetchState = self.linkPreviewFetchState()

        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { fetchedURL in
            return OWSLinkPreviewDraft(url: fetchedURL, title: "Signal", isForwarded: false)
        }

        var onStateChangeCount = 0
        linkPreviewFetchState.onStateChange = { onStateChangeCount += 1 }

        await linkPreviewFetchState.update(.init(text: "", ranges: .empty))?.value
        XCTAssertEqual(onStateChangeCount, 0)

        // Redundant updates generally don't result in state updates.
        await linkPreviewFetchState.update(.init(text: "a", ranges: .empty))?.value
        XCTAssertEqual(onStateChangeCount, 0)

        // Fetching a URL should update the state twice: to loading & to loaded.
        await linkPreviewFetchState.update(.init(text: "https://signal.org", ranges: .empty))?.value
        XCTAssertEqual(onStateChangeCount, 2)

        await linkPreviewFetchState.update(.init(text: "https://signal.org", ranges: .empty))?.value
        XCTAssertEqual(onStateChangeCount, 2)

        // Clearing the text should update the link preview.
        await linkPreviewFetchState.update(.init(text: "", ranges: .empty))?.value
        XCTAssertEqual(onStateChangeCount, 3)

        // Assigning the URL again should fetch it again.
        await linkPreviewFetchState.update(.init(text: "https://signal.org", ranges: .empty))?.value
        XCTAssertEqual(onStateChangeCount, 5)

        // Disabling the link preview should trigger an update.
        linkPreviewFetchState.disable()
        XCTAssertEqual(onStateChangeCount, 6)
    }

    func testDisable() async throws {
        let linkPreviewFetchState = self.linkPreviewFetchState()

        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { fetchedURL in
            return OWSLinkPreviewDraft(url: fetchedURL, title: "Signal", isForwarded: false)
        }

        // Fetch the original preview.
        let url = try XCTUnwrap(URL(string: "https://signal.org"))
        await linkPreviewFetchState.update(.init(text: "https://signal.org", ranges: .empty))?.value
        XCTAssertEqual(linkPreviewFetchState.linkPreviewDraftIfLoaded?.url, url)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [url])
        mockLinkPreviewFetcher._fetchedURLs.update { $0.removeAll() }

        // Dismiss the preview; make sure it goes away.
        linkPreviewFetchState.disable()
        XCTAssertNil(linkPreviewFetchState.linkPreviewDraftIfLoaded)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [])

        // Assign the same URL again; make sure it doesn't come back.
        await linkPreviewFetchState.update(.init(text: "https://signal.org", ranges: .empty))?.value
        XCTAssertNil(linkPreviewFetchState.linkPreviewDraftIfLoaded)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [])

        // Clear the URL; make sure it stays away.
        await linkPreviewFetchState.update(.init(text: "", ranges: .empty))?.value
        XCTAssertNil(linkPreviewFetchState.linkPreviewDraftIfLoaded)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [])

        // Enter a different URL; make sure we don't fetch it.
        await linkPreviewFetchState.update(.init(text: "https://signal.org/one", ranges: .empty))?.value
        XCTAssertNil(linkPreviewFetchState.linkPreviewDraftIfLoaded)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [])

        // Ensure "enableIfEmpty" doesn't enable when the text isn't empty.
        await linkPreviewFetchState.update(.init(text: "https://signal.org/one", ranges: .empty), enableIfEmpty: true)?.value
        XCTAssertNil(linkPreviewFetchState.linkPreviewDraftIfLoaded)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [])

        // Clear the text with "enableIfEmpty" to re-enable link previews.
        await linkPreviewFetchState.update(.init(text: "", ranges: .empty), enableIfEmpty: true)?.value
        XCTAssertNil(linkPreviewFetchState.linkPreviewDraftIfLoaded)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [])

        // Set a URL and make sure we fetch it.
        let url2 = try XCTUnwrap(URL(string: "https://signal.org/two"))
        await linkPreviewFetchState.update(.init(text: "https://signal.org/two", ranges: .empty), enableIfEmpty: true)?.value
        XCTAssertEqual(linkPreviewFetchState.linkPreviewDraftIfLoaded?.url, url2)
        XCTAssertEqual(mockLinkPreviewFetcher.fetchedURLs, [url2])
    }

    func testOnlyParseIfEnabled() async throws {
        do {
            let linkPreviewFetchState = self.linkPreviewFetchState(
                areLinkPreviewsEnabled: false,
                onlyParseIfEnabled: true,
            )

            await linkPreviewFetchState.update(.init(text: "https://signal.org", ranges: .empty))?.value
            XCTAssertNil(linkPreviewFetchState.currentUrl)
        }
        do {
            let linkPreviewFetchState = self.linkPreviewFetchState(
                areLinkPreviewsEnabled: false,
                onlyParseIfEnabled: false,
            )

            // If link previews are disabled, we may still want to parse URLs in the
            // text so that they can be attached (without a preview) to text stories.
            mockLinkPreviewFetcher.fetchLinkPreviewBlock = { fetchedURL in
                throw OWSGenericError("Not found.")
            }
            await linkPreviewFetchState.update(.init(text: "https://signal.org", ranges: .empty))?.value
            XCTAssertEqual(linkPreviewFetchState.currentUrl, try XCTUnwrap(URL(string: "https://signal.org")))
        }
    }

    func testDontParseInSpoilers() async throws {
        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { fetchedURL in
            return OWSLinkPreviewDraft(url: fetchedURL, title: "Signal", isForwarded: false)
        }

        let linkPreviewFetchState = self.linkPreviewFetchState(
            onlyParseIfEnabled: true,
        )

        // Bold should have no effect
        await linkPreviewFetchState.update(.init(
            text: "https://signal.org",
            ranges: .init(
                mentions: [],
                styles: [.init(.bold, range: NSRange(location: 0, length: 18))],
            ),
        ))?.value
        XCTAssertNotNil(linkPreviewFetchState.currentUrl)

        // Spoiler should mean we don't match.
        await linkPreviewFetchState.update(.init(
            text: "https://signal.org",
            ranges: .init(
                mentions: [],
                styles: [.init(.spoiler, range: NSRange(location: 0, length: 18))],
            ),
        ))?.value
        XCTAssertNil(linkPreviewFetchState.currentUrl)

        // Even if only partially covering.
        await linkPreviewFetchState.update(.init(
            text: "https://signal.org",
            ranges: .init(
                mentions: [],
                styles: [.init(.spoiler, range: NSRange(location: 3, length: 5))],
            ),
        ))?.value
        XCTAssertNil(linkPreviewFetchState.currentUrl)

        // Including if we prepend a prefix.
        await linkPreviewFetchState.update(.init(
            text: "signal.org",
            ranges: .init(
                mentions: [],
                styles: [.init(.spoiler, range: NSRange(location: 5, length: 5))],
            ),
        ))?.value
        XCTAssertNil(linkPreviewFetchState.currentUrl)
    }
}

// MARK: - Tellomi: wait for a loading link card at send time

/// Tellomi（信息卡片 P1，产品 2026-10-19 定）：按发送时卡片还在加载，最多等 3 秒；等到了带卡片发，
/// 等不到就不带卡片发；等的时候再按不会多发。
@MainActor
class TellomiLinkPreviewSendGateTest: XCTestCase {

    private let mockLinkPreviewFetcher = MockLinkPreviewFetcher()
    private let mockDB = InMemoryDB()

    private func linkPreviewFetchState() -> LinkPreviewFetchState {
        let linkPreviewSettingStore = LinkPreviewSettingStore.mock()
        mockDB.write { tx in
            linkPreviewSettingStore.setAreLinkPreviewsEnabled(true, tx: tx)
        }
        return LinkPreviewFetchState(
            db: mockDB,
            linkPreviewFetcher: mockLinkPreviewFetcher,
            linkPreviewSettingStore: linkPreviewSettingStore,
            onlyParseIfEnabled: false,
            linkPreviewDraft: nil,
        )
    }

    /// The fetch stays pending until `finish()` is called (or forever, if it never is).
    private final class PendingFetch: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<OWSLinkPreviewDraft, Error>?
        private var finishedDraftURL: URL?

        func start(_ url: URL, _ continuation: CheckedContinuation<OWSLinkPreviewDraft, Error>) {
            lock.lock()
            defer { lock.unlock() }
            if finishedDraftURL != nil {
                continuation.resume(returning: OWSLinkPreviewDraft(url: url, title: "Website Title", isForwarded: false))
            } else {
                self.continuation = continuation
            }
        }

        func finish(_ url: URL) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            finishedDraftURL = url
            lock.unlock()
            continuation?.resume(returning: OWSLinkPreviewDraft(url: url, title: "Website Title", isForwarded: false))
        }
    }

    private func installPendingFetch() -> PendingFetch {
        let pendingFetch = PendingFetch()
        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { url in
            try await withCheckedThrowingContinuation { pendingFetch.start(url, $0) }
        }
        return pendingFetch
    }

    func testDefaultTimeoutIsThreeSeconds() {
        XCTAssertEqual(TellomiLinkPreviewSendGate.defaultTimeout, 3)
    }

    func testNotLoadingSendsImmediately() async throws {
        let fetchState = linkPreviewFetchState()
        await fetchState.update(.init(text: "hello", ranges: .empty))?.value
        let gate = TellomiLinkPreviewSendGate()

        var sentDrafts = [OWSLinkPreviewDraft?]()
        XCTAssertTrue(gate.send(waitingFor: fetchState) { sentDrafts.append(fetchState.linkPreviewDraftIfLoaded) })
        // Synchronous, exactly as before this change.
        XCTAssertEqual(sentDrafts.count, 1)
        XCTAssertNil(sentDrafts[0])
        XCTAssertFalse(gate.isWaiting)
        XCTAssertNil(gate.waitTask)
    }

    func testCardThatFinishesInTimeIsSentWithTheMessage() async throws {
        let url = try XCTUnwrap(URL(string: "https://signal.org/a"))
        let pendingFetch = installPendingFetch()
        let fetchState = linkPreviewFetchState()
        fetchState.update(.init(text: "look https://signal.org/a", ranges: .empty))
        XCTAssertTrue(fetchState.isLoading)

        let gate = TellomiLinkPreviewSendGate(timeout: 3)
        var waitingChanges = [Bool]()
        gate.onWaitingChange = { waitingChanges.append(gate.isWaiting) }
        var sentDrafts = [OWSLinkPreviewDraft?]()
        let start = Date()
        XCTAssertTrue(gate.send(waitingFor: fetchState) { sentDrafts.append(fetchState.linkPreviewDraftIfLoaded) })
        XCTAssertTrue(gate.isWaiting)
        XCTAssertEqual(sentDrafts.count, 0, "must not send while the card is loading")

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sentDrafts.count, 0)
        pendingFetch.finish(url)
        await gate.waitTask?.value

        XCTAssertEqual(sentDrafts.count, 1)
        XCTAssertEqual(sentDrafts.first??.url, url)
        XCTAssertFalse(gate.isWaiting)
        XCTAssertEqual(waitingChanges, [true, false])
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "should send as soon as the card arrives, not at the timeout")
    }

    func testCardThatTimesOutIsSentWithoutIt() async throws {
        let url = try XCTUnwrap(URL(string: "https://signal.org/slow"))
        let pendingFetch = installPendingFetch()
        let fetchState = linkPreviewFetchState()
        fetchState.update(.init(text: "https://signal.org/slow", ranges: .empty))

        let gate = TellomiLinkPreviewSendGate(timeout: 0.3)
        var sentDrafts = [OWSLinkPreviewDraft?]()
        let start = Date()
        XCTAssertTrue(gate.send(waitingFor: fetchState) { sentDrafts.append(fetchState.linkPreviewDraftIfLoaded) })
        await gate.waitTask?.value

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(sentDrafts.count, 1)
        XCTAssertNil(sentDrafts[0] ?? nil, "timed out: sent without a card")
        XCTAssertGreaterThanOrEqual(elapsed, 0.25)
        XCTAssertLessThan(elapsed, 2)
        XCTAssertFalse(gate.isWaiting)

        // The fetch isn't cancelled: the late card still reaches the composer, but nothing is re-sent.
        XCTAssertTrue(fetchState.isLoading)
        pendingFetch.finish(url)
        for _ in 0..<50 where fetchState.isLoading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(fetchState.linkPreviewDraftIfLoaded?.url, url)
        XCTAssertEqual(sentDrafts.count, 1)
    }

    func testFailedCardSendsWithoutWaitingForTheTimeout() async throws {
        mockLinkPreviewFetcher.fetchLinkPreviewBlock = { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            throw LinkPreviewError.noPreview
        }
        let fetchState = linkPreviewFetchState()
        fetchState.update(.init(text: "https://signal.org/none", ranges: .empty))

        let gate = TellomiLinkPreviewSendGate(timeout: 3)
        var sentDrafts = [OWSLinkPreviewDraft?]()
        let start = Date()
        gate.send(waitingFor: fetchState) { sentDrafts.append(fetchState.linkPreviewDraftIfLoaded) }
        await gate.waitTask?.value

        XCTAssertEqual(sentDrafts.count, 1)
        XCTAssertNil(sentDrafts[0] ?? nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testDismissingTheCardWhileWaitingSendsAtOnce() async throws {
        _ = installPendingFetch()
        let fetchState = linkPreviewFetchState()
        fetchState.update(.init(text: "https://signal.org/x", ranges: .empty))

        let gate = TellomiLinkPreviewSendGate(timeout: 3)
        var sentDrafts = [OWSLinkPreviewDraft?]()
        let start = Date()
        gate.send(waitingFor: fetchState) { sentDrafts.append(fetchState.linkPreviewDraftIfLoaded) }
        fetchState.disable()
        await gate.waitTask?.value

        XCTAssertEqual(sentDrafts.count, 1)
        XCTAssertNil(sentDrafts[0] ?? nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testDoubleTapWhileWaitingSendsOnlyOnce() async throws {
        let url = try XCTUnwrap(URL(string: "https://signal.org/b"))
        let pendingFetch = installPendingFetch()
        let fetchState = linkPreviewFetchState()
        fetchState.update(.init(text: "https://signal.org/b", ranges: .empty))

        let gate = TellomiLinkPreviewSendGate(timeout: 3)
        var sendCount = 0
        XCTAssertTrue(gate.send(waitingFor: fetchState) { sendCount += 1 })
        XCTAssertFalse(gate.send(waitingFor: fetchState) { sendCount += 1 }, "second tap is ignored")
        XCTAssertFalse(gate.send(waitingFor: fetchState) { sendCount += 1 }, "third tap is ignored")
        let waitTask = gate.waitTask
        pendingFetch.finish(url)
        await waitTask?.value

        XCTAssertEqual(sendCount, 1)
        // Once the wait is over, a new tap is a new message again.
        XCTAssertTrue(gate.send(waitingFor: fetchState) { sendCount += 1 })
        XCTAssertEqual(sendCount, 2)
    }

    func testWaitWhileLoadingReturnsAtOnceWhenNothingIsLoading() async throws {
        let fetchState = linkPreviewFetchState()
        let start = Date()
        await fetchState.waitWhileLoading(timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
