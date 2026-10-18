//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedSignerCore.swift (new file)
// The Foundation-only half of the Signal-Server signer (I-11): turns Signal-Server's answers to `friend-assertions` /
// `audience-lists` into results and errors. The UIKit half (`FeedSigner+UIKit.swift`) only carries the request over
// `TSRequest` and hands back the raw status / headers / body, so everything decided here is covered by the Linux harness.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Signal-Server 对一次签名请求的原始回答（任何状态码）。没收到回答（断网等）不是这个，是传输层抛的错。
struct FeedSignerHTTPResponse: Equatable, Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data?

    init(status: Int, headers: [String: String] = [:], body: Data? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// 头名不分大小写。
    func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }
}

/// 把一个已登录账号的请求发给 Signal-Server（`TSRequest`）。2xx 和非 2xx 都要原样回（有回答就不抛）；没有回答才抛。
protocol FeedSignerTransport: Sendable {
    func send(method: String, path: String, json: Data?) async throws -> FeedSignerHTTPResponse
}

/// `friend-assertions` 的 404 **没有**带 `account_not_found` 标记：这条路由没部署（或被反代 / 旧服务端吃掉）。
/// 好友同步当作「现在做不了」：不把好友记成已报，下次再来（见 `FeedFriendSync.Outcome.signerUnavailable`）。
struct FeedSignerUnavailable: Error, Equatable {
    var status: Int
}

enum FeedSignerMarkers {
    /// Signal-Server 在「这个 ACI 没有账号」时回的 404 的错误码（服务端 / iOS / Android 共用的约定，tellomi测试 2026-10-16）。
    static let accountNotFound = "account_not_found"
    static let maxMarkerBodyBytes = 4 * 1024

    /// 只有 **`Content-Type: application/json`（可带参数，如 `; charset=utf-8`，不分大小写）且 body 是 JSON 对象、`error` 恰好是 `account_not_found`** 才算。
    /// 没 body、别的 body、不是 JSON、Content-Type 不对或没有、body 过大、`error` 不是这个字符串，都不算。对象里多出来的别的字段不管（只看 `error`）。
    static func isAccountNotFound(_ response: FeedSignerHTTPResponse) -> Bool {
        guard response.status == 404,
              let contentType = response.header("Content-Type"),
              mediaType(of: contentType) == "application/json",
              let body = response.body, !body.isEmpty, body.count <= maxMarkerBodyBytes,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let code = object["error"] as? String else { return false }
        return code == accountNotFound
    }

