//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedAPI+Comments.swift (new file)
// Comments (I-4). Mirror of Android `FeedApi.comments/createComment/approveComment` + `FeedCommentsResponse` etc.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// `GET /v1/feed/posts/{id}/comments`：审核通过、你看得到的评论，按时间正序，每页 50 条；没有 `cursor` 就到底了。
struct FeedCommentsResponse: Decodable {
    var comments: [FeedCardResult]
    var cursor: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 一条的结构不对只丢这一条（和 `FeedCardsResponse` 一样）
        comments = (try c.decodeIfPresent([Lossy<FeedCardResult>].self, forKey: .comments) ?? []).compactMap(\.value)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }

    private enum CodingKeys: String, CodingKey {
        case comments, cursor
    }
}

/// `POST /v1/feed/posts/{id}/comments`：`parentId` 是被回复的评论，直接评论帖子时不带。
/// 语音评论：`text` 是空串，`mediaKeys` 是一个上传完成的 `.m4a` 的 key（第三节第 4 条）；文字评论不带 `mediaKeys`。
struct FeedCreateCommentRequest: Encodable, Equatable {
    var text: String
    var parentId: String?
    var mediaKeys: [String]?

    private enum CodingKeys: String, CodingKey {
        case text
        case parentId = "parent_id"
        case mediaKeys = "media_keys"
    }
}

/// 评论也先审后发（R-2.2）：`state` 一般是 `pending`。
struct FeedCreateCommentResponse: Decodable, Equatable {
    var id: String
    var state: String
}

/// 界面用：一页评论（已经换成卡片）。
struct FeedCommentsPage: Equatable {
    var comments = [FeedCard]()
    var cursor: String?
}

extension FeedAPI {
    func comments(postId: String, cursor: String?) async throws -> FeedCommentsResponse {
        let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        return try await send(FeedCommentsResponse.self, request(path: ["v1", "feed", "posts", postId, "comments"], query: query))
    }

    /// 发评论。403 `comments_closed` / `reply_not_allowed` / `voice_comments_off`，409 `profile_required`（要先建公开主页），
    /// 400 `invalid_parent`（被回复的评论不在了）。
    func createComment(postId: String, request body: FeedCreateCommentRequest) async throws -> FeedCreateCommentResponse {
        let data = try Self.encoder.encode(body)
        return try await send(FeedCreateCommentResponse.self, request(path: ["v1", "feed", "posts", postId, "comments"], method: "POST", body: data))
    }

    /// 帖子作者批准一条等着的回复（第三节第 40 条）。
    func approveComment(postId: String, commentId: String) async throws {
        try await sendNoContent(request(path: ["v1", "feed", "posts", postId, "comments", commentId, "approve"], method: "POST"))
    }
}
