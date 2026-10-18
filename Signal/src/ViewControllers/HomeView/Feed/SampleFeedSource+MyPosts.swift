//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 样例里「我的动态」的可变部分（本机内存，重开就回到初始）：删掉的、申诉过的。
final class SampleMyPostsState {
    private let lock = NSLock()
    private var deletedIds = Set<String>()
    private var appealedIds = Set<String>()

    /// 样例里自带的 40 条：最前面是审核中 / 未通过（几种原因、申诉进度）/ 已撤回，后面是 34 条已发布（五档可见范围轮着来）。
    static let seedIds: Set<String> = Set(seeds(base: Date()).map(\.id))

    static func seeds(base: Date) -> [FeedMyPost] {
        func at(_ minutesAgo: Double) -> String { FeedDates.format(base.addingTimeInterval(-minutesAgo * 60)) }
        func make(_ id: String, state: String, minutes: Double, text: String, visibility: FeedVisibility = .public, reasons: [String] = [], appealable: Bool = false, appealState: String? = nil, kind: String = FeedCard.kindPost, title: String? = nil) -> FeedMyPost {
            var post = FeedMyPost(id: "mine-seed-\(id)", state: state, kind: kind, title: title, text: text, createdAt: at(minutes), appealable: appealable, appealState: appealState)
            post.visibility = visibility.apiName
            post.rejectionReasons = reasons
            return post
        }
        var posts = [
            make("p1", state: FeedMyPost.statePending, minutes: 10, text: "Waiting for review (sample)", visibility: .friends),
            make("r1", state: FeedMyPost.stateRejected, minutes: 60, text: "Rejected: prohibited words (sample)", reasons: ["prohibited_words"], appealable: true),
            make("r2", state: FeedMyPost.stateRejected, minutes: 120, text: "Rejected: review unavailable (sample)", visibility: .onlyMe, reasons: ["review_unavailable"], appealable: true),
            make("r3", state: FeedMyPost.stateRejected, minutes: 180, text: "Rejected: appeal in review (sample)", reasons: ["lexicon:x", "something_new"], appealState: FeedMyPost.appealReceived),
            make("r4", state: FeedMyPost.stateRejected, minutes: 240, text: "Rejected: appeal upheld (sample)", reasons: ["account_restricted"], appealState: FeedMyPost.appealUpheld),
            make("w1", state: FeedMyPost.stateWithdrawn, minutes: 300, text: "Removed after publishing (sample)"),
        ]
        for k in 1...34 {
            posts.append(make(
                String(k),
                state: FeedMyPost.statePublished,
                minutes: 400 + Double(k) * 90,
                text: "My sample post \(k)",
                visibility: FeedVisibility.allCases[k % FeedVisibility.allCases.count],
                kind: k % 5 == 0 ? FeedCard.kindArticle : FeedCard.kindPost,
                title: k % 5 == 0 ? "My sample article \(k)" : nil
            ))
        }
        return posts
    }

    func snapshot() -> (deleted: Set<String>, appealed: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        return (deletedIds, appealedIds)
    }

    /// 样例自带的帖子删掉：true = 删成了；不是样例自带的、或者已经删过 = false。
    func delete(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Self.seedIds.contains(id), !deletedIds.contains(id) else { return false }
        deletedIds.insert(id)
        return true
    }

    func markAppealed(_ id: String) {
        lock.lock()
        appealedIds.insert(id)
        lock.unlock()
    }
}

extension SampleFeedSource {
    private func currentMyPosts() -> [FeedMyPost] {
        let state = myPostsState.snapshot()
        var posts = ownLivePosts().map { card -> FeedMyPost in
            var post = FeedMyPost(id: card.id, state: FeedMyPost.statePublished, kind: card.kind, title: card.title, text: card.text, createdAt: card.publishedAt)
            post.visibility = FeedVisibility.public.apiName
            return post
        }
        for var post in SampleMyPostsState.seeds(base: now()) where !state.deleted.contains(post.id) {
            if state.appealed.contains(post.id) {
                post.appealable = false
                post.appealState = FeedMyPost.appealReceived
            }
            posts.append(post)
        }
        return posts
    }

    private func myPostsGate(latency: UInt64) async throws {
        let simulation = self.simulation
        if latency > 0 {
            try? await Task.sleep(nanoseconds: latency)
        }
        if simulation.feedHidden { throw FeedAPIError(status: 404, code: "feed_hidden") }
        if let seconds = simulation.myPostsThrottledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
    }

    func myPosts(before: String?) async throws -> FeedMyPostsPage {
        try await myPostsGate(latency: simulation.myPostsLatencyNanos)
        let simulation = self.simulation
        if simulation.failsMyPosts || (before != nil && simulation.failsMyPostsMore) { throw SampleFeedError.simulatedActionFailure }
        var posts = currentMyPosts()
        if let before, let cutoff = FeedDates.parse(before) {
            posts = posts.filter { (FeedDates.parse($0.createdAt ?? "") ?? .distantPast) < cutoff }
        }
        let page = Array(posts.prefix(30))
        return FeedMyPostsPage(posts: page, nextBefore: posts.count > page.count ? page.last?.createdAt : nil)
    }

    func appeal(contentId: String, text: String) async throws {
        try await myPostsGate(latency: simulation.appealLatencyNanos)
        let simulation = self.simulation
        if simulation.failsAppeals { throw SampleFeedError.simulatedActionFailure }
        guard let post = currentMyPosts().first(where: { $0.id == contentId }) else { throw FeedAPIError(status: 404, code: "not_found") }
        if simulation.appealsAlreadyAppealed { throw FeedAPIError(status: 409, code: "already_appealed") }
        if simulation.appealsNotRejected || post.state != FeedMyPost.stateRejected { throw FeedAPIError(status: 409, code: "not_rejected") }
        if post.appealState != nil || !post.appealable { throw FeedAPIError(status: 409, code: "already_appealed") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.unicodeScalars.count > FeedMyPost.maxAppealChars { throw FeedAPIError(status: 400, code: "invalid_text") }
        myPostsState.markAppealed(contentId)
    }

    /// 样例自带的已发布帖子（`mine-seed-N`）：点开详情要有卡片。
    func sampleMyPostsCard(_ id: String) -> FeedCard? {
        guard !myPostsState.snapshot().deleted.contains(id),
              let post = SampleMyPostsState.seeds(base: now()).first(where: { $0.id == id }),
              post.state == FeedMyPost.statePublished else { return nil }
        var card = FeedCard(
            id: id,
            kind: post.kind,
            displayMode: post.kind == FeedCard.kindArticle ? FeedCard.displayArticleCard : FeedCard.displayText,
            publishedAt: post.createdAt,
            author: Self.me,
            title: post.title,
            text: post.text,
            media: [],
            ipRegionLabel: Self.ipLabels[0],
        )
        card.viewer.isAuthor = true
        return card
    }
}
