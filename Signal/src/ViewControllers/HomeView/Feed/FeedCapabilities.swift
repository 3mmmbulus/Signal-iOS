//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedCapabilities.swift (new file)
// Client for the content-engine's unauthenticated `GET /v1/capabilities` (content-engine branch `bot/engine-capabilities-r1`, 821ec29;
// docs/api.md「能力查询（不要凭证）」) and the gate the friend features (I-11) sit behind.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux 测试用；iOS 上不存在这个模块，这几行不生效
#endif

/// 引擎 `features` 里的名字（`docs/api.md`）。没有 `friend_sync` / `friend_report`——好友相关只有 `friend_assertions`。
enum FeedFeature {
    static let feed = "feed"
    static let events = "events"
    static let posting = "posting"
    /// 发帖的 `audience.audience_token`（Signal-Server 签的名单）。「部分好友 / 屏蔽某些人」靠它。
    static let audienceTokens = "audience_tokens"
    static let comments = "comments"
    static let voiceComments = "voice_comments"
    static let reactions = "reactions"
    static let polls = "polls"
    static let mediaUpload = "media_upload"
    static let mediaUrl = "media_url"
    /// `POST / PUT / DELETE /v1/feed/friends`：好友声明。好友同步、好友入口靠它。
    static let friendAssertions = "friend_assertions"
    static let follow = "follow"
    static let blocks = "blocks"
    static let profiles = "profiles"
    static let search = "search"
    static let topics = "topics"
    static let notifications = "notifications"
    static let reports = "reports"
}

enum FeedCapabilitiesError: Error, Equatable {
    /// 404：引擎太旧，没有这个路由（或反代没放行）。
    case notFound
    case http(Int)
    /// 429，或带 `Retry-After` 的 503（I-21）：值是头里的秒数（夹到 1…3600），没有头就是 nil（429 无头时缓存按指数退避）。
    case throttled(retryAfterSeconds: Int?)
    case malformed
    case timeout
    case transport
}

/// `{"version":1,"features":["feed",…]}`。
///
/// **`version` 必须是整数 1，否则整个回包当作「没有能力检查」**（tellomi测试 2026-10-16 定，和 Android `FeedCapabilities.parseOrNull` 一致）：
/// 以后引擎换了回包形状会升版本号，旧客户端宁可把所有受控功能都关掉（和 404 / 失败一样），也不去猜。
/// 不认的有：缺 `version`、`0`、`2`、负数、`"1"`（字符串）、`1.0` / `1e0`（浮点）、`true`、`null`、对象、数组 ⇒ `malformed`，`features` 一个都不读。
/// 版本对了之后宽松解析：顶层是对象、`features` 是数组；数组里不是字符串的元素丢掉，不认识的名字照留（引擎以后会加）。
struct FeedCapabilities: Equatable, Sendable {
    /// 认得的协议版本。
    static let supportedVersion = 1

    var version: Int
    var features: Set<String>

    init(version: Int = FeedCapabilities.supportedVersion, features: Set<String>) {
        self.version = version
        self.features = features
    }

    static func parse(_ data: Data) throws -> FeedCapabilities {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              isSupportedVersion(object["version"]),
              let list = object["features"] as? [Any] else { throw FeedCapabilitiesError.malformed }
        return FeedCapabilities(version: supportedVersion, features: Set(list.compactMap { $0 as? String }))
    }

    /// 只认 JSON 整数 1：布尔（`objCType` 是 `c`）、浮点（`d` / `f`）、字符串、null 都不算。
    private static func isSupportedVersion(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let type = String(cString: number.objCType)
        if type == "c" || type == "d" || type == "f" { return false }
        return number.int64Value == Int64(supportedVersion)
    }
}

/// 问一次的结果。`unavailable` = 当作什么功能都没有。
enum FeedCapabilitiesSnapshot: Equatable, Sendable {
    case available(FeedCapabilities)
    case unavailable(FeedCapabilitiesError)

    func has(_ feature: String) -> Bool {
        if case let .available(capabilities) = self { return capabilities.features.contains(feature) }
        return false
    }
}

/// 功能开没开的问法。真的实现是 `FeedCapabilitiesCache`；测试和预览用 `StaticFeedFeatureGate`。
protocol FeedFeatureGate: Sendable {
    func isAvailable(_ feature: String) async -> Bool
}

struct StaticFeedFeatureGate: FeedFeatureGate {
    var features: Set<String>

    init(_ features: Set<String>) { self.features = features }

    func isAvailable(_ feature: String) async -> Bool { features.contains(feature) }
}

protocol FeedCapabilitiesFetching: Sendable {
    func fetch() async throws -> FeedCapabilities
}

/// `GET <引擎>/v1/capabilities`：不带凭证（所以不走 `FeedAPI`，它每个请求都带 Bearer），每次都真去问（缓存是 `FeedCapabilitiesCache` 的事）。
/// 不管 `FeedHTTPTransport` 自己有没有超时，这里再给 `timeout` 秒的硬上限（挂住的连接也会放手）。
final class FeedCapabilitiesFetcher: FeedCapabilitiesFetching, @unchecked Sendable {
    static let maxBodyBytes = 64 * 1024

    private let baseURL: URL
    private let transport: FeedHTTPTransport
    private let timeout: TimeInterval
    private let clock: @Sendable () -> Date

    init(baseURL: URL, transport: FeedHTTPTransport = URLSessionFeedTransport(), timeout: TimeInterval = 5, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.transport = transport
        self.timeout = timeout
        self.clock = clock
    }

