//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 动态页取数据的地方。界面只认这个协议，不管背后是内容引擎还是本机样例。和 Android `FeedSource` 同一组方法。
protocol FeedSource: AnyObject {
    func config() async throws -> FeedConfig
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage
    func setLiked(contentId: String, liked: Bool) async throws
    func notInterested(contentId: String) async throws
    func undoNotInterested(contentId: String) async throws

    /// 发一条。`clientNonce` 每条草稿一个，重试时不变（引擎按它去重，契约 7.2）。
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse

    /// 日志类事件（曝光等），一批最多 `FeedAPI.maxEvents` 条（契约 6.1）。
    func reportEvents(_ events: [FeedEventPayload]) async throws

    // I-3：卡片上的几个动作。有默认实现（抛 `feedNotAvailable`），所以已有的测试替身不用改。

    /// 以假名上报收藏 / 取消收藏（第三节第 27 条）；真正的「存进我的收藏」是 `FeedSavedMessages`。
    func setSaved(contentId: String, saved: Bool) async throws
    /// 转发到动态 / 取消（第 26 条）。
    func setReposted(contentId: String, reposted: Bool) async throws
    /// 投票，回票数和我的选择。
    func vote(contentId: String, options: [Int]) async throws -> FeedPollState
    func updatePostSettings(contentId: String, update: FeedPostSettingsUpdate) async throws
    func postSettings(contentId: String) async throws -> FeedPostSettings
    func postInsights(contentId: String) async throws -> FeedPostInsights

    // I-4：详情页和评论。同样有默认实现。

    /// 最新的一张卡片（Card API）；删了 / 看不到了是 nil。
    func card(contentId: String) async throws -> FeedCard?
    func comments(postId: String, cursor: String?) async throws -> FeedCommentsPage
    /// 发文字评论，回发布状态（`pending` / `published`）。
    func postComment(postId: String, text: String, parentId: String?) async throws -> String
    /// 发语音评论：先把 `.m4a` 传上去（tus），再带 `media_keys` 发评论。
    func postVoiceComment(postId: String, audio: Data, parentId: String?) async throws -> String
    func approveComment(postId: String, commentId: String) async throws
    /// 删自己的帖子 / 评论。
    func deletePost(contentId: String) async throws

    // I-10：举报。有默认实现。

    /// 传一张图（举报截图用）：转成 JPEG（去 EXIF）后 tus 上传，回 media key。
    func uploadImage(_ image: UIImage) async throws -> String
    func report(_ request: FeedReportRequest) async throws

    // I-9：动态设置（推荐偏好、兴趣标签、「少推荐」关键词）。有默认实现。

    func preferences() async throws -> FeedPreferences
    func savePreferences(_ update: FeedPreferencesUpdate) async throws -> FeedPreferences
    func interests() async throws -> FeedInterests
    func deleteInterest(dimension: String, key: String) async throws
    func resetInterests() async throws
    func keywords() async throws -> [FeedServerKeyword]
    func putKeyword(_ keyword: String, days: Int) async throws
    func deleteKeyword(_ keyword: String) async throws

    // I-5：公开主页、关注 / 屏蔽、名单、关心的人。有默认实现。

    /// 自己的公开主页；还没建是 nil（发帖、评论、关注前要先建，引擎回 409 `profile_required`）。
    func myProfile() async throws -> FeedMyProfile?
    func saveProfile(_ update: FeedProfileUpdate) async throws -> FeedMyProfile
    /// 别人的主页；看不到（删了、互相屏蔽、未成年人对非好友）是 nil。
    func profile(profileId: String) async throws -> FeedProfilePage?
    func profilePosts(profileId: String, cursor: String?) async throws -> FeedProfilePostsPage
    /// 回新的关注状态（`none` / `pending` / `approved`）。
    func setFollowing(profileId: String, following: Bool) async throws -> String
    func setBlocked(profileId: String, blocked: Bool) async throws
    func followRequests() async throws -> [FeedFollowRequest]
    func answerFollowRequest(profileId: String, approve: Bool) async throws
    func blocks() async throws -> [FeedBlockEntry]
    /// 从屏蔽名单里取消一项（作者、来源或话题）。
    func unblock(_ entry: FeedBlockEntry) async throws
    func hideLists() async throws -> FeedHideLists
    func setHideList(list: String, profileId: String, on: Bool) async throws
    func closePeople() async throws -> FeedClosePeopleResponse
    func addClosePerson(profileId: String) async throws -> String
    func removeClosePerson(profileId: String) async throws
    func answerClosePerson(ownerProfileId: String, accept: Bool) async throws

