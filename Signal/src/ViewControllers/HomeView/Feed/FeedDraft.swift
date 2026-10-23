//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import UIKit

/// 发布页顶部的两种（`dynamic-feed.md` 第三节第 23 条）。
enum FeedDraftKind: String, CaseIterable {
    case post
    case article

    var apiName: String { rawValue }

    var title: String {
        switch self {
        case .post:
            return OWSLocalizedString("TELLOMI_FEED_COMPOSE_KIND_POST", comment: "Feed publish page: switch at the top for a short post.")
        case .article:
            return OWSLocalizedString("TELLOMI_FEED_COMPOSE_KIND_ARTICLE", comment: "Feed publish page: switch at the top for a long article.")
        }
    }
}

/// 帖子可见范围五档（第三节第 39 条；契约 7.2 `visibility`）。
///
/// 「部分可见」「不给谁看」要选人（`needsAudience`）：选人页是 `FeedAudiencePickerViewController`，候选人是本机好友（I-11），
/// 名单由 Signal-Server 签成 `audience_token`（客户端不接触别人的假名）。没有候选人来源或引擎没有 `audience_tokens` 时这两档显示但不能选。
enum FeedVisibility: String, CaseIterable {
    case `public`
    case friends
    case include
    case exclude
    case onlyMe = "only_me"

    var apiName: String { rawValue }

    var needsAudience: Bool {
        return self == .include || self == .exclude
    }

    var title: String {
        switch self {
        case .public: return OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_PUBLIC", comment: "Feed publish page: visibility option, anyone can see the post.")
        case .friends: return OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_FRIENDS", comment: "Feed publish page: visibility option, only friends.")
        case .include: return OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_INCLUDE", comment: "Feed publish page: visibility option, only the people you pick.")
        case .exclude: return OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_EXCLUDE", comment: "Feed publish page: visibility option, everyone except the people you pick.")
        case .onlyMe: return OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_ONLY_ME", comment: "Feed publish page: visibility option, only yourself.")
        }
    }

    var subtitle: String {
        switch self {
        case .public: return OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_PUBLIC_DESCRIPTION", comment: "Feed publish page: explanation under the Public option.")
        case .friends: return OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_FRIENDS_DESCRIPTION", comment: "Feed publish page: explanation under the Friends option.")
        case .include: return OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_INCLUDE_DESCRIPTION", comment: "Feed publish page: explanation under the Only some friends option.")
        case .exclude: return OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_EXCLUDE_DESCRIPTION", comment: "Feed publish page: explanation under the Hide from option.")
        case .onlyMe: return OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_ONLY_ME_DESCRIPTION", comment: "Feed publish page: explanation under the Only me option.")
        }
    }

    /// 未成年人只能「仅好友 / 仅自己」（第 31 条；契约 7.2 客户端也不给选）。
    static func allowed(minorMode: Bool) -> [FeedVisibility] {
        return minorMode ? [.friends, .onlyMe] : allCases
    }

    /// 现在能选的：允许的里面去掉要选人的两档。
    static func selectable(minorMode: Bool) -> [FeedVisibility] {
        return allowed(minorMode: minorMode).filter { !$0.needsAudience }
    }

    /// 默认值：成年人「公开」，未成年人「仅好友」。
    static func defaultValue(minorMode: Bool) -> FeedVisibility {
        return minorMode ? .friends : .public
    }
}

/// 发布页选的一张图（只在本机，发出时再上传，契约 7.1）。
struct FeedDraftImage: Equatable {
    let id: String
    let image: UIImage

    init(id: String = UUID().uuidString, image: UIImage) {
        self.id = id
        self.image = image
    }

    static func == (lhs: FeedDraftImage, rhs: FeedDraftImage) -> Bool {
        return lhs.id == rhs.id
    }
}

