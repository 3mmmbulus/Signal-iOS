//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// 内容引擎（`tellomi/content-engine` `internal/engine/api`）的 JSON 结构，字段名与引擎逐字相同（snake_case）。
// 契约：`docs/adr/0071/client-api-2026-10.md`（已按引擎实际的接口修订）。和 Android `FeedModels.kt` 一一对应。
//
// 客户端必须忽略不认识的字段（Decodable 本来就忽略）；每个可选字段都有默认值，服务端少给一个字段不会让整页解析失败；
// 一张卡片解析失败只丢这一张（`FeedCardsResponse`）。

/// 动态的配置。引擎还没有配置接口（契约 3.2「待引擎补」），在那之前客户端用这里的默认值，
/// 只从 `GET /v1/feed/status` 拿「能不能看」。
struct FeedConfig: Decodable, Equatable {
    var enabled = false
    var region: String?
    var tabs = [String]()
    var recommendMode = FeedConfig.recommendModeEditorial
    var personalizationToggleVisible = false
    var hotEnabled = false
    var ipRegionVisible = false
    var mediaBaseUrl: String?
    var cardTtlSeconds = 600
    var limits = FeedLimits()
    var minorMode = false

    /// 大陆算法备案之前：编辑精选 + 时间顺序（`dynamic-feed.md` R-1.5）。
    static let recommendModeEditorial = "editorial_chronological"
    /// 打分（引擎 `ModeScored`）。客户端只用它决定文案，不改请求。
    static let recommendModeScored = "scored"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        region = try c.decodeIfPresent(String.self, forKey: .region)
        tabs = try c.decodeIfPresent([String].self, forKey: .tabs) ?? []
        recommendMode = try c.decodeIfPresent(String.self, forKey: .recommendMode) ?? Self.recommendModeEditorial
        personalizationToggleVisible = try c.decodeIfPresent(Bool.self, forKey: .personalizationToggleVisible) ?? false
        hotEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotEnabled) ?? false
        ipRegionVisible = try c.decodeIfPresent(Bool.self, forKey: .ipRegionVisible) ?? false
        mediaBaseUrl = try c.decodeIfPresent(String.self, forKey: .mediaBaseUrl)
        cardTtlSeconds = try c.decodeIfPresent(Int.self, forKey: .cardTtlSeconds) ?? 600
        limits = try c.decodeIfPresent(FeedLimits.self, forKey: .limits) ?? FeedLimits()
        minorMode = try c.decodeIfPresent(Bool.self, forKey: .minorMode) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, region, tabs, limits
        case recommendMode = "recommend_mode"
        case personalizationToggleVisible = "personalization_toggle_visible"
        case hotEnabled = "hot_enabled"
        case ipRegionVisible = "ip_region_visible"
        case mediaBaseUrl = "media_base_url"
        case cardTtlSeconds = "card_ttl_seconds"
        case minorMode = "minor_mode"
    }
}

/// 字数、图片张数、编辑时限（契约 3.2 `limits`；第三节第 22、23、25 条）。字数按 Unicode 码点数。
struct FeedLimits: Decodable, Equatable {
    var postTextChars = 500
    var postImages = 10
    var articleChars = 10_000
    var editWindowSeconds = 900

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postTextChars = try c.decodeIfPresent(Int.self, forKey: .postTextChars) ?? 500
        postImages = try c.decodeIfPresent(Int.self, forKey: .postImages) ?? 10
        articleChars = try c.decodeIfPresent(Int.self, forKey: .articleChars) ?? 10_000
        editWindowSeconds = try c.decodeIfPresent(Int.self, forKey: .editWindowSeconds) ?? 900
    }

    private enum CodingKeys: String, CodingKey {
        case postTextChars = "post_text_chars"
        case postImages = "post_images"
        case articleChars = "article_chars"
        case editWindowSeconds = "edit_window_seconds"
    }
}

/// `GET /v1/feed/status`：内测名单和紧急开关都过了才是 true。
struct FeedStatus: Decodable {
    var visible: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case visible
    }
}

