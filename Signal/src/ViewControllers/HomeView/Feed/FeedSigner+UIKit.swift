//
// DRAFT — NOT COMPILED ON A MAC, PARSE-ONLY ON LINUX. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedSigner+UIKit.swift (new file)
// The transport of `FeedHTTPFriendSigner` (I-11, logic in `FeedSignerCore.swift`) over Signal-Server's authenticated requests.
// Same pattern as `SignalServerFeedAuthFetcher` (I-0). It only carries the request and hands back status / headers / body; every
// decision (which 404 means "no account", what is "unavailable", errors) is made in `FeedSignerCore.swift` and tested there.
//
// UNVERIFIED (never type-checked): `TSRequest(url:method:parameters:)`, `SSKEnvironment.shared.networkManagerRef.asyncRequest`,
// `HTTPResponse.responseBodyData` / `responseHeaders`, and — new — how the thrown `OWSHTTPError` exposes the status, the response
// headers (`Content-Type`, `Retry-After`) and the response body of a non-2xx answer (`httpStatusCode`, `httpResponseHeaders`,
// `httpResponseData` are written from memory of `OWSHTTPError`). If an error does not carry the body / headers, a 404 will not
// show the `account_not_found` marker and friend sync will treat every 404 as "unavailable" (safe direction, never marks a friend reported).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

struct SignalServerFeedSignerTransport: FeedSignerTransport {
    func send(method: String, path: String, json: Data?) async throws -> FeedSignerHTTPResponse {
        var parameters: [String: Any]?
        if let json {
            parameters = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        }
        let request = TSRequest(url: URL(string: path)!, method: method, parameters: parameters)
        do {
            let response = try await SSKEnvironment.shared.networkManagerRef.asyncRequest(request)
            return FeedSignerHTTPResponse(status: response.responseStatusCode, headers: response.headers.headers, body: response.responseBodyData)
        } catch {
            // 服务端回了非 2xx：把状态、头、body 原样交出去；没有状态码 = 没收到回答，原样抛
            guard let status = error.httpStatusCode else { throw error }
            return FeedSignerHTTPResponse(status: status, headers: error.httpResponseHeaders?.headers ?? [:], body: error.httpResponseData)
        }
    }
}

/// 真的签名器（`FeedSources` 里 `SignalServerFeedSigner()`）：逻辑在 `FeedHTTPFriendSigner`，这里只接上 `TSRequest`。
struct SignalServerFeedSigner: FeedFriendSigning {
    /// 限速的等待记在 `FeedHTTPFriendSigner` 里；`SignalServerFeedSigner()` 每处都会新建一个，所以这个对象全局共用一个。
    private static let core = FeedHTTPFriendSigner(transport: SignalServerFeedSignerTransport())

    init() {}

    func friendAssertion(peerAci: String, add: Bool) async throws -> String? {
        return try await Self.core.friendAssertion(peerAci: peerAci, add: add)
    }

    func audienceToken(kind: String, peerAcis: [String]) async throws -> String {
        return try await Self.core.audienceToken(kind: kind, peerAcis: peerAcis)
    }
}
