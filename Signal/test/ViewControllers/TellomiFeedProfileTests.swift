//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedProfileTests.swift (new file)
// I-5: profile / relations models and API wire shapes, FeedProfilePageStore.
// Mirrors Android FeedProfilePageViewModelTest.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

private struct Boom: Error {}

private final class CallLog<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [T]()
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - models

final class TellomiFeedProfileModelTests: XCTestCase {
    private func decode(_ json: String) throws -> FeedProfilePage {
        try JSONDecoder().decode(FeedProfilePage.self, from: Data(json.utf8))
    }

    func testProfilePageDecodesEngineJsonAndFillsDefaults() throws {
        let page = try decode("""
        {"id":"p1","handle":"ann","display_name":"Ann","avatar_key":"a/1","bio":"hi","shown_interests":["tech"],
         "is_private":true,"ip_region_label":"重庆","followers":12,"following":3,"region_unavailable":false,
         "me":{"self":false,"follow":"pending","followed_by":true,"friend":false,"blocked":false,"muted":true,"hidden_from":true},
         "close_people":[{"id":"c1","display_name":"Bob"}]}
        """)
        XCTAssertEqual(page.displayName, "Ann")
        XCTAssertEqual(page.followers, 12)
        XCTAssertTrue(page.isPrivate)
        XCTAssertEqual(page.me.follow, "pending")
        XCTAssertTrue(page.me.followedBy)
        XCTAssertTrue(page.me.muted)
        XCTAssertTrue(page.me.hiddenFrom)
        XCTAssertEqual(page.closePeople, [FeedClosePerson(id: "c1", displayName: "Bob", avatarKey: nil)])

        let minimal = try decode(#"{"id":"p2","display_name":"Zed"}"#)
        XCTAssertEqual(minimal.me, FeedRelation())
        XCTAssertEqual(minimal.me.follow, "none")
        XCTAssertFalse(minimal.isPrivate)
        XCTAssertEqual(minimal.followers, 0)
        XCTAssertTrue(minimal.canSeePosts)
    }

    func testCanSeePostsOfAPrivateAccountOnlyForSelfFriendOrApprovedFollower() {
        var page = FeedProfilePage(id: "p", displayName: "P")
        page.isPrivate = true
        XCTAssertFalse(page.canSeePosts)
        page.me.follow = FeedRelation.followPending
        XCTAssertFalse(page.canSeePosts, "请求中还不能看")
        page.me.follow = FeedRelation.followApproved
        XCTAssertTrue(page.canSeePosts)
        page.me.follow = FeedRelation.followNone
        page.me.friend = true
        XCTAssertTrue(page.canSeePosts)
        page.me.friend = false
        page.me.isSelf = true
        XCTAssertTrue(page.canSeePosts)
    }

    func testShowsPostsNeedsVisibilityNoBlockAndSameRegion() {
        var page = FeedProfilePage(id: "p", displayName: "P")
        XCTAssertTrue(page.showsPosts)
        page.me.blocked = true
        XCTAssertFalse(page.showsPosts)
        page.me.blocked = false
        page.regionUnavailable = true
        XCTAssertFalse(page.showsPosts)
    }

    func testWithFollowMovesFollowersOnlyWhenEnteringOrLeavingApproved() {
        var page = FeedProfilePage(id: "p", displayName: "P")
        page.followers = 5
        let pending = page.withFollow("pending")
        XCTAssertEqual(pending.followers, 5, "请求中不算粉丝")
        let approved = pending.withFollow("approved")
        XCTAssertEqual(approved.followers, 6)
        XCTAssertEqual(approved.withFollow("approved").followers, 6, "同一状态不再加")
        XCTAssertEqual(approved.withFollow("none").followers, 5)
        var zero = FeedProfilePage(id: "p", displayName: "P")
        zero.me.follow = "approved"
        XCTAssertEqual(zero.withFollow("none").followers, 0, "不减到负数")
    }
}

// MARK: - wire

private final class ScriptedTransport: FeedHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests = [URLRequest]()
    private var replies = [(Int, String)]()
    func reply(_ status: Int, _ body: String) { lock.lock(); replies.append((status, body)); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.locked {
            _requests.append(request)
            return replies.isEmpty ? (204, "") : replies.removeFirst()
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }
}

private struct FixedTokens: FeedTokenSource {
    func token(forceRefresh: Bool) async throws -> String { "t" }
}

final class TellomiFeedProfileApiTests: XCTestCase {
    private func make() -> (FeedAPI, ScriptedTransport) {
        let transport = ScriptedTransport()
        return (FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens()), transport)
    }