/// `GET /v1/feed/recommend`、`GET /v1/feed/following[?cursor=]`：只给 id，卡片再走 Card API。
/// 推荐每次给新的一页、没有 cursor；关注按时间倒序，有 cursor 就还有下一页。
struct FeedIdsPage: Decodable {
    var items: [FeedItemRef]
    var cursor: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([FeedItemRef].self, forKey: .items) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }

    private enum CodingKeys: String, CodingKey {
        case items, cursor
    }
}

struct FeedItemRef: Decodable, Equatable {
    var id: String
    var reason: String?
}

/// 界面用的一页：已经把 id 换成了卡片。不是线上的 JSON。
struct FeedTimelinePage {
    var cards = [FeedCard]()
    var nextCursor: String?
}

/// `POST /v1/feed/cards`，一次最多 100 个 id。
struct FeedCardsRequest: Encodable {
    var ids: [String]
}

struct FeedCardsResponse: Decodable {
    var cards: [FeedCardResult]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 一张卡片的结构不对只丢这一张，不让整页失败
        let lossy = try c.decodeIfPresent([Lossy<FeedCardResult>].self, forKey: .cards) ?? []
        cards = lossy.compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey {
        case cards
    }
}

/// 一张卡片的结果。`card` 是审核时定下的展示字段（`pool_card.card`），每个人不同的计数和「我赞过没有」在外层。
struct FeedCardResult: Decodable {
    var id: String
    var state: String
    var version: Int
    var card: FeedCard?
    var stats: FeedStats?
    var me: FeedMine?
    var poll: FeedPollState?

    static let stateOk = "ok"
    static let stateUnavailable = "unavailable"

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? Self.stateUnavailable
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // card 结构不对（比如没有 kind）：这一项按不可用处理，不丢 id
        card = (try? c.decodeIfPresent(FeedCard.self, forKey: .card)) ?? nil
        stats = try c.decodeIfPresent(FeedStats.self, forKey: .stats)
        me = try c.decodeIfPresent(FeedMine.self, forKey: .me)
        poll = try c.decodeIfPresent(FeedPollState.self, forKey: .poll)
    }

    private enum CodingKeys: String, CodingKey {
        case id, state, version, card, stats, me, poll
    }

    /// `unavailable` 不区分原因（删除、下架、被屏蔽、无权看都一样）。不认识的 state 一律按不可用处理。
    var isAvailable: Bool {
        return state == Self.stateOk && card != nil
    }

    /// 把外层的计数、我的状态合进卡片，界面只看 `FeedCard`。
    func toCard() -> FeedCard? {
        guard isAvailable, var result = card else { return nil }
        result.id = id
        result.version = version
        if let stats {
            result.stats = stats
        }
        if let me {
            result.viewer.liked = me.liked
            result.viewer.saved = me.saved
        }
        result.pollState = poll
        return result
    }
}

/// 卡片展示字段（引擎 `moderation/worker.go` 写进 `pool_card.card` 的那些，契约第五节）。
/// `stats`、`viewer`、`pollState` 由 `FeedCardResult.toCard()` 从外层填。
struct FeedCard: Decodable, Equatable {
    /// 引擎的 `card` 里没有 id（在 Card API 外层），由 `toCard()` 填。
    var id = ""
    var kind: String
    var displayMode = FeedCard.displayText
    var version = 1
    var publishedAt: String?
    var edited = false
    var author: FeedAuthor?
    var title: String?
    var text: String?
    var summary: String?
    var media = [FeedMedia]()
    var topics = [FeedTopic]()
    var poll: FeedPoll?
    /// 被引用的帖子 id；要显示时再走一次 Card API。
    var quoteOf: String?
    var sourceUrl: String?
    var ipRegionLabel: String?
    var aiGenerated = false
    var parentId: String?
    var stats = FeedStats()
    var viewer = FeedViewer()
    var pollState: FeedPollState?

    static let kindPost = "post"
    static let kindArticle = "article"
    static let kindComment = "comment"

    static let displayText = "text"
    static let displayTextImages = "text_images"
    static let displayLink = "link"
    static let displayArticleCard = "article_card"

