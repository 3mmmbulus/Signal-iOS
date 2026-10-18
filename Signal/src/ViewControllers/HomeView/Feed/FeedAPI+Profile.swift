//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedAPI+Profile.swift (new file)
// Public profile, follow / block, follow requests, hide lists, close people (I-5).
// Mirror of Android `FeedApi.myProfile/saveProfile/profile/profilePosts/follow/block/followRequests/answerFollowRequest/blocks/hideLists/setHideList/closePeople/...`
// and the matching models in `FeedModels.kt`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// `GET` / `PUT /v1/feed/me/profile`：自己的公开主页（契约第八节）。
struct FeedMyProfile: Decodable, Equatable {
    var id: String
    var tellomiNumber: String?
    var handle: String?
    var displayName: String
    var avatarKey: String?
    var bio: String?
    var shownInterests = [String]()
    var isPrivate = false
    var isMinor = false
    var region: String?
    /// 防骚扰模式到什么时候（第三节第 30 条）；没开是 nil。
    var guardUntil: String?

    /// 防骚扰模式能选的天数；0 = 关。
    static let guardDays = [0, 3, 7, 30]
    /// 引擎的上限（`MaxNameChars`、`MaxBioChars`）。
    static let maxNameChars = FeedInputLimit.profileName
    static let maxBioChars = FeedInputLimit.profileBio

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tellomiNumber = try c.decodeIfPresent(String.self, forKey: .tellomiNumber)
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        displayName = try c.decode(String.self, forKey: .displayName)
        avatarKey = try c.decodeIfPresent(String.self, forKey: .avatarKey)
        bio = try c.decodeIfPresent(String.self, forKey: .bio)
        shownInterests = try c.decodeIfPresent([String].self, forKey: .shownInterests) ?? []
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        isMinor = try c.decodeIfPresent(Bool.self, forKey: .isMinor) ?? false
        region = try c.decodeIfPresent(String.self, forKey: .region)
        guardUntil = try c.decodeIfPresent(String.self, forKey: .guardUntil)
    }

    private enum CodingKeys: String, CodingKey {
        case id, handle, bio, region
        case tellomiNumber = "tellomi_number"
        case displayName = "display_name"
        case avatarKey = "avatar_key"
        case shownInterests = "shown_interests"
        case isPrivate = "is_private"
        case isMinor = "is_minor"
        case guardUntil = "harassment_guard_until"
    }
}

/// `PUT /v1/feed/me/profile`：第一次调用就是建主页（必须带名字）；没给的字段不变（nil 不发）。
struct FeedProfileUpdate: Encodable, Equatable {
    var displayName: String?
    var bio: String?
    /// 私密账号（第三节第 29 条）；改回公开时引擎把待处理的关注请求都通过。
    var isPrivate: Bool?
    /// 防骚扰模式开几天，0 = 关（第三节第 30 条）。0 也要发。
    var guardDays: Int?

    init(displayName: String? = nil, bio: String? = nil, isPrivate: Bool? = nil, guardDays: Int? = nil) {
        self.displayName = displayName
        self.bio = bio
        self.isPrivate = isPrivate
        self.guardDays = guardDays
    }

    private enum CodingKeys: String, CodingKey {
        case bio
        case displayName = "display_name"
        case isPrivate = "is_private"
        case guardDays = "harassment_guard_days"
    }
}

/// 我和这个主页的关系。`follow` 是 `none` / `pending` / `approved`。
struct FeedRelation: Decodable, Equatable {
    var isSelf = false
    var follow = FeedRelation.followNone
    var followedBy = false
    var friend = false
    /// 我屏蔽了对方。
    var blocked = false
    /// 我「不看 TA 的动态」。
    var muted = false
    /// 我「不让 TA 看我的动态」。
    var hiddenFrom = false

    static let followNone = "none"
    static let followPending = "pending"
    static let followApproved = "approved"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        follow = try c.decodeIfPresent(String.self, forKey: .follow) ?? Self.followNone
        followedBy = try c.decodeIfPresent(Bool.self, forKey: .followedBy) ?? false
        friend = try c.decodeIfPresent(Bool.self, forKey: .friend) ?? false
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        hiddenFrom = try c.decodeIfPresent(Bool.self, forKey: .hiddenFrom) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case follow, friend, blocked, muted
        case isSelf = "self"
        case followedBy = "followed_by"
        case hiddenFrom = "hidden_from"
    }
}

struct FeedClosePerson: Decodable, Equatable {
    var id: String
    var displayName: String
    var avatarKey: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarKey = "avatar_key"
    }
}

