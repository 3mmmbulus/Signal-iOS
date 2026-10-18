//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedProfilePageStore.swift (new file)
// Someone's public profile page, without UI (I-5). Mirror of Android `profile/FeedProfilePageViewModel.kt`:
// header, follow / unfollow / block, hide lists, post list, and the card actions on that list.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 别人主页上我对 TA 的「不看 / 不让看」。
struct FeedHideState: Equatable {
    var muted: Bool
    var hiddenFrom: Bool
}

struct FeedProfilePageState: Equatable {
    enum Notice: Equatable {
        /// 底部提示条带「撤销」（第三节「统一反馈」：关注能撤销）。
        case followed
        case requested
        /// 关注人之前要先建自己的公开主页。
        case profileRequired
        case blocked
        case unblocked
        /// 置顶满 3 条。
        case pinLimit
        case muted
        /// 存进了「我的收藏」。
        case saved
        /// 已转发到自己的动态。
        case reposted
        case hiddenFrom
        case failed
    }

    var profile: FeedProfilePage?
    var loading = true
    var failed = false
    /// 看不到这个主页（删了、互相屏蔽、未成年人对非好友），引擎不说是哪种。
    var gone = false
    var posts = [FeedCard]()
    var cursor: String?
    var postsLoading = false
    var postsLoadedOnce = false
    var postsFailed = false
    /// 关注、取消关注、屏蔽在路上，按钮先不响应第二下。
    var followBusy = false
    var notice: Notice?
    var mediaBaseUrl: String?
    var showIpRegion = false
    /// 「查看数据」弹窗；nil = 没开。
    var insights: FeedInsightsState?
    /// 别人的主页：我对 TA 的「不看 / 不让看」；还没查到是 nil。
    var hideState: FeedHideState?
}

/// 关注是乐观的：先改按钮和粉丝数，引擎说不行再改回来。私密账号对非好友先是「已请求」。
@MainActor
final class FeedProfilePageStore {
    private let profileId: String
    private let source: FeedSource
    private let savedMessages: FeedSavedMessages?

