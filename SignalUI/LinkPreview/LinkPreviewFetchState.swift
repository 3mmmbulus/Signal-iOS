//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient
public import SignalServiceKit

public class LinkPreviewFetchState {

    private let db: any DB
    private let linkPreviewFetcher: any LinkPreviewFetcher
    private let linkPreviewSettingStore: LinkPreviewSettingStore
    private let onlyParseIfEnabled: Bool

    public init(
        db: any DB,
        linkPreviewFetcher: any LinkPreviewFetcher,
        linkPreviewSettingStore: LinkPreviewSettingStore,
        onlyParseIfEnabled: Bool = true,
        linkPreviewDraft: OWSLinkPreviewDraft? = nil,
    ) {
        self.db = db
        self.linkPreviewFetcher = linkPreviewFetcher
        self.linkPreviewSettingStore = linkPreviewSettingStore
        self.onlyParseIfEnabled = onlyParseIfEnabled
        if let linkPreviewDraft {
            self._currentState = (.loaded(linkPreviewDraft), linkPreviewDraft.url)
        } else {
            self._currentState = (.none, nil)
        }
    }

    // MARK: - State

    public enum State {
        /// There's no link preview. Perhaps the text doesn't contain a URL, or
        /// perhaps the user explicitly dismissed the link preview.
        case none

        /// There's a URL in the text, and the link preview is currently loading.
        case loading

        /// There's a URL in the text, and the link preview has finished loading.
        case loaded(OWSLinkPreviewDraft)

        /// There's a URL in the text, but we couldn't load a link preview for it.
        case failed(Error)
    }

    private var _currentState: (State, URL?) {
        didSet {
            if !isLoading {
                resumeLoadingWaiters()
            }
            onStateChange?()
        }
    }

    private var fetchTask: Task<Void, Never>?

    /// Invoked when `currentState` is updated.
    public var onStateChange: (() -> Void)?

    public var currentState: State { _currentState.0 }

    /// The URL that we fetched/are fetching/failed to fetch.
    public var currentUrl: URL? { _currentState.1 }

    /// If false, the user tapped the "X" to dismiss the link preview.
    private var isEnabled = true

    /// Dismiss the current link preview (if any).
    ///
    /// This also disables future fetch attempts for this instance, regardless
    /// of whether or not link previews are enabled.
    public func disable() {
        isEnabled = false
        _currentState = (.none, nil)
    }

    public var linkPreviewDraftIfLoaded: OWSLinkPreviewDraft? {
        switch currentState {
        case .none, .loading, .failed:
            return nil
        case .loaded(let linkPreviewDraft):
            return linkPreviewDraft
        }
    }

    // MARK: - Waiting at send time

    /// True while the preview for `currentUrl` is still being fetched.
    public var isLoading: Bool {
        if case .loading = currentState {
            return true
        }
        return false
    }

    /// Tellomi (link cards P1, option a): continuations waiting for the current
    /// fetch to settle, keyed so each one is resumed exactly once.
    private var loadingWaiters = [Int: CheckedContinuation<Void, Never>]()
    private var nextLoadingWaiterId = 0