/// `GET /v1/feed/profiles/{id}`：别人的（或自己的）公开主页（第三节第 8–10、29、33、42 条）。
/// 屏蔽、删了、未成年人主页对非好友都是 404 `not_found`，不区分原因。
struct FeedProfilePage: Decodable, Equatable {
    var id: String
    var handle: String?
    /// 只在没设 handle 时给（第三节第 8 条）。
    var tellomiNumber: String?
    var displayName: String
    var avatarKey: String?
    var bio: String?
    var shownInterests = [String]()
    /// 不是个人账号时的类别（官方账号等）。
    var badge: String?
    var isPrivate = false
    /// 只有大陆区看大陆区的人才给（第三节第 10 条）。
    var ipRegionLabel: String?
    var followers = 0
    var following = 0
    /// 对方在另一个内容区域发帖，帖子到不了这里（R-1.4）。
    var regionUnavailable = false
    var me = FeedRelation()
    /// 「关心的人」，对方同意了的才有（第三节第 42 条）。
    var closePeople = [FeedClosePerson]()

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        tellomiNumber = try c.decodeIfPresent(String.self, forKey: .tellomiNumber)
        displayName = try c.decode(String.self, forKey: .displayName)
        avatarKey = try c.decodeIfPresent(String.self, forKey: .avatarKey)
        bio = try c.decodeIfPresent(String.self, forKey: .bio)
        shownInterests = try c.decodeIfPresent([String].self, forKey: .shownInterests) ?? []
        badge = try c.decodeIfPresent(String.self, forKey: .badge)
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        ipRegionLabel = try c.decodeIfPresent(String.self, forKey: .ipRegionLabel)
        followers = try c.decodeIfPresent(Int.self, forKey: .followers) ?? 0
        following = try c.decodeIfPresent(Int.self, forKey: .following) ?? 0
        regionUnavailable = try c.decodeIfPresent(Bool.self, forKey: .regionUnavailable) ?? false
        me = try c.decodeIfPresent(FeedRelation.self, forKey: .me) ?? FeedRelation()
        closePeople = try c.decodeIfPresent([FeedClosePerson].self, forKey: .closePeople) ?? []
    }

    /// 能不能看这个人的帖子：私密账号要是好友或者关注被批准（第三节第 29 条）。
    var canSeePosts: Bool {
        return me.isSelf || !isPrivate || me.friend || me.follow == FeedRelation.followApproved
    }

    /// 主页下面画不画帖子列表：看得到、没被我屏蔽、不在另一个内容区域（R-1.4）。
    var showsPosts: Bool {
        return canSeePosts && !me.blocked && !regionUnavailable
    }

    /// 换一个关注状态，粉丝数跟着「已关注」进出变。
    func withFollow(_ follow: String) -> FeedProfilePage {
        let was = me.follow == FeedRelation.followApproved
        let now = follow == FeedRelation.followApproved
        var copy = self
        copy.followers = max(0, followers + (now ? 1 : 0) - (was ? 1 : 0))
        copy.me.follow = follow
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, handle, bio, badge, followers, following, me
        case tellomiNumber = "tellomi_number"
        case displayName = "display_name"
        case avatarKey = "avatar_key"
        case shownInterests = "shown_interests"
        case isPrivate = "is_private"
        case ipRegionLabel = "ip_region_label"
        case regionUnavailable = "region_unavailable"
        case closePeople = "close_people"
    }
}

/// `GET /v1/feed/profiles/{id}/posts`：一页 20 条，满一页才有 `cursor`。
struct FeedProfilePostsResponse: Decodable {
    var posts = [FeedCardResult]()
    var cursor: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        posts = try c.decodeIfPresent([FeedCardResult].self, forKey: .posts) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }

    private enum CodingKeys: String, CodingKey { case posts, cursor }
}

/// 界面用：一页主页帖子（已经换成卡片）。
struct FeedProfilePostsPage: Equatable {
    var posts = [FeedCard]()
    var cursor: String?
}

/// `PUT` / `DELETE /v1/feed/follow/{type}/{id}` 的回包：私密账号是 `pending`，取消后是 `none`。
struct FeedFollowResponse: Decodable, Equatable {
    var state = FeedRelation.followNone

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? FeedRelation.followNone
    }

    private enum CodingKeys: String, CodingKey { case state }
}

/// 关注请求、屏蔽列表、隐藏名单里的一个人。
struct FeedPersonSummary: Decodable, Equatable {
    var id: String
    var handle: String?
    var displayName: String
    var avatarKey: String?

