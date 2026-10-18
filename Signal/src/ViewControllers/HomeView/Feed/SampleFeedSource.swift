//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import UIKit

/// 本机样例：内部用户在内容引擎接上之前看界面用。人名、内容全是虚构的，守 `internal-beta-content-generator.md` 4.1
/// （不涉政、不点名真人与品牌、不编造新闻）。只在内存里，点赞和不感兴趣重启 App 就没了。和 Android `SampleFeedSource` 同一组样例。
final class SampleFeedSource: FeedSource {
    static let shared = SampleFeedSource()

    static let pageSize = 8

    private let lock = NSLock()
    private var liked = Set<String>()
    private var hidden = Set<String>()
    /// 自己在样例里发的，放在两栏最上面。
    private var mine = [FeedCard]()
    private var published = [String: FeedCreatePostResponse]()

    private let now: () -> Date
    /// 样例取评论前先等一会儿，界面上才看得到「加载中」。单测传 0。
    private let commentsLatencyNanos: UInt64
    /// 已经让它失败过一次的帖子（见 `failsFirstCommentLoad`）：重试就成功。
    private var failedCommentLoads = Set<String>()

    init(now: @escaping () -> Date = Date.init, commentsLatencyNanos: UInt64 = 500_000_000) {
        self.now = now
        self.commentsLatencyNanos = commentsLatencyNanos
    }

    static let me = FeedAuthor(profileId: "s-me", displayName: "我", tellomiNumber: "1000000001")

    static let authors = [
        FeedAuthor(profileId: "s-1", displayName: "山风", handle: "shanfeng"),
        FeedAuthor(profileId: "s-2", displayName: "小满", tellomiNumber: "3820145967"),
        FeedAuthor(profileId: "s-3", displayName: "阿禾在路上", handle: "ahe"),
        FeedAuthor(profileId: "s-4", displayName: "周末烘焙", handle: "weekend_bake"),
        FeedAuthor(profileId: "s-5", displayName: "夜跑的猫", handle: "nightcat"),
    ]

    private static let texts = [
        "今天的云很低，像是伸手就能摸到。下班路上停下来看了五分钟。",
        "第一次自己做酸面包，外皮裂得刚刚好，就是有点酸过头了。",
        "楼下新开了一家修自行车的小铺，老板说他修了三十年车。",
        "雨后的石板路，踩上去会响。",
        "夜跑第 100 天，配速没变快，但心情变好了。",
        "整理旧照片，翻到小时候在外婆家院子里的那棵枇杷树。",
        "周末去山里住了一晚，早上被鸟叫醒，比闹钟好听多了。",
        "学会了一个新词：「回甘」。喝完这杯茶才懂。",
        "阳台的薄荷又长疯了，谁要来摘一点？",
        "地铁上看完一本小说，最后一页没舍得翻。",
        "今天试着一整天不看手机，坚持到了下午三点。",
        "给猫换了新猫砂，它研究了半个小时才肯进去。",
    ]

    private static let topics = [
        FeedTopic(slug: "daily", label: "日常"),
        FeedTopic(slug: "food", label: "美食"),
        FeedTopic(slug: "outdoors", label: "户外"),
        FeedTopic(slug: "reading", label: "读书"),
    ]

    static let ipLabels = ["四川", "重庆", "浙江", "广东", "云南"]

    private static let commentTexts = [
        "拍得真好，我也想去看看。",
        "哈哈，我家楼下也有一家这样的小店。",
        "收藏了，周末试试。",
        "好久没看到这么安静的画面了。",
        "谢谢分享！",
        "同感，下班路上最治愈。",
        "能说说具体在哪儿吗？",
        "第二张最喜欢。",
    ]

    static let commentPageSize = 5

    /// 样例帖子详情页里能看到各个状态（内部用户在没有内容引擎时看界面用）：
    /// - 评论数是 0 的帖子（`sample-0`、`sample-4`…）：「还没有评论」
    /// - `sample-2`、`sample-6`…：第一次取评论失败，点「重试」后成功
    /// - `sample-7`：打开后 Card API 说这条看不到了（「已不可见」）
    /// - 评论多于一页的（如 `sample-3`、`sample-5`）：滑到底取下一页
    static let goneIds: Set<String> = ["sample-7"]

    static func failsFirstCommentLoad(postId: String) -> Bool {
        guard let index = sampleIndex(of: postId) else { return false }
        return index % 4 == 2
    }

    static func sampleIndex(of id: String) -> Int? {
        let prefix = "sample-"
        guard id.hasPrefix(prefix) else { return nil }
        return Int(id.dropFirst(prefix.count))
    }

    private lazy var recommend: [FeedCard] = (0..<24).map(sampleCard)
    private lazy var following: [FeedCard] = recommend.filter { ["s-1", "s-3"].contains($0.author?.profileId) }

    func config() async throws -> FeedConfig {
        var config = FeedConfig()
        config.enabled = true
        config.region = "cn"
        config.tabs = FeedTab.allCases.map(\.apiName)
        config.recommendMode = FeedConfig.recommendModeEditorial
        config.ipRegionVisible = true
        return config
    }

    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage {
        return locked {
            let base = tab == .recommend ? recommend : following
            let all = (mine + base).filter { !hidden.contains($0.id) }
            let start = min(max(cursor.flatMap { Int($0) } ?? 0, 0), all.count)
            let end = min(start + Self.pageSize, all.count)
            let cards = all[start..<end].map { card -> FeedCard in
                var card = card
                let isLiked = liked.contains(card.id)
                card.viewer.liked = isLiked
                card.stats.likes += isLiked ? 1 : 0
                return card
            }
            return FeedTimelinePage(cards: cards, nextCursor: end < all.count ? String(end) : nil)
        }
    }