    // I-6：我的动态（审核状态）、编辑、申诉。有默认实现。

    func myPosts(before: String?) async throws -> FeedMyPostsPage
    /// 发布后 15 分钟内改正文 / 标题（`FeedDraft.toEditRequest`）；回新的发布状态。
    func editPost(contentId: String, draft: FeedDraft) async throws -> FeedCreatePostResponse
    func appeal(contentId: String, text: String) async throws

    // I-7：通知和通知设置。有默认实现。

    func notifications(tab: String, before: String?) async throws -> FeedNotificationsResponse
    func markNotificationsRead(tab: String) async throws
    func deleteNotification(id: String) async throws
    func muteNotifications(contentId: String, likesOnly: Bool) async throws
    func notificationSettings() async throws -> FeedNotificationSettings
    func saveNotificationSettings(_ settings: FeedNotificationSettings) async throws -> FeedNotificationSettings

    // I-8：搜索、话题页、关注的话题。有默认实现。

    func search(query: String, scope: String, cursor: String?) async throws -> FeedSearchPage
    func followedTopics() async throws -> [String]
    func topicPosts(slug: String, cursor: String?) async throws -> FeedTopicPage
    func setFollowingTopic(slug: String, following: Bool) async throws

    // I-11：好友声明交给引擎。有默认实现。

    /// 把 Signal-Server 签的好友声明原样交给引擎；两边都报了才 `true`。
    func reportFriend(assertion: String) async throws -> Bool
}

extension FeedSource {
    func setSaved(contentId: String, saved: Bool) async throws { throw FeedPublishError.feedNotAvailable }
    func setReposted(contentId: String, reposted: Bool) async throws { throw FeedPublishError.feedNotAvailable }
    func vote(contentId: String, options: [Int]) async throws -> FeedPollState { throw FeedPublishError.feedNotAvailable }
    func updatePostSettings(contentId: String, update: FeedPostSettingsUpdate) async throws { throw FeedPublishError.feedNotAvailable }
    func postSettings(contentId: String) async throws -> FeedPostSettings { throw FeedPublishError.feedNotAvailable }
    func postInsights(contentId: String) async throws -> FeedPostInsights { throw FeedPublishError.feedNotAvailable }

    func card(contentId: String) async throws -> FeedCard? { nil }
    func comments(postId: String, cursor: String?) async throws -> FeedCommentsPage { FeedCommentsPage() }
    func postComment(postId: String, text: String, parentId: String?) async throws -> String { throw FeedPublishError.feedNotAvailable }
    func postVoiceComment(postId: String, audio: Data, parentId: String?) async throws -> String { throw FeedPublishError.feedNotAvailable }
    func approveComment(postId: String, commentId: String) async throws { throw FeedPublishError.feedNotAvailable }
    func deletePost(contentId: String) async throws { throw FeedPublishError.feedNotAvailable }

    func uploadImage(_ image: UIImage) async throws -> String { throw FeedPublishError.feedNotAvailable }
    func report(_ request: FeedReportRequest) async throws { throw FeedPublishError.feedNotAvailable }

    func preferences() async throws -> FeedPreferences { throw FeedPublishError.feedNotAvailable }
    func savePreferences(_ update: FeedPreferencesUpdate) async throws -> FeedPreferences { throw FeedPublishError.feedNotAvailable }
    func interests() async throws -> FeedInterests { throw FeedPublishError.feedNotAvailable }
    func deleteInterest(dimension: String, key: String) async throws { throw FeedPublishError.feedNotAvailable }
    func resetInterests() async throws { throw FeedPublishError.feedNotAvailable }
    func keywords() async throws -> [FeedServerKeyword] { throw FeedPublishError.feedNotAvailable }
    func putKeyword(_ keyword: String, days: Int) async throws { throw FeedPublishError.feedNotAvailable }
    func deleteKeyword(_ keyword: String) async throws { throw FeedPublishError.feedNotAvailable }