    /// P1 客户端只渲染这几种 `kind`；别的（快拍、视频等）不显示，不报错（契约第五节）。
    static let renderableKinds: Set<String> = [kindPost, kindArticle, kindComment]

    var isRenderable: Bool {
        return Self.renderableKinds.contains(kind)
    }

    var isArticle: Bool {
        return kind == Self.kindArticle
    }

    init(
        id: String,
        kind: String = FeedCard.kindPost,
        displayMode: String = FeedCard.displayText,
        publishedAt: String? = nil,
        edited: Bool = false,
        author: FeedAuthor? = nil,
        title: String? = nil,
        text: String? = nil,
        summary: String? = nil,
        media: [FeedMedia] = [],
        topics: [FeedTopic] = [],
        ipRegionLabel: String? = nil,
        aiGenerated: Bool = false,
        stats: FeedStats = FeedStats(),
        viewer: FeedViewer = FeedViewer(),
    ) {
        self.id = id
        self.kind = kind
        self.displayMode = displayMode
        self.publishedAt = publishedAt
        self.edited = edited
        self.author = author
        self.title = title
        self.text = text
        self.summary = summary
        self.media = media
        self.topics = topics
        self.ipRegionLabel = ipRegionLabel
        self.aiGenerated = aiGenerated
        self.stats = stats
        self.viewer = viewer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        displayMode = try c.decodeIfPresent(String.self, forKey: .displayMode) ?? Self.displayText
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        author = try c.decodeIfPresent(FeedAuthor.self, forKey: .author)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        media = try c.decodeIfPresent([Lossy<FeedMedia>].self, forKey: .media)?.compactMap(\.value) ?? []
        topics = try c.decodeIfPresent([Lossy<FeedTopic>].self, forKey: .topics)?.compactMap(\.value) ?? []
        poll = try? c.decodeIfPresent(FeedPoll.self, forKey: .poll)
        quoteOf = try c.decodeIfPresent(String.self, forKey: .quoteOf)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        ipRegionLabel = try c.decodeIfPresent(String.self, forKey: .ipRegionLabel)
        aiGenerated = try c.decodeIfPresent(Bool.self, forKey: .aiGenerated) ?? false
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        stats = try c.decodeIfPresent(FeedStats.self, forKey: .stats) ?? FeedStats()
    }

    private enum CodingKeys: String, CodingKey {
        case kind, version, edited, author, title, text, summary, media, topics, poll, stats
        case displayMode = "display_mode"
        case publishedAt = "published_at"
        case quoteOf = "quote_of"
        case sourceUrl = "source_url"
        case ipRegionLabel = "ip_region_label"
        case aiGenerated = "ai_generated"
        case parentId = "parent_id"
    }

    var publishedDate: Date? {
        guard let publishedAt else { return nil }
        return FeedDates.parse(publishedAt)
    }
}

struct FeedAuthor: Decodable, Equatable {
    var profileId: String
    var displayName: String
    var handle: String?
    /// 引擎的卡片还没带（契约第十一节第 3 条）；没设 handle 的人显示「Tellomi 号：xxxx」（第三节第 8 条）。
    var tellomiNumber: String?
    var avatarKey: String?
    /// 开放内容的作者（`native = false`）给的是外部头像地址。
    var avatarUrl: String?
    var badge: String?
    /// false = 开放内容的外部作者：没有「发消息」「加好友」。
    var isNative = true
    var provider: String?

    init(profileId: String, displayName: String, handle: String? = nil, tellomiNumber: String? = nil) {
        self.profileId = profileId
        self.displayName = displayName
        self.handle = handle
        self.tellomiNumber = tellomiNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decode(String.self, forKey: .profileId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        tellomiNumber = try c.decodeIfPresent(String.self, forKey: .tellomiNumber)
        avatarKey = try c.decodeIfPresent(String.self, forKey: .avatarKey)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        badge = try c.decodeIfPresent(String.self, forKey: .badge)
        isNative = try c.decodeIfPresent(Bool.self, forKey: .isNative) ?? true
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
    }

    private enum CodingKeys: String, CodingKey {
        case handle, badge, provider
        case profileId = "id"
        case displayName = "display_name"
        case tellomiNumber = "tellomi_number"
        case avatarKey = "avatar_key"
        case avatarUrl = "avatar_url"
        case isNative = "native"
    }
}

struct FeedMedia: Decodable, Equatable {
    var key: String
    var type = "image"
    var w = 0
    var h = 0
    var alt = ""