    private static func mediaType(of contentType: String) -> String {
        let main = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? contentType
        return main.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// `SignalServerFeedSigner` 的逻辑部分：请求怎么组、回答怎么读、错误怎么分、被限速后怎么等。
///
/// 限速（I-21，tellomi测试 2026-10-16）：Signal-Server 回 429（或带 `Retry-After` 的 503）⇒ 错误里带 `Retry-After`（整数秒或 HTTP 日期，夹到 1…3600 秒）；
/// 在这之前同一条路由（好友声明 / 受众名单各自算）不再发请求，直接抛 429（带还剩几秒）；没有 `Retry-After` 的 429 按指数退避加抖动。
/// 好友同步遇到限速就停（`FeedFriendSync` 的 `.failed`），下次同步（至少 15 分钟后）若还在等待期里也不发请求。
final class FeedHTTPFriendSigner: FeedFriendSigning, @unchecked Sendable {
    static let assertionUnavailableCode = "assertion_unavailable"
    static let invalidAudienceCode = "invalid_audience"
    /// 受众名单被限速（429，或带 `Retry-After` 的 503）；和 Android `audience_throttled` 同名。其余失败仍是 `invalid_audience`。
    static let audienceThrottledCode = "audience_throttled"

    private let transport: FeedSignerTransport
    private let clock: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    private let lock = NSLock()
    private var gates = [String: FeedRetryGate]()

    init(
        transport: FeedSignerTransport,
        clock: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.transport = transport
        self.clock = clock
        self.jitter = jitter
    }

    func friendAssertion(peerAci: String, add: Bool) async throws -> String? {
        let response: FeedSignerHTTPResponse
        if add {
            let body = try JSONEncoder().encode(FeedFriendAssertionRequest(peerAci: peerAci))
            response = try await send("POST", FeedSignerPaths.friendAssertions, body, route: FeedSignerPaths.friendAssertions, failureCode: Self.assertionUnavailableCode)
        } else {
            response = try await send("DELETE", "\(FeedSignerPaths.friendAssertions)/\(peerAci)", nil, route: FeedSignerPaths.friendAssertions, failureCode: Self.assertionUnavailableCode)
        }
        guard (200..<300).contains(response.status) else {
            // 加好友时对方没有账号：服务端回 404 + `{"error":"account_not_found"}`（JSON）。**只有带这个标记的 404 才是「没账号」**，返回 nil（不用报）。
            if add && FeedSignerMarkers.isAccountNotFound(response) { return nil }
            // 其余的 404（没 body、别的 body、不是 JSON、路由不存在）= 路由没部署 / 现在用不了：不能当成「没账号」把好友记成已报。
            // 撤回（DELETE）服务端不查账号，所以撤回的 404 一律是路由问题（带不带标记都是）。
            if response.status == 404 { throw FeedSignerUnavailable(status: 404) }
            throw failure(response, route: FeedSignerPaths.friendAssertions, code: Self.assertionUnavailableCode)
        }
        guard let body = response.body, let decoded = try? JSONDecoder().decode(FeedFriendAssertionResponse.self, from: body) else {
            throw FeedAPIError(status: response.status, code: Self.assertionUnavailableCode, retryAfterSeconds: nil)
        }
        return decoded.assertion
    }

    func audienceToken(kind: String, peerAcis: [String]) async throws -> String {
        let body = try JSONEncoder().encode(FeedAudienceListRequest(kind: kind, peerAcis: peerAcis))
        let response = try await send("POST", FeedSignerPaths.audienceLists, body, route: FeedSignerPaths.audienceLists, failureCode: Self.invalidAudienceCode, throttledCode: Self.audienceThrottledCode)
        guard (200..<300).contains(response.status) else {
            throw failure(response, route: FeedSignerPaths.audienceLists, code: Self.invalidAudienceCode, throttledCode: Self.audienceThrottledCode)
        }
        guard let data = response.body, let decoded = try? JSONDecoder().decode(FeedAudienceListResponse.self, from: data) else {
            throw FeedAPIError(status: response.status, code: Self.invalidAudienceCode, retryAfterSeconds: nil)
        }
        return decoded.audienceToken
    }

    /// 非 2xx：带上解析好的 `Retry-After`；被限速就记下这条路由的等待。
    private func failure(_ response: FeedSignerHTTPResponse, route: String, code: String, throttledCode: String? = nil) -> FeedAPIError {
        var error = FeedAPIError(status: response.status, code: code, retryAfterSeconds: FeedRetryAfter.parse(response.header("Retry-After"), now: clock()))
        if error.isThrottle {
            error.code = throttledCode ?? code
            lock.lock(); defer { lock.unlock() }
            var gate = gates[route] ?? FeedRetryGate()
            gate.record(error, now: clock(), random: jitter())
            gates[route] = gate
        }
        return error
    }

    /// `NSLock` 不能在 async 函数里直接 lock / unlock（Swift 6 报错），所以锁只在这两个同步函数里拿。
    private func remainingWait(route: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return gates[route]?.remaining(now: clock()) ?? 0
    }

    private func clearGate(route: String) {
        lock.lock(); defer { lock.unlock() }
        gates[route] = nil
    }

    private func send(_ method: String, _ path: String, _ json: Data?, route: String, failureCode: String, throttledCode: String? = nil) async throws -> FeedSignerHTTPResponse {
        let wait = remainingWait(route: route)
        if wait > 0 {
            throw FeedAPIError(status: 429, code: throttledCode ?? failureCode, retryAfterSeconds: Int(wait.rounded(.up)))
        }
        do {
            let response = try await transport.send(method: method, path: path, json: json)
            if (200..<300).contains(response.status) {
                clearGate(route: route)
            }
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 没收到回答（断网、超时）
            throw FeedAPIError(status: 0, code: failureCode, retryAfterSeconds: nil)
        }
    }
}
