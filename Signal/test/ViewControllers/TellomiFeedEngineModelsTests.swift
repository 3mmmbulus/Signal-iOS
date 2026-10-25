//
// DRAFT — NOT COMPILED. Written on Linux; needs a Mac + Xcode to build and run.
// Intended location: Signal/test/ViewControllers/TellomiFeedEngineModelsTests.swift (new file)
// Decodes JSON shaped like what content-engine@b7b63aba actually emits (api/cards.go, api/feeds.go, api/server.go config,
// moderation/worker.go card builder). Sample JSON was written by hand from those structs — it is NOT captured from a
// live engine. Mirrors the Android FeedModels tests where they exist.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class TellomiFeedEngineModelsTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testConfigDecodesReportAndRejectionReasons() throws {
        let config = try decode(FeedConfig.self, """
        {"enabled":true,"region":"global","tabs":["recommend","following"],"recommend_mode":"scored",
         "sensitive_more_available":true,"minor_mode":false,
         "limits":{"post_text_chars":500,"post_images":10,"article_chars":10000,"edit_window_seconds":900,"voice_comment_max_seconds":60},
         "report_reasons":{"harm_others":["harassment","hate"],"my_rights":["copyright"]},
         "rejection_reasons":["prohibited_words","review_unavailable","account_restricted","community_guidelines"]}
        """)
        XCTAssertTrue(config.sensitiveMoreAvailable)
        XCTAssertEqual(config.limits.voiceCommentMaxSeconds, 60)
        XCTAssertEqual(config.reportReasons["my_rights"], ["copyright"])
        XCTAssertEqual(config.rejectionReasons.count, 4)
        // 缺字段不失败
        let bare = try decode(FeedConfig.self, "{}")
        XCTAssertTrue(bare.reportReasons.isEmpty)
        XCTAssertFalse(bare.sensitiveMoreAvailable)
    }

    func testFeedItemRepostedBy() throws {
        let page = try decode(FeedIdsPage.self, #"{"items":[{"id":"a","reason":"repost","reposted_by":"p1"},{"id":"b","reason":"friend"}]}"#)
        XCTAssertEqual(page.items[0].repostedBy, "p1")
        XCTAssertNil(page.items[1].repostedBy)
    }

    /// 外层的 shareable / pinned / held / quoted / me.author / me.reposted / stats.likes_hidden 都进卡片。
    func testCardResultCarriesOuterFields() throws {
        let response = try decode(FeedCardsResponse.self, """
        {"cards":[{"id":"c1","state":"ok","version":2,
          "card":{"kind":"post","text":"hi","topics":[{"slug":"hiking","label":"徒步"}],"root_id":null,
                  "author":{"id":"p9","display_name":"A","tellomi_number":"123456"}},
          "stats":{"likes":0,"likes_hidden":true,"comments":3,"reposts":1},
          "me":{"liked":false,"saved":true,"reposted":true,"author":true},
          "shareable":true,"pinned":true,
          "quoted":{"id":"q1","state":"deleted"}}]}
        """)
        let card = try XCTUnwrap(response.cards.first?.toCard())
        XCTAssertTrue(card.shareable)
        XCTAssertTrue(card.pinned)
        XCTAssertTrue(card.stats.likeCountHidden)       // JSON 名是 likes_hidden，不是 like_count_hidden
        XCTAssertTrue(card.viewer.isAuthor)
        XCTAssertTrue(card.viewer.reposted)
        XCTAssertTrue(card.viewer.saved)
        XCTAssertEqual(card.author?.tellomiNumber, "123456")
        let quoted = try XCTUnwrap(card.quoted)
        XCTAssertTrue(quoted.deleted)
        XCTAssertNil(quoted.card)
    }

    func testQuotedOkCarriesCardAndStats() throws {
        let response = try decode(FeedCardsResponse.self, """
        {"cards":[{"id":"c1","state":"ok","card":{"kind":"post","text":"outer","quote_of":"q1"},
          "quoted":{"id":"q1","state":"ok","card":{"kind":"post","text":"inner"},"stats":{"likes":4,"comments":0,"reposts":0}}}]}
        """)
        let card = try XCTUnwrap(response.cards.first?.toCard())
        XCTAssertEqual(card.quoted?.card?.text, "inner")
        XCTAssertEqual(card.quoted?.card?.stats.likes, 4)
        XCTAssertEqual(card.quoted?.card?.id, "q1")
        XCTAssertFalse(card.quoted?.deleted ?? true)
    }

    /// 语音评论：media[].type = audio + duration_ms；transcript；root_id / parent_id。
    func testVoiceComment() throws {
        let card = try decode(FeedCard.self, """
        {"kind":"comment","root_id":"r1","parent_id":"c0","transcript":"你好",
         "media":[{"type":"audio","key":"m/abc","duration_ms":4200}]}
        """)
        XCTAssertEqual(card.rootId, "r1")
        XCTAssertEqual(card.parentId, "c0")
        XCTAssertEqual(card.transcript, "你好")
        XCTAssertTrue(card.media[0].isAudio)
        XCTAssertEqual(card.media[0].durationMs, 4200)
    }

    /// 发帖请求：只带引擎认的字段；可选的不带；client_nonce / media_keys / audience 带上。
    func testCreatePostRequestEncoding() throws {
        var draft = FeedDraft()
        draft.text = "今天的云"
        XCTAssertEqual(
            String(decoding: try FeedAPI.encoder.encode(draft.makeRequest(clientNonce: "n-1")), as: UTF8.self),
            #"{"client_nonce":"n-1","comments_closed":false,"kind":"post","text":"今天的云","visibility":"public"}"#,
        )
        draft.visibility = .include
        XCTAssertEqual(
            String(decoding: try FeedAPI.encoder.encode(draft.makeRequest(clientNonce: "n-1", mediaKeys: ["m/1", "m/2"], audienceToken: "jwt")), as: UTF8.self),
            #"{"audience":{"audience_token":"jwt"},"client_nonce":"n-1","comments_closed":false,"kind":"post","media_keys":["m/1","m/2"],"text":"今天的云","visibility":"include"}"#,
        )
    }

    /// 契约「卡片字段」的 `attribution`、`rights{basis,license}`：有就读，缺字段、形状不对都不让卡片失败。
    func testAttributionAndRightsAreTolerant() throws {
        let full = try decode(FeedCard.self, #"{"kind":"post","attribution":{"name":"Wikimedia","url":"https://w.org","n":3},"rights":{"basis":"license","license":"CC-BY-4.0"}}"#)
        XCTAssertEqual(full.attribution, ["name": "Wikimedia", "url": "https://w.org"], "不是字符串的字段丢掉")
        XCTAssertEqual(full.rights, FeedRights(basis: "license", license: "CC-BY-4.0"))

        let missing = try decode(FeedCard.self, #"{"kind":"post"}"#)
        XCTAssertNil(missing.attribution)
        XCTAssertNil(missing.rights)

        let wrongShape = try decode(FeedCard.self, #"{"kind":"post","text":"hi","attribution":"Wikimedia","rights":["x"]}"#)
        XCTAssertNil(wrongShape.attribution)
        XCTAssertNil(wrongShape.rights)
        XCTAssertEqual(wrongShape.text, "hi")

        let partial = try decode(FeedCard.self, #"{"kind":"post","rights":{"basis":7}}"#)
        XCTAssertEqual(partial.rights, FeedRights())
    }

    // MARK: - B-8：卡片字段按内容引擎 main 66ce9cb（moderation/worker.go 的 card()、api/cards.go 的 Card）

    /// 引擎卡片里的 `topics` 是 slug 字符串数组；以前只认 `{"slug","label"}` 对象，引擎的卡片上话题全被丢掉。
    func testTopicsDecodeFromEngineSlugStrings() throws {
        let card = try decode(FeedCard.self, #"{"kind":"post","topics":["food","no-such-topic",""]}"#)
        XCTAssertEqual(card.topics.map(\.slug), ["food", "no-such-topic"], "空串那一项丢掉，其余保留")
        XCTAssertEqual(card.topics[0].label, FeedComposeViewController.topicName("food"))
        XCTAssertFalse(card.topics[0].label.isEmpty)
        XCTAssertEqual(card.topics[1].label, "no-such-topic", "不认识的 slug 直接显示 slug")
    }

    /// 对象形状照样认；没有 label 的用话题表补；两样都不是的那一项丢掉，卡片不失败。
    func testTopicsAcceptObjectsAndDropJunk() throws {
        let card = try decode(FeedCard.self, #"{"kind":"post","text":"hi","topics":[{"slug":"hiking","label":"徒步"},{"slug":"food"},7,{"label":"x"},"news"]}"#)
        XCTAssertEqual(card.topics.map(\.slug), ["hiking", "food", "news"])
        XCTAssertEqual(card.topics[0].label, "徒步")
        XCTAssertEqual(card.topics[1].label, FeedComposeViewController.topicName("food"))
        XCTAssertEqual(card.text, "hi")
    }

    /// 开放内容的图片可以带自己的 `rights`；形状不对当没有，图片不丢。
    func testMediaRights() throws {
        let card = try decode(FeedCard.self, """
        {"kind":"post","media":[{"type":"image","key":"m/1","w":10,"h":20,"rights":{"basis":"license","license":"CC-BY-4.0"}},
                                {"type":"image","key":"m/2","rights":"bad"}]}
        """)
        XCTAssertEqual(card.media.count, 2)
        XCTAssertEqual(card.media[0].rights, FeedRights(basis: "license", license: "CC-BY-4.0"))
        XCTAssertNil(card.media[1].rights)
    }

    /// 一条语音回复，形状照 `card()` 对评论的写法：有 root_id / parent_id、audio 媒体带 duration_ms、transcript；
    /// 外层 held。原生作者没设 handle 时给 tellomi_number。
    func testVoiceReplyCardFromEngine() throws {
        let response = try decode(FeedCardsResponse.self, """
        {"cards":[{"id":"cm1","state":"ok","version":1,
          "card":{"kind":"comment","display_mode":"text","source_url":null,"ai_generated":false,"edited":false,
                  "root_id":"post-1","parent_id":"cm0","text":"",
                  "media":[{"type":"audio","key":"m/a1","duration_ms":12500}],"transcript":"",
                  "author":{"id":"p1","display_name":"山风","tellomi_number":"10001","native":true}},
          "stats":{"likes":0,"comments":0,"reposts":0},"me":{"liked":false,"saved":false,"reposted":false},
          "held":true}]}
        """)
        let card = try XCTUnwrap(response.cards.first?.toCard())
        XCTAssertEqual(card.kind, "comment")
        XCTAssertEqual(card.rootId, "post-1")
        XCTAssertEqual(card.parentId, "cm0")
        XCTAssertTrue(card.held)
        XCTAssertFalse(card.shareable, "没带 shareable 就是不能分享")
        XCTAssertFalse(card.pinned)
        XCTAssertNil(card.quoted)
        XCTAssertEqual(card.transcript, "")
        XCTAssertEqual(card.media.first?.isAudio, true)
        XCTAssertEqual(card.media.first?.durationMs, 12500)
        XCTAssertNil(card.author?.handle)
        XCTAssertEqual(card.author?.tellomiNumber, "10001")
    }

    /// 回复帖子本身（不是回复某条评论）时引擎不给 parent_id；转写有文字时原样读。
    func testTopLevelCommentHasNoParent() throws {
        let card = try decode(FeedCard.self, #"{"kind":"comment","root_id":"post-1","media":[{"type":"audio","key":"m/a","duration_ms":3000}],"transcript":"你好"}"#)
        XCTAssertEqual(card.rootId, "post-1")
        XCTAssertNil(card.parentId)
        XCTAssertEqual(card.transcript, "你好")
    }

    /// 外部作者：native=false，带 id、avatar_url、provider；开放内容带 rights / attribution / published_at / source_url。
    func testExternalAuthorCard() throws {
        let card = try decode(FeedCard.self, """
        {"kind":"video","display_mode":"link","source_url":"https://example.com/v/1","ai_generated":false,"edited":false,
         "published_at":"2026-10-13T11:00:00Z","title":"t",
         "author":{"id":"x1","display_name":"Ext","handle":"ext","avatar_url":"https://example.com/a.png","provider":"youtube","native":false},
         "attribution":{"name":"Ext"},"rights":{"basis":"license","license":"CC-BY-4.0"}}
        """)
        let author = try XCTUnwrap(card.author)
        XCTAssertFalse(author.isNative)
        XCTAssertEqual(author.profileId, "x1")
        XCTAssertEqual(author.avatarUrl, "https://example.com/a.png")
        XCTAssertEqual(author.provider, "youtube")
        XCTAssertEqual(card.sourceUrl, "https://example.com/v/1")
        XCTAssertNotNil(card.publishedDate)
        XCTAssertEqual(card.rights?.license, "CC-BY-4.0")
    }

    /// 外层 quoted 三种 state：ok 带卡片（话题是字符串也能读），deleted / unavailable 只有 id；不认识的 state 当看不到。
    func testQuotedStates() throws {
        let response = try decode(FeedCardsResponse.self, """
        {"cards":[
          {"id":"a","state":"ok","card":{"kind":"post","quote_of":"q1"},"shareable":true,
           "quoted":{"id":"q1","state":"ok","card":{"kind":"post","text":"inner","topics":["food"]}}},
          {"id":"b","state":"ok","card":{"kind":"post","quote_of":"q2"},"quoted":{"id":"q2","state":"unavailable"}},
          {"id":"c","state":"ok","card":{"kind":"post","quote_of":"q3"},"quoted":{"id":"q3","state":"gone"}}]}
        """)
        let cards = response.cards.compactMap { $0.toCard() }
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].quoteOf, "q1")
        XCTAssertEqual(cards[0].quoted?.card?.text, "inner")
        XCTAssertEqual(cards[0].quoted?.card?.topics.map(\.slug), ["food"])
        XCTAssertFalse(cards[0].quoted?.deleted ?? true)
        XCTAssertNil(cards[1].quoted?.card)
        XCTAssertFalse(cards[1].quoted?.deleted ?? true)
        XCTAssertNil(cards[2].quoted?.card)
        XCTAssertFalse(cards[2].quoted?.deleted ?? true)
    }
}
