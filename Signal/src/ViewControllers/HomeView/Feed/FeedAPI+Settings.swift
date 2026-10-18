//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedAPI+Settings.swift (new file)
// "Feed settings" engine calls (I-9): content preferences, interests, "show less" keywords, notification settings.
// Mirror of Android `FeedApi.preferences/putPreferences/keywords/putKeyword/deleteKeyword/interests/deleteInterest/resetInterests/notificationSettings/putNotificationSettings`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// `GET /v1/feed/me/preferences`：内容偏好（第三节第 12、47 条）。`pausedUntil` 非空 = 暂停中。缺的字段取 Android 的默认值。
struct FeedPreferences: Decodable, Equatable {
    var personalized = true
    var style = FeedPreferences.styleKeep
    var sensitive = FeedPreferences.sensitiveStandard
    var categories = [String: String]()
    var pausedUntil: String?
    var recentTopics = [FeedRecentTopic]()

    static let styleKeep = "keep"
    static let styleExplore = "explore"
    static let styles = [styleKeep, styleExplore]

    static let sensitiveReduce = "reduce"
    static let sensitiveStandard = "standard"
    static let sensitiveMore = "more"
    static let sensitiveValues = [sensitiveReduce, sensitiveStandard, sensitiveMore]

    static let categoryReduce = "reduce"
    static let categoryDefault = "default"
    static let categoryIncrease = "increase"
    static let categoryValues = [categoryReduce, categoryDefault, categoryIncrease]

    /// 引擎只收 30（暂停）或 0（恢复）。
    static let pauseDays = 30

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personalized = try c.decodeIfPresent(Bool.self, forKey: .personalized) ?? true
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? Self.styleKeep
        sensitive = try c.decodeIfPresent(String.self, forKey: .sensitive) ?? Self.sensitiveStandard
        categories = try c.decodeIfPresent([String: String].self, forKey: .categories) ?? [:]
        pausedUntil = try c.decodeIfPresent(String.self, forKey: .pausedUntil)
        recentTopics = try c.decodeIfPresent([FeedRecentTopic].self, forKey: .recentTopics) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case personalized, style, sensitive, categories
        case pausedUntil = "paused_until"
        case recentTopics = "recent_topics"
    }
}

/// 最近 30 天看过的内容里，某个话题占多少（0–1）。
struct FeedRecentTopic: Decodable, Equatable {
    var key: String
    var share = 0.0

    init(key: String, share: Double = 0) {
        self.key = key
        self.share = share
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        share = try c.decodeIfPresent(Double.self, forKey: .share) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case key, share }
}

/// `PUT /v1/feed/me/preferences`：只发要改的字段（nil 不发）。`categories` 是整张表替换；`pauseDays` 0 也要发出去。
struct FeedPreferencesUpdate: Encodable, Equatable {
    var personalized: Bool?
    var style: String?
    var sensitive: String?
    var categories: [String: String]?
    var pauseDays: Int?

    private enum CodingKeys: String, CodingKey {
        case personalized, style, sensitive, categories
        case pauseDays = "pause_days"
    }
}

/// `GET /v1/feed/me/interests`：推荐用的兴趣标签，按行为算出，只有自己看得到（第 28、47 条；《算法推荐管理规定》第 17 条）。
/// 每类最多 30 个，强的在前。
struct FeedInterests: Decodable, Equatable {
    var topics = [FeedInterest]()
    var authors = [FeedInterest]()
    var sources = [FeedInterest]()

    static let dimTopic = "topic"
    static let dimAuthor = "author"
    static let dimSource = "source"

    init() {}

    init(topics: [FeedInterest] = [], authors: [FeedInterest] = [], sources: [FeedInterest] = []) {
        self.topics = topics
        self.authors = authors
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topics = try c.decodeIfPresent([FeedInterest].self, forKey: .topics) ?? []
        authors = try c.decodeIfPresent([FeedInterest].self, forKey: .authors) ?? []
        sources = try c.decodeIfPresent([FeedInterest].self, forKey: .sources) ?? []
    }

    var isEmpty: Bool { topics.isEmpty && authors.isEmpty && sources.isEmpty }

