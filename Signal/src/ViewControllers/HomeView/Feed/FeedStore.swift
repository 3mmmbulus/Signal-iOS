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
    /// 配置拉到了（没拉到不调）。未成年人时限（I-15）靠它记住 `minor_mode`。
    var onConfigLoaded: ((FeedConfig) -> Void)?
    private(set) var tabs = FeedTab.allCases
    private(set) var tabStates = [FeedTab: FeedTabState]()
    /// 点了「不感兴趣」、还没撤销的。卡片留在列表里，显示成反馈卡。
    private(set) var hiddenIds = Set<String>()

    /// 某一栏（nil = 全部）变了。只有一个接收者（列表页）；要多个页面一起订阅用 `subscribe`。
    var onChange: ((FeedTab?) -> Void)?
    var onTransientError: ((TransientError) -> Void)?
    var onNotice: ((Notice) -> Void)?
    /// 有「我的收藏」的实现（卡片上才出收藏按钮，I-3）。
    var canSave: Bool { savedMessages != nil }

    /// 「查看数据」弹窗；nil = 没开。变了会走 `onChange(nil)`。
    private(set) var insights: FeedInsightsState?

    private struct Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    private var subscriptions = [Weak<FeedSubscription>]()
    /// 被详情页借走的卡片（见 `retain`）。只有卡片被借着的时候才有；借的人都放手了就清掉。
    private var heldCards = [String: FeedCard]()
    /// 屏蔽了的作者 / 删掉了的帖子：被页面借着的那份不动，但借着它们的页面（搜索、话题）靠这两个集合知道该把它们去掉（`isRemoved`）。
    private var removedAuthorIds = Set<String>()
    private var removedCardIds = Set<String>()
    private var leases = [Weak<FeedCardLease>]()
    /// 每张卡片正在路上的点赞请求数（连点会有几个）：路上有请求时，刚取回来的卡片不能把界面上的赞改回服务端的旧值。
    private var likesInFlight = [String: Int]()
    private var likeConfirmed = [String: Bool]()
    private var likeTails = [String: Task<Void, Never>]()

    private var saving = FeedInFlight()
    private var reposting = FeedInFlight()
    private var voting = FeedInFlight()
    private var actionTasks = [Task<Void, Never>]()

    private var loadTasks = [FeedTab: Task<Void, Never>]()

    /// 通知的未读数（互动 / 新关注 / 系统）：动态页的红点和通知页读写同一份，改了走 `FeedChange.unread`。
    private(set) var notificationUnread = FeedUnreadCounts()
    private var unreadGate = FeedRetryGate()
    private var unreadCheckedAt: Date?
    private var unreadTask: Task<Void, Never>?
    /// 红点最多这么久问一次引擎（回到动态页、回前台都会问，太密就不发）。
    static let unreadRefreshInterval: TimeInterval = 30

    private let now: () -> Date
    private var impressionTrackers = [FeedTab: FeedImpressionTracker]()
    private var lastVisible = [FeedTab: Set<String>]()
    private var impressionRechecks = [FeedTab: Task<Void, Never>]()
    private var events = FeedEventBuffer()
    private var detailEvents = FeedDetailEventTracker()
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

    // MARK: - 订阅、按 id 取卡片、借卡片（列表页和详情页共用一个 store）

    /// 订阅所有变化（`FeedChange`）。返回的回执要一直拿着（`cancel()` 或放掉就停）；通知在主线程、改动发生的当下同步发出，
    /// 收到时 `card(id:)` 已经是新值。可以在回调里取消自己或再改 store（通知发出前先取了一份接收者名单）。
    func subscribe(_ handler: @escaping (FeedChange) -> Void) -> FeedSubscription {
        let subscription = FeedSubscription(handler)
        subscriptions.append(Weak(subscription))
        return subscription
    }

    /// 现在订着的接收者数（单测用）。
    var subscriberCount: Int {
        return subscriptions.filter { $0.value?.isActive == true }.count
    }

    /// 订阅列表里占着的位子数，包括已经取消 / 放掉、还没清掉的（单测用：确认通知一轮之后会清干净，不会越攒越多）。
    var subscriptionSlotCount: Int {
        return subscriptions.count
    }

    private func notify(_ change: FeedChange) {
        switch change {
        case .list(let tab):
            onChange?(tab)
        case .cards:
            onChange?(nil)
        case .actionFailed, .unread:
            break
        }
        subscriptions.removeAll { $0.value?.isActive != true }
        for subscription in subscriptions.compactMap(\.value) {
            subscription.deliver(change)
        }
    }

    /// 按 id 取一张卡片的**当前**样子：被借着的先取借着的，否则取两栏里找到的第一张（改动会同时改到所有副本，所以一样）。找不到是 nil。
    func card(id: String) -> FeedCard? {
        pruneLeases()
        if let held = heldCards[id] {
            return held
        }
        for feedTab in FeedTab.allCases {
            if let card = self.tab(feedTab).cards.first(where: { $0.id == id }) {
                return card
            }
        }
        return nil
    }

    /// 详情页打开一张卡片时借一下：返回凭证，页面拿着。卡片在 store 里已经有（两栏里）就用 store 里的当前样子，不用传进来的。
    func retain(_ card: FeedCard) -> FeedCardLease {
        pruneLeases()
        let lease = FeedCardLease(id: card.id)
        leases.append(Weak(lease))
        if heldCards[card.id] == nil {
            heldCards[card.id] = self.card(id: card.id) ?? card
        }
        return lease
    }

    private func pruneLeases() {
        leases.removeAll { $0.value == nil }
        let live = Set(leases.compactMap { $0.value?.id })
        for id in heldCards.keys where !live.contains(id) {
            heldCards.removeValue(forKey: id)
        }
    }

    /// 取到了一张最新的卡片（详情页的 Card API）：换掉 store 里这张的所有副本，列表马上看到新的赞数、评论数。
    /// 保留：列表专有的「谁转发了」（Card API 不带）、路上还没回来的点赞 / 收藏 / 转发（界面上的改动不被旧值盖掉）。
    func ingest(_ fresh: FeedCard) {
        var changed = false
        for tab in FeedTab.allCases {
            var state = self.tab(tab)
            guard let index = state.cards.firstIndex(where: { $0.id == fresh.id }) else { continue }
            let merged = reconciled(fresh, local: state.cards[index], keepListOnlyFields: true)
            if merged != state.cards[index] {
                state.cards[index] = merged
                tabStates[tab] = state
                changed = true
            }
        }
        if let held = heldCards[fresh.id] {
            let merged = reconciled(fresh, local: held, keepListOnlyFields: true)
            if merged != held {
                heldCards[fresh.id] = merged
                changed = true
            }
        }
        if changed {
            notify(.cards([fresh.id]))
        }
    }

    private func reconciled(_ fresh: FeedCard, local: FeedCard?, keepListOnlyFields: Bool) -> FeedCard {
        var card = fresh
        guard let local else { return card }
        if keepListOnlyFields {
            card.repostedBy = local.repostedBy
        }
        if likesInFlight[card.id, default: 0] > 0 {
            card.viewer.liked = local.viewer.liked
            card.stats.likes = local.stats.likes
        }
        if saving.contains(card.id) {
            card.viewer.saved = local.viewer.saved
        }
        if reposting.contains(card.id) {
            card.viewer.reposted = local.viewer.reposted
            card.stats.reposts = local.stats.reposts
        }
        return card
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

    /// 打开了一条详情（I-13）：报 `open`；还有没收尾的上一条，先按「现在离开」收尾。
    /// 详情页自己负责什么时候调（出现一次；返回 / 退到后台时 `onDetailClosed`），所以这里不跟动态页的「藏起来」绑在一起（推详情页本身会让动态页消失）。
    func onDetailOpened(contentId: String, surface: FeedEventSurface) {
        enqueue(detailEvents.opened(contentId: contentId, surface: surface, now: now()))
    }

    /// 离开了详情（返回、退到后台）：按停留报 `quick_exit`（≤ 3 秒）、`dwell`（≥ 30 秒）或什么都不报；没有打开的就什么都不做。
    /// `flush`：退到后台时顺便发掉（马上就可能被系统挂起）。
    func onDetailClosed(flush: Bool = false) {
        enqueue(detailEvents.closed(now: now()))
        if flush { flushEvents() }
    }

    /// 一次分享做完（I-13）：只有真的完成才报 `share`，取消不报；不能分享（`shareable` 为 false）的卡片也不报。
    /// 转发（`PUT …/repost`）有自己的接口，别走这里。
    func onShareFinished(contentId: String, surface: FeedEventSurface, shareable: Bool, outcome: FeedShareOutcome) {
        guard let event = outcome.event(contentId: contentId, surface: surface, shareable: shareable, at: now()) else { return }
        enqueue([event])
    }

    /// 列表卡片上直接分享（产品 2026-10-23）：口径同详情页（系统分享面板选了目标、复制链接才算完成），`surface` 是卡片所在的那一栏。
    /// 开关和详情事件同一条：内部开关「detail events」（默认关）并且引擎部署了 `events`（`TellomiFeed.isDetailEventsEnabled` 已含能力判断）。
    /// 引擎的 `surface` 只有五个值、没有「列表 / 详情」之分，所以同一栏里列表分享和详情分享在引擎那边分不开。
    func onListShareFinished(
        contentId: String,
        surface: FeedEventSurface,
        shareable: Bool,
        outcome: FeedShareOutcome,
        eventsEnabled: Bool = TellomiFeed.isDetailEventsEnabled
    ) {
        guard eventsEnabled else { return }
        onShareFinished(contentId: contentId, surface: surface, shareable: shareable, outcome: outcome)
    }

    private func enqueue(_ payloads: [FeedEventPayload]) {
        guard !payloads.isEmpty else { return }
        var full = false
        for payload in payloads {
            full = events.add(payload) || full
        }
        if full { flushEvents() }
        startFlushTimerIfNeeded()
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
            notify(.list(nil))
            onConfigLoaded?(config)
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
                let incoming = page.cards.filter { $0.isRenderable && !$0.matchesAny(blocked) }.map { self.reconciled($0, local: self.card(id: $0.id), keepListOnlyFields: false) }
                self.refreshHeldCopies(from: incoming)
                self.update(tab) { state in
                    // 刷新时，已经在列表里的卡片也要按「完全屏蔽」的词再过一遍：不然设置页刚加的词，刷新后屏幕上原来那几条还留着
                    state.cards = refresh ? Self.mergeRefresh(incoming: incoming, existing: state.cards.filter { !$0.matchesAny(blocked) }) : Self.appendPage(existing: state.cards, incoming: incoming)
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
        setLike(id: card.id, to: !card.viewer.liked)
    }

    /// 按 id 点赞 / 取消：以 store 里这张卡片**现在**的样子为准（详情页没有自己的副本，不会拿着过期的卡片反着点）。找不到这张卡片就什么都不做。
    func toggleLike(id: String) {
        guard let current = card(id: id) else { return }
        setLike(id: id, to: !current.viewer.liked)
    }

    /// 先改界面（所有副本一起改、所有订阅者都收到），再发请求。
    /// 同一张卡片的点赞请求**排队一个一个发**（后一个等前一个回来），不会乱序、服务器上最后落的一定是最后一次点的。
    /// 失败：前面还有后续请求在路上的，由后续的结果说了算；最后一个失败才改回「服务器已确认的那个状态」，发 `actionFailed`，列表页另有 `onTransientError`。
    private func setLike(id: String, to nowLiked: Bool) {
        if likesInFlight[id] == nil, let current = card(id: id) {
            likeConfirmed[id] = current.viewer.liked
        }
        updateCard(id) { $0 = Self.withLiked($0, nowLiked) }
        likesInFlight[id, default: 0] += 1
        let previous = likeTails[id]
        let task = Task { [weak self, source] in
            await previous?.value
            var failed = false
            do {
                try await source.setLiked(contentId: id, liked: nowLiked)
            } catch {
                Logger.warn("feed like failed: \(error)")
                failed = true
            }
            guard let self else { return }
            if !failed { self.likeConfirmed[id] = nowLiked }
            let remaining = self.finishLike(id)
            guard remaining == 0 else { return }
            let confirmed = self.likeConfirmed.removeValue(forKey: id)
            self.likeTails.removeValue(forKey: id)
            if failed {
                self.updateCard(id) { $0 = Self.withLiked($0, confirmed ?? !nowLiked) }
                self.notify(.actionFailed(cardId: id))
                self.onTransientError?(.actionFailed)
            }
        }
        likeTails[id] = task
        actionTasks.append(task)
    }

    /// 返回这张卡片还在路上的点赞请求数。
    @discardableResult
    private func finishLike(_ id: String) -> Int {
        let remaining = likesInFlight[id, default: 0] - 1
        if remaining > 0 {
            likesInFlight[id] = remaining
            return remaining
        }
        likesInFlight.removeValue(forKey: id)
        return 0
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
        notify(.list(nil))
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
            self.notify(.list(nil))
        })
    }

    func onInsightsDismissed() {
        insights = nil
        notify(.list(nil))
    }

    func notInterested(_ card: FeedCard) {
        hiddenIds.insert(card.id)
        notify(.list(nil))
        Task { [source] in
            do {
                try await source.notInterested(contentId: card.id)
            } catch {
                Logger.warn("feed not interested failed: \(error)")
            }
        }
    }

    /// 自己的帖子删掉了（引擎说成了）：两栏里去掉这一条，列表马上少一行。被详情页借着的那份不动（页面马上关，放手就清）。
    func removeCard(id: String) {
        pruneLeases()
        var changed = removedCardIds.insert(id).inserted && heldCards[id] != nil
        for tab in tabs {
            var state = self.tab(tab)
            let before = state.cards.count
            state.cards.removeAll { $0.id == id }
            if state.cards.count != before {
                tabStates[tab] = state
                changed = true
            }
        }
        if hiddenIds.remove(id) != nil { changed = true }
        if changed { notify(.list(nil)) }
    }

    /// 屏蔽了一个作者（引擎说成了）：两栏里这个人的帖子都去掉。被页面借着的那份不动。
    func removeCards(byAuthor profileId: String) {
        pruneLeases()
        removedAuthorIds.insert(profileId)
        var changed = heldCards.values.contains { $0.author?.profileId == profileId }
        for tab in tabs {
            var state = self.tab(tab)
            let before = state.cards.count
            state.cards.removeAll { $0.author?.profileId == profileId }
            if state.cards.count != before {
                tabStates[tab] = state
                changed = true
            }
        }
        if changed { notify(.list(nil)) }
    }

    // MARK: - 通知未读数

    func setNotificationUnread(_ counts: FeedUnreadCounts) {
        guard counts != notificationUnread else { return }
        notificationUnread = counts
        notify(.unread)
    }

    /// 问一次引擎最新的未读数（红点）。30 秒内问过、上一次还在路上、被限速（429 / 带 `Retry-After` 的 503，按头里的秒数或指数退避）时不发；
    /// 失败只记日志、红点保持原样（红点不是要紧事，不弹提示）。`force` 跳过 30 秒的间隔（比如下拉刷新），但不跳过限速等待。
    func refreshNotificationUnread(force: Bool = false) {
        let current = now()
        if unreadTask != nil || unreadGate.isBlocked(now: current) { return }
        if !force, let checked = unreadCheckedAt, current >= checked, current.timeIntervalSince(checked) < Self.unreadRefreshInterval { return }
        unreadCheckedAt = current
        unreadTask = Task { [weak self, source] in
            do {
                let response = try await source.notifications(tab: FeedAPI.notificationsInteractions, before: nil)
                guard let self else { return }
                self.unreadGate.reset()
                self.setNotificationUnread(response.unread)
            } catch {
                guard let self else { return }
                if let api = error as? FeedAPIError { self.unreadGate.record(api, now: self.now(), random: self.jitter()) }
                Logger.warn("feed notification unread failed: \(error)")
            }
            self?.unreadTask = nil
        }
    }

    func waitForNotificationUnread() async {
        await unreadTask?.value
    }

    /// 取消屏蔽：这个作者的帖子可以再出现在借着它们的页面里（信息流里去掉的要等下次刷新才回来）。
    func allowCards(byAuthor profileId: String) {
        removedAuthorIds.remove(profileId)
    }

    /// 这条帖子（只知道 id，比如「我的动态」里的一行）已经在别处删掉了（详情页删、自己列表里删）。
    func isRemoved(id: String) -> Bool {
        return removedCardIds.contains(id)
    }

    /// 这张卡片因为屏蔽了作者、删了帖子，已经不该再显示（借着它的页面据此去掉）。
    func isRemoved(_ card: FeedCard) -> Bool {
        if removedCardIds.contains(card.id) { return true }
        guard let author = card.author?.profileId else { return false }
        return removedAuthorIds.contains(author)
    }

    /// 详情页已经把「不感兴趣」报给引擎并且成功了：列表里这条换成可撤销的反馈卡，和在列表里点「不感兴趣」同样的显示。
    /// 不再发请求（撤销时 `undoNotInterested` 才发）。已经是反馈卡就不动。
    func markNotInterested(id: String) {
        guard hiddenIds.insert(id).inserted else { return }
        notify(.list(nil))
    }

    func undoNotInterested(_ cardId: String) {
        guard hiddenIds.remove(cardId) != nil else { return }
        notify(.list(nil))
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
        notify(.list(tab))
    }

    /// 改一张卡片：两栏里的、被借着的，所有副本一起改，然后通知所有订阅者。详情页的收藏 / 转发 / 投票 / 置顶也走这里。
    func updateCard(_ id: String, _ transform: (inout FeedCard) -> Void) {
        for (tab, var state) in tabStates {
            guard let index = state.cards.firstIndex(where: { $0.id == id }) else { continue }
            transform(&state.cards[index])
            tabStates[tab] = state
        }
        if var held = heldCards[id] {
            transform(&held)
            heldCards[id] = held
        }
        notify(.cards([id]))
    }

    /// 一页新取回来的卡片里，有被借着的就同步一下借着的那份（两份来自同一个服务端，不能一份新一份旧）。
    private func refreshHeldCopies(from incoming: [FeedCard]) {
        for card in incoming where heldCards[card.id] != nil {
            heldCards[card.id] = reconciled(card, local: heldCards[card.id], keepListOnlyFields: true)
        }
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
