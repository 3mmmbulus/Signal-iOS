//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 主页「···」里的一项（别人的主页；自己的主页没有）。
enum FeedProfileMenuItem: Equatable {
    /// 不看 TA 的动态：`on` 是点了之后的状态（现在没开 = 点了就开）。
    case mute(on: Bool)
    /// 不让 TA 看我的动态。
    case hideFrom(on: Bool)
    case block
    case unblock
    /// 举报这个作者。
    case report
}

/// 作者主页要画什么（纯逻辑，没有界面）：由 `FeedProfilePageState` 算出来，界面只照着画。
/// 关注按钮的几种状态、「···」里有哪几项、下面画帖子还是画「私密 / 已屏蔽 / 空」都在这里定，单测直接测。
struct FeedProfilePresentation: Equatable {
    enum Page: Equatable {
        case loading
        /// 加载失败（可重试）；限速时 `failedRetryAfterSeconds` 是还要等几秒。
        case failed
        /// 看不到这个主页（删了、互相屏蔽、未成年人对非好友），引擎不说是哪种。
        case gone
        /// 这个区域的动态被关了：页面该收起。
        case feedHidden
        case content
    }

    /// 名字下面那一行：有 handle 写 `@handle`，没有写「Tellomi 号」（第三节第 8 条）。
    enum Identity: Equatable {
        case handle(String)
        case tellomiNumber(String)
        case none
    }

    enum FollowButton: Equatable {
        /// 自己的主页没有。
        case hidden
        case follow
        /// 私密账号发出去、对方还没通过。点了是撤回请求（要确认）。
        case requested
        /// 点了是取消关注（要确认）。
        case following
        /// 我屏蔽了 TA：按钮变成「取消屏蔽」。
        case unblock
    }

    /// 头部下面那块。
    enum Body: Equatable {
        /// 还没有东西可画（主页刚到、帖子还在取）。
        case none
        case posts
        /// 看得到、没有帖子。
        case empty
        /// 第一页帖子加载失败。
        case postsFailed
        /// 私密账号，我还不是好友 / 没被批准。
        case privateLocked
        case blockedByMe
        /// 对方在另一个内容区域发帖（R-1.4）。
        case regionUnavailable
    }

    var page: Page
    var failedRetryAfterSeconds: Int?
    var displayName: String
    var identity: Identity
    var bio: String?
    var badge: String?
    var isPrivate: Bool
    /// 只有服务端说要显示 IP 属地的时候才有。
    var ipRegionLabel: String?
    var followers: Int
    var following: Int
    var isSelf: Bool
    var followButton: FollowButton
    var isFollowEnabled: Bool
    var menu: [FeedProfileMenuItem]
    var body: Body
    var posts: [FeedCard]
    /// 第一页帖子在取（没有别的可画，画转圈）。
    var showsPostsSpinner: Bool
    /// 往下翻页在取（列表底部转圈）。
    var showsLoadingMore: Bool
    /// 往下翻页失败（列表底部「重试」）。
    var showsLoadMoreFailed: Bool
    var canLoadMore: Bool

    init(state: FeedProfilePageState) {
        let profile = state.profile
        if state.feedHidden {
            page = .feedHidden
        } else if state.gone {
            page = .gone
        } else if profile == nil {
            page = state.failed ? .failed : .loading
        } else {
            page = .content
        }
        failedRetryAfterSeconds = page == .failed ? state.retryAfterSeconds : nil
        displayName = profile?.displayName ?? ""
        if let handle = profile?.handle, !handle.isEmpty {
            identity = .handle(handle)
        } else if let number = profile?.tellomiNumber, !number.isEmpty {
            identity = .tellomiNumber(number)
        } else {
            identity = .none
        }
        let trimmedBio = profile?.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        bio = trimmedBio.isEmpty ? nil : trimmedBio
        badge = (profile?.badge?.isEmpty ?? true) ? nil : profile?.badge
        isPrivate = profile?.isPrivate ?? false
        ipRegionLabel = state.showIpRegion ? profile?.ipRegionLabel : nil
        followers = profile?.followers ?? 0
        following = profile?.following ?? 0
        isSelf = profile?.me.isSelf ?? false
        posts = state.posts

        guard let profile, page == .content else {
            followButton = .hidden
            isFollowEnabled = false
            menu = []
            body = .none
            showsPostsSpinner = false
            showsLoadingMore = false
            showsLoadMoreFailed = false
            canLoadMore = false
            return
        }

        if profile.me.isSelf {
            followButton = .hidden
        } else if profile.me.blocked {
            followButton = .unblock
        } else {
            switch profile.me.follow {
            case FeedRelation.followApproved: followButton = .following
            case FeedRelation.followPending: followButton = .requested
            default: followButton = .follow
            }
        }
        isFollowEnabled = !state.followBusy

        if profile.me.isSelf {
            menu = []
        } else if profile.me.blocked {
            menu = [.unblock, .report]
        } else {
            var items = [FeedProfileMenuItem]()
            if let hide = state.hideState {
                items.append(.mute(on: !hide.muted))
                items.append(.hideFrom(on: !hide.hiddenFrom))
            }
            items.append(.block)
            items.append(.report)
            menu = items
        }

        let hasPosts = !state.posts.isEmpty
        if profile.me.blocked {
            body = .blockedByMe
        } else if profile.regionUnavailable {
            body = .regionUnavailable
        } else if !profile.canSeePosts {
            body = .privateLocked
        } else if hasPosts {
            body = .posts
        } else if state.postsFailed {
            body = .postsFailed
        } else if state.postsLoadedOnce {
            body = .empty
        } else {
            body = .none
        }
        let drawsPosts = profile.showsPosts
        showsPostsSpinner = drawsPosts && !hasPosts && state.postsLoading
        showsLoadingMore = drawsPosts && hasPosts && state.postsLoading
        showsLoadMoreFailed = drawsPosts && hasPosts && state.postsFailed && !state.postsLoading
        canLoadMore = drawsPosts && state.cursor != nil && !state.postsLoading
    }
}
