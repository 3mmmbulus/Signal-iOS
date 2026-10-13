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
/// 「部分可见」「不给谁看」要选人（`needsAudience`），选人复用快拍「选定的人」组件；对方的假名怎么拿到还没定
/// （契约第十一节第 2 条），在那之前这两档显示但不能选，不让用户发出一条没有名单的帖子。
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

    enum Problem: Equatable {
        case empty
        case missingTitle
        case tooLong
        case tooManyImages
        case visibilityNotAllowed
        case missingAudience
    }

    var isEmpty: Bool {
        return title.isBlank && text.isBlank && images.isEmpty
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
        if text.isBlank, attachedImages.isEmpty { return .empty }
        if textLength > textLimit(limits) { return .tooLong }
        if attachedImages.count > limits.postImages { return .tooManyImages }
        if !FeedVisibility.allowed(minorMode: minorMode).contains(visibility) { return .visibilityNotAllowed }
        if visibility.needsAudience { return .missingAudience }
        return nil
    }

    /// `POST /v1/feed/posts` 的请求体：只放引擎认的字段（契约 7.2）。评论权限在后面的 PR 加（第三节第 40 条）。
    var request: FeedCreatePostRequest {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeedCreatePostRequest(
            kind: kind.apiName,
            title: kind == .article && !trimmedTitle.isEmpty ? trimmedTitle : nil,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            visibility: visibility.apiName,
            commentsClosed: false,
        )
    }
}

/// `POST /v1/feed/posts`。引擎按 `DisallowUnknownFields` 解析，多一个字段就 400，所以只放引擎认的字段；
/// `client_nonce`（重试去重）和 `media_keys`（图片）待引擎补（契约 7.2），补上之前带图的帖子发不了。
struct FeedCreatePostRequest: Encodable, Equatable {
    var kind: String
    var title: String?
    var text: String
    var visibility: String
    var commentsClosed: Bool

    private enum CodingKeys: String, CodingKey {
        case kind, title, text, visibility
        case commentsClosed = "comments_closed"
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
