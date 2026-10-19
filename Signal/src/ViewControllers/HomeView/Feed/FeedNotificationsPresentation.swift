//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 系统通知的几种（`detail.type`）；认不得的归 `other`（界面说一句泛泛的话）。
enum FeedSystemNotificationKind: Equatable {
    case rejected
    case editRejected
    case takenDown
    case appealUpheld
    case appealOverturned
    case other
}

/// 一行通知说的是什么（纯逻辑，没有文字）：界面按这个挑本地化句子。`name` 是 nil = 还没查到这个人（界面说「有人」）。
enum FeedNotificationSummary: Equatable {
    /// 赞：`names` 是已知名字的前两个（新的在前），`total` 是点赞的人数（同一个人只算一次）。
    case liked(names: [String], total: Int)
    case commented(name: String?)
    case replied(name: String?)
    /// 评论 / 回复在等我批准（被限制的人、或者开了评论审核）。
    case commentHeld(name: String?)
    case replyHeld(name: String?)
    case followed(name: String?)
    case followRequested(name: String?)
    case system(FeedSystemNotificationKind)
    /// 有人把我设成了亲密好友请求。
    case closePersonRequest(name: String?)
    case other
}

/// 点一行通知要去哪。
enum FeedNotificationTarget: Equatable {
    case post(contentId: String)
    case profile(id: String)
}

/// 通知页要画什么（纯逻辑，没有界面）：由 `FeedNotificationsState` 算出来，界面只照着画。
struct FeedNotificationsPresentation: Equatable {
    enum Status: Equatable {
        case loading
        /// 第一页加载失败；限速时带还要等几秒。
        case failed(retryAfterSeconds: Int?)
        case empty(tab: String)
        case loadingMore
        case loadMoreFailed(retryAfterSeconds: Int?)
    }

    enum Row: Equatable {
        case header(FeedNotificationBucket)
        case notification(FeedNotificationRow)
        case status(Status)
    }

    var tab: String
    var rows: [Row]
    /// 滚到底该不该再翻页：有下一页、没有在加载、上一次没失败（失败了只在点「重试」时再来）。
    var canLoadMore: Bool
    /// 引擎说动态被关了：页面该收起。
    var feedHidden: Bool
    var unread: FeedUnreadCounts
    var people: [String: FeedPersonSummary]

    init(state: FeedNotificationsState, now: Date, calendar: Calendar) {
        tab = state.selectedTab
        feedHidden = state.feedHidden
        unread = state.unread
        people = state.people
        let current = state.tab(state.selectedTab)
        canLoadMore = current.hasMore && !current.loading && !current.loadingMore && !current.loadMoreFailed && !current.failed

        if state.feedHidden {
            rows = []
            return
        }
        if !current.loadedOnce {
            if current.failed {
                rows = [.status(.failed(retryAfterSeconds: current.retryAfterSeconds))]
            } else {
                rows = current.loading ? [.status(.loading)] : []
            }
            return
        }
        var rows = [Row]()
        // 下拉刷新失败：已有的留着，最上面说一句失败 + 重试
        if current.failed { rows.append(.status(.failed(retryAfterSeconds: current.retryAfterSeconds))) }
        let sections = FeedNotificationGrouping.group(current.items, now: now, calendar: calendar)
        if sections.isEmpty {
            rows.append(.status(current.loading ? .loading : .empty(tab: state.selectedTab)))
        } else {
            for section in sections {
                rows.append(.header(section.bucket))
                rows += section.rows.map { .notification($0) }
            }
            if current.loadingMore {
                rows.append(.status(.loadingMore))
            } else if current.loadMoreFailed {
                rows.append(.status(.loadMoreFailed(retryAfterSeconds: current.retryAfterSeconds)))
            }
        }
        self.rows = rows
    }

    /// 某一栏标签上的未读数。
    func badge(for tab: String) -> Int {
        return unread.of(tab: tab)
    }

    func summary(for row: FeedNotificationRow) -> FeedNotificationSummary {
        return Self.summary(for: row, people: people)
    }

    static func summary(for row: FeedNotificationRow, people: [String: FeedPersonSummary]) -> FeedNotificationSummary {
        func name(_ id: String?) -> String? {
            guard let id, let person = people[id], !person.displayName.isEmpty else { return nil }
            return person.displayName
        }
        let first = name(row.actorIds.first)
        switch row.kind {
        case FeedNotification.kindLike:
            let known = row.actorIds.compactMap { name($0) }
            return .liked(names: Array(known.prefix(2)), total: max(row.actorIds.count, 1))
        case FeedNotification.kindComment:
            return row.held ? .commentHeld(name: first) : .commented(name: first)
        case FeedNotification.kindReply:
            return row.held ? .replyHeld(name: first) : .replied(name: first)
        case FeedNotification.kindFollow:
            return .followed(name: first)
        case FeedNotification.kindFollowRequest:
            return .followRequested(name: first)
        case FeedNotification.kindSystem:
            switch row.systemType {
            case FeedNotification.systemClosePersonRequest:
                return .closePersonRequest(name: name(row.profileId))
            case FeedNotification.systemRejected:
                return .system(.rejected)
            case FeedNotification.systemEditRejected:
                return .system(.editRejected)
            case FeedNotification.systemTakenDown:
                return .system(.takenDown)
            case FeedNotification.systemAppealUpheld:
                return .system(.appealUpheld)
            case FeedNotification.systemAppealOverturned:
                return .system(.appealOverturned)
            default:
                return .system(.other)
            }
        default:
            return .other
        }
    }

    /// 点一行去哪：赞 / 评论 / 回复 → 帖子；新关注 / 关注请求 → 那个人的主页；系统通知只有「亲密好友请求」能点（去设置的人的主页）。
    static func target(for row: FeedNotificationRow) -> FeedNotificationTarget? {
        switch row.kind {
        case FeedNotification.kindLike, FeedNotification.kindComment, FeedNotification.kindReply:
            guard let contentId = row.contentId, !contentId.isEmpty else { return nil }
            return .post(contentId: contentId)
        case FeedNotification.kindFollow, FeedNotification.kindFollowRequest:
            guard let id = row.actorIds.first, !id.isEmpty else { return nil }
            return .profile(id: id)
        case FeedNotification.kindSystem:
            guard row.systemType == FeedNotification.systemClosePersonRequest, let id = row.profileId, !id.isEmpty else { return nil }
            return .profile(id: id)
        default:
            return nil
        }
    }

    /// 评论 / 回复通知点进去要定位到的那条评论（通知的 `subject_id` = 新评论本身）；赞、关注、系统通知和没带 id 的是 nil。
    static func focusCommentId(for row: FeedNotificationRow) -> String? {
        guard row.kind == FeedNotification.kindComment || row.kind == FeedNotification.kindReply else { return nil }
        guard let id = row.subjectId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return id
    }

    /// 行上能不能「不再通知这条帖子」（滑动菜单）：只有带帖子的赞 / 评论 / 回复。
    static func canMute(_ row: FeedNotificationRow) -> Bool {
        if case .post = target(for: row) { return true }
        return false
    }
}
