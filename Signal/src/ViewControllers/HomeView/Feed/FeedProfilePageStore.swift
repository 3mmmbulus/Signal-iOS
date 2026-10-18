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
        /// 被限速：`state.retryAfterSeconds` 是还要等几秒（可能没有）。
        case throttled
        /// 举报作者提交成功。
        case reported
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
    /// 被限速时还要等几秒（`notice == .throttled`，或整页加载被限速时 `failed` 页上说）；没有 `Retry-After` 是 nil。
    var retryAfterSeconds: Int?
    /// 引擎说这个区域的动态被关了（404 `feed_hidden`）：页面该收起，不是「加载失败」。
    var feedHidden = false
}

/// 关注是乐观的：先改按钮和粉丝数，引擎说不行再改回来。私密账号对非好友先是「已请求」。
@MainActor
final class FeedProfilePageStore {
    let profileId: String
    private let source: FeedSource
    private let savedMessages: FeedSavedMessages?
    /// 和信息流共用的 store（nil = 独立运行，单测和还没接上的页面用）。有它的时候，主页上每条帖子的唯一数据在它里面：
    /// `state.posts` 只是每次它变了之后从它重新读的投影；赞、收藏、转发、置顶都改到它里面，信息流和详情页同时看到。
    private let feed: FeedStore?
    private var leases = [FeedCardLease]()
    private var subscription: FeedSubscription?

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

    init(profileId: String, source: FeedSource, savedMessages: FeedSavedMessages? = nil, feed: FeedStore? = nil) {
        self.profileId = profileId
        self.source = source
        self.savedMessages = savedMessages
        self.feed = feed
        if let feed {
            subscription = feed.subscribe { [weak self] change in
                self?.onFeedChange(change)
            }
        }
    }

    // MARK: - 和信息流 store 同步

    /// 还在订阅信息流 store 吗（单测 / 页面检查用）。
    var isObservingFeed: Bool {
        return subscription?.isActive == true
    }

    /// 借着的帖子数（单测用）。
    var leaseCount: Int { leases.count }

    /// 页面离开了：不再订阅、放掉借着的卡片。可以重复调用。
    func detach() {
        subscription?.cancel()
        subscription = nil
        leases = []
    }

    private func onFeedChange(_ change: FeedChange) {
        switch change {
        case .cards(let ids):
            if state.posts.contains(where: { ids.contains($0.id) }) { adoptPostsFromFeed() }
        case .list:
            adoptPostsFromFeed()
        case .actionFailed(let cardId):
            if state.posts.contains(where: { $0.id == cardId }) {
                state.retryAfterSeconds = nil
                state.notice = .failed
            }
        }
    }

    private func adoptPostsFromFeed() {
        guard let feed else { return }
        let next = state.posts.map { feed.card(id: $0.id) ?? $0 }
        if next != state.posts { state.posts = next }
    }

    /// 一页新取回来的帖子：先让信息流里同一张卡片换成最新的，再借着，主页上显示信息流里现在的样子。
    private func adopt(_ cards: [FeedCard]) -> [FeedCard] {
        guard let feed else { return cards }
        var adopted = [FeedCard]()
        for card in cards {
            feed.ingest(card)
            leases.append(feed.retain(card))
            adopted.append(feed.card(id: card.id) ?? card)
        }
        return adopted
    }

    /// 改一条帖子：有信息流 store 就改在 store 里（`state.posts` 随通知更新），没有就改自己的。
    private func updatePost(_ id: String, _ change: (FeedCard) -> FeedCard) {
        if let feed, feed.card(id: id) != nil {
            feed.updateCard(id) { $0 = change($0) }
        } else {
            state.posts = state.posts.map { $0.id == id ? change($0) : $0 }
        }
    }

    /// 同 `told`，但 404 也算「操作失败」（列表上的动作、关注之外的设置）。
    private func toldFailed(_ error: Error) {
        if told(error) == .gone { state.notice = .failed }
    }

