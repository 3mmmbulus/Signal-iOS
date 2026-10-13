//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 一栏的列表、翻页位置和加载状态。
struct FeedTabState: Equatable {
    var cards = [FeedCard]()
    var nextCursor: String?
    var loading = false
    var refreshing = false
    var loadedOnce = false
    var failed = false
}

/// 动态页的状态（Android `FeedViewModel` 的 iOS 版）：两个分栏各自一份列表。
///
/// - 下拉刷新 = 不带 cursor 重新取，新结果放最上面，按 id 去重（契约 4.1）；
/// - 点赞先改界面，失败再改回来（契约第六节「先改界面、失败再回滚」）；
/// - 不感兴趣：这条原地换成一张小反馈卡，可以撤销（第三节第 11 条；「管理内容偏好」「这条让我不舒服」随内容偏好页做）。
@MainActor
final class FeedStore {

    enum TransientError: Equatable {
        case network
        case actionFailed
    }

    private let source: FeedSource

    private(set) var config: FeedConfig?
    private(set) var tabs = FeedTab.allCases
    private(set) var tabStates = [FeedTab: FeedTabState]()
    /// 点了「不感兴趣」、还没撤销的。卡片留在列表里，显示成反馈卡。
    private(set) var hiddenIds = Set<String>()

    /// 某一栏（nil = 全部）变了。
    var onChange: ((FeedTab?) -> Void)?
    var onTransientError: ((TransientError) -> Void)?

    private var loadTasks = [FeedTab: Task<Void, Never>]()

    private let now: () -> Date
    private var impressionTrackers = [FeedTab: FeedImpressionTracker]()
    private var lastVisible = [FeedTab: Set<String>]()
    private var impressionRechecks = [FeedTab: Task<Void, Never>]()
    private var events = FeedEventBuffer()
    private var flushTimer: Task<Void, Never>?

    init(source: FeedSource, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.now = now
    }

    // MARK: - Impressions（契约 6.1）

    /// 还没发出去的事件数（单测用）。
    var pendingEventCount: Int {
        return events.pending.count
    }

