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

/// 动态的配置：`GET /v1/feed/config`（契约 3.2，引擎已有）。没拉到配置时客户端用这里的默认值。
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
    /// 内容偏好里「更多敏感内容」档能不能选（海外 true，大陆 false；契约 3.2）。
    var sensitiveMoreAvailable = false
    /// 举报原因：`{"<组>": ["<原因>", …]}`；`fraud` 和 `my_rights` 下的原因要截图，`my_rights` 还要写关系（契约 6.2）。空 = 不给举报入口。
    var reportReasons = [String: [String]]()
    /// 作者可能看到的未通过原因代码；文案由客户端定，不认识的代码按 `community_guidelines` 显示（契约 7.3）。
    var rejectionReasons = [String]()

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
        sensitiveMoreAvailable = try c.decodeIfPresent(Bool.self, forKey: .sensitiveMoreAvailable) ?? false
        reportReasons = try c.decodeIfPresent([String: [String]].self, forKey: .reportReasons) ?? [:]
        rejectionReasons = try c.decodeIfPresent([String].self, forKey: .rejectionReasons) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, region, tabs, limits
        case sensitiveMoreAvailable = "sensitive_more_available"
        case reportReasons = "report_reasons"
        case rejectionReasons = "rejection_reasons"
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
    var voiceCommentMaxSeconds = 60

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postTextChars = try c.decodeIfPresent(Int.self, forKey: .postTextChars) ?? 500
        postImages = try c.decodeIfPresent(Int.self, forKey: .postImages) ?? 10
        articleChars = try c.decodeIfPresent(Int.self, forKey: .articleChars) ?? 10_000
        editWindowSeconds = try c.decodeIfPresent(Int.self, forKey: .editWindowSeconds) ?? 900
        voiceCommentMaxSeconds = try c.decodeIfPresent(Int.self, forKey: .voiceCommentMaxSeconds) ?? 60
    }

    private enum CodingKeys: String, CodingKey {
        case postTextChars = "post_text_chars"
        case postImages = "post_images"
        case articleChars = "article_chars"
        case editWindowSeconds = "edit_window_seconds"
        case voiceCommentMaxSeconds = "voice_comment_max_seconds"
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
    /// `reason == "repost"` 时：转发的人（profile id），第三节第 26 条。
    var repostedBy: String?

    private enum CodingKeys: String, CodingKey {
        case id, reason
        case repostedBy = "reposted_by"
    }
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
    /// 等帖子作者批准的回复（第 40 条），只有写的人和帖子作者看得到。
    var held = false
    /// 能不能给「复制链接 / 分享到其他 App」：公开动态、作者不是私密账号（第 29 条）。没带就当不能。
    var shareable = false
    /// 作者置顶了（第 26 条）；主页第一页排在最前。
    var pinned = false
    /// `card.quote_of` 那条，引擎直接带上（只一层）。
    var quoted: FeedQuotedResult?

    static let stateOk = "ok"
    static let stateUnavailable = "unavailable"
    /// 只会出现在 `quoted` 里：作者删了原帖（第 41 条「原动态已被作者删除」）。
    static let stateDeleted = "deleted"

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
        held = try c.decodeIfPresent(Bool.self, forKey: .held) ?? false
        shareable = try c.decodeIfPresent(Bool.self, forKey: .shareable) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        quoted = (try? c.decodeIfPresent(FeedQuotedResult.self, forKey: .quoted)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, state, version, card, stats, me, poll, held, shareable, pinned, quoted
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
            result.viewer.isAuthor = me.author
            result.viewer.reposted = me.reposted
        }
        result.pollState = poll
        result.held = held
        result.shareable = shareable
        result.pinned = pinned
        result.quoted = quoted?.toQuoted()
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
    /// 语音评论的服务端转写；转写还没接上时是空串，空的不显示。
    var transcript = ""
    var topics = [FeedTopic]()
    var poll: FeedPoll?
    /// 被引用的帖子 id；引擎已把那条嵌在 Card API 外层的 `quoted`，由 `FeedCardResult.toCard()` 填进 `quoted`。
    var quoteOf: String?
    var sourceUrl: String?
    /// 开放内容的来源（契约「卡片字段」`attribution`，形状还没定稿）：先只留字符串字段，形状不对就当没有，不让整张卡片失败。和 Android 一样暂不显示。
    var attribution: [String: String]?
    /// 非原生内容的版权依据 `rights{basis,license}`；缺字段、形状不对都当没有。
    var rights: FeedRights?
    var ipRegionLabel: String?
    var aiGenerated = false
    /// 评论才有：所属的帖子。
    var rootId: String?
    /// 回复别的评论时才有：被回复的那条评论（直接评论帖子时没有）。
    var parentId: String?
    var stats = FeedStats()
    var viewer = FeedViewer()
    var pollState: FeedPollState?
    // 下面五个来自 Card API 外层，不在 `card` 的 JSON 里（`init(from:)` 不读，由 `toCard()` 填）。
    var held = false
    var shareable = false
    var pinned = false
    var quoted: FeedQuotedCard?
    /// 关注流里因为有人转发才出现的（`reason == "repost"`）：卡片顶上写「谁 转发了」。由来源按 `FeedItemRef.repostedBy` 填。
    var repostedBy: FeedRepostedBy?
    /// 正文第一条网址的预览（链接卡片用）。引擎的卡片里还没有这个字段，`init(from:)` 不读：现在只有 TestFlight 的本机示例数据填。
    var linkPreview: FeedLinkCard.Preview?

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
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        topics = try c.decodeIfPresent([Lossy<FeedTopic>].self, forKey: .topics)?.compactMap(\.value) ?? []
        poll = try? c.decodeIfPresent(FeedPoll.self, forKey: .poll)
        quoteOf = try c.decodeIfPresent(String.self, forKey: .quoteOf)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        let rawAttribution = (try? c.decodeIfPresent([String: Lossy<String>].self, forKey: .attribution)) ?? nil
        attribution = rawAttribution?.compactMapValues(\.value)
        rights = (try? c.decodeIfPresent(FeedRights.self, forKey: .rights)) ?? nil
        ipRegionLabel = try c.decodeIfPresent(String.self, forKey: .ipRegionLabel)
        aiGenerated = try c.decodeIfPresent(Bool.self, forKey: .aiGenerated) ?? false
        rootId = try c.decodeIfPresent(String.self, forKey: .rootId)
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        stats = try c.decodeIfPresent(FeedStats.self, forKey: .stats) ?? FeedStats()
    }

    private enum CodingKeys: String, CodingKey {
        case kind, version, edited, author, title, text, summary, media, topics, poll, stats, transcript, attribution, rights
        case rootId = "root_id"
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

/// 卡片 `rights{basis,license}`（非原生内容）。两个都可以没有。
struct FeedRights: Decodable, Equatable {
    var basis: String?
    var license: String?

    init(basis: String? = nil, license: String? = nil) {
        self.basis = basis
        self.license = license
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        basis = try? c.decodeIfPresent(String.self, forKey: .basis)
        license = try? c.decodeIfPresent(String.self, forKey: .license)
    }

    private enum CodingKeys: String, CodingKey {
        case basis, license
    }
}

struct FeedAuthor: Decodable, Equatable {
    var profileId: String
    var displayName: String
    var handle: String?
    /// 只在没设 handle 时给（引擎卡片已带）；界面显示「Tellomi 号：xxxx」（第三节第 8 条）。
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
    /// 语音评论（`type == "audio"`）的时长，服务端从文件头读。
    var durationMs = 0
    /// 开放内容的图片可能带自己的 `rights{basis,license}`（引擎 `moderation/worker.go` 的 `media.Rights`）；形状不对当没有。
    var rights: FeedRights?

    static let typeAudio = "audio"

    var isAudio: Bool {
        return type == Self.typeAudio
    }

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
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        rights = (try? c.decodeIfPresent(FeedRights.self, forKey: .rights)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case key, type, w, h, alt, rights
        case durationMs = "duration_ms"
    }

    /// 图片宽高比限制在 3:4（竖）到 16:9（横）之间，免得一张极长的图把整屏占掉。
    var clampedAspectRatio: CGFloat {
        guard w > 0, h > 0 else { return 1 }
        return min(max(CGFloat(w) / CGFloat(h), 3.0 / 4.0), 16.0 / 9.0)
    }
}

/// 卡片上的话题。引擎卡片里是 slug 字符串数组（`moderation/worker.go`：`"topics": ["hiking"]`，契约第五节），
/// 显示名由客户端的话题表给（`FeedComposeViewController.topicName`，不认识的 slug 直接显示 slug）。
/// 也认 `{"slug","label"}` 对象（样例数据、旧草稿用的形状）；两样都不是的那一项丢掉，不让整张卡片失败。
struct FeedTopic: Decodable, Equatable {
    var slug: String
    var label: String
}

extension FeedTopic {
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let slug = try? single.decode(String.self) {
            guard !slug.isEmpty else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "empty topic slug")
            }
            self.init(slug: slug, label: FeedComposeViewController.topicName(slug))
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let slug = try c.decode(String.self, forKey: .slug)
        let label = try c.decodeIfPresent(String.self, forKey: .label)
        self.init(slug: slug, label: label ?? FeedComposeViewController.topicName(slug))
    }

    private enum CodingKeys: String, CodingKey {
        case slug, label
    }
}

