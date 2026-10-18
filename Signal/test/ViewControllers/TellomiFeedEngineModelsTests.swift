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
}
