//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedSignerResponseTests.swift (new file)
// I-11: the 404 `account_not_found` marker on `friend-assertions` (shared server / iOS / Android rule) and what friend sync does
// with a 404 that does not carry it.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

private struct Boom: Error {}

private final class SignerLog<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [T]()
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class ScriptedSignerTransport: FeedSignerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies = [Result<FeedSignerHTTPResponse, Error>]()
    let requests = SignerLog<String>()
    let bodies = SignerLog<String>()

    func reply(_ status: Int, _ body: String? = nil, contentType: String? = nil, headers: [String: String] = [:]) {
        var all = headers
        if let contentType { all["Content-Type"] = contentType }
        lock.lock(); replies.append(.success(FeedSignerHTTPResponse(status: status, headers: all, body: body.map { Data($0.utf8) }))); lock.unlock()
    }
    func fail(_ error: Error) { lock.lock(); replies.append(.failure(error)); lock.unlock() }

    func send(method: String, path: String, json: Data?) async throws -> FeedSignerHTTPResponse {
        requests.append("\(method) \(path)")
        bodies.append(json.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        let next = lock.locked {
            replies.isEmpty ? Result<FeedSignerHTTPResponse, Error>.failure(Boom()) : replies.removeFirst()
        }
        return try next.get()
    }
}

private let aci = "11111111-2222-3333-4444-555555555555"
private let marker = #"{"error":"account_not_found"}"#

final class TellomiFeedSignerResponseTests: XCTestCase {
    private func signer(_ transport: ScriptedSignerTransport) -> FeedHTTPFriendSigner { FeedHTTPFriendSigner(transport: transport) }

    // MARK: the marker

