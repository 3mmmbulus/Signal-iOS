//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 作者主页样例里「我」和每个作者的关系（本机内存，重开就回到初始）。
final class SampleProfileState {
    private let lock = NSLock()
    private var follow = ["s-1": FeedRelation.followApproved, "s-3": FeedRelation.followApproved]
    private var blocked = Set<String>()
    private var muted = Set<String>()
    private var hiddenFrom = Set<String>()

    func withLock<T>(_ body: (inout [String: String], inout Set<String>, inout Set<String>, inout Set<String>) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&follow, &blocked, &muted, &hiddenFrom)
    }
}

/// 样例的作者主页（内部用户在没有内容引擎时看界面用）：
/// - `s-1` 山风、`s-3` 阿禾：公开，已关注。
/// - `s-2` 小满：**私密账号**，没关注：只看到「私密」；关注后是「已请求」。
/// - `s-4` 周末烘焙：公开，没关注。
/// - `s-5` 夜跑的猫：在另一个内容区域发帖（看不到帖子）。
/// - `s-me`：自己的主页（没有关注 / 屏蔽按钮）。
/// - 其它 id：看不到这个主页。
/// 每页 3 条帖子（能看到翻页）；各种失败、慢、限速见 `Simulation` 里主页相关的开关。
extension SampleFeedSource {
    static let profilePostsPageSize = 3

    private static let bios: [String: String] = [
        "s-1": "爬山、拍云、偶尔写点东西。",
        "s-2": "慢慢来。",
        "s-3": "在路上。",
        "s-4": "周末的烤箱里总有点什么。",
        "s-5": "每天跑一点点。",
        "s-me": "这是我的主页。",
    ]

    func profile(profileId: String) async throws -> FeedProfilePage? {
        let simulation = self.simulation
        if simulation.profileLatencyNanos > 0 {
            try? await Task.sleep(nanoseconds: simulation.profileLatencyNanos)
        }
        if simulation.feedHidden { throw FeedAPIError(status: 404, code: "feed_hidden") }
        if let seconds = simulation.profileThrottledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
        if simulation.failsProfile { throw SampleFeedError.simulatedActionFailure }
        let author = profileId == Self.me.profileId ? Self.me : Self.authors.first { $0.profileId == profileId }
        guard let author else { return nil }
        var page = FeedProfilePage(id: author.profileId, displayName: author.displayName)
        page.handle = author.handle
        page.tellomiNumber = author.tellomiNumber
        page.bio = Self.bios[author.profileId]
        page.isPrivate = author.profileId == "s-2"
        page.regionUnavailable = author.profileId == "s-5"
        page.followers = 1280 - 211 * (Self.authors.firstIndex { $0.profileId == author.profileId } ?? 0)
        page.following = 86
        page.ipRegionLabel = Self.ipLabels[(Self.authors.firstIndex { $0.profileId == author.profileId } ?? 0) % Self.ipLabels.count]
        page.me = profiles.withLock { follow, blocked, muted, hiddenFrom in
            var relation = FeedRelation()
            relation.isSelf = author.profileId == Self.me.profileId
            relation.follow = follow[author.profileId] ?? FeedRelation.followNone
            relation.blocked = blocked.contains(author.profileId)
            relation.muted = muted.contains(author.profileId)
            relation.hiddenFrom = hiddenFrom.contains(author.profileId)
            return relation
        }
        // 粉丝数里已经算上我的关注
        if page.me.follow == FeedRelation.followApproved { page.followers += 1 }
        return page
    }

    func profilePosts(profileId: String, cursor: String?) async throws -> FeedProfilePostsPage {
        let simulation = self.simulation
        if simulation.profilePostsLatencyNanos > 0 {
            try? await Task.sleep(nanoseconds: simulation.profilePostsLatencyNanos)
        }
        if simulation.feedHidden { throw FeedAPIError(status: 404, code: "feed_hidden") }
        if simulation.failsProfilePosts { throw SampleFeedError.simulatedActionFailure }
        // 信息流样例里这个作者的所有帖子（自己发的在最前面）
        let first = try await timeline(tab: .recommend, cursor: nil)
        var cards = first.cards
        var next = first.nextCursor
        while let cursor = next {
            let page = try await timeline(tab: .recommend, cursor: cursor)
            cards += page.cards
            next = page.nextCursor
        }
        let all = cards.filter { $0.author?.profileId == profileId }
        let offset = cursor.flatMap(Int.init) ?? 0
        let end = min(all.count, offset + Self.profilePostsPageSize)
        guard offset < all.count else { return FeedProfilePostsPage() }
        return FeedProfilePostsPage(posts: Array(all[offset..<end]), cursor: end < all.count ? String(end) : nil)
    }

    func setFollowing(profileId: String, following: Bool) async throws -> String {
        try await simulatedProfileAction(latency: simulation.followLatencyNanos, fails: simulation.failsFollow)
        let isPrivate = profileId == "s-2"
        return profiles.withLock { follow, _, _, _ in
            let result = following ? (isPrivate ? FeedRelation.followPending : FeedRelation.followApproved) : FeedRelation.followNone
            follow[profileId] = result == FeedRelation.followNone ? nil : result
            return result
        }
    }

    func setBlocked(profileId: String, blocked isBlocked: Bool) async throws {
        try await simulatedProfileAction(latency: simulation.followLatencyNanos, fails: simulation.failsBlock)
        profiles.withLock { follow, blocked, _, _ in
            if isBlocked {
                blocked.insert(profileId)
                follow[profileId] = nil
            } else {
                blocked.remove(profileId)
            }
        }
    }

    func setHideList(list: String, profileId: String, on: Bool) async throws {
        try await simulatedProfileAction(latency: simulation.followLatencyNanos, fails: simulation.failsHideLists)
        profiles.withLock { _, _, muted, hiddenFrom in
            if list == FeedAPI.hideMute {
                if on { muted.insert(profileId) } else { muted.remove(profileId) }
            } else {
                if on { hiddenFrom.insert(profileId) } else { hiddenFrom.remove(profileId) }
            }
        }
        if !on { removeFromSeededHideList(list: list, profileId: profileId) }
    }

    private func simulatedProfileAction(latency: UInt64, fails: Bool) async throws {
        let simulation = self.simulation
        if latency > 0 {
            try? await Task.sleep(nanoseconds: latency)
        }
        if simulation.feedHidden { throw FeedAPIError(status: 404, code: "feed_hidden") }
        if let seconds = simulation.throttledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
        if fails { throw SampleFeedError.simulatedActionFailure }
    }
}
