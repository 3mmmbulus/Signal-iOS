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
    private var edits = [String: (title: String?, text: String)]()

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

    func markEdited(_ id: String, title: String?, text: String) {
        lock.lock()
        edits[id] = (title, text)
        lock.unlock()
    }

    func edit(for id: String) -> (title: String?, text: String)? {
        lock.lock()
        defer { lock.unlock() }
        return edits[id]
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
            if let edit = myPostsState.edit(for: post.id) {
                post.text = edit.text
                if post.kind == FeedCard.kindArticle { post.title = edit.title }
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
            text: post.kind == FeedCard.kindArticle ? Self.sampleArticleBody : post.text,
            summary: post.kind == FeedCard.kindArticle ? post.text : nil,
            media: [],
            ipRegionLabel: Self.ipLabels[0],
        )
        card.viewer.isAuthor = true
        applyDetailExtras(to: &card)
        return card
    }

    /// 样例里长文的整篇正文（点开详情、打开长文阅读页时看到）：小标题、引用、列表、粗体、斜体都有一点，中文为主。
    static let sampleArticleBody = """
    # 为什么我开始写长文

    过去一年我在**短动态**里写了很多想法，但越写越觉得，*真正想说清楚的事*，一百个字是放不下的。

    ## 三个原因

    1. 短动态适合记录，不适合论证。
    2. 长文可以慢慢铺开，读的人也愿意停下来。
    3. 写完一篇长文，自己的想法才算真的整理过一遍。

    > 写作不是为了表达已经想清楚的东西，而是为了想清楚。

    ## 我的做法

    - 先写**标题**，再写三句话的提纲。
    - 每天只写一小段，不追求一次写完。
    - 发布前读一遍，删掉*最没把握*的那一句。

    English is fine too: a *good* article has a **clear** point, and it respects the reader's time.

    谢谢你读到这里。
    """
}