    func myProfile() async throws -> FeedMyProfile? { nil }
    func saveProfile(_ update: FeedProfileUpdate) async throws -> FeedMyProfile { throw FeedPublishError.feedNotAvailable }
    func profile(profileId: String) async throws -> FeedProfilePage? { nil }
    func profilePosts(profileId: String, cursor: String?) async throws -> FeedProfilePostsPage { FeedProfilePostsPage() }
    func setFollowing(profileId: String, following: Bool) async throws -> String { throw FeedPublishError.feedNotAvailable }
    func setBlocked(profileId: String, blocked: Bool) async throws { throw FeedPublishError.feedNotAvailable }
    func followRequests() async throws -> [FeedFollowRequest] { [] }
    func answerFollowRequest(profileId: String, approve: Bool) async throws { throw FeedPublishError.feedNotAvailable }
    func blocks() async throws -> [FeedBlockEntry] { [] }
    func unblock(_ entry: FeedBlockEntry) async throws {
        guard entry.type == FeedAPI.targetAuthor else { throw FeedPublishError.feedNotAvailable }
        try await setBlocked(profileId: entry.id, blocked: false)
    }
    func hideLists() async throws -> FeedHideLists { throw FeedPublishError.feedNotAvailable }
    func setHideList(list: String, profileId: String, on: Bool) async throws { throw FeedPublishError.feedNotAvailable }
    func closePeople() async throws -> FeedClosePeopleResponse { throw FeedPublishError.feedNotAvailable }
    func addClosePerson(profileId: String) async throws -> String { throw FeedPublishError.feedNotAvailable }
    func removeClosePerson(profileId: String) async throws { throw FeedPublishError.feedNotAvailable }
    func answerClosePerson(ownerProfileId: String, accept: Bool) async throws { throw FeedPublishError.feedNotAvailable }

    func myPosts(before: String?) async throws -> FeedMyPostsPage { FeedMyPostsPage() }
    func editPost(contentId: String, draft: FeedDraft) async throws -> FeedCreatePostResponse { throw FeedPublishError.feedNotAvailable }
    func appeal(contentId: String, text: String) async throws { throw FeedPublishError.feedNotAvailable }

    func notifications(tab: String, before: String?) async throws -> FeedNotificationsResponse { FeedNotificationsResponse() }
    func markNotificationsRead(tab: String) async throws {}
    func deleteNotification(id: String) async throws { throw FeedPublishError.feedNotAvailable }
    func muteNotifications(contentId: String, likesOnly: Bool) async throws { throw FeedPublishError.feedNotAvailable }
    func notificationSettings() async throws -> FeedNotificationSettings { throw FeedPublishError.feedNotAvailable }
    func saveNotificationSettings(_ settings: FeedNotificationSettings) async throws -> FeedNotificationSettings { throw FeedPublishError.feedNotAvailable }

    func search(query: String, scope: String, cursor: String?) async throws -> FeedSearchPage { FeedSearchPage() }
    func followedTopics() async throws -> [String] { [] }
    func topicPosts(slug: String, cursor: String?) async throws -> FeedTopicPage { FeedTopicPage() }
    func setFollowingTopic(slug: String, following: Bool) async throws { throw FeedPublishError.feedNotAvailable }

    func reportFriend(assertion: String) async throws -> Bool { throw FeedPublishError.feedNotAvailable }
}

/// 发不出去：图片的 tus 上传（I-2）还没做，所以带图的帖子不发；或者没有可用的内容引擎。
enum FeedPublishError: Error {
    case mediaUploadNotAvailable
    case feedNotAvailable
}

/// 内容引擎。列表只给 id，这里再用 Card API 换成卡片（一次最多 `FeedAPI.maxCardIds` 个），
/// 不可用的卡片（删了、被屏蔽、没权限看，引擎不说是哪种）直接跳过。
final class RemoteFeedSource: FeedSource {
    /// 推荐「还有下一页」的标记，不发给服务端。
    static let recommendMore = "more"