    private func body(_ request: URLRequest) -> String { String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "" }

    func testNotFoundAndProfileRequiredBecomeNil() async throws {
        let (api, transport) = make()
        transport.reply(404, #"{"error":"not_found"}"#)
        let gone = try await api.profile(profileId: "p1")
        XCTAssertNil(gone)
        transport.reply(404, #"{"error":"profile_required"}"#)
        let mine = try await api.myProfile()
        XCTAssertNil(mine)
        transport.reply(404, #"{"error":"something_else"}"#)
        do {
            _ = try await api.profile(profileId: "p1")
            XCTFail("其它 404 不能吞掉")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.code, "something_else")
        }
        transport.reply(500, "")
        do {
            _ = try await api.profile(profileId: "p1")
            XCTFail()
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 500)
        }
    }

    func testFollowAndBlockRoutesMethodsAndReplyState() async throws {
        let (api, transport) = make()
        transport.reply(200, #"{"state":"pending"}"#)
        let state = try await api.follow(type: "author", id: "p/1", on: true)
        XCTAssertEqual(state, "pending")
        transport.reply(200, "{}")
        let none = try await api.follow(type: "author", id: "p1", on: false)
        XCTAssertEqual(none, "none")
        try await api.block(type: "author", id: "p1", on: true)
        try await api.block(type: "author", id: "p1", on: false)
        let r = transport.requests
        XCTAssertEqual(r.map { $0.httpMethod }, ["PUT", "DELETE", "PUT", "DELETE"])
        XCTAssertEqual(r[0].url?.absoluteString, "https://feed.example.test/v1/feed/follow/author/p%2F1")
        XCTAssertEqual(r[2].url?.path, "/v1/feed/blocks/author/p1")
    }

    func testFollowRequestsBlocksAndHideLists() async throws {
        let (api, transport) = make()
        transport.reply(200, #"{"requests":[{"profile":{"id":"a","display_name":"A"},"requested_at":"2026-10-01T00:00:00Z"}]}"#)
        let requests = try await api.followRequests()
        XCTAssertEqual(requests, [FeedFollowRequest(profile: FeedPersonSummary(id: "a", handle: nil, displayName: "A", avatarKey: nil), requestedAt: "2026-10-01T00:00:00Z")])
        try await api.answerFollowRequest(profileId: "a", approve: false)
        transport.reply(200, #"{"blocks":[{"type":"author","id":"b","profile":{"id":"b","handle":"bob","display_name":"Bob"}},{"type":"topic","id":"spam"}]}"#)
        let blocks = try await api.blocks()
        XCTAssertEqual(blocks.map(\.type), ["author", "topic"])
        XCTAssertEqual(blocks[0].profile?.handle, "bob")
        XCTAssertNil(blocks[1].profile)
        transport.reply(200, #"{"mute":[{"id":"m","display_name":"M"}],"hide_from":[]}"#)
        let lists = try await api.hideLists()
        XCTAssertEqual(lists.mute.map(\.id), ["m"])
        XCTAssertEqual(lists.hideFrom, [])
        try await api.setHideList(list: "mute", profileId: "m", on: true)
        try await api.setHideList(list: "hide_from", profileId: "m", on: false)
        do {
            try await api.setHideList(list: "bogus", profileId: "m", on: true)
            XCTFail()
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.code, "unknown_hide_list")
        }

        let r = transport.requests
        XCTAssertEqual(r.count, 6, "bogus 名单没发请求")
        XCTAssertEqual(r[1].httpMethod, "POST")
        XCTAssertEqual(r[1].url?.path, "/v1/feed/me/follow-requests/a")
        XCTAssertEqual(body(r[1]), #"{"approve":false}"#)
        XCTAssertEqual(r[4].url?.path, "/v1/feed/me/hide-lists/mute/m")
        XCTAssertEqual(r[4].httpMethod, "PUT")
        XCTAssertEqual(r[5].url?.path, "/v1/feed/me/hide-lists/hide_from/m")
        XCTAssertEqual(r[5].httpMethod, "DELETE")
    }

    func testProfilePostsPagingAndSaveProfileBody() async throws {
        let (api, transport) = make()
        transport.reply(200, #"{"posts":[{"id":"x","state":"ok","version":1,"card":{"kind":"post","text":"A"},"pinned":true}],"cursor":"c2"}"#)
        let page = try await api.profilePosts(profileId: "p1", cursor: "c1")
        XCTAssertEqual(page.cursor, "c2")
        XCTAssertEqual(page.posts.first?.toCard()?.text, "A")
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://feed.example.test/v1/feed/profiles/p1/posts?cursor=c1")

        transport.reply(200, #"{"id":"me","display_name":"Me","is_private":true,"harassment_guard_until":"2026-10-20T00:00:00Z"}"#)
        let saved = try await api.saveProfile(FeedProfileUpdate(displayName: nil, bio: nil, isPrivate: nil, guardDays: 0))
        XCTAssertEqual(saved.guardUntil, "2026-10-20T00:00:00Z")
        XCTAssertTrue(saved.isPrivate)
        _ = try? await api.saveProfile(FeedProfileUpdate(displayName: "Me", bio: "x", isPrivate: false, guardDays: nil))
        XCTAssertEqual(body(transport.requests[1]), #"{"harassment_guard_days":0}"#, "0 也发，nil 不发")
        XCTAssertEqual(body(transport.requests[2]), #"{"bio":"x","display_name":"Me","is_private":false}"#)
        XCTAssertEqual(transport.requests[1].httpMethod, "PUT")
    }

    func testClosePeopleRoutes() async throws {
        let (api, transport) = make()
        transport.reply(200, #"{"mine":[{"id":"a","display_name":"A","state":"accepted"},{"id":"b","display_name":"B"}],"requests":[{"id":"c","display_name":"C","state":"pending"}]}"#)
        let people = try await api.closePeople()
        XCTAssertEqual(people.mine.map(\.accepted), [true, false])
        XCTAssertEqual(people.requests.map(\.id), ["c"])
        transport.reply(200, #"{"state":"pending"}"#)
        let state = try await api.addClosePerson(profileId: "z")
        XCTAssertEqual(state, "pending")
        try await api.removeClosePerson(profileId: "z")
        try await api.answerClosePerson(ownerProfileId: "c", accept: true)
        let r = transport.requests
        XCTAssertEqual(r.map { $0.httpMethod }, ["GET", "PUT", "DELETE", "POST"])
        XCTAssertEqual(r[3].url?.path, "/v1/feed/me/close-people/requests/c")
        XCTAssertEqual(body(r[3]), #"{"accept":true}"#)
    }
}

// MARK: - store

private final class ProfileSource: FeedSource {
    var profileValue: FeedProfilePage? = FeedProfilePage(id: "p1", displayName: "Ann")
    var profileError: Error?
    var pages = [String: FeedProfilePostsPage]()   // key = cursor ?? ""
    var postsError: Error?
    var followResult = "approved"
    var followError: Error?
    var blockError: Error?
    var hideError: Error?
    var likeError: Error?
    var repostError: Error?
    var settingsError: Error?
    var insightsError: Error?
    let calls = CallLog<String>()

    func config() async throws -> FeedConfig {
        var c = FeedConfig()
        c.mediaBaseUrl = "https://img.example.test/"
        c.ipRegionVisible = true
        return c
    }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {
        calls.append("like \(contentId) \(liked)")
        if let likeError { throw likeError }
    }
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func setReposted(contentId: String, reposted: Bool) async throws {
        calls.append("repost \(contentId) \(reposted)")
        if let repostError { throw repostError }
    }
    func updatePostSettings(contentId: String, update: FeedPostSettingsUpdate) async throws {
        calls.append("settings \(contentId)")
        if let settingsError { throw settingsError }
    }
    func postInsights(contentId: String) async throws -> FeedPostInsights {
        calls.append("insights \(contentId)")
        if let insightsError { throw insightsError }
        return FeedPostInsights()
    }

    func profile(profileId: String) async throws -> FeedProfilePage? {
        calls.append("profile \(profileId)")
        if let profileError { throw profileError }
        return profileValue
    }
    func profilePosts(profileId: String, cursor: String?) async throws -> FeedProfilePostsPage {
        calls.append("posts \(cursor ?? "-")")
        if let postsError { throw postsError }
        return pages[cursor ?? ""] ?? FeedProfilePostsPage()
    }
    func setFollowing(profileId: String, following: Bool) async throws -> String {
        calls.append("follow \(following)")
        if let followError { throw followError }
        return following ? followResult : "none"
    }
    func setBlocked(profileId: String, blocked: Bool) async throws {
        calls.append("block \(blocked)")
        if let blockError { throw blockError }
    }
    func setHideList(list: String, profileId: String, on: Bool) async throws {
        calls.append("hide \(list) \(on)")
        if let hideError { throw hideError }
    }
}

@MainActor
final class TellomiFeedProfilePageStoreTests: XCTestCase {
    private func card(_ id: String, mine: Bool = false) -> FeedCard {
        var c = FeedCard(id: id, kind: FeedCard.kindPost, author: FeedAuthor(profileId: "p1", displayName: "Ann"), text: "t \(id)")
        c.viewer.isAuthor = mine
        return c
    }

    private func started(_ source: ProfileSource) async -> FeedProfilePageStore {
        let store = FeedProfilePageStore(profileId: "p1", source: source)
        store.start()
        await store.waitForTasks()
        return store
    }

    private func page(followers: Int = 10, isPrivate: Bool = false, follow: String = "none", friend: Bool = false) -> FeedProfilePage {
        var p = FeedProfilePage(id: "p1", displayName: "Ann")
        p.followers = followers
        p.isPrivate = isPrivate
        p.me.follow = follow
        p.me.friend = friend
        return p
    }

    func testStartLoadsConfigProfileAndFirstPostsAndHideState() async {
        let source = ProfileSource()
        var p = page()
        p.me.muted = true
        source.profileValue = p
        source.pages[""] = FeedProfilePostsPage(posts: [card("a"), card("b")], cursor: "c1")
        let store = await started(source)
        XCTAssertFalse(store.state.loading)
        XCTAssertFalse(store.state.gone)
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b"])
        XCTAssertEqual(store.state.cursor, "c1")
        XCTAssertTrue(store.state.postsLoadedOnce)
        XCTAssertEqual(store.state.hideState, FeedHideState(muted: true, hiddenFrom: false))
        XCTAssertEqual(store.state.mediaBaseUrl, "https://img.example.test/")
        XCTAssertTrue(store.state.showIpRegion)
    }

    func testSelfBlockedAndHiddenProfilesGetNoHideStateOrPosts() async {
        let own = ProfileSource()
        var mine = page()
        mine.me.isSelf = true
        own.profileValue = mine
        let ownStore = await started(own)
        XCTAssertNil(ownStore.state.hideState)

        let blocked = ProfileSource()
        var b = page()
        b.me.blocked = true
        blocked.profileValue = b
        let blockedStore = await started(blocked)
        XCTAssertNil(blockedStore.state.hideState)
        XCTAssertEqual(blocked.calls.all.filter { $0.hasPrefix("posts") }, [], "我屏蔽的人不拉帖子")

        let privateOne = ProfileSource()
        privateOne.profileValue = page(isPrivate: true)
        _ = await started(privateOne)
        XCTAssertEqual(privateOne.calls.all.filter { $0.hasPrefix("posts") }, [], "私密账号对非好友不拉帖子")
    }

    func testMissingProfileIsGoneAndFailureIsFailed() async {
        let source = ProfileSource()
        source.profileValue = nil
        let store = await started(source)
        XCTAssertTrue(store.state.gone)
        XCTAssertFalse(store.state.loading)
        XCTAssertNil(store.state.profile)

        let failing = ProfileSource()
        failing.profileError = Boom()
        let second = await started(failing)
        XCTAssertTrue(second.state.failed)
        XCTAssertFalse(second.state.gone)
        XCTAssertFalse(second.state.loading)
    }

    func testPagingAppendsWithoutDuplicatesAndDoesNothingWithoutACursor() async {
        let source = ProfileSource()
        source.pages[""] = FeedProfilePostsPage(posts: [card("a"), card("b")], cursor: "c1")
        source.pages["c1"] = FeedProfilePostsPage(posts: [card("b"), card("c")], cursor: nil)
        let store = await started(source)
        store.loadMorePosts()
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["a", "b", "c"])
        XCTAssertNil(store.state.cursor)
        store.loadMorePosts()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("posts") }.count, 2)
    }

    func testPostsRejectedWith404MakesThePageGoneOtherErrorsOnlyFailTheList() async {
        let source = ProfileSource()
        source.pages[""] = FeedProfilePostsPage(posts: [card("a")], cursor: "c1")
        let store = await started(source)
        source.postsError = Boom()
        store.loadMorePosts()
        await store.waitForTasks()
        XCTAssertTrue(store.state.postsFailed)
        XCTAssertEqual(store.state.posts.map(\.id), ["a"])
        XCTAssertFalse(store.state.postsLoading)
        XCTAssertFalse(store.state.gone)

        source.postsError = FeedAPIError(status: 404, code: "not_found", retryAfterSeconds: nil)
        store.loadMorePosts()
        await store.waitForTasks()
        XCTAssertTrue(store.state.gone)
        XCTAssertNil(store.state.profile)
        XCTAssertEqual(store.state.posts, [])
    }

    func testFollowPublicIsOptimisticThenConfirmed() async {
        let source = ProfileSource()
        source.profileValue = page(followers: 10)
        let store = await started(source)
        store.follow()
        XCTAssertEqual(store.state.profile?.me.follow, "approved", "先改按钮")
        XCTAssertEqual(store.state.profile?.followers, 11, "粉丝数乐观 +1")
        XCTAssertTrue(store.state.followBusy)
        store.follow()   // 在途时不响应第二下
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0 == "follow true" }.count, 1)
        XCTAssertFalse(store.state.followBusy)
        XCTAssertEqual(store.state.notice, .followed)
        XCTAssertEqual(store.state.profile?.followers, 11)
    }

    func testFollowPrivateGuessesPendingAndLoadsPostsOnlyWhenApproved() async {
        let source = ProfileSource()
        source.profileValue = page(isPrivate: true)
        source.followResult = "pending"
        let store = await started(source)
        store.follow()
        XCTAssertEqual(store.state.profile?.me.follow, "pending")
        XCTAssertEqual(store.state.profile?.followers, 10, "请求中粉丝数不动")
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .requested)
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("posts") }, [])

        // 私密账号但引擎直接通过（比如已经是好友）：看得到了就拉帖子
        let approvedSource = ProfileSource()
        approvedSource.profileValue = page(isPrivate: true)
        approvedSource.followResult = "approved"
        approvedSource.pages[""] = FeedProfilePostsPage(posts: [card("a")], cursor: nil)
        let second = await started(approvedSource)
        second.follow()
        await second.waitForTasks()
        XCTAssertEqual(second.state.posts.map(\.id), ["a"])
        XCTAssertEqual(second.state.notice, .followed)
    }

    func testFollowIsIgnoredForSelfAndWhenAlreadyFollowing() async {
        let source = ProfileSource()
        source.profileValue = page(follow: "approved")
        let store = await started(source)
        store.follow()
        XCTAssertFalse(store.state.followBusy)
        var mine = page()
        mine.me.isSelf = true
        let own = ProfileSource()
        own.profileValue = mine
        let ownStore2 = await started(own)
        ownStore2.follow()
        XCTAssertFalse(ownStore2.state.followBusy)
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("follow") }, [])
    }

    func testFollowFailuresRollBackAndAreToldApart() async {
        for (error, notice, gone) in [
            (FeedAPIError(status: 409, code: "profile_required", retryAfterSeconds: nil), FeedProfilePageState.Notice.profileRequired as FeedProfilePageState.Notice?, false),
            (FeedAPIError(status: 404, code: "not_found", retryAfterSeconds: nil), nil, true),
            (FeedAPIError(status: 500, code: nil, retryAfterSeconds: nil), .failed, false),
        ] {
            let source = ProfileSource()
            source.profileValue = page(followers: 10)
            source.followError = error
            let store = await started(source)
            store.follow()
            await store.waitForTasks()
            XCTAssertFalse(store.state.followBusy)
            XCTAssertEqual(store.state.gone, gone, "\(error)")
            XCTAssertEqual(store.state.notice, notice, "\(error)")
            if !gone {
                XCTAssertEqual(store.state.profile?.me.follow, "none")
                XCTAssertEqual(store.state.profile?.followers, 10)
            }
        }
        let plain = ProfileSource()
        plain.followError = Boom()
        let store = await started(plain)
        store.follow()
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .failed, "不是 FeedAPIError 也一样")
    }

    func testUnfollowOfAPrivateAccountHidesPostsAndFailureBringsThemBack() async {
        let source = ProfileSource()
        source.profileValue = page(followers: 10, isPrivate: true, follow: "approved")
        source.pages[""] = FeedProfilePostsPage(posts: [card("a")], cursor: "c1")
        let store = await started(source)
        XCTAssertEqual(store.state.posts.count, 1)
        store.unfollow()
        XCTAssertEqual(store.state.profile?.me.follow, "none")
        XCTAssertEqual(store.state.profile?.followers, 9)
        XCTAssertEqual(store.state.posts, [], "私密账号取消后帖子收起来")
        XCTAssertNil(store.state.cursor)
        await store.waitForTasks()
        XCTAssertFalse(store.state.followBusy)

        let failing = ProfileSource()
        failing.profileValue = page(followers: 10, isPrivate: true, follow: "approved")
        failing.pages[""] = FeedProfilePostsPage(posts: [card("a")], cursor: nil)
        let second = await started(failing)
        failing.followError = Boom()
        second.unfollow()
        await second.waitForTasks()
        XCTAssertEqual(second.state.profile?.me.follow, "approved")
        XCTAssertEqual(second.state.profile?.followers, 10)
        XCTAssertEqual(second.state.notice, .failed)
        XCTAssertEqual(second.state.posts.map(\.id), ["a"], "失败后重新拉回帖子")
    }

    func testUnfollowOfAPublicAccountKeepsPostsAndNoOpWhenNotFollowing() async {
        let source = ProfileSource()
        source.profileValue = page(follow: "approved")
        source.pages[""] = FeedProfilePostsPage(posts: [card("a")], cursor: nil)
        let store = await started(source)
        store.unfollow()
        XCTAssertEqual(store.state.posts.map(\.id), ["a"])
        await store.waitForTasks()
        store.unfollow()
        XCTAssertFalse(store.state.followBusy, "已经没关注：不发")
        XCTAssertEqual(source.calls.all.filter { $0 == "follow false" }.count, 1)
    }

    func testBlockRemovesFollowAndPostsAndUnblockReloads() async {
        let source = ProfileSource()
        source.profileValue = page(followers: 10, follow: "approved")
        source.pages[""] = FeedProfilePostsPage(posts: [card("a")], cursor: "c")
        let store = await started(source)
        store.setBlocked(true)
        XCTAssertTrue(store.state.followBusy)
        await store.waitForTasks()
        XCTAssertEqual(store.state.profile?.me.blocked, true)
        XCTAssertEqual(store.state.profile?.me.follow, "none")
        XCTAssertEqual(store.state.profile?.followers, 9)
        XCTAssertEqual(store.state.posts, [])
        XCTAssertEqual(store.state.notice, .blocked)
        XCTAssertFalse(store.state.followBusy)

        let before = source.calls.all.filter { $0 == "profile p1" }.count
        source.profileValue = page(followers: 9)
        store.setBlocked(false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .unblocked)
        XCTAssertEqual(source.calls.all.filter { $0 == "profile p1" }.count, before + 1, "取消屏蔽后重新拉主页")
        XCTAssertEqual(store.state.profile?.me.blocked, false)

        source.blockError = Boom()
        store.setBlocked(true)
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .failed)
        XCTAssertEqual(store.state.profile?.me.blocked, false)
        XCTAssertFalse(store.state.followBusy)
    }

