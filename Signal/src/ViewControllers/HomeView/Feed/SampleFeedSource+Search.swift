//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 样例里「我关注的话题」（本机内存，重开就回到初始：关注了 `food`）。
final class SampleTopicState {
    private let lock = NSLock()
    private var followed = ["food"]

    func withLock<T>(_ body: (inout [String]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&followed)
    }
}

/// 样例的搜索和话题页（内部用户在没有内容引擎时看界面用）：
/// - 搜索：词包含在帖子文字里（或作者名 / handle 里，用户）就算命中，不分大小写；`all` = 最多 5 个人 + 帖子，`users` = 最多 20 个人，`posts` = 只有帖子；帖子每页 3 条（能看到翻页）。
///   试试：「云」「面包」「夜跑」「山」「周末」；搜「zzz」没有结果。
/// - 话题：`daily` 日常、`food` 美食（已关注）、`outdoors` 户外、`reading` 读书；别的 slug 是 404（话题页说「找不到」）。每页 3 条。
/// 各种失败 / 慢 / 限速见 `Simulation` 里搜索、话题相关的开关。
extension SampleFeedSource {
    static let searchPostsPageSize = 3
    static let topicPostsPageSize = 3

    func search(query: String, scope: String, cursor: String?) async throws -> FeedSearchPage {
        let simulation = self.simulation
        if simulation.searchLatencyNanos > 0 {
            try? await Task.sleep(nanoseconds: simulation.searchLatencyNanos)
        }
        if simulation.feedHidden { throw FeedAPIError(status: 404, code: "feed_hidden") }
        if let seconds = simulation.searchThrottledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
        if simulation.failsSearch || (cursor != nil && simulation.failsSearchMore) { throw SampleFeedError.simulatedActionFailure }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return FeedSearchPage() }
        var page = FeedSearchPage()
        if cursor == nil, scope != FeedAPI.searchPosts {
            let limit = scope == FeedAPI.searchUsers ? 20 : 5
            page.users = Self.authors
                .filter { $0.displayName.lowercased().contains(needle) || ($0.handle ?? "").lowercased().contains(needle) }
                .prefix(limit)
                .map { FeedSearchUser(id: $0.profileId, displayName: $0.displayName, handle: $0.handle) }
        }
        if scope != FeedAPI.searchUsers {
            let all = try await allSampleCards().filter { ($0.text ?? "").lowercased().contains(needle) }
            let offset = cursor.flatMap(Int.init) ?? 0
            if offset < all.count {
                let end = min(all.count, offset + Self.searchPostsPageSize)
                page.posts = Array(all[offset..<end])
                page.cursor = end < all.count ? String(end) : nil
            }
        }
        return page
    }

    func followedTopics() async throws -> [String] {
        return topicFollows.withLock { $0 }
    }

    func topicPosts(slug: String, cursor: String?) async throws -> FeedTopicPage {
        let simulation = self.simulation
        if simulation.topicLatencyNanos > 0 {
            try? await Task.sleep(nanoseconds: simulation.topicLatencyNanos)
        }
        if simulation.feedHidden { throw FeedAPIError(status: 404, code: "feed_hidden") }
        if let seconds = simulation.topicThrottledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
        if simulation.failsTopic || (cursor != nil && simulation.failsTopicMore) { throw SampleFeedError.simulatedActionFailure }
        guard Self.topics.contains(where: { $0.slug == slug }) else { throw FeedAPIError(status: 404, code: "not_found") }

        let all = try await allSampleCards().filter { $0.topics.contains { $0.slug == slug } }
        let offset = cursor.flatMap(Int.init) ?? 0
        let following = topicFollows.withLock { $0.contains(slug) }
        guard offset < all.count else { return FeedTopicPage(posts: [], cursor: nil, following: following) }
        let end = min(all.count, offset + Self.topicPostsPageSize)
        return FeedTopicPage(posts: Array(all[offset..<end]), cursor: end < all.count ? String(end) : nil, following: following)
    }

    func setFollowingTopic(slug: String, following: Bool) async throws {
        let simulation = self.simulation
        if simulation.followLatencyNanos > 0 {
            try? await Task.sleep(nanoseconds: simulation.followLatencyNanos)
        }
        if simulation.feedHidden { throw FeedAPIError(status: 404, code: "feed_hidden") }
        if let seconds = simulation.throttledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
        if simulation.failsTopicFollow { throw SampleFeedError.simulatedActionFailure }
        topicFollows.withLock { followed in
            followed.removeAll { $0 == slug }
            if following { followed.insert(slug, at: 0) }
        }
    }

    /// 信息流样例里的全部帖子（自己发的在最前面），搜索和话题页从这里筛。
    private func allSampleCards() async throws -> [FeedCard] {
        let first = try await timeline(tab: .recommend, cursor: nil)
        var cards = first.cards
        var next = first.nextCursor
        while let cursor = next {
            let page = try await timeline(tab: .recommend, cursor: cursor)
            cards += page.cards
            next = page.nextCursor
        }
        return cards
    }
}