    func request() -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/v1/capabilities"
        var request = URLRequest(url: components.url ?? baseURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 响应自己带 max-age=60；这里的缓存是 `FeedCapabilitiesCache` 管，不让系统的 URL 缓存再叠一层
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        return request
    }

    func fetch() async throws -> FeedCapabilities {
        let request = request()
        let nanos = UInt64(max(timeout, 0.001) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: FeedCapabilities.self) { group in
            group.addTask { try await self.perform(request) }
            group.addTask {
                try await Task.sleep(nanoseconds: nanos)
                throw FeedCapabilitiesError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw FeedCapabilitiesError.transport }
            return first
        }
    }

    private func perform(_ request: URLRequest) async throws -> FeedCapabilities {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as FeedCapabilitiesError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw FeedCapabilitiesError.timeout
        } catch {
            throw FeedCapabilitiesError.transport
        }
        switch response.statusCode {
        case 200..<300:
            guard data.count <= Self.maxBodyBytes else { throw FeedCapabilitiesError.malformed }
            return try FeedCapabilities.parse(data)
        case 404:
            throw FeedCapabilitiesError.notFound
        default:
            let seconds = FeedRetryAfter.parse(response.value(forHTTPHeaderField: "Retry-After"), now: clock())
            if response.statusCode == 429 || (response.statusCode == 503 && seconds != nil) {
                throw FeedCapabilitiesError.throttled(retryAfterSeconds: seconds)
            }
            throw FeedCapabilitiesError.http(response.statusCode)
        }
    }
}

/// 缓存「引擎有什么功能」。每个引擎地址一份（引擎地址变了就新建一个）。
///
/// 规则：
/// - 成功：缓存 `ttl`（默认 60 秒，和响应的 `Cache-Control: max-age=60` 一样）。
/// - 失败（断网、超时、5xx、解析不了）：当作什么功能都没有，**不拿旧的顶**，缓存 `failureTTL`（默认 30 秒）再试，免得每次进前台都等一次超时。
/// - 404（引擎太旧）：当作什么功能都没有，缓存 `notFoundTTL`（默认 10 分钟；部署了新版自然会好）。
/// - 同时来很多问的只发一次请求；时钟被调回去算过期；`invalidate()` 丢掉缓存（换引擎、用户点重试）。
actor FeedCapabilitiesCache: FeedFeatureGate {
    static let defaultTTL: TimeInterval = 60
    static let defaultFailureTTL: TimeInterval = 30
    static let defaultNotFoundTTL: TimeInterval = 10 * 60

    private struct Entry {
        var snapshot: FeedCapabilitiesSnapshot
        var fetchedAt: Date
        var ttl: TimeInterval
    }

    private let fetcher: FeedCapabilitiesFetching
    private let ttl: TimeInterval
    private let failureTTL: TimeInterval
    private let notFoundTTL: TimeInterval
    private let clock: @Sendable () -> Date
    private var entry: Entry?
    private var inflight: Task<FeedCapabilitiesSnapshot, Never>?
    private var generation = 0
    /// 连续被限速几次（没有 `Retry-After` 时按它指数退避；一次不是限速的结果就清零）。
    private var throttleStreak = 0
    private let jitter: @Sendable () -> Double

    init(
        fetcher: FeedCapabilitiesFetching,
        ttl: TimeInterval = FeedCapabilitiesCache.defaultTTL,
        failureTTL: TimeInterval = FeedCapabilitiesCache.defaultFailureTTL,
        notFoundTTL: TimeInterval = FeedCapabilitiesCache.defaultNotFoundTTL,
        clock: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.fetcher = fetcher
        self.jitter = jitter
        self.ttl = ttl
        self.failureTTL = failureTTL
        self.notFoundTTL = notFoundTTL
        self.clock = clock
    }

    func current() async -> FeedCapabilitiesSnapshot {
        let now = clock()
        if let entry {
            let age = now.timeIntervalSince(entry.fetchedAt)
            if age >= 0, age < entry.ttl { return entry.snapshot }
        }
        if let inflight { return await inflight.value }
        let fetcher = self.fetcher
        let startedGeneration = generation
        let task = Task<FeedCapabilitiesSnapshot, Never> {
            do {
                return .available(try await fetcher.fetch())
            } catch let error as FeedCapabilitiesError {
                return .unavailable(error)
            } catch {
                return .unavailable(.transport)
            }
        }
        inflight = task
        let snapshot = await task.value
        // 问的过程中被 invalidate 了：这次的结果只给等着的人，不进缓存
        if generation == startedGeneration {
            let lifetime: TimeInterval
            switch snapshot {
            case .available: lifetime = ttl
            case .unavailable(.notFound): lifetime = notFoundTTL
            case let .unavailable(.throttled(seconds)):
                // 被限速：至少等 `Retry-After`（没有就指数退避），但不短于普通失败的 `failureTTL`
                throttleStreak += 1
                let wait = seconds.map(FeedRetryAfter.clamp) ?? FeedBackoff.delay(attempt: throttleStreak, random: jitter())
                lifetime = max(failureTTL, TimeInterval(wait))
            case .unavailable: lifetime = failureTTL
            }
            if case .unavailable(.throttled) = snapshot {} else { throttleStreak = 0 }
            entry = Entry(snapshot: snapshot, fetchedAt: clock(), ttl: lifetime)
            inflight = nil
        }
        return snapshot
    }

    func isAvailable(_ feature: String) async -> Bool {
        return await current().has(feature)
    }

    func invalidate() {
        generation += 1
        entry = nil
        inflight = nil
    }
}
