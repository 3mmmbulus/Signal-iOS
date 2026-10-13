//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// M11 动态第二刀：内容引擎客户端（契约 `docs/adr/0071/client-api-2026-10.md`）、本机样例、信息流状态和帖子卡片。
/// 与 Android `FeedModelsTest` / `FeedApiTest` / `RemoteFeedSourceTest` / `FeedPostCardTest` 同口径。
final class TellomiFeedClientTests: XCTestCase {

    // MARK: - 模型（契约第四、五节）

    /// 契约 4.2 的示例原样解析：计数、我的状态、投票在外层，合进卡片；`unavailable` 跳过。
    func testCardsResponseFromTheContract() throws {
        let json = """
        { "cards": [
            { "id": "0192", "state": "ok", "version": 2,
              "card": {
                "kind": "post", "display_mode": "text_images", "source_url": null, "ai_generated": false, "edited": true,
                "published_at": "2026-10-13T11:00:00Z", "title": "…", "text": "今天的云很好看", "summary": "…",
                "media": [ { "type": "image", "key": "m/1", "w": 1080, "h": 1440 } ],
                "poll": { "options": ["A", "B"], "closes_at": null, "multi": false },
                "quote_of": "0190",
                "author": { "id": "0191", "display_name": "山风", "handle": "shanfeng", "avatar_key": "avatars/1", "badge": "official", "native": true },
                "ip_region_label": "四川",
                "attribution": { "name": "x" },
                "rights": { "basis": "b", "license": "l" },
                "some_future_field": [1, 2, 3]
              },
              "stats": { "likes": 12, "comments": 3, "reposts": 0 },
              "me": { "liked": true, "saved": false },
              "poll": { "counts": [3, 5], "voted": [] } },
            { "id": "0193", "state": "unavailable" },
            { "id": "0194", "state": "something_new", "card": { "kind": "post" } },
            { "id": "0195", "state": "ok", "card": { "no_kind": true } },
            { "state": "ok" }
        ] }
        """
        let response = try JSONDecoder().decode(FeedCardsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.cards.map(\.id), ["0192", "0193", "0194", "0195"], "没有 id 的一项丢掉，其余照收")

        let card = try XCTUnwrap(response.cards[0].toCard())
        XCTAssertEqual(card.id, "0192")
        XCTAssertEqual(card.version, 2)
        XCTAssertEqual(card.kind, FeedCard.kindPost)
        XCTAssertEqual(card.displayMode, FeedCard.displayTextImages)
        XCTAssertTrue(card.edited)
        XCTAssertEqual(card.text, "今天的云很好看")
        XCTAssertEqual(card.media, [FeedMedia(key: "m/1", w: 1080, h: 1440)])
        XCTAssertEqual(card.poll?.options, ["A", "B"])
        XCTAssertEqual(card.quoteOf, "0190")
        XCTAssertEqual(card.author?.profileId, "0191")
        XCTAssertEqual(card.author?.displayName, "山风")
        XCTAssertEqual(card.author?.badge, "official")
        XCTAssertEqual(card.author?.isNative, true)
        XCTAssertEqual(card.ipRegionLabel, "四川")
        XCTAssertEqual(card.stats, FeedStats(likes: 12, comments: 3, reposts: 0))
        XCTAssertTrue(card.viewer.liked)
        XCTAssertEqual(card.pollState?.counts, [3, 5])
        XCTAssertEqual(card.publishedDate, Date(timeIntervalSince1970: 1_791_889_200))

        XCTAssertNil(response.cards[1].toCard(), "unavailable 不区分原因，跳过")
        XCTAssertNil(response.cards[2].toCard(), "不认识的 state 当不可用")
        XCTAssertNil(response.cards[3].toCard(), "card 结构不对当不可用")
    }