    func testBlockingYourselfIsIgnored() async {
        var mine = page()
        mine.me.isSelf = true
        let source = ProfileSource()
        source.profileValue = mine
        let store = await started(source)
        store.setBlocked(true)
        XCTAssertFalse(store.state.followBusy)
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("block") }, [])
    }

    func testHideListsAreOptimisticWithNoticesAndRollback() async {
        let source = ProfileSource()
        let store = await started(source)
        store.setHidden(list: "mute", on: true)
        XCTAssertEqual(store.state.hideState, FeedHideState(muted: true, hiddenFrom: false))
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .muted)
        store.onNoticeShown()
        store.setHidden(list: "hide_from", on: true)
        await store.waitForTasks()
        XCTAssertEqual(store.state.hideState, FeedHideState(muted: true, hiddenFrom: true))
        XCTAssertEqual(store.state.notice, .hiddenFrom)
        store.onNoticeShown()
        store.setHidden(list: "mute", on: false)
        await store.waitForTasks()
        XCTAssertNil(store.state.notice, "移出不提示")

        source.hideError = FeedAPIError(status: 409, code: "profile_required", retryAfterSeconds: nil)
        store.setHidden(list: "mute", on: true)
        await store.waitForTasks()
        XCTAssertEqual(store.state.hideState?.muted, false)
        XCTAssertEqual(store.state.notice, .profileRequired)
        source.hideError = Boom()
        store.setHidden(list: "mute", on: true)
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testLikeAndRepostRollBackOnFailure() async {
        let source = ProfileSource()
        source.pages[""] = FeedProfilePostsPage(posts: [card("a")], cursor: nil)
        let store = await started(source)
        let a = store.state.posts[0]
        store.toggleLike(a)
        XCTAssertTrue(store.state.posts[0].viewer.liked)
        await store.waitForTasks()
        XCTAssertTrue(store.state.posts[0].viewer.liked)

        source.likeError = Boom()
        store.toggleLike(store.state.posts[0])
        await store.waitForTasks()
        XCTAssertTrue(store.state.posts[0].viewer.liked, "取消赞失败：改回已赞")
        XCTAssertEqual(store.state.notice, .failed)
        store.onNoticeShown()

        store.toggleRepost(a)
        XCTAssertTrue(store.state.posts[0].viewer.reposted)
        store.toggleRepost(a)   // 在途不重复
        await store.waitForTasks()
        XCTAssertEqual(source.calls.all.filter { $0.hasPrefix("repost") }.count, 1)
        XCTAssertEqual(store.state.notice, .reposted)
        source.repostError = Boom()
        store.toggleRepost(store.state.posts[0])
        await store.waitForTasks()
        XCTAssertTrue(store.state.posts[0].viewer.reposted)
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testPinReloadsFirstPageAndPinLimitRollsBack() async {
        let source = ProfileSource()
        source.pages[""] = FeedProfilePostsPage(posts: [card("a", mine: true), card("b", mine: true)], cursor: nil)
        let store = await started(source)
        store.onOwnPostAction(store.state.posts[1], .pin)
        XCTAssertTrue(store.state.posts[1].pinned, "先改界面")
        source.pages[""] = FeedProfilePostsPage(posts: [card("b", mine: true), card("a", mine: true)], cursor: nil)
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["b", "a"], "置顶变了重拉第一页")

        source.settingsError = FeedAPIError(status: 409, code: "too_many_pinned", retryAfterSeconds: nil)
        let a = store.state.posts[1]
        store.onOwnPostAction(a, .pin)
        XCTAssertTrue(store.state.posts[1].pinned)
        await store.waitForTasks()
        XCTAssertFalse(store.state.posts[1].pinned)
        XCTAssertEqual(store.state.notice, .pinLimit)

        source.settingsError = Boom()
        store.onOwnPostAction(a, .hideLikes)
        await store.waitForTasks()
        XCTAssertFalse(store.state.posts[1].stats.likeCountHidden)
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testInsightsOpenAndDismissAndSaveNeedsAnImplementation() async {
        let source = ProfileSource()
        source.pages[""] = FeedProfilePostsPage(posts: [card("a", mine: true)], cursor: nil)
        let store = await started(source)
        store.onOwnPostAction(store.state.posts[0], .insights)
        XCTAssertEqual(store.state.insights, .loading)
        await store.waitForTasks()
        XCTAssertEqual(store.state.insights, .ready(FeedPostInsights()))
        store.onInsightsDismissed()
        XCTAssertNil(store.state.insights)

        source.insightsError = Boom()
        store.onOwnPostAction(store.state.posts[0], .insights)
        store.onInsightsDismissed()   // 关掉后结果回来不再弹
        await store.waitForTasks()
        XCTAssertNil(store.state.insights)

        store.toggleSave(store.state.posts[0])
        XCTAssertTrue(store.state.posts[0].viewer.saved)
        await store.waitForTasks()
        XCTAssertFalse(store.state.posts[0].viewer.saved, "没有收藏实现：改回去并提示")
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testRefreshReplacesTheListAndDropsAStaleResponse() async {
        let source = ProfileSource()
        source.pages[""] = FeedProfilePostsPage(posts: [card("a")], cursor: "c1")
        let store = await started(source)
        source.pages[""] = FeedProfilePostsPage(posts: [card("z")], cursor: nil)
        store.refresh()
        XCTAssertTrue(store.state.loading)
        await store.waitForTasks()
        XCTAssertEqual(store.state.posts.map(\.id), ["z"])
        XCTAssertNil(store.state.cursor)
        XCTAssertFalse(store.state.loading)
    }
}

/// `NSLock.lock()` 在 async 函数里不让直接调（Swift 6）；临界区都不跨 `await`，放进同步闭包里。
private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
