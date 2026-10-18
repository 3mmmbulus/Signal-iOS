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
    var failed = false
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
    }

    var selectedTab = FeedAPI.notificationsInteractions
    var tabs = [String: FeedNotificationsTab]()
    var unread = FeedUnreadCounts()
    /// actor id → 名字和头像（引擎带了或者查过主页的）。
    var people = [String: FeedPersonSummary]()
    var notice: Notice?
    /// 要打开详情的帖子（`openPost` 换好的）。
    var openCard: FeedCard?

    func tab(_ name: String) -> FeedNotificationsTab { tabs[name] ?? FeedNotificationsTab() }
}

/// 动态通知（第三节第 43 条）：互动 / 新关注 / 系统三栏。
/// 一栏第一次加载完就整栏标为已读（这一次仍按服务端的已读状态画小点）。引擎只给 `actor_id` 时，按人查一次主页拿名字，同一个人只查一次。
@MainActor
final class FeedNotificationsStore {
    static let tabs = [FeedAPI.notificationsInteractions, FeedAPI.notificationsFollows, FeedAPI.notificationsSystem]

    private let source: FeedSource
    private var tasks = [Task<Void, Never>]()
    private var loadTasks = [String: Task<Void, Never>]()
    private var running = Set<String>()
    private var lookedUp = Set<String>()

    private(set) var state: FeedNotificationsState {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedNotificationsState) -> Void)?

    init(initialTab: String = FeedAPI.notificationsInteractions, source: FeedSource) {
        self.source = source
        self.state = FeedNotificationsState(selectedTab: initialTab)
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
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

    func loadMore() {
        let tab = state.selectedTab
        let current = state.tab(tab)
        guard current.hasMore, !running.contains(tab), let last = current.items.last else { return }
        load(tab, before: last.createdAt)
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
        }
        let task = Task { [weak self, source] in
            let response: FeedNotificationsResponse
            do {
                response = try await source.notifications(tab: tab, before: before)
            } catch {
                Logger.warn("feed notifications failed: \(error)")
                guard !Task.isCancelled, let self else { return }
                self.running.remove(tab)
                self.updateTab(tab) {
                    $0.loading = false
                    $0.loadingMore = false
                    $0.failed = true
                }
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
            self.state.unread = response.unread
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
                self.state.unread = self.state.unread.without(tab: tab)
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

    /// 删一行（合并过的赞是几条一起删）。
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
                self?.updateTab(tab) { $0.items = before }
                self?.state.notice = .failed
            }
        })
    }

    /// 这条帖子不再通知：全部，或者只关赞。已经在列表里的相应几行一起拿掉。
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
                self?.updateTab(tab) { $0.items = before }
                self?.state.notice = .failed
            }
        })
    }

    /// 点赞 / 评论通知：先换成卡片再进详情；帖子删了就提示一下。
    func openPost(_ contentId: String) {
        tasks.append(Task { [weak self, source] in
            let card: FeedCard?
            do {
                card = try await source.card(contentId: contentId)
            } catch {
                Logger.warn("feed notification card failed: \(error)")
                self?.state.notice = .failed
                return
            }
            if let card { self?.state.openCard = card } else { self?.state.notice = .postGone }
        })
    }

    func onCardOpened() {
        state.openCard = nil
    }

    func onNoticeShown() {
        state.notice = nil
    }
}

// MARK: - 设置 → 通知

struct FeedNotificationSettingsState: Equatable {
    enum Notice: Equatable {
        case profileRequired
        case saveFailed
    }

    var settings: FeedNotificationSettings?
    var loading = false
    var loadFailed = false
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
        tasks.append(Task { [weak self, source] in
            do {
                let settings = try await source.notificationSettings()
                self?.state.loading = false
                self?.state.settings = settings
            } catch {
                Logger.warn("feed notification settings failed: \(error)")
                self?.state.loading = false
                self?.state.loadFailed = true
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
                let api = error as? FeedAPIError
                let notice: FeedNotificationSettingsState.Notice = api?.status == 409 && api?.code == "profile_required" ? .profileRequired : .saveFailed
                // 只在还是这一次改的值时改回去，别盖掉后面的改动
                if self.state.settings == after { self.state.settings = before }
                self.state.notice = notice
            }
        }
        lastSave = task
        tasks.append(task)
    }
}