    func card(contentId: String) async throws -> FeedCard? {
        return locked {
            guard !Self.goneIds.contains(contentId) else { return nil }
            guard var card = (mine + recommend).first(where: { $0.id == contentId }) else { return nil }
            let isLiked = liked.contains(card.id)
            card.viewer.liked = isLiked
            card.stats.likes += isLiked ? 1 : 0
            return card
        }
    }

    func comments(postId: String, cursor: String?) async throws -> FeedCommentsPage {
        if commentsLatencyNanos > 0 {
            try? await Task.sleep(nanoseconds: commentsLatencyNanos)
        }
        let failNow = locked { () -> Bool in
            guard cursor == nil, Self.failsFirstCommentLoad(postId: postId), !failedCommentLoads.contains(postId) else { return false }
            failedCommentLoads.insert(postId)
            return true
        }
        if failNow {
            throw SampleFeedError.simulatedCommentFailure
        }
        let all = sampleComments(postId: postId)
        let start = min(max(cursor.flatMap { Int($0) } ?? 0, 0), all.count)
        let end = min(start + Self.commentPageSize, all.count)
        return FeedCommentsPage(comments: Array(all[start..<end]), cursor: end < all.count ? String(end) : nil)
    }

    func setLiked(contentId: String, liked isLiked: Bool) async throws {
        locked {
            if isLiked {
                liked.insert(contentId)
            } else {
                liked.remove(contentId)
            }
        }
    }

    func notInterested(contentId: String) async throws {
        _ = locked { hidden.insert(contentId) }
    }

    func undoNotInterested(contentId: String) async throws {
        _ = locked { hidden.remove(contentId) }
    }

    /// 同一个 `clientNonce` 重复发只算一次（契约 7.2 的去重）。选的图只放在本机内存（`FeedLocalImages`），样例卡片能显示出来。
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        return locked {
            if let existing = published[clientNonce] {
                return existing
            }
            let id = "mine-\(mine.count)"
            let media = draft.attachedImages.map { image -> FeedMedia in
                let key = FeedLocalImages.key(for: image.id)
                FeedLocalImages.shared.set(image.image, for: key)
                return FeedMedia(key: key, w: Int(image.image.size.width), h: Int(image.image.size.height))
            }
            let request = draft.request
            var card = FeedCard(
                id: id,
                kind: draft.kind.apiName,
                displayMode: draft.kind == .article ? FeedCard.displayArticleCard : (media.isEmpty ? FeedCard.displayText : FeedCard.displayTextImages),
                publishedAt: FeedDates.format(now()),
                author: Self.me,
                title: request.title,
                text: request.text,
                media: media,
                ipRegionLabel: Self.ipLabels[0],
            )
            card.viewer.isAuthor = true
            mine.insert(card, at: 0)
            let response = FeedCreatePostResponse(id: id, state: FeedCreatePostResponse.statePublished)
            published[clientNonce] = response
            return response
        }
    }

    /// 样例不连网：事件只记个数，方便内部用户在日志里看曝光有没有在算。
    private(set) var reportedEvents = [FeedEventPayload]()

    func reportEvents(_ events: [FeedEventPayload]) async throws {
        locked { reportedEvents += events }
        Logger.debug("feed sample events: \(events.count)")
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// 一个样例帖子的评论，按时间正序（和引擎一样）。每三条一组：第 0 条直接评论帖子，第 1 条回复它，第 2 条回复第 1 条（楼中楼里「回复 @某人」）。
    /// 条数和帖子卡片上的评论数一致；找不到这个帖子（自己发的、别的 id）就没有评论。
    private func sampleComments(postId: String) -> [FeedCard] {
        guard let index = Self.sampleIndex(of: postId) else { return [] }
        let count = (index * 3) % 12
        let current = now()
        return (0..<count).map { j -> FeedCard in
            var comment = FeedCard(
                id: "\(postId)-c\(j)",
                kind: FeedCard.kindComment,
                publishedAt: FeedDates.format(current.addingTimeInterval(-Double(count - j) * 7 * 60)),
                author: Self.authors[(index + j + 1) % Self.authors.count],
                text: Self.commentTexts[(index + j) % Self.commentTexts.count],
            )
            comment.rootId = postId
            if j % 3 != 0 {
                comment.parentId = "\(postId)-c\(j - 1)"
            }
            return comment
        }
    }

    private func sampleCard(_ index: Int) -> FeedCard {
        let author = Self.authors[index % Self.authors.count]
        let imageCount: Int
        switch index % 4 {
        case 1: imageCount = 1
        case 3: imageCount = 3
        default: imageCount = 0
        }
        return FeedCard(
            id: "sample-\(index)",
            kind: FeedCard.kindPost,
            displayMode: imageCount > 0 ? FeedCard.displayTextImages : FeedCard.displayText,
            publishedAt: FeedDates.format(now().addingTimeInterval(-Double(index * 37 + 5) * 60)),
            edited: index == 5,
            author: author,
            text: Self.texts[index % Self.texts.count],
            media: (0..<imageCount).map { FeedMedia(key: "sample/\(index)/\($0)", w: 1080, h: $0 % 2 == 0 ? 1440 : 1080) },
            topics: [Self.topics[index % Self.topics.count]],
            ipRegionLabel: Self.ipLabels[index % Self.ipLabels.count],
            stats: FeedStats(likes: (index * 7) % 50, comments: (index * 3) % 12, reposts: index % 4),
        )
    }
}

enum SampleFeedError: Error {
    /// 样例里「评论加载失败」的状态（只失败第一次，重试成功）。
    case simulatedCommentFailure
}