    private let api: FeedAPI
    /// 把选中的图编码成要上传的 JPEG；没有就不能发带图的帖子（`mediaUploadNotAvailable`，和 I-2 之前一样）。
    private let imageEncoder: FeedImageEncoding?
    private let uploads = FeedUploadMemo()
    /// 「部分可见 / 不给谁看」的名单找 Signal-Server 签；没有就不能发这两档（`feedNotAvailable`）。
    private let audienceSigner: FeedFriendSigning?

    init(api: FeedAPI, imageEncoder: FeedImageEncoding? = nil, audienceSigner: FeedFriendSigning? = nil) {
        self.api = api
        self.imageEncoder = imageEncoder
        self.audienceSigner = audienceSigner
    }

    /// 能不能看（`GET /v1/feed/status`）。`FeedEntryCheck` 用它；引擎回 404 `feed_hidden` 时抛 `FeedAPIError`（`isFeedHidden`）。
    func isVisible() async throws -> Bool {
        return try await api.status().visible
    }

    /// `GET /v1/feed/config`（契约 3.2）。和 Android `RemoteFeedSource.config()` 一样直接用引擎给的：
    /// 图片主机（`media_base_url`）、卡片有效期、推荐模式、`ip_region_visible`、举报原因都在里面，`status` 里没有。
    /// （原来只调 `status` 再拼一份默认值，上面这些永远是默认的。）
    func config() async throws -> FeedConfig {
        return try await api.config()
    }

    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage {
        switch tab {
        case .following:
            let page = try await api.feed(tabApiName: tab.apiName, cursor: cursor)
            return FeedTimelinePage(cards: try await hydrate(page.items), nextCursor: page.cursor)
        case .recommend:
            // 推荐没有 cursor：每次给新的一页（看过的引擎记了曝光），给空了才算到底（契约 4.1）
            let page = try await api.feed(tabApiName: tab.apiName, cursor: nil)
            return FeedTimelinePage(cards: try await hydrate(page.items), nextCursor: page.items.isEmpty ? nil : Self.recommendMore)
        }
    }

    func setLiked(contentId: String, liked: Bool) async throws {
        try await api.setReaction(contentId: contentId, reaction: .like, on: liked)
    }

    func setSaved(contentId: String, saved: Bool) async throws {
        try await api.setReaction(contentId: contentId, reaction: .save, on: saved)
    }

    func setReposted(contentId: String, reposted: Bool) async throws {
        try await api.setRepost(contentId: contentId, on: reposted)
    }

    func vote(contentId: String, options: [Int]) async throws -> FeedPollState {
        return try await api.vote(contentId: contentId, options: options)
    }

    func updatePostSettings(contentId: String, update: FeedPostSettingsUpdate) async throws {
        try await api.updatePostSettings(contentId: contentId, update: update)
    }

    func postSettings(contentId: String) async throws -> FeedPostSettings {
        return try await api.postSettings(contentId: contentId)
    }

    func postInsights(contentId: String) async throws -> FeedPostInsights {
        return try await api.postInsights(contentId: contentId)
    }

    func card(contentId: String) async throws -> FeedCard? {
        return try await api.cards(ids: [contentId]).cards.first?.toCard()
    }

    func comments(postId: String, cursor: String?) async throws -> FeedCommentsPage {
        let response = try await api.comments(postId: postId, cursor: cursor)
        return FeedCommentsPage(comments: response.comments.compactMap { $0.toCard() }, cursor: response.cursor)
    }

