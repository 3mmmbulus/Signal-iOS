//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 样例里通知的可变部分（本机内存，重开就回到初始）：已读、删掉的、不再通知的帖子、通知设置。
final class SampleNotificationState {
    private let lock = NSLock()
    private var readIds = Set<String>()
    private var deletedIds = Set<String>()
    private var mutedContent = Set<String>()
    private var mutedLikeContent = Set<String>()
    private var settings = FeedNotificationSettings()

    struct Snapshot {
        var readIds: Set<String>
        var deletedIds: Set<String>
        var mutedContent: Set<String>
        var mutedLikeContent: Set<String>
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(readIds: readIds, deletedIds: deletedIds, mutedContent: mutedContent, mutedLikeContent: mutedLikeContent)
    }

    func markRead(_ ids: [String]) {
        lock.lock()
        readIds.formUnion(ids)
        lock.unlock()
    }

    func delete(_ id: String) {
        lock.lock()
        deletedIds.insert(id)
        lock.unlock()
    }

    func mute(contentId: String, likesOnly: Bool) {
        lock.lock()
        if likesOnly { mutedLikeContent.insert(contentId) } else { mutedContent.insert(contentId) }
        lock.unlock()
    }

    func currentSettings() -> FeedNotificationSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    func save(_ value: FeedNotificationSettings) {
        lock.lock()
        settings = value
        lock.unlock()
    }
}

/// 样例的通知（内部用户在没有内容引擎时看界面用）。三栏：
/// - 互动：同一条帖子的赞会合成一行（`sample-0` 上有三个人的赞）、评论、回复（一条只带 `actor_id`，要靠查主页拿名字）、等我批准的评论，一共 36 条（第一页 30 条，能看到翻页）；
/// - 新关注：新关注、关注请求；
/// - 系统：被拒绝、被下架、申诉成立、亲密好友请求。
/// 第一次打开一栏时整栏标已读，红点（`unread`）随之清零；删除、不再通知也在内存里生效。
/// 失败 / 慢 / 限速见 `Simulation` 里通知相关的开关。
extension SampleFeedSource {
    private static let interactionCount = 36

    private func sampleNotificationItems(_ tab: String) -> [FeedNotification] {
        let base = now()
        func at(_ minutesAgo: Double) -> String { FeedDates.format(base.addingTimeInterval(-minutesAgo * 60)) }
        func person(_ index: Int) -> FeedPersonSummary {
            let author = Self.authors[index % Self.authors.count]
            return FeedPersonSummary(id: author.profileId, handle: author.handle, displayName: author.displayName, avatarKey: nil)
        }
        switch tab {
        case FeedAPI.notificationsFollows:
            return [
                FeedNotification(id: "n-f-1", kind: FeedNotification.kindFollow, createdAt: at(30), actorId: "s-2", actor: person(1)),
                FeedNotification(id: "n-f-2", kind: FeedNotification.kindFollowRequest, createdAt: at(180), actorId: "s-5", actor: person(4)),
                FeedNotification(id: "n-f-3", kind: FeedNotification.kindFollow, createdAt: at(2 * 24 * 60), actorId: "s-4", actor: person(3)),
                FeedNotification(id: "n-f-4", kind: FeedNotification.kindFollow, createdAt: at(10 * 24 * 60), actorId: "s-1", actor: person(0)),
            ]
        case FeedAPI.notificationsSystem:
            return [
                FeedNotification(id: "n-s-1", kind: FeedNotification.kindSystem, createdAt: at(90), contentId: "sample-4", detail: FeedNotificationDetail(type: FeedNotification.systemRejected)),
                FeedNotification(id: "n-s-2", kind: FeedNotification.kindSystem, createdAt: at(24 * 60), contentId: "sample-5", detail: FeedNotificationDetail(type: FeedNotification.systemTakenDown)),
                FeedNotification(id: "n-s-3", kind: FeedNotification.kindSystem, createdAt: at(3 * 24 * 60), contentId: "sample-5", detail: FeedNotificationDetail(type: FeedNotification.systemAppealUpheld)),
                FeedNotification(id: "n-s-4", kind: FeedNotification.kindSystem, createdAt: at(4 * 24 * 60), detail: FeedNotificationDetail(type: FeedNotification.systemClosePersonRequest, profileId: "s-1")),
                FeedNotification(id: "n-s-5", kind: FeedNotification.kindSystem, createdAt: at(12 * 24 * 60), contentId: "sample-6", detail: FeedNotificationDetail(type: FeedNotification.systemEditRejected)),
            ]
        default:
            var items = [
                FeedNotification(id: "n-i-1", kind: FeedNotification.kindLike, createdAt: at(5), actorId: "s-1", contentId: "sample-0", actor: person(0)),
                FeedNotification(id: "n-i-2", kind: FeedNotification.kindLike, createdAt: at(10), actorId: "s-3", contentId: "sample-0", actor: person(2)),
                FeedNotification(id: "n-i-3", kind: FeedNotification.kindLike, createdAt: at(20), actorId: "s-4", contentId: "sample-0", actor: person(3)),
                FeedNotification(id: "n-i-4", kind: FeedNotification.kindComment, createdAt: at(60), actorId: "s-2", contentId: "sample-1", actor: person(1)),
                FeedNotification(id: "n-i-5", kind: FeedNotification.kindReply, createdAt: at(120), actorId: "s-5", contentId: "sample-1"),
                FeedNotification(id: "n-i-6", kind: FeedNotification.kindComment, createdAt: at(180), actorId: "s-4", contentId: "sample-2", detail: FeedNotificationDetail(held: true), actor: person(3)),
            ]
            for k in 7...Self.interactionCount {
                items.append(FeedNotification(
                    id: "n-i-\(k)",
                    kind: k % 3 == 0 ? FeedNotification.kindComment : FeedNotification.kindLike,
                    createdAt: at(Double(k) * 400),   // 每条隔 6 小时 40 分：前面几条在今天 / 七天内，后面是更早
                    actorId: Self.authors[k % Self.authors.count].profileId,
                    contentId: "sample-\(k % 12)",
                    actor: person(k)
                ))
            }
            return items
        }
    }