/// 正在写的一条。和 Android `FeedDraft` 同一套规则。
struct FeedDraft: Equatable {
    var kind = FeedDraftKind.post
    var title = ""
    var text = ""
    var images = [FeedDraftImage]()
    var visibility = FeedVisibility.public
    /// 「部分可见 / 不给谁看」选的人；别的档位不发出去，切回来还在（I-11）。
    var audience = [FeedAudienceMember]()
    /// 投票（第三节第 22 条），只有动态能带；切到长文时留着、切回来还在（I-12）。
    var poll: FeedDraftPoll?
    /// 回复选项（第三节第 40 条），动态和长文都有（I-12）。
    var replies = FeedReplySettings()
    /// 话题：最多 `maxTopics` 个 slug（第三节第 22 条，I-12）。
    var topics = [String]()
    /// 引用的那条（第三节第 26 条）；引用也要写点什么，而且只能是动态（I-12）。
    var quote: FeedQuoteTarget?

    /// 一条最多带 3 个话题（引擎 `MaxPostTopics`）。
    static let maxTopics = 3

    /// 名单最多 500 人（Signal-Server `MAX_AUDIENCE_MEMBERS`、引擎 `MaxAudienceMembers`）。
    static let maxAudience = 500

    enum Problem: Equatable {
        case empty
        case missingTitle
        case tooLong
        case tooManyImages
        case visibilityNotAllowed
        case missingAudience
        case audienceTooLarge
        /// 投票少于 2 个填了的选项，或某一项超过 40 字（I-12）。
        case invalidPoll
        /// 编辑时和原来一样，没什么可保存的（只由 `FeedComposeState.problem` 给出，I-12）。
        case unchanged
    }

    var isEmpty: Bool {
        return title.isBlank && text.isBlank && images.isEmpty && poll == nil
    }

    /// 真正发出去的投票：长文不带。
    var attachedPoll: FeedDraftPoll? {
        return kind == .post ? poll : nil
    }

    /// 真正发出去的图：长文 P1 不带图（第 25 条只有标题和排版），切到长文时已选的图留着、切回来还在。
    var attachedImages: [FeedDraftImage] {
        return kind == .post ? images : []
    }

    /// 正文字数上限：动态 500，长文 1 万（第 22、25 条；数值以服务端 `limits` 为准）。
    func textLimit(_ limits: FeedLimits) -> Int {
        switch kind {
        case .post: return limits.postTextChars
        case .article: return limits.articleChars
        }
    }

    /// 按 Unicode 码点数（一个汉字算 1），客户端和引擎同一个口径（契约 3.2）。
    var textLength: Int {
        return text.unicodeScalars.count
    }

    /// 发不出去的原因；能发返回 nil。
    func problem(limits: FeedLimits, minorMode: Bool) -> Problem? {
        if kind == .article, title.isBlank { return .missingTitle }
        if text.isBlank, attachedImages.isEmpty, attachedPoll == nil { return .empty }
        if textLength > textLimit(limits) { return .tooLong }
        if attachedImages.count > limits.postImages { return .tooManyImages }
        if let poll = attachedPoll, !poll.isValid { return .invalidPoll }
        if !FeedVisibility.allowed(minorMode: minorMode).contains(visibility) { return .visibilityNotAllowed }
        if visibility.needsAudience && audience.isEmpty { return .missingAudience }
        if visibility.needsAudience && audience.count > Self.maxAudience { return .audienceTooLarge }
        return nil
    }

    /// 不带可选字段的请求体（本机样例和老的单测用）。
    var request: FeedCreatePostRequest {
        return makeRequest()
    }