    /// Tellomi (link cards P1, option a): returns as soon as the state stops
    /// being `.loading` (loaded, failed, dismissed or the URL was removed), or
    /// after `timeout` seconds, whichever comes first. Returns at once if
    /// nothing is loading. It never cancels the fetch: a preview that arrives
    /// after the timeout still shows up in the composer as before.
    @MainActor
    public func waitWhileLoading(timeout: TimeInterval) async {
        guard isLoading else {
            return
        }
        let waiterId = nextLoadingWaiterId
        nextLoadingWaiterId += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loadingWaiters[waiterId] = continuation
            // Holds `self` for at most `timeout`, so a waiter can never be left hanging.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                self.resumeLoadingWaiter(waiterId)
            }
        }
    }

    private func resumeLoadingWaiter(_ waiterId: Int) {
        loadingWaiters.removeValue(forKey: waiterId)?.resume()
    }

    private func resumeLoadingWaiters() {
        guard !loadingWaiters.isEmpty else {
            return
        }
        let waiters = loadingWaiters
        loadingWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    // MARK: - Fetching

    /// Updates the user-provided text that may contain a URL.
    ///
    /// - Parameter body: An entire blob of text entered by the user, such as
    /// in the conversation input text field.
    ///
    /// - Parameter enableIfEmpty: If true, link preview fetches will be
    /// re-enabled if the provided text is empty.
    ///
    /// - Parameter prependSchemeIfNeeded: If true, an "https://" scheme will be
    /// prepended to `rawText` if it doesn't have another scheme. This is useful
    /// for text fields dedicated to URL entry.
    @discardableResult
    public func update(
        _ body: MessageBody,
        enableIfEmpty: Bool = false,
        prependSchemeIfNeeded: Bool = false,
    ) -> Task<Void, Never>? {
        if enableIfEmpty, body.text.isEmpty {
            isEnabled = true
        }

        let proposedUrl = validUrl(in: body, prependSchemeIfNeeded: prependSchemeIfNeeded)

        if currentUrl == proposedUrl {
            return self.fetchTask
        }

        self.fetchTask?.cancel()
        self.fetchTask = nil

        guard let proposedUrl else {
            _currentState = (.none, nil)
            return nil
        }

        _currentState = (.loading, proposedUrl)

        self.fetchTask = Task { @MainActor [weak self, linkPreviewFetcher] in
            do {
                let linkPreviewDraft = try await linkPreviewFetcher.fetchLinkPreview(for: proposedUrl)
                guard let self else { return }
                // Obsolete callback.
                guard self.currentUrl == proposedUrl else { return }

                self._currentState = (.loaded(linkPreviewDraft), proposedUrl)
            } catch {
                guard let self else { return }
                // Obsolete callback.
                guard self.currentUrl == proposedUrl else { return }

                self._currentState = (.failed(error), proposedUrl)
            }
        }
        return self.fetchTask
    }

    private func validUrl(
        in body: MessageBody,
        prependSchemeIfNeeded: Bool,
    ) -> URL? {
        if !isEnabled {
            return nil
        }

        if body.text.isEmpty {
            return nil
        }

        let areLinkPreviewsEnabled: () -> Bool = {
            return self.db.read { tx in
                self.linkPreviewSettingStore.areLinkPreviewsEnabled(tx: tx)
            }
        }

        if onlyParseIfEnabled, !areLinkPreviewsEnabled() {
            return nil
        }

        var body = body
        if prependSchemeIfNeeded {
            body = self.prependingSchemeIfNeeded(to: body)
        }

        return LinkValidator.firstLinkPreviewURL(in: body)
    }

    private func prependingSchemeIfNeeded(to body: MessageBody) -> MessageBody {
        // Prepend HTTPS if address is missing one…
        let schemePrefix = "https://"
        guard body.text.range(of: schemePrefix, options: [.caseInsensitive, .anchored]) == nil else {
            return body
        }
        // …and it doesn't appear to have any other protocol specified.
        guard body.text.range(of: "://") == nil else {
            return body
        }
        return body.prepending(schemePrefix)
    }
}

// MARK: -

/// Tellomi (link cards P1, option a; product decision 2026-10-19): when Send is
/// tapped while the link card is still loading, wait up to `defaultTimeout`
/// seconds. If the card finishes in time the message goes out with it,
/// otherwise without it. No card is added to the message later (no edit).
///
/// While waiting, `isWaiting` is true: the composer shows its loading state and
/// further taps are ignored, so the message is sent only once.
///
/// Telegram doesn't need this: it sends at once and its server attaches the
/// preview afterwards. Tellomi has no preview server (ADR-0063 §6.5), so the
/// card has to be ready on the sender before the message leaves.
@MainActor
public final class TellomiLinkPreviewSendGate {

    public nonisolated static let defaultTimeout: TimeInterval = 3

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = TellomiLinkPreviewSendGate.defaultTimeout) {
        self.timeout = timeout
    }

    /// Invoked when `isWaiting` changes.
    public var onWaitingChange: (() -> Void)?

    public private(set) var isWaiting = false {
        didSet {
            if oldValue != isWaiting {
                onWaitingChange?()
            }
        }
    }

    /// The pending wait, if any (exposed for tests).
    private(set) var waitTask: Task<Void, Never>?

    /// Runs `send` now if no link card is loading; otherwise waits (see the type
    /// comment) and then runs it. `send` should read the composer's current
    /// link preview draft when it runs.
    ///
    /// - Returns: false if the tap was ignored because a wait is already in progress.
    @discardableResult
    public func send(
        waitingFor fetchState: LinkPreviewFetchState,
        _ send: @escaping @MainActor () -> Void,
    ) -> Bool {
        guard !isWaiting else {
            return false
        }
        guard fetchState.isLoading else {
            send()
            return true
        }
        isWaiting = true
        let timeout = self.timeout
        waitTask = Task { @MainActor in
            await fetchState.waitWhileLoading(timeout: timeout)
            self.isWaiting = false
            self.waitTask = nil
            send()
        }
        return true
    }
}

// MARK: -

public extension LinkPreviewFetchState.State {
    /// Tellomi（ADR-0063 §5.1 铁律 2）：取不到预览就不显示预览区，也不出「无法预览」之类的提示——唯一的例外是群邀请链接确定已失效，
    /// 照上游安卓在输入框提示发送者。Telegram 没有这种提示，它的输入框只有成功一种状态（iOS `UpdateChatPresentationInterfaceState.swift` L299–349）。
    var failureMessageToShow: String? {
        guard case .failed(let error) = self, let previewError = error as? LinkPreviewError, previewError == .groupLinkInactive else {
            return nil
        }
        return OWSLocalizedString(
            "TELLOMI_LINK_PREVIEW_GROUP_LINK_NOT_ACTIVE",
            comment: "Tellomi (ADR-0063 §5.1): shown in the message composer's link preview area when the pasted group invite link is definitely not active",
        )
    }
}
