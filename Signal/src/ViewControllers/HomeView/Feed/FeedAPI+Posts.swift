//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedAPI+Posts.swift (new file)
// Post-level engine calls used by the card (I-3): repost, poll vote, own-post settings / insights, delete.
// Mirror of Android `FeedApi.setRepost/vote/updatePostSettings/postSettings/postInsights/deletePost`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// `PUT /v1/feed/posts/{id}/vote`：选项下标，单选只能一个；每人一次，投了不能改。
struct FeedVoteRequest: Encodable, Equatable {
    var options: [Int]
}

/// `PATCH /v1/feed/posts/{id}/settings`：只带要改的字段，nil 不发（合成的 `Encodable` 对 Optional 用 `encodeIfPresent`）。
/// 引擎按 `DisallowUnknownFields` 解析，字段名必须是下面这几个。
struct FeedPostSettingsUpdate: Encodable, Equatable {
    var pinned: Bool?
    var likeCountHidden: Bool?
    var replyPolicy: String?
    var commentsClosed: Bool?
    var replyModeration: Bool?
    var voiceComments: Bool?

    private enum CodingKeys: String, CodingKey {
        case pinned
        case likeCountHidden = "like_count_hidden"
        case replyPolicy = "reply_policy"
        case commentsClosed = "comments_closed"
        case replyModeration = "reply_moderation"
        case voiceComments = "voice_comments"
    }
}

/// `GET /v1/feed/posts/{id}/settings`：自己帖子当前的设置，只有作者拿得到（别人 404）。缺的字段取 Android 的默认值。
struct FeedPostSettings: Decodable, Equatable {
    var pinned = false
    var likeCountHidden = false
    var replyPolicy = "everyone"
    var commentsClosed = false
    var replyModeration = false
    var voiceComments = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        likeCountHidden = try c.decodeIfPresent(Bool.self, forKey: .likeCountHidden) ?? false
        replyPolicy = try c.decodeIfPresent(String.self, forKey: .replyPolicy) ?? "everyone"
        commentsClosed = try c.decodeIfPresent(Bool.self, forKey: .commentsClosed) ?? false
        replyModeration = try c.decodeIfPresent(Bool.self, forKey: .replyModeration) ?? false
        voiceComments = try c.decodeIfPresent(Bool.self, forKey: .voiceComments) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case pinned
        case likeCountHidden = "like_count_hidden"
        case replyPolicy = "reply_policy"
        case commentsClosed = "comments_closed"
        case replyModeration = "reply_moderation"
        case voiceComments = "voice_comments"
    }
}

/// `GET /v1/feed/posts/{id}/insights`：「查看数据」，只有作者拿得到。
struct FeedPostInsights: Decodable, Equatable {
    var opens = 0
    var likes = 0
    var comments = 0
    var reposts = 0
    var saves = 0

    init(opens: Int = 0, likes: Int = 0, comments: Int = 0, reposts: Int = 0, saves: Int = 0) {
        self.opens = opens
        self.likes = likes
        self.comments = comments
        self.reposts = reposts
        self.saves = saves
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opens = try c.decodeIfPresent(Int.self, forKey: .opens) ?? 0
        likes = try c.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        comments = try c.decodeIfPresent(Int.self, forKey: .comments) ?? 0
        reposts = try c.decodeIfPresent(Int.self, forKey: .reposts) ?? 0
        saves = try c.decodeIfPresent(Int.self, forKey: .saves) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case opens, likes, comments, reposts, saves
    }
}

extension FeedAPI {
    /// 转发到动态 / 取消（第三节第 26 条）：PUT 加、DELETE 去，幂等；不能转发的 404。
    func setRepost(contentId: String, on: Bool) async throws {
        try await sendNoContent(request(path: ["v1", "feed", "posts", contentId, "repost"], method: on ? "PUT" : "DELETE"))
    }

    /// 投票。投了不能改（每人一次）；回的是票数和我的选择，界面直接换上。
    func vote(contentId: String, options: [Int]) async throws -> FeedPollState {
        let body = try Self.encoder.encode(FeedVoteRequest(options: options))
        return try await send(FeedPollState.self, request(path: ["v1", "feed", "posts", contentId, "vote"], method: "PUT", body: body))
    }

    /// 自己帖子的置顶、隐藏点赞数、回复选项 → 204。置顶满 3 条 409 `too_many_pinned`。
    func updatePostSettings(contentId: String, update: FeedPostSettingsUpdate) async throws {
        let body = try Self.encoder.encode(update)
        try await sendNoContent(request(path: ["v1", "feed", "posts", contentId, "settings"], method: "PATCH", body: body))
    }

    func postSettings(contentId: String) async throws -> FeedPostSettings {
        return try await send(FeedPostSettings.self, request(path: ["v1", "feed", "posts", contentId, "settings"]))
    }

    func postInsights(contentId: String) async throws -> FeedPostInsights {
        return try await send(FeedPostInsights.self, request(path: ["v1", "feed", "posts", contentId, "insights"]))
    }

    func deletePost(contentId: String) async throws {
        try await sendNoContent(request(path: ["v1", "feed", "posts", contentId], method: "DELETE"))
    }
}
