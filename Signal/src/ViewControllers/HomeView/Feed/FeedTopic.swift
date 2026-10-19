//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedTopic.swift (new file)
// Topic page: posts with a topic + follow / unfollow topic (I-8).
// Mirror of Android `topic/FeedTopicViewModel.kt`, `FeedApi.topicPosts`, `FeedTopicPostsResponse` / `FeedTopicPage`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// `GET /v1/feed/topics/{slug}/posts`：带这个话题的帖子按时间倒序；`following` 是我有没有关注它。
struct FeedTopicPostsResponse: Decodable, Equatable {
    var items = [FeedItemRef]()
    var cursor: String?
    var following = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([FeedItemRef].self, forKey: .items) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        following = try c.decodeIfPresent(Bool.self, forKey: .following) ?? false
    }

    private enum CodingKeys: String, CodingKey { case items, cursor, following }
}

/// 话题页的一页：卡片已经补好。
struct FeedTopicPage: Equatable {
    var posts = [FeedCard]()
    var cursor: String?
    var following = false
}

extension FeedAPI {
    /// 话题页：带 `slug` 的帖子，新的在前；屏蔽了这个话题是空页，slug 不合法 404。
    func topicPosts(slug: String, cursor: String?) async throws -> FeedTopicPostsResponse {
        let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        return try await send(FeedTopicPostsResponse.self, request(path: ["v1", "feed", "topics", slug, "posts"], query: query))
    }
}

struct FeedTopicState: Equatable {
    enum Notice: Equatable {
        /// 底部提示条（关注成功；「撤销」还没做，见报告）。
        case followed
        case unfollowed
        case saved
        case reposted
        case failed
        /// 被限速；要等几秒在 `retryAfterSeconds`。
        case throttled
        /// 要先建自己的公开主页（关注话题也要）。
        case profileRequired
    }

    var following = false
    var posts = [FeedCard]()
    var cursor: String?
    var loading = true
    /// 这一次加载是在翻页（不是刷新）：列表末尾画「加载中」。
    var loadingMore = false
    var loadedOnce = false
    /// 第一页加载失败（界面说「加载失败」+ 重试）。
    var failed = false
    /// 翻页失败：已有的帖子和 `cursor` 留着，列表末尾给「重试」。
    var loadMoreFailed = false
    /// 引擎不认这个话题（slug 不合法，404）。
    var gone = false
    /// 被限速时还要等几秒（`failed` / `loadMoreFailed` 页或 `notice == .throttled` 时说）；没有 `Retry-After` 是 nil。
    var retryAfterSeconds: Int?
    /// 引擎说这个区域的动态被关了（404 `feed_hidden`）：页面该收起，不是「加载失败」。
    var feedHidden = false
    var notice: Notice?
}

/// 话题页：带这个话题的帖子按时间倒序，头上一个「关注话题」（第三节第 18 条：关注的话题进「关注」栏）。
/// 过滤（屏蔽、不看 TA、不感兴趣、可见范围）都在引擎；屏蔽了这个话题就是空页。
///
/// 和信息流共用 `FeedStore`（传了 `feed` 的时候）：帖子的唯一数据在它里面，`state.posts` 只是每次它变了之后从它重新读的投影，
/// 赞、收藏、转发改在它里面，别的页面同时看到；屏蔽了作者、删了帖子这里也跟着没了。不传就自己独立运行（单测）。
@MainActor
final class FeedTopicStore {
    let slug: String
    private let source: FeedSource
    private let savedMessages: FeedSavedMessages?
    private let mirror: FeedCardMirror?