    func postComment(postId: String, text: String, parentId: String?) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await api.createComment(postId: postId, request: FeedCreateCommentRequest(text: trimmed, parentId: parentId)).state
    }

    func postVoiceComment(postId: String, audio: Data, parentId: String?) async throws -> String {
        let key = try await FeedImageUploader(api: api).upload(audio)
        return try await api.createComment(postId: postId, request: FeedCreateCommentRequest(text: "", parentId: parentId, mediaKeys: [key])).state
    }

    func approveComment(postId: String, commentId: String) async throws {
        try await api.approveComment(postId: postId, commentId: commentId)
    }

    func deletePost(contentId: String) async throws {
        try await api.deletePost(contentId: contentId)
    }

    /// I-11：把 Signal-Server 签的好友声明交给这个引擎（`POST /v1/feed/friends`）。两边都报了才 `confirmed`。
    func reportFriendAssertion(_ assertion: String) async throws {
        _ = try await api.reportFriend(assertion: assertion)
    }

    func uploadImage(_ image: UIImage) async throws -> String {
        guard let imageEncoder else { throw FeedPublishError.mediaUploadNotAvailable }
        return try await FeedImageUploader(api: api).upload(try await imageEncoder.jpegData(for: image))
    }

    func report(_ request: FeedReportRequest) async throws {
        try await api.report(request)
    }

    func preferences() async throws -> FeedPreferences { try await api.preferences() }
    func savePreferences(_ update: FeedPreferencesUpdate) async throws -> FeedPreferences { try await api.putPreferences(update) }
    func interests() async throws -> FeedInterests { try await api.interests() }
    func deleteInterest(dimension: String, key: String) async throws { try await api.deleteInterest(dimension: dimension, key: key) }
    func resetInterests() async throws { try await api.resetInterests() }
    func keywords() async throws -> [FeedServerKeyword] { try await api.keywords() }
    func putKeyword(_ keyword: String, days: Int) async throws { try await api.putKeyword(keyword, days: days) }
    func deleteKeyword(_ keyword: String) async throws { try await api.deleteKeyword(keyword) }

    func myProfile() async throws -> FeedMyProfile? { try await api.myProfile() }
    func saveProfile(_ update: FeedProfileUpdate) async throws -> FeedMyProfile { try await api.saveProfile(update) }
    func profile(profileId: String) async throws -> FeedProfilePage? { try await api.profile(profileId: profileId) }
    func profilePosts(profileId: String, cursor: String?) async throws -> FeedProfilePostsPage {
        let response = try await api.profilePosts(profileId: profileId, cursor: cursor)
        return FeedProfilePostsPage(posts: response.posts.compactMap { $0.toCard() }, cursor: response.cursor)
    }
    func setFollowing(profileId: String, following: Bool) async throws -> String { try await api.follow(type: FeedAPI.targetAuthor, id: profileId, on: following) }
    func setBlocked(profileId: String, blocked: Bool) async throws { try await api.block(type: FeedAPI.targetAuthor, id: profileId, on: blocked) }
    func followRequests() async throws -> [FeedFollowRequest] { try await api.followRequests() }
    func answerFollowRequest(profileId: String, approve: Bool) async throws { try await api.answerFollowRequest(profileId: profileId, approve: approve) }
    func blocks() async throws -> [FeedBlockEntry] { try await api.blocks() }
    func unblock(_ entry: FeedBlockEntry) async throws { try await api.block(type: entry.type, id: entry.id, on: false) }
    func hideLists() async throws -> FeedHideLists { try await api.hideLists() }
    func setHideList(list: String, profileId: String, on: Bool) async throws { try await api.setHideList(list: list, profileId: profileId, on: on) }
    func closePeople() async throws -> FeedClosePeopleResponse { try await api.closePeople() }
    func addClosePerson(profileId: String) async throws -> String { try await api.addClosePerson(profileId: profileId) }
    func removeClosePerson(profileId: String) async throws { try await api.removeClosePerson(profileId: profileId) }
    func answerClosePerson(ownerProfileId: String, accept: Bool) async throws { try await api.answerClosePerson(ownerProfileId: ownerProfileId, accept: accept) }

    func myPosts(before: String?) async throws -> FeedMyPostsPage { try await api.myPosts(before: before) }
    func editPost(contentId: String, draft: FeedDraft) async throws -> FeedCreatePostResponse {
        try await api.editPost(contentId: contentId, request: draft.toEditRequest())
    }
    func appeal(contentId: String, text: String) async throws {
        try await api.appeal(contentId: contentId, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func notifications(tab: String, before: String?) async throws -> FeedNotificationsResponse { try await api.notifications(tab: tab, before: before) }
    func markNotificationsRead(tab: String) async throws { try await api.markNotificationsRead(tab: tab) }
    func deleteNotification(id: String) async throws { try await api.deleteNotification(id: id) }
    func muteNotifications(contentId: String, likesOnly: Bool) async throws { try await api.muteNotifications(contentId: contentId, likesOnly: likesOnly) }
    func notificationSettings() async throws -> FeedNotificationSettings { try await api.notificationSettings() }
    func saveNotificationSettings(_ settings: FeedNotificationSettings) async throws -> FeedNotificationSettings { try await api.putNotificationSettings(settings) }

    func search(query: String, scope: String, cursor: String?) async throws -> FeedSearchPage {
        let response = try await api.search(query: query, scope: scope, cursor: cursor)
        return FeedSearchPage(users: response.users, posts: try await hydrate(response.items), cursor: response.cursor)
    }
    func followedTopics() async throws -> [String] { try await api.followedTopics().topics.map(\.slug) }
    func topicPosts(slug: String, cursor: String?) async throws -> FeedTopicPage {
        let response = try await api.topicPosts(slug: slug, cursor: cursor)
        return FeedTopicPage(posts: try await hydrate(response.items), cursor: response.cursor, following: response.following)
    }
    func setFollowingTopic(slug: String, following: Bool) async throws {
        _ = try await api.follow(type: FeedAPI.targetTopic, id: slug, on: following)
    }

    func reportFriend(assertion: String) async throws -> Bool { try await api.reportFriend(assertion: assertion) }

    func notInterested(contentId: String) async throws {
        try await api.notInterested(contentId: contentId, reason: nil)
    }

    func undoNotInterested(contentId: String) async throws {
        try await api.undoNotInterested(contentId: contentId)
    }

    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        // 引擎收 client_nonce 和 media_keys（契约 7.1 / 7.2）：带上 client_nonce，重试不会多出一条；
        // 图片先一张张 tus 上传（和 Android `RemoteFeedSource.publish` 同一个顺序），key 按图片顺序放进 media_keys。
        var mediaKeys = [String]()
        let images = draft.attachedImages
        if !images.isEmpty {
            guard let imageEncoder else {
                throw FeedPublishError.mediaUploadNotAvailable
            }
            for image in images {
                mediaKeys.append(try await uploadOnce(clientNonce: clientNonce, image: image, encoder: imageEncoder))
            }
        }
        var audienceToken: String?
        if draft.visibility.needsAudience {
            guard let audienceSigner else { throw FeedPublishError.feedNotAvailable }
            // 名单里同一个人只交一次（顺序不变）
            var seen = Set<String>()
            let acis = draft.audience.map(\.aci).filter { seen.insert($0).inserted }
            audienceToken = try await audienceSigner.audienceToken(kind: draft.visibility.apiName, peerAcis: acis)
        }
        let response = try await api.createPost(draft.makeRequest(clientNonce: clientNonce, mediaKeys: mediaKeys, audienceToken: audienceToken))
        await uploads.forget(clientNonce: clientNonce)
        return response
    }

    /// 已经传好的图：同一条草稿重试时不再传一遍（引擎的 key 没用在帖子上之前一直能用，一天后清掉）。发成功后清掉。
    private func uploadOnce(clientNonce: String, image: FeedDraftImage, encoder: FeedImageEncoding) async throws -> String {
        if let key = await uploads.key(clientNonce: clientNonce, imageId: image.id) {
            return key
        }
        let bytes = try await encoder.jpegData(for: image.image)
        let key = try await FeedImageUploader(api: api).upload(bytes)
        await uploads.set(key, clientNonce: clientNonce, imageId: image.id)
        return key
    }

    func reportEvents(_ events: [FeedEventPayload]) async throws {
        try await api.events(events)
    }

    private func hydrate(_ items: [FeedItemRef]) async throws -> [FeedCard] {
        var ids = [String]()
        for item in items where !ids.contains(item.id) {
            ids.append(item.id)
        }
        var cards = [FeedCard]()
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + FeedAPI.maxCardIds, ids.count)])
            let response = try await api.cards(ids: chunk)
            let byId = Dictionary(response.cards.compactMap { result in result.toCard().map { (result.id, $0) } }, uniquingKeysWith: { first, _ in first })
            // 按列表给的顺序，不按 Card API 返回的顺序
            cards += chunk.compactMap { byId[$0] }
            start += FeedAPI.maxCardIds
        }
        return Self.markingReposts(cards, items: items)
    }

    /// 关注流里因为有人转发才出现的（`reason == "repost"`，带 `reposted_by` = 转发人的 profile id）：卡片顶上写「谁 转发了」。
    /// 名字要按人取公开主页（Android `repostersFor`），iOS 的主页接口是 I-5，在那之前 `displayName` 是 nil，界面只写「转发」
    /// （`FeedRepostedBy` 本来就允许取不到名字）。
    static func markingReposts(_ cards: [FeedCard], items: [FeedItemRef]) -> [FeedCard] {
        let reposters = items.reduce(into: [String: String]()) { result, item in
            if item.reason == repostReason, let profileId = item.repostedBy, result[item.id] == nil {
                result[item.id] = profileId
            }
        }
        guard !reposters.isEmpty else { return cards }
        return cards.map { card in
            guard let profileId = reposters[card.id] else { return card }
            var marked = card
            marked.repostedBy = FeedRepostedBy(profileId: profileId, displayName: nil)
            return marked
        }
    }

    static let repostReason = "repost"
}