    /// 只渲染 post / article / comment；别的 kind 不显示、不报错。不认识的 display_mode 按 text 渲染。
    func testOnlyKnownKindsAreRendered() throws {
        for (kind, renderable) in [("post", true), ("article", true), ("comment", true), ("story", false), ("video", false), ("podcast_episode", false)] {
            let card = try JSONDecoder().decode(FeedCard.self, from: Data(#"{"kind":"\#(kind)","display_mode":"hologram"}"#.utf8))
            XCTAssertEqual(card.isRenderable, renderable, kind)
            XCTAssertEqual(card.displayMode, "hologram")
        }
        let minimal = try JSONDecoder().decode(FeedCard.self, from: Data(#"{"kind":"post"}"#.utf8))
        XCTAssertEqual(minimal.displayMode, FeedCard.displayText)
        XCTAssertEqual(minimal.stats, FeedStats())
        XCTAssertFalse(minimal.viewer.liked)
    }

    /// 配置：缺的字段用默认值（契约 3.2 右列）；时间带不带小数秒都认。
    func testConfigDefaultsAndDates() throws {
        let config = try JSONDecoder().decode(FeedConfig.self, from: Data(#"{"limits":{"post_images":4}}"#.utf8))
        XCTAssertEqual(config.recommendMode, FeedConfig.recommendModeEditorial)
        XCTAssertFalse(config.personalizationToggleVisible)
        XCTAssertFalse(config.hotEnabled)
        XCTAssertEqual(config.cardTtlSeconds, 600)
        XCTAssertEqual(config.limits.postTextChars, 500)
        XCTAssertEqual(config.limits.postImages, 4)
        XCTAssertEqual(config.limits.articleChars, 10_000)
        XCTAssertEqual(config.limits.editWindowSeconds, 900)
        XCTAssertFalse(config.minorMode)

        XCTAssertEqual(FeedDates.parse("2026-10-13T11:00:00Z"), FeedDates.parse("2026-10-13T11:00:00.000Z"))
        XCTAssertNil(FeedDates.parse("yesterday"))
        XCTAssertEqual(FeedMedia(key: "a", w: 1000, h: 100).clampedAspectRatio, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(FeedMedia(key: "a", w: 100, h: 1000).clampedAspectRatio, 3.0 / 4.0, accuracy: 0.001)
        XCTAssertEqual(FeedMedia(key: "a").clampedAspectRatio, 1)
    }

    // MARK: - FeedAPI（契约第一、四、六节）

    func testRoutesMethodsAndBodies() async throws {
        let transport = FakeTransport()
        let api = FeedAPI(baseURL: URL(string: "https://feed.example/base/")!, transport: transport, tokens: FakeTokens())

        transport.respond(200, #"{"visible":true}"#)
        let visible = try await api.status().visible
        XCTAssertTrue(visible)

        transport.respond(200, #"{"items":[{"id":"a","reason":"editorial"}]}"#)
        _ = try await api.feed(tabApiName: FeedAPI.tabRecommend, cursor: nil, personalized: false)
        transport.respond(200, #"{"items":[],"cursor":"c2"}"#)
        let following = try await api.feed(tabApiName: FeedAPI.tabFollowing, cursor: "c 1")
        XCTAssertEqual(following.cursor, "c2")

        transport.respond(200, #"{"cards":[]}"#)
        _ = try await api.cards(ids: ["a", "b"])
        transport.respond(204, "")
        try await api.setReaction(contentId: "a/../x", reaction: .like, on: true)
        transport.respond(204, "")
        try await api.setReaction(contentId: "a", reaction: .save, on: false)
        transport.respond(204, "")
        try await api.notInterested(contentId: "a", reason: nil)
        transport.respond(204, "")
        try await api.undoNotInterested(contentId: "a")

        XCTAssertEqual(transport.sent.map { "\($0.httpMethod!) \($0.url!.absoluteString)" }, [
            "GET https://feed.example/base/v1/feed/status",
            "GET https://feed.example/base/v1/feed/recommend?personalized=false",
            "GET https://feed.example/base/v1/feed/following?cursor=c%201",
            "POST https://feed.example/base/v1/feed/cards",
            "PUT https://feed.example/base/v1/feed/posts/a%2F..%2Fx/like",
            "DELETE https://feed.example/base/v1/feed/posts/a/save",
            "POST https://feed.example/base/v1/feed/not-interested",
            "DELETE https://feed.example/base/v1/feed/not-interested/a",
        ])
        XCTAssertEqual(transport.bodies[3], #"{"ids":["a","b"]}"#)
        XCTAssertEqual(transport.bodies[6], #"{"content_id":"a"}"#, "请求体只放契约列出的字段，nil 不发")
        XCTAssertTrue(transport.sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer t0" })
    }

    /// 401 换一次 token 再试，只重试一次；还是 401 就抛出。
    func testUnauthorizedRefreshesTheTokenOnce() async throws {
        let transport = FakeTransport()
        let tokens = FakeTokens()
        let api = FeedAPI(baseURL: URL(string: "https://feed.example")!, transport: transport, tokens: tokens)

        transport.respond(401, #"{"error":"credential_expired"}"#)
        transport.respond(200, #"{"visible":true}"#)
        let visible = try await api.status().visible
        XCTAssertTrue(visible)
        XCTAssertEqual(transport.sent.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer t0", "Bearer t1"])

        transport.respond(401, #"{"error":"credential_invalid"}"#)
        transport.respond(401, #"{"error":"credential_invalid"}"#)
        do {
            _ = try await api.status()
            XCTFail("should throw")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error, FeedAPIError(status: 401, code: "credential_invalid"))
        }
        XCTAssertEqual(transport.sent.count, 4)
    }

    /// 404 `feed_hidden` = 不在内测名单或紧急开关关了；429 带 Retry-After。
    func testErrorCodes() async throws {
        let transport = FakeTransport()
        let api = FeedAPI(baseURL: URL(string: "https://feed.example")!, transport: transport, tokens: FakeTokens())

        transport.respond(404, #"{"error":"feed_hidden"}"#)
        do {
            _ = try await api.feed(tabApiName: FeedAPI.tabFollowing, cursor: nil)
            XCTFail("should throw")
        } catch let error as FeedAPIError {
            XCTAssertTrue(error.isFeedHidden)
        }

        transport.respond(429, "", headers: ["Retry-After": "30"])
        do {
            _ = try await api.status()
            XCTFail("should throw")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 429)
            XCTAssertEqual(error.retryAfterSeconds, 30)
            XCTAssertFalse(error.isFeedHidden)
        }
    }

    /// 列表只给 id，卡片按列表的顺序换回来；不可用的跳过；重复 id 只要一次；超过 100 个分批。
    func testRemoteSourceHydratesIdsInOrder() async throws {
        let transport = FakeTransport()
        let source = RemoteFeedSource(api: FeedAPI(baseURL: URL(string: "https://feed.example")!, transport: transport, tokens: FakeTokens()))

        transport.respond(200, #"{"items":[{"id":"b"},{"id":"a"},{"id":"b"},{"id":"gone"}],"cursor":"next"}"#)
        transport.respond(200, """
        {"cards":[{"id":"a","state":"ok","card":{"kind":"post","text":"A"}},
                  {"id":"gone","state":"unavailable"},
                  {"id":"b","state":"ok","card":{"kind":"post","text":"B"}}]}
        """)
        let page = try await source.timeline(tab: .following, cursor: nil)
        XCTAssertEqual(page.cards.map(\.id), ["b", "a"])
        XCTAssertEqual(page.nextCursor, "next")
        XCTAssertEqual(transport.bodies[1], #"{"ids":["b","a","gone"]}"#)

        // 推荐没有 cursor：有内容就还能再要一页，空了才到底；再要一页时也不带 cursor
        let ids = (0..<150).map { #"{"id":"r\#($0)"}"# }.joined(separator: ",")
        transport.respond(200, #"{"items":[\#(ids)]}"#)
        transport.respond(200, #"{"cards":[]}"#)
        transport.respond(200, #"{"cards":[]}"#)
        let recommend = try await source.timeline(tab: .recommend, cursor: RemoteFeedSource.recommendMore)
        XCTAssertEqual(recommend.nextCursor, RemoteFeedSource.recommendMore)
        XCTAssertEqual(transport.sent[2].url?.absoluteString, "https://feed.example/v1/feed/recommend")
        XCTAssertEqual(transport.sent.count, 5, "150 个 id 分两批换卡片")

        transport.respond(200, #"{"items":[]}"#)
        let end = try await source.timeline(tab: .recommend, cursor: RemoteFeedSource.recommendMore)
        XCTAssertNil(end.nextCursor)
    }

    // MARK: - 本机样例

    func testSampleSourcePagesAndRemembersLikes() async throws {
        let sample = SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) })
        let first = try await sample.timeline(tab: .recommend, cursor: nil)
        XCTAssertEqual(first.cards.count, SampleFeedSource.pageSize)
        XCTAssertEqual(first.nextCursor, "8")
        XCTAssertTrue(first.cards.allSatisfy { $0.isRenderable })

        let following = try await sample.timeline(tab: .following, cursor: nil)
        XCTAssertTrue(following.cards.allSatisfy { ["s-1", "s-3"].contains($0.author?.profileId) })

        let card = first.cards[0]
        try await sample.setLiked(contentId: card.id, liked: true)
        let again = try await sample.timeline(tab: .recommend, cursor: nil)
        XCTAssertTrue(again.cards[0].viewer.liked)
        XCTAssertEqual(again.cards[0].stats.likes, card.stats.likes + 1)

        try await sample.notInterested(contentId: card.id)
        let hidden = try await sample.timeline(tab: .recommend, cursor: nil)
        XCTAssertFalse(hidden.cards.contains { $0.id == card.id })
        try await sample.undoNotInterested(contentId: card.id)
        let restored = try await sample.timeline(tab: .recommend, cursor: nil)
        XCTAssertEqual(restored.cards[0].id, card.id)

        var cursor: String? = nil
        var total = 0
        repeat {
            let page = try await sample.timeline(tab: .recommend, cursor: cursor)
            total += page.cards.count
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(total, 24)
    }

    // MARK: - FeedStore

    @MainActor
    func testRefreshPutsNewOnTopAndLoadMoreAppends() async throws {
        let source = ScriptedSource()
        let store = FeedStore(source: source)

        source.pages = [FeedTimelinePage(cards: [card("a"), card("b")], nextCursor: "1")]
        store.onTabShown(.following)
        await store.waitForLoad(.following)
        XCTAssertEqual(store.tab(.following).cards.map(\.id), ["a", "b"])
        XCTAssertTrue(store.tab(.following).loadedOnce)

        source.pages = [FeedTimelinePage(cards: [card("b"), card("c")], nextCursor: nil)]
        store.loadMore(.following)
        await store.waitForLoad(.following)
        XCTAssertEqual(store.tab(.following).cards.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(source.cursors, [nil, "1"])

        store.loadMore(.following)
        await store.waitForLoad(.following)
        XCTAssertEqual(source.cursors.count, 2, "没有下一页就不再取")

        source.pages = [FeedTimelinePage(cards: [card("z"), card("a")], nextCursor: "9")]
        store.refresh(.following)
        await store.waitForLoad(.following)
        XCTAssertEqual(store.tab(.following).cards.map(\.id), ["z", "a", "b", "c"])
        XCTAssertEqual(source.cursors.last, .some(nil))

        // 第一页就失败：列表空着才算失败页；有内容时只提示
        var errors = [FeedStore.TransientError]()
        store.onTransientError = { errors.append($0) }
        source.fail = true
        store.refresh(.following)
        await store.waitForLoad(.following)
        XCTAssertFalse(store.tab(.following).failed)
        XCTAssertEqual(errors, [.network])
        store.onTabShown(.recommend)
        await store.waitForLoad(.recommend)
        XCTAssertTrue(store.tab(.recommend).failed)

        // 不认识的 kind 不进列表
        source.fail = false
        source.pages = [FeedTimelinePage(cards: [card("s", kind: "story"), card("p")])]
        store.refresh(.recommend)
        await store.waitForLoad(.recommend)
        XCTAssertEqual(store.tab(.recommend).cards.map(\.id), ["p"])
    }

    /// 点赞先改界面；失败改回来并提示（契约第六节）。
    @MainActor
    func testLikeIsOptimisticAndRollsBack() async throws {
        let source = ScriptedSource()
        let store = FeedStore(source: source)
        source.pages = [FeedTimelinePage(cards: [card("a", likes: 3)])]
        store.onTabShown(.recommend)
        await store.waitForLoad(.recommend)

        store.toggleLike(store.tab(.recommend).cards[0])
        XCTAssertTrue(store.tab(.recommend).cards[0].viewer.liked)
        XCTAssertEqual(store.tab(.recommend).cards[0].stats.likes, 4)
        await source.waitForActions(1)
        XCTAssertEqual(source.likes, ["a:true"])

        var errors = [FeedStore.TransientError]()
        store.onTransientError = { errors.append($0) }
        source.failActions = true
        store.toggleLike(store.tab(.recommend).cards[0])
        XCTAssertFalse(store.tab(.recommend).cards[0].viewer.liked)
        await source.waitForActions(2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.tab(.recommend).cards[0].viewer.liked, "失败改回赞过")
        XCTAssertEqual(store.tab(.recommend).cards[0].stats.likes, 4)
        XCTAssertEqual(errors, [.actionFailed])
    }

    /// 不感兴趣：原地变成反馈卡，撤销后回来；两件事都报给来源。
    @MainActor
    func testNotInterestedAndUndo() async throws {
        let source = ScriptedSource()
        let store = FeedStore(source: source)
        source.pages = [FeedTimelinePage(cards: [card("a"), card("b")])]
        store.onTabShown(.recommend)
        await store.waitForLoad(.recommend)

        store.notInterested(store.tab(.recommend).cards[1])
        XCTAssertEqual(store.hiddenIds, ["b"])
        XCTAssertEqual(store.tab(.recommend).cards.map(\.id), ["a", "b"], "卡片留着，显示成反馈卡")
        store.undoNotInterested("b")
        XCTAssertEqual(store.hiddenIds, [])
        await source.waitForActions(2)
        XCTAssertEqual(source.notInterested, ["+b", "-b"])
    }

    // MARK: - 卡片

    /// 副标题：有 ID 显示 @ID，没有显示 Tellomi 号；IP 属地看配置；编辑过加「已编辑」。
    func testSubtitle() {
        var card = card("a")
        card.author = FeedAuthor(profileId: "p", displayName: "山风", handle: "shanfeng")
        card.ipRegionLabel = "四川"
        card.edited = true
        let ip = String(format: OWSLocalizedString("TELLOMI_FEED_IP_REGION_FORMAT", comment: ""), "四川")
        let edited = OWSLocalizedString("TELLOMI_FEED_EDITED", comment: "")
        XCTAssertEqual(FeedPostCell.subtitle(for: card, showIpRegion: true), "@shanfeng · \(ip) · \(edited)")
        XCTAssertEqual(FeedPostCell.subtitle(for: card, showIpRegion: false), "@shanfeng · \(edited)")
        XCTAssertTrue(ip.contains("四川"))

        card.author = FeedAuthor(profileId: "p", displayName: "小满", tellomiNumber: "3820145967")
        card.edited = false
        XCTAssertEqual(FeedPostCell.subtitle(for: card, showIpRegion: false), String(format: OWSLocalizedString("TELLOMI_FEED_TELLOMI_NUMBER_FORMAT", comment: ""), "3820145967"))
        XCTAssertTrue(FeedPostCell.subtitle(for: card, showIpRegion: false).contains("3820145967"))

        let now = Date(timeIntervalSince1970: 1_791_889_200)
        XCTAssertEqual(FeedPostCell.relativeTime(now.addingTimeInterval(-10), now: now), OWSLocalizedString("DATE_NOW", comment: ""))
        XCTAssertEqual(FeedPostCell.relativeTime(now.addingTimeInterval(60), now: now), OWSLocalizedString("DATE_NOW", comment: ""), "未来的时间按「刚刚」")
        XCTAssertNotEqual(FeedPostCell.relativeTime(now.addingTimeInterval(-3600), now: now), OWSLocalizedString("DATE_NOW", comment: ""))
    }

    /// 卡片：别人的帖子有「···」，自己的没有；赞数为 0 不显示；长文只露 4 行；AI 生成有标记。
    @MainActor
    func testCellContents() {
        let cell = FeedPostCell(style: .default, reuseIdentifier: nil)
        var post = card("a", likes: 0)
        post.text = "正文"
        post.aiGenerated = true
        cell.configure(card: post, showIpRegion: true)
        let labels = allLabels(cell).filter { !$0.isHidden }.compactMap(\.text)
        XCTAssertTrue(labels.contains("正文"))
        XCTAssertTrue(labels.contains(OWSLocalizedString("TELLOMI_FEED_AI_GENERATED", comment: "")))
        let buttons = allViews(cell).compactMap { $0 as? UIButton }
        let more = buttons.first { $0.accessibilityLabel == OWSLocalizedString("TELLOMI_FEED_MORE", comment: "") }
        XCTAssertEqual(more?.isHidden, false)
        XCTAssertEqual(more?.menu?.children.map(\.title), [OWSLocalizedString("TELLOMI_FEED_NOT_INTERESTED", comment: "")])
        let like = buttons.first { $0.accessibilityLabel == OWSLocalizedString("TELLOMI_FEED_LIKE", comment: "") }
        XCTAssertNotNil(like)
        XCTAssertNil(like?.configuration?.title)

        var liked: [String] = []
        cell.onLike = { liked.append($0.id) }
        like?.sendActions(for: .touchUpInside)
        XCTAssertEqual(liked, ["a"])

        var mine = card("m", kind: FeedCard.kindArticle, likes: 5)
        mine.title = "标题"
        mine.summary = "摘要"
        mine.viewer.isAuthor = true
        mine.viewer.liked = true
        cell.configure(card: mine, showIpRegion: true)
        XCTAssertEqual(more?.isHidden, true)
        let body = allLabels(cell).first { $0.text == "摘要" }
        XCTAssertEqual(body?.numberOfLines, FeedPostCell.articlePreviewLines)
        XCTAssertTrue(allLabels(cell).contains { $0.text == "标题" && !$0.isHidden })
        let unlike = allViews(cell).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == OWSLocalizedString("TELLOMI_FEED_UNLIKE", comment: "") }
        XCTAssertEqual(unlike?.configuration?.title, "5")
    }

    /// 给人看的截图（TELLOMI_SHOTS=1 时才跑）：样例数据的推荐、点过赞、不感兴趣后的反馈卡。
    @MainActor
    func testShotsOfSampleFeed() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(UIScreen.main.bounds.size.width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let feed = FeedViewController(source: SampleFeedSource())
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = OWSNavigationController(rootViewController: feed)
        window.isHidden = false
        window.layoutIfNeeded()
        await feed.store.loadConfig()
        await feed.store.waitForLoad(.recommend)
        try await Task.sleep(nanoseconds: 500_000_000)

        func shoot(_ name: String) throws {
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        }

        try shoot("feed-sample-recommend")

        let cards = feed.store.tab(.recommend).cards
        feed.store.toggleLike(cards[0])
        feed.store.notInterested(cards[2])
        try await Task.sleep(nanoseconds: 300_000_000)
        try shoot("feed-sample-liked-and-hidden")

        let tableView = feed.pages[0].tableView
        tableView.setContentOffset(CGPoint(x: 0, y: 700), animated: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        try shoot("feed-sample-scrolled")

        window.isHidden = true
        window.rootViewController = nil
    }

    // MARK: - Helpers

    private func card(_ id: String, kind: String = FeedCard.kindPost, likes: Int = 0) -> FeedCard {
        return FeedCard(id: id, kind: kind, author: FeedAuthor(profileId: "p-\(id)", displayName: "作者"), text: "文字 \(id)", stats: FeedStats(likes: likes))
    }

    private func allViews(_ view: UIView) -> [UIView] {
        return [view] + view.subviews.flatMap { allViews($0) }
    }

    private func allLabels(_ view: UIView) -> [UILabel] {
        return allViews(view).compactMap { $0 as? UILabel }
    }
}

// MARK: - Fakes

private final class FakeTokens: FeedTokenSource {
    private var count = 0

    func token(forceRefresh: Bool) async throws -> String {
        if forceRefresh {
            count += 1
        }
        return "t\(count)"
    }
}

private final class FakeTransport: FeedHTTPTransport {
    private var responses = [(Int, String, [String: String])]()
    private(set) var sent = [URLRequest]()

    var bodies: [String] {
        return sent.map { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }
    }

    func respond(_ status: Int, _ body: String, headers: [String: String] = [:]) {
        responses.append((status, body, headers))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        let (status, body, headers) = responses.isEmpty ? (500, "", [:]) : responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(body.utf8), response)
    }
}

private final class ScriptedSource: FeedSource {
    var pages = [FeedTimelinePage]()
    var fail = false
    var failActions = false
    private(set) var cursors = [String?]()
    private(set) var likes = [String]()
    private(set) var notInterested = [String]()
    private var actionCount = 0

    struct Failure: Error {}

    func config() async throws -> FeedConfig { FeedConfig() }

    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage {
        cursors.append(cursor)
        if fail {
            throw Failure()
        }
        return pages.isEmpty ? FeedTimelinePage() : pages.removeFirst()
    }

    func setLiked(contentId: String, liked: Bool) async throws {
        likes.append("\(contentId):\(liked)")
        actionCount += 1
        if failActions {
            throw Failure()
        }
    }

    func notInterested(contentId: String) async throws {
        notInterested.append("+\(contentId)")
        actionCount += 1
    }

    func undoNotInterested(contentId: String) async throws {
        notInterested.append("-\(contentId)")
        actionCount += 1
    }

    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        return FeedCreatePostResponse(id: "new", state: FeedCreatePostResponse.statePublished)
    }

    func waitForActions(_ count: Int) async {
        for _ in 0..<200 where actionCount < count {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
