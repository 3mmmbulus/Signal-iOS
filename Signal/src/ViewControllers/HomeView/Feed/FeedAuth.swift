//
// DRAFT — NOT COMPILED. Written on Linux; needs a Mac + Xcode to build and test.
// Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedAuth.swift (new file)
// Mirror of Android feed/net/FeedAuth.kt (FeedAuthResponse, FeedAuthApi.getAuth, CachingFeedTokenSource).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// `GET /v1/tellomi/feed/auth` 的回包（契约第二节）。`region` 只用来选主机、做展示上的区域差异，不拿来做审核或过滤。
struct FeedAuthResponse: Decodable, Equatable {
    var token: String
    var expiresAt: String
    var region: String?

    private enum CodingKeys: String, CodingKey {
        case token, region
        case expiresAt = "expires_at"
    }
}

/// 取 token 的那一层，单测换成假的。
protocol FeedAuthFetching {
    func fetch() async throws -> FeedAuthResponse
}

/// `GET /v1/tellomi/feed/auth` 在服务器上不存在（**2026-10-16 起按「Signal-Server 还没部署这个接口」处理**，没有线上核实）。
/// 这种情况不能当成普通失败反复重试，也不能让动态页崩：入口检查保持「不可见」，token 源短时间内不再打网络。
extension FeedAPIError {
    static let authNotDeployedCode = "feed_auth_not_deployed"

    var isAuthNotDeployed: Bool {
        return code == Self.authNotDeployedCode
    }
}

enum FeedAuthFailure {
    static let unavailableCode = "auth_unavailable"
    /// 被限速（服务端回的，或 `CachingFeedTokenSource` 本地挡下的）；和 Android `auth_throttled` 同名。
    static let throttledCode = "auth_throttled"

    /// 404 / 405 / 501：这个路径没有处理器（接口没部署）。429 和带 `Retry-After` 的 503：被限速，错误里带等待秒数（`FeedRetryAfter`，1…3600），
    /// 调用方（`CachingFeedTokenSource`）在这之前不再问（I-21）。401/403（账号鉴权问题）、没带头的 503 / 别的 5xx 是别的毛病，返回 nil 让调用方按普通错误处理。
    static func classify(statusCode: Int?, retryAfter: String? = nil, now: Date = Date()) -> FeedAPIError? {
        guard let statusCode else { return nil }
        if [404, 405, 501].contains(statusCode) {
            return FeedAPIError(status: statusCode, code: FeedAPIError.authNotDeployedCode, retryAfterSeconds: nil)
        }
        let seconds = FeedRetryAfter.parse(retryAfter, now: now)
        if statusCode == 429 || (statusCode == 503 && seconds != nil) {
            return FeedAPIError(status: statusCode, code: throttledCode, retryAfterSeconds: seconds)
        }
        return nil
    }
}

/// 从 Signal-Server（`TellomiFeedController`，`GET /v1/tellomi/feed/auth`）取：走已登录的账号鉴权，和别的 `/v1/` 请求一样。
///
/// UNVERIFIED: `TSRequest(url:method:parameters:)` 默认带账号鉴权，`networkManager.asyncRequest` 返回
/// `HTTPResponse`（`responseBodyData`）——照 `IdentityKeyChecker.fetchIdentityPublicKey` 和
/// `TellomiAccountLogout.deletePushTokenRequest` 的写法推的，没有编译过。
struct SignalServerFeedAuthFetcher: FeedAuthFetching {
    static let path = "v1/tellomi/feed/auth"

    func fetch() async throws -> FeedAuthResponse {
        let request = TSRequest(url: URL(string: Self.path)!, method: "GET", parameters: nil)
        let response: HTTPResponse
        do {
            response = try await SSKEnvironment.shared.networkManagerRef.asyncRequest(request)
        } catch {
            // UNVERIFIED: `Error.httpStatusCode` (HTTPUtils.swift) — 接口没部署时 Signal-Server 回 404
            throw FeedAuthFailure.classify(statusCode: error.httpStatusCode, retryAfter: error.httpResponseHeaders?["Retry-After"]) ?? error
            // UNVERIFIED: `Error.httpResponseHeaders`（同 `FeedSigner+UIKit.swift`）；读不到头就是没有 `Retry-After`，429 走指数退避
        }
        guard let body = response.responseBodyData else {
            throw FeedAPIError(status: response.responseStatusCode, code: "auth_unavailable", retryAfterSeconds: nil)
        }
        return try JSONDecoder().decode(FeedAuthResponse.self, from: body)
    }
}