    private(set) var state = FeedTopicState() {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedTopicState) -> Void)?

    private var tasks = [Task<Void, Never>]()
    private var postsTask: Task<Void, Never>?
    private var postsRunning = false
    private var followRunning = false
    private var saving = FeedInFlight()
    private var reposting = FeedInFlight()

    init(slug: String, source: FeedSource, savedMessages: FeedSavedMessages? = nil, feed: FeedStore? = nil) {
        self.slug = slug
        self.source = source
        self.savedMessages = savedMessages
        mirror = feed.map { FeedCardMirror(feed: $0) }
        mirror?.shownIds = { [weak self] in Set(self?.state.posts.map(\.id) ?? []) }
        mirror?.onChange = { [weak self] in self?.reproject() }
        mirror?.onActionFailed = { [weak self] in
            self?.state.retryAfterSeconds = nil
            self?.state.notice = .failed
        }
    }

    // MARK: - 和信息流 store 同步

    var isObservingFeed: Bool { mirror?.isObserving == true }
    var leaseCount: Int { mirror?.leaseCount ?? 0 }

    /// 页面离开了：不再订阅、放掉借着的卡片。可以重复调用。
    func detach() {
        mirror?.detach()
    }

    private func reproject() {
        guard let mirror else { return }
        let next = mirror.project(state.posts)
        if next != state.posts { state.posts = next }
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
        await mirror?.waitForActions()
    }

    func start() {
        load(cursor: nil)
    }

    func refresh() {
        load(cursor: nil)
    }

    /// 往下翻（滚到底、或点末尾的「重试」）。
    func loadMore() {
        guard let cursor = state.cursor, !postsRunning else { return }
        load(cursor: cursor)
    }

    /// 举报 / 别处让页面该收起（`feed_hidden`）。
    func onFeedHidden() {
        state.feedHidden = true
    }

    private func load(cursor: String?) {
        postsTask?.cancel()
        postsRunning = true
        state.loading = true
        state.loadingMore = cursor != nil
        state.failed = false
        state.loadMoreFailed = false
        state.retryAfterSeconds = nil
        let task = Task { [weak self, source, slug] in
            do {
                let page = try await source.topicPosts(slug: slug, cursor: cursor)
                guard !Task.isCancelled, let self else { return }
                if cursor == nil { self.mirror?.releaseAll() }
                let base = cursor == nil ? [] : self.state.posts
                let known = Set(base.map(\.id))
                let fresh = page.posts.filter { !known.contains($0.id) }
                self.state.posts = base + (self.mirror?.adopt(fresh) ?? fresh)
                self.state.cursor = page.cursor
                self.state.loading = false
                self.state.loadingMore = false
                self.state.loadedOnce = true
                self.state.gone = false
                // 关注按钮在路上时不拿回包盖掉它
                if !self.followRunning { self.state.following = page.following }
                self.postsRunning = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.postsRunning = false
                Logger.warn("feed topic failed: \(error)")
                self.state.loading = false
                self.state.loadingMore = false
                switch FeedActionFailure.classify(error) {
                case .feedHidden:
                    self.state.feedHidden = true
                    return
                case .gone where cursor == nil:
                    // 引擎不认这个话题
                    self.state.loadedOnce = true
                    self.state.gone = true
                    self.state.posts = []
                    self.state.cursor = nil
                    self.mirror?.releaseAll()
                    return
                case .throttled(let seconds):
                    self.state.retryAfterSeconds = seconds
                default:
                    self.state.retryAfterSeconds = nil
                }
                if cursor == nil {
                    self.state.loadedOnce = true
                    self.state.failed = true
                } else {
                    // 翻页失败：已有的留着
                    self.state.loadMoreFailed = true
                }
            }
        }
        postsTask = task
        tasks.append(task)
    }

    /// 关注 / 取消关注：先改按钮，失败改回来。关注成功给一条提示。
    func toggleFollow() {
        let before = state
        if !before.loadedOnce || before.gone || followRunning { return }
        let target = !before.following
        followRunning = true
        state.following = target
        let task = Task { [weak self, source, slug] in
            do {
                try await source.setFollowingTopic(slug: slug, following: target)
                self?.followRunning = false
                self?.state.notice = target ? .followed : .unfollowed
            } catch {
                Logger.warn("feed follow topic failed: \(error)")
                self?.followRunning = false
                self?.state.following = !target
                self?.toldFailed(error)
            }
        }
        tasks.append(task)
    }

    func toggleLike(_ card: FeedCard) {
        if let mirror {
            // 赞的乐观更新、失败回滚、连点都在 FeedStore 里；失败时它发 `.actionFailed`，这里变成 `.failed` 提示
            mirror.toggleLike(id: card.id)
            return
        }
        let nowLiked = !card.viewer.liked
        updatePost(card.id) { FeedStore.withLiked($0, nowLiked) }
        tasks.append(Task { [weak self, source] in
            do {
                try await source.setLiked(contentId: card.id, liked: nowLiked)
            } catch {
                Logger.warn("feed topic like failed: \(error)")
                self?.updatePost(card.id) { FeedStore.withLiked($0, !nowLiked) }
                self?.state.notice = .failed
            }
        })
    }

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
                Logger.warn("feed topic save failed: \(error)")
                self?.saving.end(card.id)
                self?.updatePost(card.id) { $0.withSaved(!nowSaved) }
                self?.toldFailed(error)
            }
        })
    }

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
                Logger.warn("feed topic repost failed: \(error)")
                self?.reposting.end(card.id)
                self?.updatePost(card.id) { $0.withReposted(!nowReposted) }
                self?.toldFailed(error)
            }
        })
    }

    func onNoticeShown() {
        state.notice = nil
        if !state.failed, !state.loadMoreFailed { state.retryAfterSeconds = nil }
    }

    /// 动作失败：按引擎的错误给提示（限速带秒数、`feed_hidden` 收页、要先建主页）；其它 404 也算「操作失败」。
    private func toldFailed(_ error: Error) {
        switch FeedActionFailure.classify(error) {
        case .feedHidden:
            state.feedHidden = true
        case .throttled(let seconds):
            state.retryAfterSeconds = seconds
            state.notice = .throttled
        case .profileRequired:
            state.notice = .profileRequired
        case .gone, .failed:
            state.retryAfterSeconds = nil
            state.notice = .failed
        }
    }

    /// 改一条帖子：有信息流 store 就改在 store 里（`state.posts` 随通知更新），没有就改自己的。
    private func updatePost(_ id: String, _ change: (FeedCard) -> FeedCard) {
        if let mirror, mirror.has(id) {
            mirror.update(id, change)
            return
        }
        state.posts = state.posts.map { $0.id == id ? change($0) : $0 }
    }
}