    private enum CodingKeys: String, CodingKey {
        case id, handle
        case displayName = "display_name"
        case avatarKey = "avatar_key"
    }
}

/// `GET /v1/feed/me/hide-lists`：「不看 TA」和「不让 TA 看」两张名单，最近加的在前。
struct FeedHideLists: Decodable, Equatable {
    var mute = [FeedPersonSummary]()
    var hideFrom = [FeedPersonSummary]()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mute = try c.decodeIfPresent([FeedPersonSummary].self, forKey: .mute) ?? []
        hideFrom = try c.decodeIfPresent([FeedPersonSummary].self, forKey: .hideFrom) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case mute
        case hideFrom = "hide_from"
    }
}

/// `GET /v1/feed/me/follow-requests`：别人想关注我的私密账号。
struct FeedFollowRequest: Decodable, Equatable {
    var profile: FeedPersonSummary
    var requestedAt: String?

    private enum CodingKeys: String, CodingKey {
        case profile
        case requestedAt = "requested_at"
    }
}

private struct FeedFollowRequestsResponse: Decodable {
    var requests = [FeedFollowRequest]()

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requests = try c.decodeIfPresent([FeedFollowRequest].self, forKey: .requests) ?? []
    }

    private enum CodingKeys: String, CodingKey { case requests }
}

struct FeedFollowRequestDecision: Encodable, Equatable {
    var approve: Bool
}

/// `GET /v1/feed/me/blocks`：作者、来源、话题都在里面；只有作者带 `profile`。
struct FeedBlockEntry: Decodable, Equatable {
    var type: String
    var id: String
    var createdAt: String?
    var profile: FeedPersonSummary?

    private enum CodingKeys: String, CodingKey {
        case type, id, profile
        case createdAt = "created_at"
    }
}

private struct FeedBlocksResponse: Decodable {
    var blocks = [FeedBlockEntry]()

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocks = try c.decodeIfPresent([FeedBlockEntry].self, forKey: .blocks) ?? []
    }

    private enum CodingKeys: String, CodingKey { case blocks }
}

/// `GET /v1/feed/me/close-people`（第三节第 42 条）：我设的人，和设了我的人。
struct FeedClosePeopleResponse: Decodable, Equatable {
    var mine = [FeedClosePersonEntry]()
    var requests = [FeedClosePersonEntry]()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mine = try c.decodeIfPresent([FeedClosePersonEntry].self, forKey: .mine) ?? []
        requests = try c.decodeIfPresent([FeedClosePersonEntry].self, forKey: .requests) ?? []
    }

    private enum CodingKeys: String, CodingKey { case mine, requests }
}

struct FeedClosePersonEntry: Decodable, Equatable {
    var id: String
    var displayName: String
    var avatarKey: String?
    var state = FeedClosePersonEntry.statePending

    static let statePending = "pending"
    static let stateAccepted = "accepted"
    /// 最多设 3 个（含待同意）。
    static let max = 3

    var accepted: Bool { state == Self.stateAccepted }

    init(id: String, displayName: String, avatarKey: String? = nil, state: String = FeedClosePersonEntry.statePending) {
        self.id = id
        self.displayName = displayName
        self.avatarKey = avatarKey
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        avatarKey = try c.decodeIfPresent(String.self, forKey: .avatarKey)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? Self.statePending
    }

    private enum CodingKeys: String, CodingKey {
        case id, state
        case displayName = "display_name"
        case avatarKey = "avatar_key"
    }
}

private struct FeedClosePersonState: Decodable {
    var state = FeedClosePersonEntry.statePending

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? FeedClosePersonEntry.statePending
    }

    private enum CodingKeys: String, CodingKey { case state }
}

private struct FeedClosePersonAnswer: Encodable {
    var accept: Bool
}

extension FeedAPI {
    static let targetAuthor = "author"
    static let hideMute = "mute"
    static let hideFrom = "hide_from"
    static let notFound = "not_found"

    /// 自己的公开主页；没建过时引擎回 404 `profile_required`，这里给 nil。
    func myProfile() async throws -> FeedMyProfile? {
        do {
            return try await send(FeedMyProfile.self, request(path: ["v1", "feed", "me", "profile"]))
        } catch let error as FeedAPIError where error.status == 404 && error.code == "profile_required" {
            return nil
        }
    }

    /// 建或改公开主页。400 `invalid_field` / `display_name_required`。
    func saveProfile(_ update: FeedProfileUpdate) async throws -> FeedMyProfile {
        let body = try Self.encoder.encode(update)
        return try await send(FeedMyProfile.self, request(path: ["v1", "feed", "me", "profile"], method: "PUT", body: body))
    }

