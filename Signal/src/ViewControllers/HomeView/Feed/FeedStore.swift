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

    /// 刚发生、界面要给一句提示的事（Android `FeedState` 的 `savedNotice` / `repostedNotice` / `PIN_LIMIT`）。
    enum Notice: Equatable {
        /// 已存进「我的收藏」
        case saved
        /// 已转发到动态
        case reposted
        /// 置顶已满 3 条
        case pinLimit
    }

    private let source: FeedSource
    private let savedMessages: FeedSavedMessages?
    /// 「完全屏蔽」的词（I-9）：每页现读，设置页刚改的下一页就生效。nil = 不过滤。
    private let blockedKeywords: FeedBlockedKeywords?

    private(set) var config: FeedConfig?
    private(set) var tabs = FeedTab.allCases
    private(set) var tabStates = [FeedTab: FeedTabState]()
    /// 点了「不感兴趣」、还没撤销的。卡片留在列表里，显示成反馈卡。
    private(set) var hiddenIds = Set<String>()

    /// 某一栏（nil = 全部）变了。
    var onChange: ((FeedTab?) -> Void)?
    var onTransientError: ((TransientError) -> Void)?
    var onNotice: ((Notice) -> Void)?

    /// 「查看数据」弹窗；nil = 没开。变了会走 `onChange(nil)`。
    private(set) var insights: FeedInsightsState?

    private var saving = FeedInFlight()
    private var reposting = FeedInFlight()
    private var voting = FeedInFlight()
    private var actionTasks = [Task<Void, Never>]()

    private var loadTasks = [FeedTab: Task<Void, Never>]()

    private let now: () -> Date
    private var impressionTrackers = [FeedTab: FeedImpressionTracker]()
    private var lastVisible = [FeedTab: Set<String>]()
    private var impressionRechecks = [FeedTab: Task<Void, Never>]()
    private var events = FeedEventBuffer()
    private var flushTimer: Task<Void, Never>?
    /// 被限速（429 / 带 `Retry-After` 的 503）而没发出去的批次：不丢，等解封后先于新事件发出去（I-21）。
    private var heldBatches = [[FeedEventPayload]]()
    private var eventsGate = FeedRetryGate()
    private var eventFlushes = [Task<Void, Never>]()
    /// 0…1 的随机数，给没有 `Retry-After` 的 429 的指数退避加抖动；测试里换成定值。
    private let jitter: () -> Double

    /// `savedMessages` 是「存进我的收藏」的实现（I-3，要用 SignalServiceKit，在 Mac 上接）；没有就不能收藏（回滚并提示）。
    init(source: FeedSource, savedMessages: FeedSavedMessages? = nil, blockedKeywords: FeedBlockedKeywords? = nil, now: @escaping () -> Date = Date.init, jitter: @escaping () -> Double = { Double.random(in: 0...1) }) {
        self.source = source
        self.savedMessages = savedMessages
        self.blockedKeywords = blockedKeywords
        self.now = now
        self.jitter = jitter
    }

    // MARK: - Impressions（契约 6.1）

    /// 还没发出去的事件数（单测用）。
    var pendingEventCount: Int {
        return events.pending.count + heldBatches.reduce(0) { $0 + $1.count }
    }

    /// 被限速时还要等几秒才会再发事件（单测 / 界面都不需要，调试用）；没在限速是 0。
    var eventsBackoffRemaining: TimeInterval {
        return eventsGate.remaining(now: now())
    }

    /// 等正在发的事件发完（单测用）。
    func waitForEventFlushes() async {
        while let task = eventFlushes.first {
            await task.value
            eventFlushes.removeFirst()
        }
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

    /// 发掉攒着的事件。普通失败的批次丢掉，不重试、不落盘（契约 6.1）。
    ///
    /// **被限速时不丢（I-21）**：引擎回 429（或带 `Retry-After` 的 503）就停下，这一批和后面还没发的批次都留着（最多 `maxQueuedEvents` = 1000 条，超过丢最旧的）；
    /// 在 `Retry-After`（夹到 1…3600 秒）里不再发，没有这个头的 429 按指数退避加抖动；时间到了由下一次 `flushEvents`
    /// （30 秒一次的定时器、退到后台、攒满 50 条）接着发，旧的先发。
    func flushEvents() {
        if eventsGate.isBlocked(now: now()) {
            // 等待期里新攒的也并进排队的（不再发），超过上限丢最旧的
            heldBatches += events.drain()
            trimHeldEvents()
            return
        }
        let batches = heldBatches + events.drain()
        heldBatches = []
        guard !batches.isEmpty else { return }
        let task = Task { [source, weak self] in
            for (index, batch) in batches.enumerated() {
                do {
                    try await source.reportEvents(batch)
                    self?.eventsGate.reset()
                } catch let error as FeedAPIError where error.isThrottle {
                    guard let self else { return }
                    self.eventsGate.record(error, now: self.now(), random: self.jitter())
                    self.heldBatches = Array(batches[index...]) + self.heldBatches
                    self.trimHeldEvents()
                    Logger.warn("feed events held back for \(Int(self.eventsGate.remaining(now: self.now()))) s: \(self.pendingEventCount) queued")
                    return
                } catch {
                    Logger.warn("feed events dropped: \(batch.count)")
                }
            }
        }
        eventFlushes.append(task)
    }

    /// 被限速时最多留这么多条没发的事件（和 Android `FeedEventBuffer` 的 1000 一样），超过的从最旧的开始丢。
    static let maxQueuedEvents = 1000

    private func trimHeldEvents() {
        var excess = heldBatches.reduce(0) { $0 + $1.count } - Self.maxQueuedEvents
        guard excess > 0 else { return }
        Logger.warn("feed events queue over \(Self.maxQueuedEvents): dropping the \(excess) oldest")
        while excess > 0, var first = heldBatches.first {
            if first.count <= excess {
                excess -= first.count
                heldBatches.removeFirst()
            } else {
                first.removeFirst(excess)
                heldBatches[0] = first
                excess = 0
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
                // 「完全屏蔽」的词在本机过滤（第三节第 12 条）；只作用于信息流这两栏
                let blocked = self.blockedKeywords?.active(now: self.now()) ?? []
                let incoming = page.cards.filter { $0.isRenderable && !$0.matchesAny(blocked) }
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

    // MARK: - 卡片上的动作（I-3）

    /// 单测用：等已经发出去的动作都做完。
    func waitForActions() async {
        // 等到队列空（等的时候新加的也等）
        while let task = actionTasks.first {
            await task.value
            actionTasks.removeFirst()
        }
    }

    /// 收藏 / 取消收藏（第三节第 27 条）：先改界面；先存进或删掉「我的收藏」里那条，成功了再以假名上报，
    /// 上报失败不影响收藏本身。存不进「我的收藏」就改回来。
    func toggleSave(_ card: FeedCard) {
        guard saving.begin(card.id) else { return }
        let nowSaved = !card.viewer.saved
        updateCard(card.id) { $0 = $0.withSaved(nowSaved) }
        actionTasks.append(Task { [weak self, source, savedMessages] in
            do {
                guard let savedMessages else { throw FeedPublishError.feedNotAvailable }
                try await FeedSaveFlow.setSaved(card, saved: nowSaved, savedMessages: savedMessages, source: source) {
                    Logger.warn("feed save report failed: \($0)")
                }
                self?.finishSave(card.id, notice: nowSaved ? .saved : nil)
            } catch {
                Logger.warn("feed saved messages failed: \(error)")
                self?.finishSave(card.id, revertTo: !nowSaved)
            }
        })
    }

    private func finishSave(_ id: String, notice: Notice? = nil, revertTo: Bool? = nil) {
        saving.end(id)
        if let revertTo {
            updateCard(id) { $0 = $0.withSaved(revertTo) }
            onTransientError?(.actionFailed)
        } else if let notice {
            onNotice?(notice)
        }
    }

    /// 转发到动态 / 取消（第 26 条）：先改界面，失败改回来。
    func toggleRepost(_ card: FeedCard) {
        guard reposting.begin(card.id) else { return }
        let nowReposted = !card.viewer.reposted
        updateCard(card.id) { $0 = $0.withReposted(nowReposted) }
        actionTasks.append(Task { [weak self, source] in
            do {
                try await source.setReposted(contentId: card.id, reposted: nowReposted)
                guard let self else { return }
                self.reposting.end(card.id)
                if nowReposted { self.onNotice?(.reposted) }
            } catch {
                Logger.warn("feed repost failed: \(error)")
                guard let self else { return }
                self.reposting.end(card.id)
                self.updateCard(card.id) { $0 = $0.withReposted(!nowReposted) }
                self.onTransientError?(.actionFailed)
            }
        })
    }

    /// 投票不能撤回，所以不先改界面：等服务端回了票数再换上。
    func vote(_ card: FeedCard, options: [Int]) {
        guard !options.isEmpty, voting.begin(card.id) else { return }
        actionTasks.append(Task { [weak self, source] in
            do {
                let state = try await source.vote(contentId: card.id, options: options)
                guard let self else { return }
                self.voting.end(card.id)
                self.updateCard(card.id) { $0 = $0.withPollState(state) }
            } catch {
                Logger.warn("feed vote failed: \(error)")
                guard let self else { return }
                self.voting.end(card.id)
                self.onTransientError?(.actionFailed)
            }
        })
    }

    /// 自己帖子「···」里的置顶、隐藏点赞数（先改界面，失败改回来）和查看数据。置顶满 3 条时引擎回 409，单独提示。
    func onOwnPostAction(_ card: FeedCard, _ action: FeedOwnPostAction) {
        guard let update = action.settingsUpdate else {
            if action == .insights { loadInsights(card.id) }   // 回复选项由卡片自己开面板（Android 同）
            return
        }
        updateCard(card.id) { $0 = $0.withSettings(update) }
        actionTasks.append(Task { [weak self, source] in
            do {
                try await source.updatePostSettings(contentId: card.id, update: update)
            } catch {
                Logger.warn("feed post settings failed: \(error)")
                guard let self else { return }
                self.updateCard(card.id) {
                    $0.pinned = card.pinned
                    $0.stats.likeCountHidden = card.stats.likeCountHidden
                }
                if FeedOwnPostAction.isPinLimit(error) {
                    self.onNotice?(.pinLimit)
                } else {
                    self.onTransientError?(.actionFailed)
                }
            }
        })
    }

    private func loadInsights(_ contentId: String) {
        insights = .loading
        onChange?(nil)
        actionTasks.append(Task { [weak self, source] in
            let result: FeedInsightsState
            do {
                result = .ready(try await source.postInsights(contentId: contentId))
            } catch {
                Logger.warn("feed insights failed: \(error)")
                result = .failed
            }
            guard let self, self.insights != nil else { return }   // 等的时候关掉了弹窗就不再弹
            self.insights = result
            self.onChange?(nil)
        })
    }

    func onInsightsDismissed() {
        insights = nil
        onChange?(nil)
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
