//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedEventsApiTests.swift (new file)
// `FeedAPI.events` end to end against a fake transport: wire shape of every event type, the 50 cap, no crash above it.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class TellomiFeedEventsApiTests: XCTestCase {
    private final class RecordingTransport: FeedHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests = [URLRequest]()
        var statusCode = 200
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        private func record(_ request: URLRequest) { lock.lock(); _requests.append(request); lock.unlock() }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (Data("{\"accepted\":1}".utf8), response)
        }
    }

    private struct FixedTokens: FeedTokenSource {
        func token(forceRefresh: Bool) async throws -> String { "tok" }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeAPI(_ transport: FeedHTTPTransport) -> FeedAPI {
        return FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens())
    }

    private func bodyString(_ request: URLRequest) -> String {
        return String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    /// 五种事件的线上形状：字段名、`value` 只在 dwell / quick_exit 里出现、`occurred_at` 是 RFC 3339。
    func testWireShapeOfEveryEventType() async throws {
        let transport = RecordingTransport()
        let api = makeAPI(transport)
        let events: [FeedEventPayload] = [
            .impression(contentId: "c1", tab: .recommend, at: t0),
            .open(contentId: "c1", surface: .search, at: t0),
            .dwell(contentId: "c1", surface: .following, seconds: 42.5, at: t0),
            .quickExit(contentId: "c1", surface: .profile, seconds: 1.25, at: t0),
            .share(contentId: "c1", surface: .recommend, at: t0),
        ]
        try await api.events(events)

        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/feed/events")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["events"])
        let sent = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(sent.map { $0["type"] as? String }, ["impression", "open", "dwell", "quick_exit", "share"])
        XCTAssertEqual(sent.map { $0["surface"] as? String }, ["recommend", "search", "following", "profile", "recommend"])
        XCTAssertEqual(sent.map { $0["value"] as? Double }, [nil, nil, 42.5, 1.25, nil])
        for event in sent {
            XCTAssertEqual(Set(event.keys).subtracting(["value"]), ["content_id", "type", "surface", "occurred_at"])
            XCTAssertEqual(event["content_id"] as? String, "c1")
            XCTAssertEqual(event["occurred_at"] as? String, FeedDates.format(t0))
        }
    }

    func testExactlyTheCapIsSentInOneRequest() async throws {
        let transport = RecordingTransport()
        let api = makeAPI(transport)
        let events = (0..<FeedAPI.maxEvents).map { FeedEventPayload.impression(contentId: "c\($0)", tab: .recommend, at: t0) }
        try await api.events(events)
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// 超过 50 条：抛错、不发请求、不崩溃（原来是 `precondition`，Android 是 `require`）。
    func testMoreThanTheCapThrowsInsteadOfCrashingAndSendsNothing() async {
        let transport = RecordingTransport()
        let api = makeAPI(transport)
        let events = (0...FeedAPI.maxEvents).map { FeedEventPayload.impression(contentId: "c\($0)", tab: .recommend, at: t0) }
        do {
            try await api.events(events)
            XCTFail("expected an error")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.code, FeedAPI.tooManyEventsCode)
            XCTAssertEqual(error.status, 0)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// 缓冲区一次攒了 51…230 条：每一批都不超过上限，全部能发出去。
    func testEveryDrainedBatchFitsTheCap() async throws {
        let transport = RecordingTransport()
        let api = makeAPI(transport)
        var buffer = FeedEventBuffer()
        for i in 0..<230 { _ = buffer.add(.impression(contentId: "c\(i)", tab: .following, at: t0)) }
        let batches = buffer.drain()
        XCTAssertEqual(batches.map(\.count), [50, 50, 50, 50, 30])
        for batch in batches { try await api.events(batch) }
        XCTAssertEqual(transport.requests.count, 5)
    }
}