    /// 一个公开主页。看不到（删了、互相屏蔽、未成年人对非好友）时引擎回 404 `not_found`，这里给 nil。
    func profile(profileId: String) async throws -> FeedProfilePage? {
        do {
            return try await send(FeedProfilePage.self, request(path: ["v1", "feed", "profiles", profileId]))
        } catch let error as FeedAPIError where error.status == 404 && error.code == Self.notFound {
            return nil
        }
    }

    /// 主页上的帖子，新的在前，一页 20 条。看不到这个主页时 404 `not_found`。
    func profilePosts(profileId: String, cursor: String?) async throws -> FeedProfilePostsResponse {
        let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        return try await send(FeedProfilePostsResponse.self, request(path: ["v1", "feed", "profiles", profileId, "posts"], query: query))
    }

    /// 关注 / 取消关注（`type` 是 `author`、`topic` 或 `source`），返回新的状态：私密账号对非好友是 `pending`，取消后是 `none`。
    /// 关注人之前要先有公开主页（409 `profile_required`）；看不到的人 404 `not_found`。
    func follow(type: String, id: String, on: Bool) async throws -> String {
        return try await send(FeedFollowResponse.self, request(path: ["v1", "feed", "follow", type, id], method: on ? "PUT" : "DELETE")).state
    }

    /// 在动态里屏蔽 / 取消屏蔽（204）。屏蔽作者会把双方的关注一起删掉。不能屏蔽自己（400 `invalid_target`）。
    func block(type: String, id: String, on: Bool) async throws {
        try await sendNoContent(request(path: ["v1", "feed", "blocks", type, id], method: on ? "PUT" : "DELETE"))
    }

    func followRequests() async throws -> [FeedFollowRequest] {
        return try await send(FeedFollowRequestsResponse.self, request(path: ["v1", "feed", "me", "follow-requests"])).requests
    }

    /// 同意或拒绝一条关注请求（204）。对方已经撤回时 404。
    func answerFollowRequest(profileId: String, approve: Bool) async throws {
        let body = try Self.encoder.encode(FeedFollowRequestDecision(approve: approve))
        try await sendNoContent(request(path: ["v1", "feed", "me", "follow-requests", profileId], method: "POST", body: body))
    }

    func blocks() async throws -> [FeedBlockEntry] {
        return try await send(FeedBlocksResponse.self, request(path: ["v1", "feed", "me", "blocks"])).blocks
    }

    func hideLists() async throws -> FeedHideLists {
        return try await send(FeedHideLists.self, request(path: ["v1", "feed", "me", "hide-lists"]))
    }

    /// 加进或移出 `list`（`mute` / `hide_from`）→ 204，可以重复调。没有主页 409 `profile_required`；自己、互相屏蔽的人 404。
    /// 不认识的名单名：Android `require` 失败（抛异常）；这里抛 400 风格的 `FeedAPIError`，不崩。
    func setHideList(list: String, profileId: String, on: Bool) async throws {
        guard list == Self.hideMute || list == Self.hideFrom else {
            throw FeedAPIError(status: 400, code: "unknown_hide_list", retryAfterSeconds: nil)
        }
        try await sendNoContent(request(path: ["v1", "feed", "me", "hide-lists", list, profileId], method: on ? "PUT" : "DELETE"))
    }

    /// 关心的人：我设的和设了我的。
    func closePeople() async throws -> FeedClosePeopleResponse {
        return try await send(FeedClosePeopleResponse.self, request(path: ["v1", "feed", "me", "close-people"]))
    }

    /// 设一个人，对方同意前是 `pending`。满 3 个 409 `close_people_full`；不能设的人 404。
    func addClosePerson(profileId: String) async throws -> String {
        return try await send(FeedClosePersonState.self, request(path: ["v1", "feed", "me", "close-people", profileId], method: "PUT")).state
    }

    func removeClosePerson(profileId: String) async throws {
        try await sendNoContent(request(path: ["v1", "feed", "me", "close-people", profileId], method: "DELETE"))
    }

    /// 回应设了我的人：同意，或者拒绝（同意过的也能这样撤回）。
    func answerClosePerson(ownerProfileId: String, accept: Bool) async throws {
        let body = try Self.encoder.encode(FeedClosePersonAnswer(accept: accept))
        try await sendNoContent(request(path: ["v1", "feed", "me", "close-people", "requests", ownerProfileId], method: "POST", body: body))
    }
}
