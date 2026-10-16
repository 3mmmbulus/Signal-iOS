//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// feed token 的来源：Signal-Server 签的短期 JWT（内容引擎 `internal/engine/auth`；契约第二节）。只在内存里，不落盘。
///
/// 正式实现从 Signal-Server `GET /v1/tellomi/feed/auth` 取（Signal-Server 这边还没写，契约第十一节第 1 条）。
protocol FeedTokenSource {
    /// 当前可用的 token；`forceRefresh` 为真时丢掉缓存重新取。
    func token(forceRefresh: Bool) async throws -> String
}

/// 发 HTTP 请求的那一层，单测换成假的。
protocol FeedHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionFeedTransport: FeedHTTPTransport {
    var session: URLSession = .shared

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// 内容引擎返回的错误。`code` 是错误体 `{"error": "…"}` 里的机器可读代码（契约 1.1）。
struct FeedAPIError: Error, Equatable {
    var status: Int
    var code: String?
    var retryAfterSeconds: Int?

    /// 引擎对每个接口都回 404 `feed_hidden`：不在内测名单，或这个区域的紧急开关关了。客户端隐藏入口，不显示空列表。
    var isFeedHidden: Bool {
        return status == 404 && code == "feed_hidden"
    }
}

/// 内容引擎的 HTTP 客户端，只做动态列表页要用的那几个接口。和 Android `FeedApi` 同一套路由。
///
/// - 401（`credential_expired` 等）时换一次 token 再试，**只重试一次**（契约 1.1）；
/// - 不在这里重试别的错误，也不缓存：缓存是调用方的事；
/// - 请求体只放契约列出的字段（引擎按 `DisallowUnknownFields` 解析，多一个字段就 400）。
final class FeedAPI {
    static let tabRecommend = "recommend"
    static let tabFollowing = "following"

    static let maxCardIds = 100
    /// 引擎一次最多收 50 条，超过整批拒收（content-engine `MaxEvents`），所以和攒批的 50 一样。
    static let maxEvents = 50

    enum Reaction: String {
        case like
        case save
    }

    private let baseURL: URL
    private let transport: FeedHTTPTransport
    private let tokens: FeedTokenSource

    init(baseURL: URL, transport: FeedHTTPTransport = URLSessionFeedTransport(), tokens: FeedTokenSource) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokens = tokens
    }

    /// 能不能看动态：不在内测名单或者紧急开关关了是 false。
    func status() async throws -> FeedStatus {
        return try await send(FeedStatus.self, request(path: ["v1", "feed", "status"]))
    }

    /// 一栏的一页 id：`tabApiName` 是 `recommend` 或 `following`。推荐不收 cursor（每次给新的一页）；
    /// `personalized` 只对推荐有用，个性化开关关掉时传 false（第三节第 47 条）。
    func feed(tabApiName: String, cursor: String?, personalized: Bool = true) async throws -> FeedIdsPage {
        precondition(tabApiName == Self.tabRecommend || tabApiName == Self.tabFollowing, "unknown tab \(tabApiName)")
        var query = [URLQueryItem]()
        if let cursor {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if tabApiName == Self.tabRecommend, !personalized {
            query.append(URLQueryItem(name: "personalized", value: "false"))
        }
        return try await send(FeedIdsPage.self, request(path: ["v1", "feed", tabApiName], query: query))
    }

    func cards(ids: [String]) async throws -> FeedCardsResponse {
        precondition(ids.count <= Self.maxCardIds, "at most \(Self.maxCardIds) ids per call")
        let body = try Self.encoder.encode(FeedCardsRequest(ids: ids))
        return try await send(FeedCardsResponse.self, request(path: ["v1", "feed", "cards"], method: "POST", body: body))
    }

    /// 点赞 / 收藏：PUT 加、DELETE 去，幂等。
    func setReaction(contentId: String, reaction: Reaction, on: Bool) async throws {
        try await sendNoContent(request(path: ["v1", "feed", "posts", contentId, reaction.rawValue], method: on ? "PUT" : "DELETE"))
    }

    func notInterested(contentId: String, reason: String?) async throws {
        let body = try Self.encoder.encode(FeedNotInterestedRequest(contentId: contentId, reason: reason))
        try await sendNoContent(request(path: ["v1", "feed", "not-interested"], method: "POST", body: body))
    }

    func undoNotInterested(contentId: String) async throws {
        try await sendNoContent(request(path: ["v1", "feed", "not-interested", contentId], method: "DELETE"))
    }

    /// 发帖。大陆区返回 `pending`（先审后发，R-2.2）；没建过主页返回 409 `profile_required`（契约 1.1）。
    func createPost(_ request: FeedCreatePostRequest) async throws -> FeedCreatePostResponse {
        let body = try Self.encoder.encode(request)
        return try await send(FeedCreatePostResponse.self, self.request(path: ["v1", "feed", "posts"], method: "POST", body: body))
    }

    /// 日志类事件，一批最多 50 条（引擎超过 50 条整批拒收）；失败由调用方丢弃，不重试（契约 6.1）。
    func events(_ events: [FeedEventPayload]) async throws {
        precondition(events.count <= Self.maxEvents, "at most \(Self.maxEvents) events per call")
        let body = try Self.encoder.encode(FeedEventsRequest(events: events))
        try await sendNoContent(request(path: ["v1", "feed", "events"], method: "POST", body: body))
    }

    // MARK: -

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private struct PendingRequest {
        var url: URL
        var method: String
        var body: Data?
    }

    private func request(path: [String], query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) -> PendingRequest {
        // 每一段单独转义（id 里的 `/`、`?`、`%` 也转），id 不会改到路由
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        let escaped = path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/" + escaped.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        return PendingRequest(url: components.url ?? baseURL, method: method, body: body)
    }

    private func send<T: Decodable>(_ type: T.Type, _ pending: PendingRequest) async throws -> T {
        let data = try await execute(pending)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendNoContent(_ pending: PendingRequest) async throws {
        _ = try await execute(pending)
    }

    private func execute(_ pending: PendingRequest) async throws -> Data {
        var (data, response) = try await transport.send(urlRequest(pending, token: tokens.token(forceRefresh: false)))
        if response.statusCode == 401 {
            (data, response) = try await transport.send(urlRequest(pending, token: tokens.token(forceRefresh: true)))
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = try? JSONDecoder().decode(FeedErrorBody.self, from: data)
            let retryAfter = (response.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) }
            throw FeedAPIError(status: response.statusCode, code: body?.error, retryAfterSeconds: retryAfter)
        }
        return data
    }

    private func urlRequest(_ pending: PendingRequest, token: String) -> URLRequest {
        var request = URLRequest(url: pending.url)
        request.httpMethod = pending.method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = pending.body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
