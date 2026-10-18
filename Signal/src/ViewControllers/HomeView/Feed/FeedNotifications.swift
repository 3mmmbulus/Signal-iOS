//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedNotifications.swift (new file)
// Feed notifications (I-7): models, API, grouping, list store, and the "Settings → Notifications" store, without UI.
// Mirror of Android `notifications/FeedNotificationRows.kt`, `FeedNotificationsViewModel.kt`,
// `settings/FeedNotificationSettingsViewModel.kt`, `FeedApi.notifications/markNotificationsRead/deleteNotification/muteNotifications`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

struct FeedUnreadCounts: Decodable, Equatable {
    var interactions = 0
    var follows = 0
    var system = 0

    init() {}

    init(interactions: Int = 0, follows: Int = 0, system: Int = 0) {
        self.interactions = interactions
        self.follows = follows
        self.system = system
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interactions = try c.decodeIfPresent(Int.self, forKey: .interactions) ?? 0
        follows = try c.decodeIfPresent(Int.self, forKey: .follows) ?? 0
        system = try c.decodeIfPresent(Int.self, forKey: .system) ?? 0
    }

    func of(tab: String) -> Int {
        switch tab {
        case FeedAPI.notificationsFollows: return follows
        case FeedAPI.notificationsSystem: return system
        default: return interactions
        }
    }