    /// 列表每次滚动 / 布局变化时调：`visibleIds` 是这一栏现在露出过半的卡片。满 1 秒的记一次曝光；
    /// 停着不动时由这里自己约下一次检查，不靠界面再来调。
    func onCardsVisible(_ tab: FeedTab, _ visibleIds: Set<String>) {
        lastVisible[tab] = visibleIds
        var tracker = impressionTrackers[tab] ?? FeedImpressionTracker()
        let date = now()
        var full = false
        for id in tracker.update(visibleIds: visibleIds, now: date) {
            full = events.add(.impression(contentId: id, tab: tab, at: date)) || full
        }
        let nextCheck = tracker.nextCheckAt
        impressionTrackers[tab] = tracker
        if full {
            flushEvents()
        }
        startFlushTimerIfNeeded()

        impressionRechecks[tab]?.cancel()
        guard let nextCheck else { return }
        let delay = max(nextCheck.timeIntervalSince(date), 0)
        impressionRechecks[tab] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000) + 1_000_000)
            guard !Task.isCancelled, let self else { return }
            self.onCardsVisible(tab, self.lastVisible[tab] ?? [])
        }
    }

    /// 动态页看不见了（切到别的标签、退到后台）：停掉计时，发掉攒着的事件。
    func onFeedHidden() {
        for tab in FeedTab.allCases {
            onCardsVisible(tab, [])
        }
        flushEvents()
    }

    /// 发掉攒着的事件；失败的丢掉，不重试、不落盘。
    func flushEvents() {
        let batches = events.drain()
        guard !batches.isEmpty else { return }
        Task { [source] in
            for batch in batches {
                do {
                    try await source.reportEvents(batch)
                } catch {
                    Logger.warn("feed events dropped: \(batch.count)")
                }
            }
        }
    }

    /// 攒不满 50 条时每 30 秒发一次。
    private func startFlushTimerIfNeeded() {
        guard flushTimer == nil else { return }
        flushTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(FeedEventBuffer.flushInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.flushEvents()
            }
        }
    }

    func tab(_ tab: FeedTab) -> FeedTabState {
        return tabStates[tab] ?? FeedTabState()
    }

    /// 大陆备案前推荐页只有编辑精选 + 时间顺序（R-1.5），界面上不说「为你推荐」。
    var isEditorialRecommend: Bool {
        return config?.recommendMode != FeedConfig.recommendModeScored
    }

    var showsIpRegion: Bool {
        return config?.ipRegionVisible == true
    }

    func loadConfig() async {
        do {
            let config = try await source.config()
            self.config = config
            tabs = FeedTab.fromApiNames(config.tabs)
            onChange?(nil)
        } catch {
            Logger.warn("feed config failed: \(error)")
        }
    }

    /// 第一次显示某个分栏时调用；已经有内容就不再取。
    func onTabShown(_ tab: FeedTab) {
        let state = self.tab(tab)
        if !state.loadedOnce, !state.loading {
            load(tab, refresh: true)
        }
    }

    func refresh(_ tab: FeedTab) {
        load(tab, refresh: true)
    }

    func loadMore(_ tab: FeedTab) {
        let state = self.tab(tab)
        guard !state.loading, state.nextCursor != nil else { return }
        load(tab, refresh: false)
    }

    /// 等这一栏正在进行的加载结束（单测用）。
    func waitForLoad(_ tab: FeedTab) async {
        await loadTasks[tab]?.value
    }

    private func load(_ tab: FeedTab, refresh: Bool) {
        loadTasks[tab]?.cancel()
        let cursor = refresh ? nil : self.tab(tab).nextCursor
        update(tab) {
            $0.loading = true
            $0.refreshing = refresh && $0.loadedOnce
        }

        loadTasks[tab] = Task { [weak self, source] in
            do {
                let page = try await source.timeline(tab: tab, cursor: cursor)
                guard !Task.isCancelled, let self else { return }
                let incoming = page.cards.filter(\.isRenderable)
                self.update(tab) { state in
                    state.cards = refresh ? Self.mergeRefresh(incoming: incoming, existing: state.cards) : Self.appendPage(existing: state.cards, incoming: incoming)
                    state.nextCursor = page.nextCursor
                    state.loading = false
                    state.refreshing = false
                    state.loadedOnce = true
                    state.failed = false
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                Logger.warn("feed timeline \(tab.apiName) failed: \(error)")
                self.update(tab) { state in
                    state.loading = false
                    state.refreshing = false
                    state.loadedOnce = true
                    state.failed = state.cards.isEmpty
                }
                if !self.tab(tab).cards.isEmpty {
                    self.onTransientError?(.network)
                }
            }
        }
    }

    func toggleLike(_ card: FeedCard) {
        let nowLiked = !card.viewer.liked
        updateCard(card.id) { $0 = Self.withLiked($0, nowLiked) }

        Task { [weak self, source] in
            do {
                try await source.setLiked(contentId: card.id, liked: nowLiked)
            } catch {
                Logger.warn("feed like failed: \(error)")
                guard let self else { return }
                self.updateCard(card.id) { $0 = Self.withLiked($0, !nowLiked) }
                self.onTransientError?(.actionFailed)
            }
        }
    }

    func notInterested(_ card: FeedCard) {
        hiddenIds.insert(card.id)
        onChange?(nil)
        Task { [source] in
            do {
                try await source.notInterested(contentId: card.id)
            } catch {
                Logger.warn("feed not interested failed: \(error)")
            }
        }
    }

    func undoNotInterested(_ cardId: String) {
        guard hiddenIds.remove(cardId) != nil else { return }
        onChange?(nil)
        Task { [source] in
            do {
                try await source.undoNotInterested(contentId: cardId)
            } catch {
                Logger.warn("feed undo not interested failed: \(error)")
            }
        }
    }

    /// 发布页带回服务端给的 `state` 之后：两栏都刷新，自己刚发的出现在最上面（待审的只有自己看得到，R-2.2）。
    func onPublished() {
        for tab in tabs {
            refresh(tab)
        }
    }

    // MARK: -

    private func update(_ tab: FeedTab, _ transform: (inout FeedTabState) -> Void) {
        var state = self.tab(tab)
        transform(&state)
        tabStates[tab] = state
        onChange?(tab)
    }

    private func updateCard(_ id: String, _ transform: (inout FeedCard) -> Void) {
        for (tab, var state) in tabStates {
            guard let index = state.cards.firstIndex(where: { $0.id == id }) else { continue }
            transform(&state.cards[index])
            tabStates[tab] = state
        }
        onChange?(nil)
    }

    /// 下拉刷新：新结果在上，旧的里面和新结果重复的去掉（契约 4.1）。
    nonisolated static func mergeRefresh(incoming: [FeedCard], existing: [FeedCard]) -> [FeedCard] {
        let ids = Set(incoming.map(\.id))
        return dedupe(incoming) + existing.filter { !ids.contains($0.id) }
    }

    /// 翻页：接在后面，已经有的不重复加。
    nonisolated static func appendPage(existing: [FeedCard], incoming: [FeedCard]) -> [FeedCard] {
        let ids = Set(existing.map(\.id))
        return existing + dedupe(incoming.filter { !ids.contains($0.id) })
    }

    nonisolated private static func dedupe(_ cards: [FeedCard]) -> [FeedCard] {
        var seen = Set<String>()
        return cards.filter { seen.insert($0.id).inserted }
    }

    nonisolated static func withLiked(_ card: FeedCard, _ liked: Bool) -> FeedCard {
        guard card.viewer.liked != liked else { return card }
        var card = card
        card.viewer.liked = liked
        card.stats.likes = max(0, card.stats.likes + (liked ? 1 : -1))
        return card
    }
}