/// 投票的题面（卡片里，审核时定下）。
struct FeedPoll: Codable, Equatable {
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
        // 引擎 `Stats.LikesHidden` 的 JSON 名是 `likes_hidden`（api/cards.go）；原来写的 `like_count_hidden` 永远读不到。
        // 作者自己的帖子设置（`/settings`）里才叫 `like_count_hidden`，不是这里。
        case likeCountHidden = "likes_hidden"
    }
}

/// Card API 外层的 `me`。
struct FeedMine: Decodable, Equatable {
    var liked: Bool
    var saved: Bool
    /// 这条是我发的（自己的「···」菜单）。
    var author: Bool
    /// 我转发到动态了（第 26 条）。
    var reposted: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liked = try c.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        saved = try c.decodeIfPresent(Bool.self, forKey: .saved) ?? false
        author = try c.decodeIfPresent(Bool.self, forKey: .author) ?? false
        reposted = try c.decodeIfPresent(Bool.self, forKey: .reposted) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case liked, saved, author, reposted
    }
}

/// 界面用：我和这条的关系。`liked`、`saved`、`isAuthor`、`reposted` 来自 `FeedMine`。
struct FeedViewer: Equatable {
    var liked = false
    var saved = false
    var isAuthor = false
    var reposted = false
    /// 引擎没有这个字段（Android 同），恒为 true；详情页发评论被拒（`comments_closed`）后只在本页关掉输入框。
    var canComment = true
}