    func without(tab: String) -> FeedUnreadCounts {
        var copy = self
        switch tab {
        case FeedAPI.notificationsFollows: copy.follows = 0
        case FeedAPI.notificationsSystem: copy.system = 0
        default: copy.interactions = 0
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey { case interactions, follows, system }
}

/// 通知里的 `detail`（只认三个字段；不是对象或字段类型不对就当没有，和 Android 的 `try/catch` 一样）。
struct FeedNotificationDetail: Decodable, Equatable {
    /// 系统通知的类型（`rejected`、`edit_rejected`、`taken_down`、`appeal_upheld`、`appeal_overturned`、`close_person_request`）。
    var type: String?
    /// 评论等我批准。
    var held: Bool?
    /// `close_person_request` 里设我的人。
    var profileId: String?

    init(type: String? = nil, held: Bool? = nil, profileId: String? = nil) {
        self.type = type
        self.held = held
        self.profileId = profileId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        held = (try? c.decodeIfPresent(Bool.self, forKey: .held)) ?? nil
        profileId = (try? c.decodeIfPresent(String.self, forKey: .profileId)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case type, held
        case profileId = "profile_id"
    }
}

struct FeedNotification: Decodable, Equatable {
    var id: String
    var kind: String
    var actorId: String?
    var contentId: String?
    var subjectId: String?
    var detail: FeedNotificationDetail?
    var createdAt: String
    var read = false
    var actor: FeedPersonSummary?

    static let kindLike = "like"
    static let kindComment = "comment"
    static let kindReply = "reply"
    static let kindFollow = "follow"
    static let kindFollowRequest = "follow_request"
    static let kindSystem = "system"

    static let systemRejected = "rejected"
    static let systemEditRejected = "edit_rejected"
    static let systemTakenDown = "taken_down"
    static let systemAppealUpheld = "appeal_upheld"
    static let systemAppealOverturned = "appeal_overturned"
    static let systemClosePersonRequest = "close_person_request"

    init(id: String, kind: String, createdAt: String, actorId: String? = nil, contentId: String? = nil, subjectId: String? = nil,
         detail: FeedNotificationDetail? = nil, read: Bool = false, actor: FeedPersonSummary? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.actorId = actorId
        self.contentId = contentId
        self.subjectId = subjectId
        self.detail = detail
        self.read = read
        self.actor = actor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        actorId = try c.decodeIfPresent(String.self, forKey: .actorId)
        contentId = try c.decodeIfPresent(String.self, forKey: .contentId)
        subjectId = try c.decodeIfPresent(String.self, forKey: .subjectId)
        detail = (try? c.decodeIfPresent(FeedNotificationDetail.self, forKey: .detail)) ?? nil
        createdAt = try c.decode(String.self, forKey: .createdAt)
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
        actor = try c.decodeIfPresent(FeedPersonSummary.self, forKey: .actor)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, detail, read, actor
        case actorId = "actor_id"
        case contentId = "content_id"
        case subjectId = "subject_id"
        case createdAt = "created_at"
    }
}

/// `GET /v1/feed/me/notifications?tab=`：一页 30 条，新的在前。引擎只给 `actorId`；带了 `actor` 就直接用，没带客户端自己查主页。
struct FeedNotificationsResponse: Decodable, Equatable {
    var notifications = [FeedNotification]()
    var unread = FeedUnreadCounts()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifications = try c.decodeIfPresent([FeedNotification].self, forKey: .notifications) ?? []
        unread = try c.decodeIfPresent(FeedUnreadCounts.self, forKey: .unread) ?? FeedUnreadCounts()
    }

    private enum CodingKeys: String, CodingKey { case notifications, unread }
}

private struct FeedNotificationsReadRequest: Encodable {
    var tab: String
}

private struct FeedNotificationMuteRequest: Encodable {
    var likesOnly: Bool

    private enum CodingKeys: String, CodingKey { case likesOnly = "likes_only" }
}

extension FeedAPI {
    static let notificationsInteractions = "interactions"
    static let notificationsFollows = "follows"
    static let notificationsSystem = "system"
    static let notificationsPage = 30

    /// 一栏通知，新的在前；`before` 是上一页最后一条的 `created_at`。
    func notifications(tab: String, before: String?) async throws -> FeedNotificationsResponse {
        var query = [URLQueryItem(name: "tab", value: tab)]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        return try await send(FeedNotificationsResponse.self, request(path: ["v1", "feed", "me", "notifications"], query: query))
    }

    /// 整栏标为已读（204）。
    func markNotificationsRead(tab: String) async throws {
        let body = try Self.encoder.encode(FeedNotificationsReadRequest(tab: tab))
        try await sendNoContent(request(path: ["v1", "feed", "me", "notifications", "read"], method: "POST", body: body))
    }

    /// 删一条通知（204）。
    func deleteNotification(id: String) async throws {
        try await sendNoContent(request(path: ["v1", "feed", "me", "notifications", id], method: "DELETE"))
    }

    /// 这条帖子不再通知：全部，或者只关赞（204）。
    func muteNotifications(contentId: String, likesOnly: Bool) async throws {
        let body = try Self.encoder.encode(FeedNotificationMuteRequest(likesOnly: likesOnly))
        try await sendNoContent(request(path: ["v1", "feed", "me", "notification-mutes", contentId], method: "PUT", body: body))
    }
}

// MARK: - 分组

/// 一行通知。同一条帖子的赞合成一行，`actorIds` 新的在前。
struct FeedNotificationRow: Equatable {
    var key: String
    var kind: String
    var ids: [String]
    var actorIds: [String]
    var contentId: String?
    var subjectId: String?
    var systemType: String?
    /// 评论等我批准（被「限制」的人、或者开了评论审核）。
    var held: Bool
    /// `close_person_request` 里设我的人。
    var profileId: String?
    var createdAt: Date
    var unread: Bool
}

enum FeedNotificationBucket: Int, Comparable {
    case today
    case thisWeek
    case earlier

    static func < (lhs: FeedNotificationBucket, rhs: FeedNotificationBucket) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct FeedNotificationSection: Equatable {
    var bucket: FeedNotificationBucket
    var rows: [FeedNotificationRow]
}

enum FeedNotificationGrouping {
    /// 合并赞、按时间分组（今天 / 七天内 / 更早）。列表本来就是新的在前，合并后的一行排在最新那个赞的位置。
    /// 读不懂时间的通知丢掉（Android 同）。`calendar` 决定「今天」按哪个时区算。
    static func group(_ items: [FeedNotification], now: Date, calendar: Calendar) -> [FeedNotificationSection] {
        var rows = [FeedNotificationRow]()
        var likeRowIndex = [String: Int]()

        for item in items {
            guard let createdAt = FeedDates.parse(item.createdAt) else { continue }
            if item.kind == FeedNotification.kindLike, let contentId = item.contentId {
                if let index = likeRowIndex[contentId] {
                    rows[index].ids.append(item.id)
                    if let actorId = item.actorId, !rows[index].actorIds.contains(actorId) {
                        rows[index].actorIds.append(actorId)
                    }
                    rows[index].unread = rows[index].unread || !item.read
                    continue
                }
                likeRowIndex[contentId] = rows.count
            }
            rows.append(FeedNotificationRow(
                key: item.id,
                kind: item.kind,
                ids: [item.id],
                actorIds: item.actorId.map { [$0] } ?? [],
                contentId: item.contentId,
                subjectId: item.subjectId,
                systemType: item.detail?.type,
                held: item.detail?.held == true,
                profileId: item.detail?.profileId,
                createdAt: createdAt,
                unread: !item.read
            ))
        }

        let today = calendar.startOfDay(for: now)
        var byBucket = [FeedNotificationBucket: [FeedNotificationRow]]()
        for row in rows {
            let day = calendar.startOfDay(for: row.createdAt)
            byBucket[bucket(of: day, today: today, calendar: calendar), default: []].append(row)
        }
        return byBucket.keys.sorted().map { FeedNotificationSection(bucket: $0, rows: byBucket[$0] ?? []) }
    }

    private static func bucket(of day: Date, today: Date, calendar: Calendar) -> FeedNotificationBucket {
        if day >= today { return .today }
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        if day > weekAgo { return .thisWeek }
        return .earlier
    }
}

// MARK: - 列表

struct FeedNotificationsTab: Equatable {
    var items = [FeedNotification]()
    var loading = false
    var loadingMore = false
    /// 第一页加载失败（已有的 `items` 留着；界面只在没有内容时说「加载失败」+ 重试，有内容时弹提示）。
    var failed = false
    /// 翻页失败：已有的留着，列表末尾给「重试」，不自动再试。
    var loadMoreFailed = false
    /// 被限速时还要等几秒（`failed` / `loadMoreFailed` 时说）；没有 `Retry-After` 是 nil。
    var retryAfterSeconds: Int?
    var loadedOnce = false
    var hasMore = false
}

struct FeedNotificationsState: Equatable {
    enum Notice: Equatable {
        case deleted
        case muted
        case mutedLikes
        case postGone
        case failed
        /// 被限速；要等几秒在 `retryAfterSeconds`。
        case throttled
    }

    var selectedTab = FeedAPI.notificationsInteractions
    var tabs = [String: FeedNotificationsTab]()
    var unread = FeedUnreadCounts()
    /// actor id → 名字和头像（引擎带了或者查过主页的）。
    var people = [String: FeedPersonSummary]()
    var notice: Notice?
    /// `notice == .throttled` 时还要等几秒。
    var retryAfterSeconds: Int?
    /// 引擎说这个区域的动态被关了（404 `feed_hidden`）：页面该收起，不是「加载失败」。
    var feedHidden = false
    /// 要打开详情的帖子（`openPost` 换好的，已经是 `FeedStore` 里现在的样子）。
    var openCard: FeedCard?

    func tab(_ name: String) -> FeedNotificationsTab { tabs[name] ?? FeedNotificationsTab() }
}

/// 动态通知（第三节第 43 条）：互动 / 新关注 / 系统三栏。
/// 一栏第一次加载完就整栏标为已读（这一次仍按服务端的已读状态画小点）。引擎只给 `actor_id` 时，按人查一次主页拿名字，同一个人只查一次。
///
/// 和信息流共用 `FeedStore`（传了 `feed` 的时候）：未读数放在它里面（动态页的红点和这一页同一份）；点开帖子时先把取到的最新卡片换进它里面（`FeedCardMirror`），
/// 详情页拿到的就是它里面现在的样子，赞、评论数和别的页面一致；被屏蔽作者的、删掉的帖子打不开（提示「帖子已不可见」）。不传就自己独立运行（单测）。
@MainActor
final class FeedNotificationsStore {
    static let tabs = [FeedAPI.notificationsInteractions, FeedAPI.notificationsFollows, FeedAPI.notificationsSystem]

    private let source: FeedSource
    private let feed: FeedStore?
    private let mirror: FeedCardMirror?
    private var unreadSubscription: FeedSubscription?
    private var tasks = [Task<Void, Never>]()
    private var loadTasks = [String: Task<Void, Never>]()
    private var running = Set<String>()
    private var lookedUp = Set<String>()

    private(set) var state: FeedNotificationsState {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedNotificationsState) -> Void)?

    init(initialTab: String = FeedAPI.notificationsInteractions, source: FeedSource, feed: FeedStore? = nil) {
        self.source = source
        self.feed = feed
        self.mirror = feed.map { FeedCardMirror(feed: $0) }
        var initial = FeedNotificationsState(selectedTab: initialTab)
        if let feed { initial.unread = feed.notificationUnread }
        self.state = initial
        mirror?.shownIds = { [weak self] in Set(self?.state.openCard.map { [$0.id] } ?? []) }
        mirror?.onChange = { [weak self] in
            guard let self, let card = self.state.openCard, let next = self.mirror?.project([card]).first, next != card else { return }
            self.state.openCard = next
        }
        unreadSubscription = feed?.subscribe { [weak self] change in
            guard change == .unread, let self, let feed = self.feed, self.state.unread != feed.notificationUnread else { return }
            self.state.unread = feed.notificationUnread
        }
    }

    // MARK: - 和信息流 store 同步

    var isObservingFeed: Bool { mirror?.isObserving == true && unreadSubscription?.isActive == true }
    /// 借着的帖子数（单测用）。
    var leaseCount: Int { mirror?.leaseCount ?? 0 }

    /// 页面离开了：不再订阅、放掉借着的卡片。可以重复调用。
    func detach() {
        mirror?.detach()
        unreadSubscription?.cancel()
        unreadSubscription = nil
    }

    private func setUnread(_ counts: FeedUnreadCounts) {
        state.unread = counts
        feed?.setNotificationUnread(counts)
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
        await mirror?.waitForActions()
    }

    func start() {
        load(state.selectedTab, before: nil)
    }

    func selectTab(_ tab: String) {
        state.selectedTab = tab
        if !state.tab(tab).loadedOnce && !running.contains(tab) { load(tab, before: nil) }
    }

    func refresh() {
        load(state.selectedTab, before: nil)
    }

    /// 往下翻（滚到底、或点末尾的「重试」）。
    func loadMore() {
        let tab = state.selectedTab
        let current = state.tab(tab)
        guard current.hasMore, !running.contains(tab), let last = current.items.last else { return }
        load(tab, before: last.createdAt)
    }

    /// 举报 / 别处让页面该收起（`feed_hidden`）。
    func onFeedHidden() {
        state.feedHidden = true
    }

    private func updateTab(_ tab: String, _ change: (inout FeedNotificationsTab) -> Void) {
        var current = state.tab(tab)
        change(&current)
        state.tabs[tab] = current
    }

    private func load(_ tab: String, before: String?) {
        loadTasks[tab]?.cancel()
        running.insert(tab)
        updateTab(tab) {
            $0.loading = before == nil
            $0.loadingMore = before != nil
            $0.failed = false
            $0.loadMoreFailed = false
            $0.retryAfterSeconds = nil
        }
        let task = Task { [weak self, source] in
            let response: FeedNotificationsResponse
            do {
                response = try await source.notifications(tab: tab, before: before)
            } catch {
                Logger.warn("feed notifications failed: \(error)")
                guard !Task.isCancelled, let self else { return }
                self.running.remove(tab)
                let failure = FeedActionFailure.classify(error)
                var seconds: Int?
                if case .throttled(let retryAfter) = failure { seconds = retryAfter }
                self.updateTab(tab) {
                    $0.loading = false
                    $0.loadingMore = false
                    if failure != .feedHidden {
                        if before == nil { $0.failed = true } else { $0.loadMoreFailed = true }
                        $0.retryAfterSeconds = seconds
                    }
                }
                if failure == .feedHidden { self.state.feedHidden = true }
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.running.remove(tab)
            let wasLoaded = self.state.tab(tab).loadedOnce
            var old = self.state.tab(tab)
            let known = before == nil ? Set<String>() : Set(old.items.map(\.id))
            let base = before == nil ? [] : old.items
            old.items = base + response.notifications.filter { !known.contains($0.id) }
            old.loading = false
            old.loadingMore = false
            old.loadedOnce = true
            old.hasMore = response.notifications.count >= FeedAPI.notificationsPage
            self.state.tabs[tab] = old
            self.setUnread(response.unread)
            for n in response.notifications {
                if let actor = n.actor { self.state.people[actor.id] = actor }
            }
            self.lookUpActors(response.notifications)
            if !wasLoaded && response.unread.of(tab: tab) > 0 { self.markRead(tab) }
        }
        loadTasks[tab] = task
        tasks.append(task)
    }

    private func markRead(_ tab: String) {
        tasks.append(Task { [weak self, source] in
            do {
                try await source.markNotificationsRead(tab: tab)
                guard let self else { return }
                self.setUnread(self.state.unread.without(tab: tab))
            } catch {
                Logger.warn("feed mark read failed: \(error)")
            }
        })
    }

    private func lookUpActors(_ items: [FeedNotification]) {
        var wanted = [String]()
        for item in items {
            if item.actor == nil, let id = item.actorId { wanted.append(id) }
            if let id = item.detail?.profileId { wanted.append(id) }
        }
        var seen = Set<String>()
        let missing = wanted.filter { seen.insert($0).inserted && state.people[$0] == nil && lookedUp.insert($0).inserted }
        for id in missing {
            tasks.append(Task { [weak self, source] in
                do {
                    guard let profile = try await source.profile(profileId: id) else { return }
                    let person = FeedPersonSummary(id: profile.id, handle: profile.handle, displayName: profile.displayName, avatarKey: profile.avatarKey)
                    self?.state.people[id] = person
                } catch {
                    Logger.warn("feed actor lookup failed: \(error)")
                    self?.lookedUp.remove(id)
                }
            })
        }
    }

    /// 删一行（合并过的赞是几条一起删）。已经不存在（404）当删成了。
    func delete(_ row: FeedNotificationRow) {
        let tab = state.selectedTab
        let before = state.tab(tab).items
        updateTab(tab) { $0.items.removeAll { row.ids.contains($0.id) } }
        tasks.append(Task { [weak self, source] in
            do {
                for id in row.ids { try await source.deleteNotification(id: id) }
                self?.state.notice = .deleted
            } catch {
                Logger.warn("feed notification delete failed: \(error)")
                if FeedActionFailure.classify(error) == .gone {
                    self?.state.notice = .deleted
                    return
                }
                self?.updateTab(tab) { $0.items = before }
                self?.told(error, goneNotice: .failed)
            }
        })
    }

    /// 这条帖子不再通知：全部，或者只关赞。已经在列表里的相应几行一起拿掉。帖子已经不存在（404）：拿掉的不放回来，提示「帖子已不可见」。
    func mute(_ row: FeedNotificationRow, likesOnly: Bool) {
        guard let contentId = row.contentId else { return }
        let tab = state.selectedTab
        let before = state.tab(tab).items
        updateTab(tab) { $0.items.removeAll { $0.contentId == contentId && (!likesOnly || $0.kind == FeedNotification.kindLike) } }
        tasks.append(Task { [weak self, source] in
            do {
                try await source.muteNotifications(contentId: contentId, likesOnly: likesOnly)
                self?.state.notice = likesOnly ? .mutedLikes : .muted
            } catch {
                Logger.warn("feed notification mute failed: \(error)")
                if FeedActionFailure.classify(error) == .gone {
                    self?.state.notice = .postGone
                    return
                }
                self?.updateTab(tab) { $0.items = before }
                self?.told(error, goneNotice: .postGone)
            }
        })
    }

    /// 点赞 / 评论通知：先换成卡片再进详情；帖子删了、作者被屏蔽了就提示一下。
    func openPost(_ contentId: String) {
        tasks.append(Task { [weak self, source] in
            let card: FeedCard?
            do {
                card = try await source.card(contentId: contentId)
            } catch {
                Logger.warn("feed notification card failed: \(error)")
                self?.told(error, goneNotice: .postGone)
                return
            }
            guard let self else { return }
            guard let card else {
                self.state.notice = .postGone
                return
            }
            if let mirror = self.mirror {
                guard let adopted = mirror.adopt([card]).first else {
                    self.state.notice = .postGone
                    return
                }
                self.state.openCard = adopted
            } else {
                self.state.openCard = card
            }
        })
    }

    /// 详情页已经打开（它自己借着这张卡片了）：这边放手。
    func onCardOpened() {
        state.openCard = nil
        mirror?.releaseAll()
    }

    func onNoticeShown() {
        state.notice = nil
        state.retryAfterSeconds = nil
    }

    /// 操作失败，按引擎的错误给提示：限速带秒数、`feed_hidden` 收页、404 用调用方给的提示、别的「操作失败」。
    private func told(_ error: Error, goneNotice: FeedNotificationsState.Notice) {
        switch FeedActionFailure.classify(error) {
        case .feedHidden:
            state.feedHidden = true
        case .throttled(let seconds):
            state.retryAfterSeconds = seconds
            state.notice = .throttled
        case .gone:
            state.notice = goneNotice
        case .profileRequired, .failed:
            state.retryAfterSeconds = nil
            state.notice = .failed
        }
    }
}

// MARK: - 设置 → 通知

struct FeedNotificationSettingsState: Equatable {
    enum Notice: Equatable {
        case profileRequired
        case saveFailed
        /// 被限速；要等几秒在 `retryAfterSeconds`。
        case throttled
    }

    var settings: FeedNotificationSettings?
    var loading = false
    var loadFailed = false
    /// 被限速时还要等几秒（`loadFailed` 页或 `notice == .throttled` 时说）；没有 `Retry-After` 是 nil。
    var retryAfterSeconds: Int?
    /// 引擎说这个区域的动态被关了（404 `feed_hidden`）：页面该收起，不是「加载失败」。
    var feedHidden = false
    var notice: Notice?

    /// 来源选了「都不接收」时，下面三个开关没有意义，变灰。
    var categoriesEnabled: Bool {
        guard let settings else { return false }
        return settings.fromWhom != FeedNotificationSettings.fromNone
    }
}

/// 「设置 → 通知」里的动态那一段（第三节第 30、43 条）。打开页面时读一次；改了立刻存，先在界面上改过去，存不上再改回来。
/// 没有公开主页时引擎不让存（409 `profile_required`），提示先建主页。
@MainActor
final class FeedNotificationSettingsStore {
    private let source: FeedSource
    private var tasks = [Task<Void, Never>]()
    /// 整份设置一起 PUT，所以几次保存要按点的顺序一个接一个发，不然后点的可能先到、被先点的盖掉。
    private var lastSave: Task<Void, Never>?

    private(set) var state = FeedNotificationSettingsState() {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedNotificationSettingsState) -> Void)?

    init(source: FeedSource) {
        self.source = source
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
    }

    /// 回到页面时调；读到了就不再读。
    func load() {
        if state.settings != nil || state.loading { return }
        state.loading = true
        state.loadFailed = false
        state.retryAfterSeconds = nil
        tasks.append(Task { [weak self, source] in
            do {
                let settings = try await source.notificationSettings()
                self?.state.loading = false
                self?.state.settings = settings
            } catch {
                Logger.warn("feed notification settings failed: \(error)")
                guard let self else { return }
                self.state.loading = false
                switch FeedActionFailure.classify(error) {
                case .feedHidden:
                    self.state.feedHidden = true
                case .throttled(let seconds):
                    self.state.retryAfterSeconds = seconds
                    self.state.loadFailed = true
                default:
                    self.state.loadFailed = true
                }
            }
        })
    }

    func setFromWhom(_ value: String) {
        if FeedNotificationSettings.fromValues.contains(value) { save { $0.fromWhom = value } }
    }

    func setLikes(_ on: Bool) { save { $0.likes = on } }
    func setComments(_ on: Bool) { save { $0.comments = on } }
    func setFollows(_ on: Bool) { save { $0.follows = on } }

    func onNoticeShown() {
        state.notice = nil
        if !state.loadFailed { state.retryAfterSeconds = nil }
    }

    /// 页面离开前 / 别处让页面该收起（`feed_hidden`）。
    func onFeedHidden() {
        state.feedHidden = true
    }

    private func save(_ transform: (inout FeedNotificationSettings) -> Void) {
        guard let before = state.settings else { return }
        var after = before
        transform(&after)
        if after == before { return }
        state.settings = after
        let previous = lastSave
        let task = Task { [weak self, source] in
            await previous?.value
            do {
                _ = try await source.saveNotificationSettings(after)
            } catch {
                Logger.warn("feed save notification settings failed: \(error)")
                guard let self else { return }
                // 只在还是这一次改的值时改回去，别盖掉后面的改动
                if self.state.settings == after { self.state.settings = before }
                switch FeedActionFailure.classify(error) {
                case .feedHidden:
                    self.state.feedHidden = true
                case .throttled(let seconds):
                    self.state.retryAfterSeconds = seconds
                    self.state.notice = .throttled
                case .profileRequired:
                    self.state.notice = .profileRequired
                case .gone, .failed:
                    self.state.notice = .saveFailed
                }
            }
        }
        lastSave = task
        tasks.append(task)
    }
}
