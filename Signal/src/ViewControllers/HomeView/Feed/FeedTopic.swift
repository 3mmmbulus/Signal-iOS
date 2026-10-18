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
        /// 底部提示条带「撤销」（第三节「统一反馈」）。
        case followed
        case unfollowed
        case saved
        case reposted
        case failed
    }

    var following = false
    var posts = [FeedCard]()
    var cursor: String?
    var loading = true
    var loadedOnce = false
    var failed = false
    /// 引擎不认这个话题（slug 不合法，404）。
    var gone = false
    var notice: Notice?
}

/// 话题页：带这个话题的帖子按时间倒序，头上一个「关注话题」（第三节第 18 条：关注的话题进「关注」栏）。
/// 过滤（屏蔽、不看 TA、不感兴趣、可见范围）都在引擎；屏蔽了这个话题就是空页。
@MainActor
final class FeedTopicStore {
    let slug: String
    private let source: FeedSource
    private let savedMessages: FeedSavedMessages?

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

    init(slug: String, source: FeedSource, savedMessages: FeedSavedMessages? = nil) {
        self.slug = slug
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
        load(cursor: nil)
    }

    func refresh() {
        load(cursor: nil)
    }

    func loadMore() {
        guard let cursor = state.cursor, !postsRunning else { return }
        load(cursor: cursor)
    }

    private func load(cursor: String?) {
        postsTask?.cancel()
        postsRunning = true
        state.loading = true
        state.failed = false
        let task = Task { [weak self, source, slug] in
            do {
                let page = try await source.topicPosts(slug: slug, cursor: cursor)
                guard !Task.isCancelled, let self else { return }
                let base = cursor == nil ? [] : self.state.posts
                let known = Set(base.map(\.id))
                self.state.posts = base + page.posts.filter { !known.contains($0.id) }
                self.state.cursor = page.cursor
                self.state.loading = false
                self.state.loadedOnce = true
                // 关注按钮在路上时不拿回包盖掉它
                if !self.followRunning { self.state.following = page.following }
                self.postsRunning = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.postsRunning = false
                if let error = error as? FeedAPIError {
                    Logger.warn("feed topic rejected: \(error.status) \(error.code ?? "")")
                    self.state.loading = false
                    self.state.loadedOnce = true
                    self.state.failed = error.status != 404
                    self.state.gone = error.status == 404
                } else {
                    Logger.warn("feed topic failed: \(error)")
                    self.state.loading = false
                    self.state.loadedOnce = true
                    self.state.failed = true
                }
            }
        }
        postsTask = task
        tasks.append(task)
    }

    /// 关注 / 取消关注：先改按钮，失败改回来。关注成功给一条带「撤销」的提示（撤销 = 再调一次）。
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
                self?.state.notice = .failed
            }
        }
        tasks.append(task)
    }

    func toggleLike(_ card: FeedCard) {
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
                self?.state.notice = .failed
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
                self?.state.notice = .failed
            }
        })
    }

    func onNoticeShown() {
        state.notice = nil
    }

    private func updatePost(_ id: String, _ change: (FeedCard) -> FeedCard) {
        state.posts = state.posts.map { $0.id == id ? change($0) : $0 }
    }
}