/// Card API 外层的 `quoted`：`ok` 带卡片，`deleted` / `unavailable` 只有 id。形状和一项 `FeedCardResult` 一样，只嵌一层。
struct FeedQuotedResult: Decodable {
    var id: String
    var state: String
    var card: FeedCard?
    var stats: FeedStats?

    private enum CodingKeys: String, CodingKey {
        case id, state, card, stats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? FeedCardResult.stateUnavailable
        card = (try? c.decodeIfPresent(FeedCard.self, forKey: .card)) ?? nil
        stats = try c.decodeIfPresent(FeedStats.self, forKey: .stats)
    }

    func toQuoted() -> FeedQuotedCard {
        var base: FeedCard?
        if state == FeedCardResult.stateOk, var card {
            card.id = id
            if let stats { card.stats = stats }
            base = card
        }
        return FeedQuotedCard(id: id, card: base, deleted: state == FeedCardResult.stateDeleted)
    }
}

/// 被引用的那条：`card` 为 nil 是看不到了；`deleted` 是作者删了（第 41 条「原动态已被作者删除」），别的原因不分。
///
/// 必须是 class：`FeedCard` 里放 `FeedQuotedCard?`，而它又装着一个 `FeedCard?`，值类型会变成递归存储，编译不过
/// （"value type 'FeedCard' cannot have a stored property that recursively contains it"）。Android 里都是 class 没有这个问题。
final class FeedQuotedCard: Equatable {
    let id: String
    let card: FeedCard?
    let deleted: Bool

    init(id: String, card: FeedCard?, deleted: Bool = false) {
        self.id = id
        self.card = card
        self.deleted = deleted
    }

    static func == (lhs: FeedQuotedCard, rhs: FeedQuotedCard) -> Bool {
        return lhs.id == rhs.id && lhs.card == rhs.card && lhs.deleted == rhs.deleted
    }
}

/// 转发这条的人；名字取不到时只写「转发」。
struct FeedRepostedBy: Equatable {
    var profileId: String
    var displayName: String?
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