/// 内存里缓存 token（契约第二节：不落盘）。离过期不到 `refreshBefore` 时先换新的；
/// 引擎回 401 时 `FeedAPI` 用 `forceRefresh = true` 再取一次。并发的请求只发一次换取（actor 串行化）。
/// 和 Android `CachingFeedTokenSource` 同一套规则。
actor CachingFeedTokenSource: FeedTokenSource {
    static let refreshBefore: TimeInterval = 5 * 60
    /// 接口没部署（`isAuthNotDeployed`）之后，这么久之内直接失败、不打网络（包括 `forceRefresh`）。
    static let notDeployedBackoff: TimeInterval = 10 * 60

    private struct Cached {
        var token: String
        var expiresAt: Date
    }

    private let fetcher: FeedAuthFetching
    private let clock: () -> Date
    private let refreshBefore: TimeInterval
    private let notDeployedBackoff: TimeInterval
    private var cached: Cached?
    private var notDeployedSince: Date?
    /// 被限速（429 / 带 `Retry-After` 的 503）之后的等待（I-21）。
    private var throttle = FeedRetryGate()
    private let jitter: @Sendable () -> Double
    /// 正在进行的那一次换取：别的调用直接等它，不再发第二次（Android 用 Mutex 把整个换取锁住，效果一样）。
    private var inFlight: Task<FeedAuthResponse, Error>?
    /// `clear()` 每调一次加一：换取期间被清掉（退出登录、切区）的结果不进缓存。
    private var generation = 0

    init(
        fetcher: FeedAuthFetching,
        refreshBefore: TimeInterval = CachingFeedTokenSource.refreshBefore,
        notDeployedBackoff: TimeInterval = CachingFeedTokenSource.notDeployedBackoff,
        clock: @escaping () -> Date = Date.init,
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
    ) {
        self.fetcher = fetcher
        self.refreshBefore = refreshBefore
        self.notDeployedBackoff = notDeployedBackoff
        self.clock = clock
        self.jitter = jitter
    }

    func token(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cached, clock() < cached.expiresAt.addingTimeInterval(-refreshBefore) {
            return cached.token
        }
        // 刚确认过接口没部署：先别问了。时钟往回拨过（现在早于记录的时刻）当作已过期，再问一次。
        let now = clock()
        if let since = notDeployedSince, (0..<notDeployedBackoff).contains(now.timeIntervalSince(since)) {
            throw FeedAPIError(status: 404, code: FeedAPIError.authNotDeployedCode, retryAfterSeconds: nil)
        }
        // 刚被限速：到 `Retry-After`（或指数退避）为止不再问，包括 `forceRefresh`；不打网络，直接抛 429（带还剩几秒）
        let wait = throttle.remaining(now: now)
        if wait > 0 {
            throw FeedAPIError(status: 429, code: FeedAuthFailure.throttledCode, retryAfterSeconds: Int(wait.rounded(.up)))
        }
        // actor 在 `await` 处会让出，所以两个调用可能同时走到这里。已经有一次在换了就等它的结果
        // （和 Android `CachingFeedTokenSource` 的「并发的请求只发一次换取」同一条规则）。
        // 和 Android 的一点差别：Android 里 `forceRefresh` 的调用各自再换一次（排队）；这里碰上正在进行的换取就共用它，
        // 那次换取拿到的一定比调用方手里被引擎拒掉的那个新。
        if let running = inFlight {
            return try await running.value.token
        }

        let startedIn = generation
        let task = Task { [fetcher] in try await fetcher.fetch() }
        inFlight = task
        let response: FeedAuthResponse
        do {
            response = try await task.value
        } catch let error as FeedAPIError where error.isAuthNotDeployed {
            if startedIn == generation {
                inFlight = nil
                notDeployedSince = now
                cached = nil
            }
            throw error
        } catch {
            if startedIn == generation {
                inFlight = nil
                if let apiError = error as? FeedAPIError { throttle.record(apiError, now: clock(), random: jitter()) }
            }
            throw error
        }
        guard startedIn == generation else {
            // 换取期间被 `clear()` 了（`inFlight` 也已被它清掉，可能已经有新的一次在跑）：这次的 token 用上，但不留下
            return response.token
        }
        inFlight = nil
        notDeployedSince = nil
        throttle.reset()
        // 过期时间读不懂就不缓存：这次用上，下次再换（Android 同）
        if let expiresAt = FeedDates.parse(response.expiresAt) {
            cached = Cached(token: response.token, expiresAt: expiresAt)
        } else {
            cached = nil
        }
        return response.token
    }

    /// 退出登录、切区时丢掉缓存。
    func clear() {
        cached = nil
        notDeployedSince = nil
        throttle.reset()
        generation += 1
        inFlight = nil
    }
}