    init(key: String, w: Int = 0, h: Int = 0, alt: String = "") {
        self.key = key
        self.w = w
        self.h = h
        self.alt = alt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "image"
        w = try c.decodeIfPresent(Int.self, forKey: .w) ?? 0
        h = try c.decodeIfPresent(Int.self, forKey: .h) ?? 0
        alt = try c.decodeIfPresent(String.self, forKey: .alt) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case key, type, w, h, alt
    }

    /// 图片宽高比限制在 3:4（竖）到 16:9（横）之间，免得一张极长的图把整屏占掉。
    var clampedAspectRatio: CGFloat {
        guard w > 0, h > 0 else { return 1 }
        return min(max(CGFloat(w) / CGFloat(h), 3.0 / 4.0), 16.0 / 9.0)
    }
}

struct FeedTopic: Decodable, Equatable {
    var slug: String
    var label: String
}

/// 投票的题面（卡片里，审核时定下）。
struct FeedPoll: Decodable, Equatable {
    var options: [String]
    var closesAt: String?
    var multi: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        closesAt = try c.decodeIfPresent(String.self, forKey: .closesAt)
        multi = try c.decodeIfPresent(Bool.self, forKey: .multi) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case options, multi
        case closesAt = "closes_at"
    }
}

/// 投票的票数和我的选择（Card API 外层，每个人不同）。
struct FeedPollState: Decodable, Equatable {
    var counts: [Int]
    var voted: [Int]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counts = try c.decodeIfPresent([Int].self, forKey: .counts) ?? []
        voted = try c.decodeIfPresent([Int].self, forKey: .voted) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case counts, voted
    }
}

struct FeedStats: Decodable, Equatable {
    var likes = 0
    var comments = 0
    var reposts = 0
    var likeCountHidden = false

    init(likes: Int = 0, comments: Int = 0, reposts: Int = 0) {
        self.likes = likes
        self.comments = comments
        self.reposts = reposts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        likes = try c.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        comments = try c.decodeIfPresent(Int.self, forKey: .comments) ?? 0
        reposts = try c.decodeIfPresent(Int.self, forKey: .reposts) ?? 0
        likeCountHidden = try c.decodeIfPresent(Bool.self, forKey: .likeCountHidden) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case likes, comments, reposts
        case likeCountHidden = "like_count_hidden"
    }
}

/// Card API 外层的 `me`。
struct FeedMine: Decodable, Equatable {
    var liked: Bool
    var saved: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liked = try c.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        saved = try c.decodeIfPresent(Bool.self, forKey: .saved) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case liked, saved
    }
}

/// 界面用：我和这条的关系。`liked`、`saved` 来自 `FeedMine`，其余引擎还没给。
struct FeedViewer: Equatable {
    var liked = false
    var saved = false
    var isAuthor = false
}

/// `POST /v1/feed/not-interested`。原因最多 40 字，可空（第三节第 11 条）。
struct FeedNotInterestedRequest: Encodable {
    var contentId: String
    var reason: String?

    private enum CodingKeys: String, CodingKey {
        case reason
        case contentId = "content_id"
    }
}

/// 错误体 `{"error": "…"}`。
struct FeedErrorBody: Decodable {
    var error: String?
}

/// 解析失败的元素变成 nil，不让整个数组失败。
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

enum FeedDates {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// RFC 3339（契约 1「编码」），带不带小数秒都认。
    static func parse(_ value: String) -> Date? {
        return plain.date(from: value) ?? withFractionalSeconds.date(from: value)
    }

    static func format(_ date: Date) -> String {
        return plain.string(from: date)
    }
}