    /// `POST /v1/feed/posts` 的请求体：只放引擎认的字段（契约 7.2）。
    /// - `clientNonce`：每条草稿一个 UUID，重试时不变；同一个再发，引擎回 200 和第一次那条，不会多出一条。
    /// - `mediaKeys`：7.1 上传完成的图片 key，按显示顺序；图片上传是 I-2，在那之前传 nil。
    /// - `audienceToken`：`include` / `exclude` 时 Signal-Server 签的名单；名单接口（I-3 之后）接上之前传 nil。
    /// - `now`：投票的截止时间在点发布的那一刻算（I-12）。
    func makeRequest(clientNonce: String? = nil, mediaKeys: [String]? = nil, audienceToken: String? = nil, now: Date = Date()) -> FeedCreatePostRequest {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeedCreatePostRequest(
            kind: kind.apiName,
            title: kind == .article && !trimmedTitle.isEmpty ? trimmedTitle : nil,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            visibility: visibility.apiName,
            commentsClosed: replies.commentsClosed,
            // 「所有人」不发，用引擎默认
            replyPolicy: replies.policy == .everyone ? nil : replies.policy.apiName,
            replyModeration: replies.moderation,
            clientNonce: clientNonce,
            mediaKeys: (mediaKeys?.isEmpty ?? true) ? nil : mediaKeys,
            audience: audienceToken.map { FeedAudienceToken(audienceToken: $0) },
            poll: attachedPoll?.toApi(now: now),
            topics: topics.isEmpty ? nil : topics,
            quoteOf: quote?.id,
        )
    }
}

/// `POST /v1/feed/posts`。引擎按 `DisallowUnknownFields` 解析，多一个字段就 400，所以只放引擎认的字段（契约 7.2；和 Android
/// `FeedCreatePostRequest` 同一组）。可选字段为 nil 时不编码（`encodeIfPresent`），引擎用默认值。
struct FeedCreatePostRequest: Encodable, Equatable {
    var kind: String
    var title: String?
    var text: String
    var visibility: String
    var commentsClosed: Bool
    /// `everyone` / `friends` / `following`（引擎暂定，Q-11）；nil 用引擎默认（所有人）。
    var replyPolicy: String?
    /// 审核回复：别人的回复等作者批准后才公开（第 40 条）。
    var replyModeration = false
    var clientNonce: String?
    var mediaKeys: [String]?
    var audience: FeedAudienceToken?
    /// 只有 `kind == "post"` 能带（引擎 `invalid_poll`）。
    var poll: FeedPoll?
    /// 话题 slug，最多 3 个（引擎 `invalid_topics`）。
    var topics: [String]?
    /// 引用的那条（第 26 条「引用」）；只有 `kind == "post"` 能引用。
    var quoteOf: String?

    private enum CodingKeys: String, CodingKey {
        case kind, title, text, visibility, audience, poll, topics
        case commentsClosed = "comments_closed"
        case replyPolicy = "reply_policy"
        case replyModeration = "reply_moderation"
        case clientNonce = "client_nonce"
        case mediaKeys = "media_keys"
        case quoteOf = "quote_of"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(text, forKey: .text)
        try c.encode(visibility, forKey: .visibility)
        try c.encode(commentsClosed, forKey: .commentsClosed)
        try c.encodeIfPresent(replyPolicy, forKey: .replyPolicy)
        // 默认值不编码：和 Android（kotlinx 默认不编码 `false`）一样只在开着时带
        if replyModeration { try c.encode(replyModeration, forKey: .replyModeration) }
        try c.encodeIfPresent(clientNonce, forKey: .clientNonce)
        try c.encodeIfPresent(mediaKeys, forKey: .mediaKeys)
        try c.encodeIfPresent(audience, forKey: .audience)
        try c.encodeIfPresent(poll, forKey: .poll)
        try c.encodeIfPresent(topics, forKey: .topics)
        try c.encodeIfPresent(quoteOf, forKey: .quoteOf)
    }
}

/// 发帖时的 `audience`：`{"audience_token": "<Signal-Server 签的 JWT>"}`，`kind` 要和 `visibility` 一致。
struct FeedAudienceToken: Codable, Equatable {
    var audienceToken: String

    private enum CodingKeys: String, CodingKey {
        case audienceToken = "audience_token"
    }
}

struct FeedCreatePostResponse: Decodable, Equatable {
    var id: String
    var state: String
    var version: Int

    /// 大陆先审后发（R-2.2）：作者看到「审核中」，别人看不到。
    static let statePending = "pending"
    static let statePublished = "published"

    init(id: String, state: String, version: Int = 1) {
        self.id = id
        self.state = state
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? Self.statePending
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }

    private enum CodingKeys: String, CodingKey {
        case id, state, version
    }
}

private extension String {
    var isBlank: Bool {
        return trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