    private(set) var state = FeedProfilePageState() {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedProfilePageState) -> Void)?

    private var tasks = [Task<Void, Never>]()
    private var loadTask: Task<Void, Never>?
    private var postsTask: Task<Void, Never>?
    private var postsRunning = false
    private var saving = FeedInFlight()
    private var reposting = FeedInFlight()

    init(profileId: String, source: FeedSource, savedMessages: FeedSavedMessages? = nil) {
        self.profileId = profileId
        self.source = source
        self.savedMessages = savedMessages
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
    }

    func start() {
        tasks.append(Task { [weak self, source] in
            do {
                let config = try await source.config()
                self?.state.mediaBaseUrl = config.mediaBaseUrl
                self?.state.showIpRegion = config.ipRegionVisible
            } catch {
                Logger.warn("feed profile config failed: \(error)")
            }
        })
        refresh()
    }

    func refresh() {
        loadTask?.cancel()
        postsTask?.cancel()
        postsRunning = false
        state.loading = true
        state.failed = false
        let task = Task { [weak self, source, profileId] in
            let profile: FeedProfilePage?
            do {
                profile = try await source.profile(profileId: profileId)
            } catch {
                Logger.warn("feed profile failed: \(error)")
                guard !Task.isCancelled else { return }
                self?.state.loading = false
                self?.state.failed = true
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard let profile else {
                self.state.loading = false
                self.state.gone = true
                self.state.profile = nil
                self.state.posts = []
                self.state.cursor = nil
                return
            }
            // 不看 / 不让 TA 看：自己和已屏蔽的人不给这两项
            let hide: FeedHideState? = (profile.me.isSelf || profile.me.blocked) ? nil : FeedHideState(muted: profile.me.muted, hiddenFrom: profile.me.hiddenFrom)
            self.state.loading = false
            self.state.gone = false
            self.state.profile = profile
            self.state.posts = []
            self.state.cursor = nil
            self.state.postsLoadedOnce = false
            self.state.hideState = hide
            if profile.showsPosts { self.loadPosts(cursor: nil) }
        }
        loadTask = task
        tasks.append(task)
    }

    // MARK: - 不看 / 不让看

    /// 「不看 TA 的动态」/「不让 TA 看我的动态」的加进、移出（`list` 是 `FeedAPI.hideMute` / `FeedAPI.hideFrom`）。先改菜单，失败改回来。
    func setHidden(list: String, on: Bool) {
        guard let before = state.hideState else { return }
        var after = before
        if list == FeedAPI.hideMute { after.muted = on } else { after.hiddenFrom = on }
        state.hideState = after
        tasks.append(Task { [weak self, source, profileId] in
            do {
                try await source.setHideList(list: list, profileId: profileId, on: on)
                guard on else { return }
                self?.state.notice = list == FeedAPI.hideMute ? .muted : .hiddenFrom
            } catch {
                Logger.warn("feed hide list failed: \(error)")
                self?.state.hideState = before
                self?.state.notice = (error as? FeedAPIError)?.code == "profile_required" ? .profileRequired : .failed
            }
        })
    }

    // MARK: - 帖子

    func loadMorePosts() {
        guard let cursor = state.cursor, !postsRunning else { return }
        loadPosts(cursor: cursor)
    }

    private func loadPosts(cursor: String?) {
        postsTask?.cancel()
        postsRunning = true
        state.postsLoading = true
        state.postsFailed = false
        let task = Task { [weak self, source, profileId] in
            do {
                let page = try await source.profilePosts(profileId: profileId, cursor: cursor)
                guard !Task.isCancelled, let self else { return }
                let known = cursor == nil ? Set<String>() : Set(self.state.posts.map(\.id))
                let base = cursor == nil ? [] : self.state.posts
                self.state.posts = base + page.posts.filter { !known.contains($0.id) }
                self.state.cursor = page.cursor
                self.state.postsLoading = false
                self.state.postsLoadedOnce = true
                self.postsRunning = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.postsRunning = false
                if let error = error as? FeedAPIError {
                    Logger.warn("feed profile posts rejected: \(error.status) \(error.code ?? "")")
                    // 打开以后被对方屏蔽、删号了：整页换成「看不到」
                    if error.status == 404 && error.code == FeedAPI.notFound {
                        self.state.gone = true
                        self.state.profile = nil
                        self.state.posts = []
                        self.state.cursor = nil
                        self.state.postsLoading = false
                        return
                    }
                } else {
                    Logger.warn("feed profile posts failed: \(error)")
                }
                self.state.postsLoading = false
                self.state.postsFailed = true
                self.state.postsLoadedOnce = true
            }
        }
        postsTask = task
        tasks.append(task)
    }

    // MARK: - 关注 / 屏蔽

    /// 关注：先改按钮和粉丝数（粉丝数乐观 +1）。
    func follow() {
        guard let before = state.profile else { return }
        if state.followBusy || before.me.isSelf || before.me.follow != FeedRelation.followNone { return }
        let guess = before.isPrivate && !before.me.friend ? FeedRelation.followPending : FeedRelation.followApproved
        state.profile = before.withFollow(guess)
        state.followBusy = true
        tasks.append(Task { [weak self, source, profileId] in
            do {
                let result = try await source.setFollowing(profileId: profileId, following: true)
                guard let self else { return }
                let after = before.withFollow(result)
                self.state.profile = after
                self.state.followBusy = false
                self.state.notice = result == FeedRelation.followPending ? .requested : .followed
                if !before.showsPosts && after.showsPosts { self.loadPosts(cursor: nil) }
            } catch {
                Logger.warn("feed follow failed: \(error)")
                guard let self else { return }
                let apiError = error as? FeedAPIError
                if apiError?.code == "profile_required" {
                    self.state.profile = before
                    self.state.followBusy = false
                    self.state.notice = .profileRequired
                } else if apiError?.status == 404 {
                    self.state.gone = true
                    self.state.profile = nil
                    self.state.posts = []
                    self.state.cursor = nil
                    self.state.followBusy = false
                } else {
                    self.state.profile = before
                    self.state.followBusy = false
                    self.state.notice = .failed
                }
            }
        })
    }

    /// 取消关注或撤回关注请求（确认框在界面上弹）。私密账号取消后帖子跟着收起来。
    func unfollow() {
        guard let before = state.profile else { return }
        if state.followBusy || before.me.follow == FeedRelation.followNone { return }
        let after = before.withFollow(FeedRelation.followNone)
        state.profile = after
        state.followBusy = true
        if !after.showsPosts {
            state.posts = []
            state.cursor = nil
        }
        tasks.append(Task { [weak self, source, profileId] in
            do {
                _ = try await source.setFollowing(profileId: profileId, following: false)
                self?.state.followBusy = false
            } catch {
                Logger.warn("feed unfollow failed: \(error)")
                guard let self else { return }
                self.state.profile = before
                self.state.followBusy = false
                self.state.notice = .failed
                if !after.showsPosts && before.showsPosts { self.loadPosts(cursor: nil) }
            }
        })
    }

    /// 屏蔽：双方的关注一起没了，帖子收起来；取消屏蔽后重新拉一遍主页。
    func setBlocked(_ blocked: Bool) {
        guard let before = state.profile else { return }
        if before.me.isSelf || state.followBusy { return }
        state.followBusy = true
        tasks.append(Task { [weak self, source, profileId] in
            do {
                try await source.setBlocked(profileId: profileId, blocked: blocked)
                guard let self else { return }
                if blocked {
                    let wasFollowing = before.me.follow == FeedRelation.followApproved
                    var after = before
                    if wasFollowing { after.followers = max(0, before.followers - 1) }
                    after.me.blocked = true
                    after.me.follow = FeedRelation.followNone
                    after.me.followedBy = false
                    self.state.profile = after
                    self.state.posts = []
                    self.state.cursor = nil
                    self.state.followBusy = false
                    self.state.notice = .blocked
                } else {
                    self.state.followBusy = false
                    self.state.notice = .unblocked
                    self.refresh()
                }
            } catch {
                Logger.warn("feed block failed: \(error)")
                self?.state.followBusy = false
                self?.state.notice = .failed
            }
        })
    }

    // MARK: - 列表上的卡片操作

    func toggleLike(_ card: FeedCard) {
        let nowLiked = !card.viewer.liked
        updatePost(card.id) { FeedStore.withLiked($0, nowLiked) }
        tasks.append(Task { [weak self, source] in
            do {
                try await source.setLiked(contentId: card.id, liked: nowLiked)
            } catch {
                Logger.warn("feed profile like failed: \(error)")
                self?.updatePost(card.id) { FeedStore.withLiked($0, !nowLiked) }
                self?.state.notice = .failed
            }
        })
    }

    /// 收藏 / 取消收藏：先改书签，存不进「我的收藏」就改回来。
    func toggleSave(_ card: FeedCard) {
        guard saving.begin(card.id) else { return }
        let nowSaved = !card.viewer.saved
        updatePost(card.id) { $0.withSaved(nowSaved) }
        tasks.append(Task { [weak self, source, savedMessages] in
            do {
                guard let savedMessages else { throw FeedPublishError.feedNotAvailable }
                try await FeedSaveFlow.setSaved(card, saved: nowSaved, savedMessages: savedMessages, source: source) {
                    Logger.warn("feed save report failed: \($0)")
                }
                self?.saving.end(card.id)
                if nowSaved { self?.state.notice = .saved }
            } catch {
                Logger.warn("feed profile save failed: \(error)")
                self?.saving.end(card.id)
                self?.updatePost(card.id) { $0.withSaved(!nowSaved) }
                self?.state.notice = .failed
            }
        })
    }

    /// 转发到动态 / 取消：先改界面，失败改回来。
    func toggleRepost(_ card: FeedCard) {
        guard reposting.begin(card.id) else { return }
        let nowReposted = !card.viewer.reposted
        updatePost(card.id) { $0.withReposted(nowReposted) }
        tasks.append(Task { [weak self, source] in
            do {
                try await source.setReposted(contentId: card.id, reposted: nowReposted)
                self?.reposting.end(card.id)
                if nowReposted { self?.state.notice = .reposted }
            } catch {
                Logger.warn("feed profile repost failed: \(error)")
                self?.reposting.end(card.id)
                self?.updatePost(card.id) { $0.withReposted(!nowReposted) }
                self?.state.notice = .failed
            }
        })
    }

    /// 自己帖子「···」：置顶 / 隐藏点赞数先改界面，失败改回来；置顶变了重新拉第一页，让置顶的排到最前。查看数据开一个弹窗。
    func onOwnPostAction(_ card: FeedCard, _ action: FeedOwnPostAction) {
        guard let update = action.settingsUpdate else {
            if action == .insights { loadInsights(card.id) }
            return
        }
        updatePost(card.id) { $0.withSettings(update) }
        tasks.append(Task { [weak self, source] in
            do {
                try await source.updatePostSettings(contentId: card.id, update: update)
                if update.pinned != nil { self?.loadPosts(cursor: nil) }
            } catch {
                Logger.warn("feed profile post settings failed: \(error)")
                self?.updatePost(card.id) { current in
                    var reverted = current
                    reverted.pinned = card.pinned
                    reverted.stats.likeCountHidden = card.stats.likeCountHidden
                    return reverted
                }
                self?.state.notice = FeedOwnPostAction.isPinLimit(error) ? .pinLimit : .failed
            }
        })
    }

    private func loadInsights(_ contentId: String) {
        state.insights = .loading
        tasks.append(Task { [weak self, source] in
            let result: FeedInsightsState
            do {
                result = .ready(try await source.postInsights(contentId: contentId))
            } catch {
                Logger.warn("feed profile insights failed: \(error)")
                result = .failed
            }
            guard let self, self.state.insights != nil else { return }
            self.state.insights = result
        })
    }

    func onInsightsDismissed() {
        state.insights = nil
    }

    func onNoticeShown() {
        state.notice = nil
    }

    private func updatePost(_ id: String, _ change: (FeedCard) -> FeedCard) {
        state.posts = state.posts.map { $0.id == id ? change($0) : $0 }
    }
}