/// 一条草稿（`clientNonce`）里已经上传好的图的 media key。
private actor FeedUploadMemo {
    private var keys = [String: String]()

    func key(clientNonce: String, imageId: String) -> String? {
        return keys["\(clientNonce) \(imageId)"]
    }

    func set(_ key: String, clientNonce: String, imageId: String) {
        keys["\(clientNonce) \(imageId)"] = key
    }

    func forget(clientNonce: String) {
        keys = keys.filter { !$0.key.hasPrefix("\(clientNonce) ") }
    }
}

/// 没有可用的内容引擎时用的空来源：配置是「关」，信息流是空的。
///
/// 只在内容引擎的主机不可用时用（RegionProfile 的 `feed` 不是 https 地址）。
final class EmptyFeedSource: FeedSource {
    static let shared = EmptyFeedSource()

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    // Android `EmptyFeedSource`：收藏 / 转发上报什么都不做，其余（投票、设置、数据）抛错
    func setSaved(contentId: String, saved: Bool) async throws {}
    func setReposted(contentId: String, reposted: Bool) async throws {}
    func deletePost(contentId: String) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        throw FeedPublishError.feedNotAvailable
    }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
}

enum FeedSources {
    /// 内部用户强制打开动态标签、并且没关掉「Feed sample data」时用本机样例（`SampleFeedSource`），不发任何网络请求；
    /// 其余情况连当前区的内容引擎（RegionProfile 的 `feed`），凭证从 Signal-Server 取。
    static func current() -> FeedSource {
        return TellomiFeed.isSampleDataEnabled ? SampleFeedSource.shared : engine()
    }

    /// 当前区的内容引擎（不看样例开关；`FeedEntryCheck` 用它问 `status`）。
    /// 每个区一份：切区后 `TellomiRegions.active()` 换了，下次取到的是新区的主机和新的凭证缓存（token 里带着区）。
    static func engine() -> FeedSource {
        let region = TellomiRegions.active()
        guard let baseURL = URL(string: region.feed), baseURL.scheme == "https" else {
            return EmptyFeedSource.shared
        }
        let key = "\(region.id.rawValue) \(region.feed)"
        engineLock.lock()
        defer { engineLock.unlock() }
        if let cached = engineCache, cached.key == key {
            return cached.source
        }
        let tokens = CachingFeedTokenSource(fetcher: SignalServerFeedAuthFetcher())
        let source = RemoteFeedSource(api: FeedAPI(baseURL: baseURL, tokens: tokens), imageEncoder: FeedImageEncoder(), audienceSigner: SignalServerFeedSigner())
        engineCache = (key, source)
        return source
    }

    // 部署目标是 iOS 15，不能用 OSAllocatedUnfairLock（iOS 16）；用 NSLock。
    private static let engineLock = NSLock()
    private static var engineCache: (key: String, source: FeedSource)?
}
