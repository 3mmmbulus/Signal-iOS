//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedRemoteSourceTests.swift (new file)
// `RemoteFeedSource` against a fake transport: `config()` now reads `GET /v1/feed/config`; reposts are marked on the cards.
// JSON is hand-written from content-engine@b7b63aba (`api/server.go` config, `api/cards.go`), not captured from a live engine.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class TellomiFeedRemoteSourceTests: XCTestCase {
    /// 按路径回固定的 JSON，记下收到的请求。
    private final class RoutingTransport: FeedHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _paths = [String]()
        var routes = [String: String]()
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
        private func record(_ path: String) { lock.lock(); _paths.append(path); lock.unlock() }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            record(path)
            guard let body = routes[path] else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"error":"not_found"}"#.utf8), response)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private struct FixedTokens: FeedTokenSource {
        func token(forceRefresh: Bool) async throws -> String { "tok" }
    }

    private func makeSource(_ transport: RoutingTransport) -> RemoteFeedSource {
        let api = FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens())
        return RemoteFeedSource(api: api)
    }

    private func card(_ id: String) -> String {
        return #"{"id":"\#(id)","state":"ok","card":{"kind":"post","text":"t \#(id)","author":{"id":"p-\#(id)","display_name":"A"}}}"#
    }

    func testConfigComesFromTheConfigEndpointNotFromStatus() async throws {
        let transport = RoutingTransport()
        transport.routes["/v1/feed/config"] = """
        {"enabled":true,"region":"cn","tabs":["recommend","following"],"recommend_mode":"editorial_chronological",
         "personalization_toggle_visible":false,"hot_enabled":false,"ip_region_visible":true,"sensitive_more_available":false,
         "media_base_url":"https://m.example.test/","card_ttl_seconds":600,"minor_mode":true,
         "limits":{"post_text_chars":500,"post_images":10,"article_chars":10000,"edit_window_seconds":900,"voice_comment_max_seconds":60},
         "report_reasons":{"fraud":["scam"]},"rejection_reasons":["community_guidelines"]}
        """
        let config = try await makeSource(transport).config()
        XCTAssertEqual(transport.paths, ["/v1/feed/config"], "must not fall back to /status")
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.region, "cn")
        XCTAssertEqual(config.mediaBaseUrl, "https://m.example.test/")   // 老实现（只看 status）永远是 nil
        XCTAssertTrue(config.ipRegionVisible)
        XCTAssertTrue(config.minorMode)
        XCTAssertEqual(config.reportReasons["fraud"], ["scam"])
    }

    /// 引擎没开给这个人：config 仍然是 200，`enabled == false`。
    func testConfigWhenTheViewerCannotSeeTheFeed() async throws {
        let transport = RoutingTransport()
        transport.routes["/v1/feed/config"] = #"{"enabled":false,"region":"global","tabs":["recommend","following"]}"#
        let config = try await makeSource(transport).config()
        XCTAssertFalse(config.enabled)
    }

    func testRepostedCardsAreMarkedWithTheReposterId() async throws {
        let transport = RoutingTransport()
        transport.routes["/v1/feed/following"] = """
        {"items":[{"id":"a","reason":"repost","reposted_by":"p-friend"},{"id":"b","reason":"friend"},{"id":"c","reason":"repost"}],"cursor":"n"}
        """
        transport.routes["/v1/feed/cards"] = #"{"cards":[\#(card("a")),\#(card("b")),\#(card("c"))]}"#
        let page = try await makeSource(transport).timeline(tab: .following, cursor: nil)
        XCTAssertEqual(page.cards.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(page.cards[0].repostedBy, FeedRepostedBy(profileId: "p-friend", displayName: nil))
        XCTAssertNil(page.cards[1].repostedBy, "reason is not repost")
        XCTAssertNil(page.cards[2].repostedBy, "a repost without reposted_by is not marked")
        XCTAssertEqual(page.nextCursor, "n")
    }

    /// 没有转发的页面原样返回（顺序、内容都不变），不多发请求。
    func testPlainPageIsUntouched() async throws {
        let transport = RoutingTransport()
        transport.routes["/v1/feed/recommend"] = #"{"items":[{"id":"b"},{"id":"a"}]}"#
        transport.routes["/v1/feed/cards"] = #"{"cards":[\#(card("a")),\#(card("b"))]}"#
        let page = try await makeSource(transport).timeline(tab: .recommend, cursor: nil)
        XCTAssertEqual(page.cards.map(\.id), ["b", "a"])
        XCTAssertTrue(page.cards.allSatisfy { $0.repostedBy == nil })
        XCTAssertEqual(transport.paths, ["/v1/feed/recommend", "/v1/feed/cards"])
    }
}