    func testA404WithTheMarkerMeansThePeerHasNoAccount() async throws {
        for contentType in ["application/json", "application/json; charset=utf-8", "Application/JSON", "application/json;charset=UTF-8", " application/json "] {
            let transport = ScriptedSignerTransport()
            transport.reply(404, marker, contentType: contentType)
            let result = try await signer(transport).friendAssertion(peerAci: aci, add: true)
            XCTAssertNil(result, "标记 + \(contentType) = 没账号")
        }
        // 头名不分大小写；多出来的字段不管
        let transport = ScriptedSignerTransport()
        transport.reply(404, #"{"error":"account_not_found","detail":"x"}"#, headers: ["content-type": "application/json"])
        let result = try await signer(transport).friendAssertion(peerAci: aci, add: true)
        XCTAssertNil(result)
    }

    /// 没带标记的 404 一律是「没部署 / 现在用不了」，不是「没账号」。
    func testAny404WithoutTheMarkerIsUnavailableNeverNoAccount() async {
        let cases: [(String, String?, String?)] = [
            ("no body, no content type", nil, nil),
            ("empty body", "", "application/json"),
            ("no content type", marker, nil),
            ("text/plain content type", marker, "text/plain"),
            ("html content type", marker, "text/html; charset=utf-8"),
            ("problem+json is not application/json", marker, "application/problem+json"),
            ("other json type", marker, "application/jsonp"),
            ("other error", #"{"error":"peer_not_found"}"#, "application/json"),
            ("marker spelled differently", #"{"error":"Account_Not_Found"}"#, "application/json"),
            ("marker in another key", #"{"code":"account_not_found"}"#, "application/json"),
            ("marker not a string", #"{"error":["account_not_found"]}"#, "application/json"),
            ("marker as plain text", "account_not_found", "application/json"),
            ("marker as plain text with text type", "account_not_found", "text/plain"),
            ("json string", #""account_not_found""#, "application/json"),
            ("json array", #"[{"error":"account_not_found"}]"#, "application/json"),
            ("json null", "null", "application/json"),
            ("route missing: html", "<html>404 Not Found</html>", "text/html"),
            ("route missing: plain 404 page", "404 page not found", "text/plain; charset=utf-8"),
            ("broken json", #"{"error":"account_not_found""#, "application/json"),
            ("oversized body", #"{"error":"account_not_found","pad":""#.appending(String(repeating: "x", count: 5_000)) + #""}"#, "application/json"),
        ]
        for (name, body, contentType) in cases {
            let transport = ScriptedSignerTransport()
            transport.reply(404, body, contentType: contentType)
            do {
                let result = try await signer(transport).friendAssertion(peerAci: aci, add: true)
                XCTFail("\(name): 应该是不可用，却返回了 \(String(describing: result))")
            } catch {
                XCTAssertEqual(error as? FeedSignerUnavailable, FeedSignerUnavailable(status: 404), name)
            }
        }
    }

    func testAWithdrawalNeverTreatsA404AsNoAccount() async {
        for (body, contentType) in [(marker, "application/json"), (nil, nil)] as [(String?, String?)] {
            let transport = ScriptedSignerTransport()
            transport.reply(404, body, contentType: contentType)
            do {
                _ = try await signer(transport).friendAssertion(peerAci: aci, add: false)
                XCTFail("撤回的 404 不能当成功")
            } catch {
                XCTAssertEqual(error as? FeedSignerUnavailable, FeedSignerUnavailable(status: 404))
            }
            XCTAssertEqual(transport.requests.all, ["DELETE v1/tellomi/feed/friend-assertions/\(aci)"])
        }
    }

    func testOtherStatusesKeepTheirOwnErrorAndOnlyA404IsSpecial() async throws {
        for status in [400, 401, 403, 405, 410, 422, 429, 500, 501, 502, 503] {
            let transport = ScriptedSignerTransport()
            transport.reply(status, marker, contentType: "application/json")   // 标记只对 404 有意义
            do {
                _ = try await signer(transport).friendAssertion(peerAci: aci, add: true)
                XCTFail("\(status) 应该抛")
            } catch {
                XCTAssertEqual(error as? FeedAPIError, FeedAPIError(status: status, code: "assertion_unavailable", retryAfterSeconds: nil), "\(status)")
            }
        }
        // 没回答（断网）：状态 0
        let offline = ScriptedSignerTransport()
        offline.fail(URLError(.notConnectedToInternet))
        do {
            _ = try await signer(offline).friendAssertion(peerAci: aci, add: true)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? FeedAPIError, FeedAPIError(status: 0, code: "assertion_unavailable", retryAfterSeconds: nil))
        }
        // 成功
        let ok = ScriptedSignerTransport()
        ok.reply(200, #"{"assertion":"signed"}"#, contentType: "application/json")
        let signed = try await signer(ok).friendAssertion(peerAci: aci, add: true)
        XCTAssertEqual(signed, "signed")
        XCTAssertEqual(ok.requests.all, ["POST v1/tellomi/feed/friend-assertions"])
        XCTAssertEqual(ok.bodies.all, [#"{"peer_aci":"\#(aci)"}"#])
        let broken = ScriptedSignerTransport()
        broken.reply(200, "not json", contentType: "application/json")
        do {
            _ = try await signer(broken).friendAssertion(peerAci: aci, add: true)
            XCTFail()
        } catch {
            XCTAssertEqual((error as? FeedAPIError)?.status, 200)
        }
    }

    func testAudienceListsKeepTheirErrorMappingAndAre404SafeToo() async throws {
        let ok = ScriptedSignerTransport()
        ok.reply(200, #"{"audience_token":"tok"}"#, contentType: "application/json")
        let token = try await signer(ok).audienceToken(kind: "include", peerAcis: [aci])
        XCTAssertEqual(token, "tok")
        XCTAssertEqual(ok.requests.all, ["POST v1/tellomi/feed/audience-lists"])
        for status in [400, 404, 422, 429, 503] {
            let transport = ScriptedSignerTransport()
            transport.reply(status, marker, contentType: "application/json")
            do {
                _ = try await signer(transport).audienceToken(kind: "exclude", peerAcis: [aci])
                XCTFail()
            } catch {
                XCTAssertEqual(error as? FeedAPIError, FeedAPIError(status: status, code: status == 429 ? "audience_throttled" : "invalid_audience", retryAfterSeconds: nil), "\(status)")
            }
        }
    }
}

// MARK: - friend sync with a real signer on a scripted transport

private final class SyncEnv: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = FeedDates.parse("2026-10-13T12:00:00Z")!
    var now: Date { get { lock.lock(); defer { lock.unlock() }; return _now } set { lock.lock(); _now = newValue; lock.unlock() } }
    let engineCalls = SignerLog<String>()
}

final class TellomiFeedFriendSyncMarkerTests: XCTestCase {
    private let a = "aaaaaaaa-0000-0000-0000-000000000001"
    private let b = "bbbbbbbb-0000-0000-0000-000000000002"

    private func make(_ env: SyncEnv, _ transport: ScriptedSignerTransport, friends: Set<String>, state: FeedFriendSyncState = InMemoryFeedFriendSyncState()) -> (FeedFriendSync, FeedFriendSyncState) {
        let sync = FeedFriendSync(
            enabled: { true },
            engineKey: { "cn https://feed.example.test" },
            friends: { friends },
            signer: FeedHTTPFriendSigner(transport: transport),
            engine: { env.engineCalls.append($0) },
            state: state,
            features: StaticFeedFeatureGate([FeedFeature.friendAssertions]),
            clock: { env.now }
        )
        return (sync, state)
    }

    /// 带标记的 404：这位好友没账号，记成已报（不再重试）；下一位照常签。
    func testAnAccountNotFoundFriendIsMarkedReportedAndTheNextOneIsSigned() async {
        let env = SyncEnv(), transport = ScriptedSignerTransport()
        transport.reply(404, marker, contentType: "application/json")
        transport.reply(200, #"{"assertion":"s-b"}"#, contentType: "application/json")
        let (sync, state) = make(env, transport, friends: [a, b])
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(state.reported(engineKey: "cn https://feed.example.test"), [a, b])
        XCTAssertEqual(env.engineCalls.all, ["s-b"], "没账号的没交给引擎")
    }

    /// 没带标记的 404：好友不能记成已报，也不继续（后面的也会 404）；15 分钟内不再问；之后再试一次，这回路由好了就全报上。
    func testA404WithoutTheMarkerStopsSyncMarksNobodyAndRetriesLater() async {
        let env = SyncEnv(), transport = ScriptedSignerTransport()
        transport.reply(404, "404 page not found", contentType: "text/plain; charset=utf-8")
        let (sync, state) = make(env, transport, friends: [a, b])
        let first = await sync.syncIfStale()
        XCTAssertEqual(first, .signerUnavailable)
        XCTAssertEqual(state.reported(engineKey: "cn https://feed.example.test"), [], "一个都不能记成已报")
        XCTAssertEqual(transport.requests.all.count, 1, "第一个 404 就停，不对其他好友再试")
        XCTAssertTrue(env.engineCalls.all.isEmpty)
        XCTAssertNotNil(state.checkedAt, "记了检查时间：15 分钟的间隔就是退避")

        env.now = env.now.addingTimeInterval(FeedFriendSync.interval - 1)
        let tooSoon = await sync.syncIfStale()
        XCTAssertEqual(tooSoon, .skipped)
        XCTAssertEqual(transport.requests.all.count, 1, "间隔内不再去问服务端")

        env.now = env.now.addingTimeInterval(2)
        transport.reply(200, #"{"assertion":"s-a"}"#, contentType: "application/json")
        transport.reply(200, #"{"assertion":"s-b"}"#, contentType: "application/json")
        let later = await sync.syncIfStale()
        XCTAssertEqual(later, .done)
        XCTAssertEqual(state.reported(engineKey: "cn https://feed.example.test"), [a, b])
        XCTAssertEqual(env.engineCalls.all, ["s-a", "s-b"])
    }

    /// 前面几个已经签成功的留着；第 3 个遇到没标记的 404：只停在这里。
    func testFriendsReportedBeforeAnUnmarked404StayReported() async {
        let env = SyncEnv(), transport = ScriptedSignerTransport()
        transport.reply(200, #"{"assertion":"s-a"}"#, contentType: "application/json")
        transport.reply(404, nil)
        let (sync, state) = make(env, transport, friends: [a, b])
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .signerUnavailable)
        XCTAssertEqual(state.reported(engineKey: "cn https://feed.example.test"), [a])
        XCTAssertEqual(env.engineCalls.all, ["s-a"])
    }

    /// 撤回遇到 404（带不带标记）也一样：不当成撤回成功。
    func testAWithdrawalThatGets404IsNotMarkedWithdrawn() async {
        let env = SyncEnv(), transport = ScriptedSignerTransport()
        let state = InMemoryFeedFriendSyncState()
        state.save(engineKey: "cn https://feed.example.test", acis: [a])
        transport.reply(404, marker, contentType: "application/json")
        let (sync, _) = make(env, transport, friends: [], state: state)
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .signerUnavailable)
        XCTAssertEqual(state.reported(engineKey: "cn https://feed.example.test"), [a], "撤回没成，名字还在")
    }

    /// 别的错（500 等）仍是 `.failed`，不是 `.signerUnavailable`。
    func testOtherFailuresStayFailed() async {
        let env = SyncEnv(), transport = ScriptedSignerTransport()
        transport.reply(500, "oops")
        let (sync, state) = make(env, transport, friends: [a])
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(state.reported(engineKey: "cn https://feed.example.test"), [])
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