    /// 动作失败：按引擎的错误给提示（限速带秒数、`feed_hidden` 收页、要先建主页），调用方自己改回界面。
    /// `.gone`（404）什么都不提示，由调用方决定（整页「看不到」还是只算失败）。
    @discardableResult
    private func told(_ error: Error) -> FeedActionFailure {
        let failure = FeedActionFailure.classify(error)
        switch failure {
        case .feedHidden:
            state.feedHidden = true
        case .throttled(let seconds):
            state.retryAfterSeconds = seconds
            state.notice = .throttled
        case .profileRequired:
            state.notice = .profileRequired
        case .gone:
            break
        case .failed:
            state.retryAfterSeconds = nil
            state.notice = .failed
        }
        return failure
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
        await feed?.waitForActions()
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
        state.retryAfterSeconds = nil
        let task = Task { [weak self, source, profileId] in
            let profile: FeedProfilePage?
            do {
                profile = try await source.profile(profileId: profileId)
            } catch {
                Logger.warn("feed profile failed: \(error)")
                guard !Task.isCancelled, let self else { return }
                self.state.loading = false
                switch FeedActionFailure.classify(error) {
                case .feedHidden:
                    self.state.feedHidden = true
                case .throttled(let seconds):
                    self.state.retryAfterSeconds = seconds
                    self.state.failed = true
                default:
                    self.state.retryAfterSeconds = nil
                    self.state.failed = true
                }
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
                self?.toldFailed(error)
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
                if cursor == nil { self.leases = [] }
                self.state.posts = base + self.adopt(page.posts.filter { !known.contains($0.id) })
                self.state.cursor = page.cursor
                self.state.postsLoading = false
                self.state.postsLoadedOnce = true
                self.postsRunning = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.postsRunning = false
                Logger.warn("feed profile posts failed: \(error)")
                switch FeedActionFailure.classify(error) {
                case .feedHidden:
                    self.state.feedHidden = true
                case .gone:
                    // 打开以后被对方屏蔽、删号了：整页换成「看不到」
                    self.state.gone = true
                    self.state.profile = nil
                    self.state.posts = []
                    self.state.cursor = nil
                    self.leases = []
                    self.state.postsLoading = false
                    return
                case .throttled(let seconds):
                    self.state.retryAfterSeconds = seconds
                default:
                    break
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
                self.state.followBusy = false
                if self.told(error) == .gone {
                    self.state.gone = true
                    self.state.profile = nil
                    self.state.posts = []
                    self.state.cursor = nil
                    self.leases = []
                } else {
                    self.state.profile = before
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
                self.toldFailed(error)
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
                    self.leases = []
                    self.state.followBusy = false
                    self.state.notice = .blocked
                    // 屏蔽了：这个人的帖子也从信息流里拿掉
                    self.feed?.removeCards(byAuthor: self.profileId)
                } else {
                    self.state.followBusy = false
                    self.state.notice = .unblocked
                    self.feed?.allowCards(byAuthor: self.profileId)
                    self.refresh()
                }
            } catch {
                Logger.warn("feed block failed: \(error)")
                self?.state.followBusy = false
                self?.toldFailed(error)
            }
        })
    }

    // MARK: - 列表上的卡片操作

    func toggleLike(_ card: FeedCard) {
        if let feed {
            // 赞的乐观更新、失败回滚、连点都在 FeedStore 里；失败时它发 `.actionFailed`，这里变成 `.failed` 提示
            feed.toggleLike(id: card.id)
            return
        }
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
                self?.toldFailed(error)
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
                if FeedOwnPostAction.isPinLimit(error) {
                    self?.state.notice = .pinLimit
                } else {
                    self?.toldFailed(error)
                }
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
        state.retryAfterSeconds = nil
    }

    // MARK: - 回到页面、举报作者

    /// 从帖子详情回到主页：悄悄重新取第一页（那边可能删了帖子、改了置顶）。旧列表先留着，回来了再换。
    func onReappeared() {
        guard !postsRunning, state.postsLoadedOnce, state.profile?.showsPosts == true else { return }
        loadPosts(cursor: nil)
    }

    /// 举报这个作者：给举报页用的 store，提交成功后界面调 `onReported()`。
    func reportStore() -> FeedReportStore {
        return FeedReportStore(target: .author(profileId), source: source)
    }

    func onReported() {
        state.retryAfterSeconds = nil
        state.notice = .reported
    }

    /// 举报页碰到 `feed_hidden`：主页也收起。
    func onFeedHidden() {
        state.feedHidden = true
    }
}