    func without(dimension: String, key: String) -> FeedInterests {
        var copy = self
        switch dimension {
        case Self.dimTopic: copy.topics.removeAll { $0.key == key }
        case Self.dimAuthor: copy.authors.removeAll { $0.key == key }
        case Self.dimSource: copy.sources.removeAll { $0.key == key }
        default: break
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey { case topics, authors, sources }
}

/// 一个标签：话题是 slug（名字客户端自己起），作者、来源带 `label`。`score` 是同类里相对最强那个的比例。
struct FeedInterest: Decodable, Equatable {
    var key: String
    var label: String?
    var score = 0.0

    init(key: String, label: String? = nil, score: Double = 0) {
        self.key = key
        self.label = label
        self.score = score
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case key, label, score }
}

/// `GET /v1/feed/me/keywords` 里的一项：「少推荐」的词。`expiresAt` RFC 3339，nil = 永久。
struct FeedServerKeyword: Decodable, Equatable {
    var keyword: String
    var expiresAt: String?

    init(keyword: String, expiresAt: String? = nil) {
        self.keyword = keyword
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case keyword
        case expiresAt = "expires_at"
    }
}

private struct FeedKeywordsResponse: Decodable {
    var keywords: [FeedServerKeyword]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keywords = try c.decodeIfPresent([FeedServerKeyword].self, forKey: .keywords) ?? []
    }

    private enum CodingKeys: String, CodingKey { case keywords }
}

/// `PUT /v1/feed/me/keywords`：`days` 0 = 永久、7、30。**0 也要发出去**（合成的 `Encodable` 对非 Optional 的 0 照常编码）。
struct FeedKeywordRequest: Encodable, Equatable {
    var keyword: String
    var days = 0

    static let maxChars = FeedInputLimit.keyword
    static let maxKeywords = 100
    static let allowedDays = [0, 30, 7]
}

/// 通知设置（`GET/PUT /v1/feed/me/notification-settings`）。四个字段 PUT 时都发（Android `@EncodeDefault`）。
struct FeedNotificationSettings: Codable, Equatable {
    var fromWhom = FeedNotificationSettings.fromEveryone
    var likes = true
    /// 评论和回复。
    var comments = true
    /// 新关注者和关注请求。
    var follows = true

    static let fromEveryone = "everyone"
    static let fromFollowing = "following"
    static let fromFriends = "friends"
    static let fromNone = "none"
    static let fromValues = [fromEveryone, fromFollowing, fromFriends, fromNone]

    init(fromWhom: String = FeedNotificationSettings.fromEveryone, likes: Bool = true, comments: Bool = true, follows: Bool = true) {
        self.fromWhom = fromWhom
        self.likes = likes
        self.comments = comments
        self.follows = follows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fromWhom = try c.decodeIfPresent(String.self, forKey: .fromWhom) ?? Self.fromEveryone
        likes = try c.decodeIfPresent(Bool.self, forKey: .likes) ?? true
        comments = try c.decodeIfPresent(Bool.self, forKey: .comments) ?? true
        follows = try c.decodeIfPresent(Bool.self, forKey: .follows) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case likes, comments, follows
        case fromWhom = "from_whom"
    }
}

extension FeedAPI {
    /// 动态通知的来源和类别以外的内容偏好。没设置过给默认值。
    func preferences() async throws -> FeedPreferences {
        return try await send(FeedPreferences.self, request(path: ["v1", "feed", "me", "preferences"]))
    }

    /// 回的是改完之后的整份（不含 `recent_topics`）。
    func putPreferences(_ update: FeedPreferencesUpdate) async throws -> FeedPreferences {
        let body = try Self.encoder.encode(update)
        return try await send(FeedPreferences.self, request(path: ["v1", "feed", "me", "preferences"], method: "PUT", body: body))
    }

    func keywords() async throws -> [FeedServerKeyword] {
        return try await send(FeedKeywordsResponse.self, request(path: ["v1", "feed", "me", "keywords"])).keywords
    }

    /// 加一个「少推荐」的词；已经有就改有效期。超过 100 个 409 `too_many_keywords`。
    func putKeyword(_ keyword: String, days: Int) async throws {
        let body = try Self.encoder.encode(FeedKeywordRequest(keyword: keyword, days: days))
        try await sendNoContent(request(path: ["v1", "feed", "me", "keywords"], method: "PUT", body: body))
    }

    func deleteKeyword(_ keyword: String) async throws {
        try await sendNoContent(request(path: ["v1", "feed", "me", "keywords", keyword], method: "DELETE"))
    }

    func interests() async throws -> FeedInterests {
        return try await send(FeedInterests.self, request(path: ["v1", "feed", "me", "interests"]))
    }

    /// 删掉一个兴趣标签：之后不会再长回来（引擎留一行置零的记录）。
    func deleteInterest(dimension: String, key: String) async throws {
        try await sendNoContent(request(path: ["v1", "feed", "me", "interests", dimension, key], method: "DELETE"))
    }

    /// 重置推荐：算出来的标签全清掉，删过的照样不回来。客户端二次确认（第 12 条）。
    func resetInterests() async throws {
        try await sendNoContent(request(path: ["v1", "feed", "me", "interests", "reset"], method: "POST"))
    }

    func notificationSettings() async throws -> FeedNotificationSettings {
        return try await send(FeedNotificationSettings.self, request(path: ["v1", "feed", "me", "notification-settings"]))
    }

    /// 改通知设置；没有公开主页时 409 `profile_required`（只有有主页的人收得到通知）。
    func putNotificationSettings(_ settings: FeedNotificationSettings) async throws -> FeedNotificationSettings {
        let body = try Self.encoder.encode(settings)
        return try await send(FeedNotificationSettings.self, request(path: ["v1", "feed", "me", "notification-settings"], method: "PUT", body: body))
    }
}