    private func visibleNotifications(_ tab: String) -> [FeedNotification] {
        let state = notificationState.snapshot()
        return sampleNotificationItems(tab).compactMap { item -> FeedNotification? in
            if state.deletedIds.contains(item.id) { return nil }
            if let contentId = item.contentId {
                if state.mutedContent.contains(contentId) { return nil }
                if item.kind == FeedNotification.kindLike, state.mutedLikeContent.contains(contentId) { return nil }
            }
            var copy = item
            // 第一批未读：互动前 6 条、新关注前 2 条、系统前 2 条
            let unreadLimit = tab == FeedAPI.notificationsInteractions ? 6 : 2
            let index = Int(item.id.split(separator: "-").last ?? "") ?? 0
            copy.read = state.readIds.contains(item.id) || index > unreadLimit
            return copy
        }
    }

    private func unreadCounts() -> FeedUnreadCounts {
        func count(_ tab: String) -> Int { visibleNotifications(tab).filter { !$0.read }.count }
        return FeedUnreadCounts(interactions: count(FeedAPI.notificationsInteractions), follows: count(FeedAPI.notificationsFollows), system: count(FeedAPI.notificationsSystem))
    }

    private func notificationGate() async throws {
        let simulation = self.simulation
        if simulation.notificationsLatencyNanos > 0 {
            try? await Task.sleep(nanoseconds: simulation.notificationsLatencyNanos)
        }
        if simulation.feedHidden { throw FeedAPIError(status: 404, code: "feed_hidden") }
    }

    func notifications(tab: String, before: String?) async throws -> FeedNotificationsResponse {
        try await notificationGate()
        let simulation = self.simulation
        if let seconds = simulation.notificationsThrottledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
        if simulation.failsNotifications || (before != nil && simulation.failsNotificationsMore) { throw SampleFeedError.simulatedActionFailure }
        var items = visibleNotifications(tab)
        if let before, let cutoff = FeedDates.parse(before) {
            items = items.filter { (FeedDates.parse($0.createdAt) ?? .distantPast) < cutoff }
        }
        var response = FeedNotificationsResponse()
        response.notifications = Array(items.prefix(FeedAPI.notificationsPage))
        response.unread = unreadCounts()
        return response
    }

    private func notificationActionGate() async throws {
        try await notificationGate()
        let simulation = self.simulation
        if let seconds = simulation.notificationsThrottledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
        if simulation.notificationActionsGone { throw FeedAPIError(status: 404, code: "not_found") }
        if simulation.failsNotificationActions { throw SampleFeedError.simulatedActionFailure }
    }

    func markNotificationsRead(tab: String) async throws {
        try await notificationActionGate()
        notificationState.markRead(sampleNotificationItems(tab).map(\.id))
    }

    func deleteNotification(id: String) async throws {
        try await notificationActionGate()
        notificationState.delete(id)
    }

    func muteNotifications(contentId: String, likesOnly: Bool) async throws {
        try await notificationActionGate()
        notificationState.mute(contentId: contentId, likesOnly: likesOnly)
    }

    func notificationSettings() async throws -> FeedNotificationSettings {
        try await notificationGate()
        let simulation = self.simulation
        if simulation.failsNotificationSettingsLoad { throw SampleFeedError.simulatedActionFailure }
        return notificationState.currentSettings()
    }

    func saveNotificationSettings(_ settings: FeedNotificationSettings) async throws -> FeedNotificationSettings {
        try await notificationGate()
        let simulation = self.simulation
        if let seconds = simulation.notificationSettingsThrottledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
        if simulation.notificationSettingsNeedProfile { throw FeedAPIError(status: 409, code: "profile_required") }
        if simulation.failsNotificationSettingsSave { throw SampleFeedError.simulatedActionFailure }
        notificationState.save(settings)
        return settings
    }
}
