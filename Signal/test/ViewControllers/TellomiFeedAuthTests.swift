//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedAuthTests.swift (new file)
// Tests for CachingFeedTokenSource (FeedAuth.swift) and FeedEntryCheck (FeedEntryCheck.swift).
// Mirrors Android CachingFeedTokenSource / FeedEntryCheck unit tests' intent.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class TellomiFeedAuthTests: XCTestCase {
    private final class FakeFetcher: FeedAuthFetching, @unchecked Sendable {
        var calls = 0
        var expiresAt: String
        init(expiresAt: String) { self.expiresAt = expiresAt }
        func fetch() async throws -> FeedAuthResponse {
            calls += 1
            return FeedAuthResponse(token: "t\(calls)", expiresAt: expiresAt, region: "global")
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTokenIsCachedUntilFiveMinutesBeforeExpiry() async throws {
        let fetcher = FakeFetcher(expiresAt: FeedDates.format(t0.addingTimeInterval(3600)))
        var now = t0
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { now })
        let first = try await source.token(forceRefresh: false)
        let second = try await source.token(forceRefresh: false)
        XCTAssertEqual(first, "t1")
        XCTAssertEqual(second, "t1")
        XCTAssertEqual(fetcher.calls, 1)

        now = t0.addingTimeInterval(3600 - 4 * 60) // 离过期 4 分钟：该换了
        let third = try await source.token(forceRefresh: false)
        XCTAssertEqual(third, "t2")
        XCTAssertEqual(fetcher.calls, 2)
    }

    func testForceRefreshAlwaysFetches() async throws {
        let fetcher = FakeFetcher(expiresAt: FeedDates.format(t0.addingTimeInterval(3600)))
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { self.t0 })
        _ = try await source.token(forceRefresh: false)
        let refreshed = try await source.token(forceRefresh: true)
        XCTAssertEqual(refreshed, "t2")
    }

    /// 过期时间读不懂：这次用上，下次再换（不缓存）。
    func testUnparseableExpiryIsNotCached() async throws {
        let fetcher = FakeFetcher(expiresAt: "not a date")
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { self.t0 })
        _ = try await source.token(forceRefresh: false)
        _ = try await source.token(forceRefresh: false)
        XCTAssertEqual(fetcher.calls, 2)
    }

    func testClearDropsTheCache() async throws {
        let fetcher = FakeFetcher(expiresAt: FeedDates.format(t0.addingTimeInterval(3600)))
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { self.t0 })
        _ = try await source.token(forceRefresh: false)
        await source.clear()
        _ = try await source.token(forceRefresh: false)
        XCTAssertEqual(fetcher.calls, 2)
    }
}

/// `/v1/tellomi/feed/auth` 没部署（2026-10-16 起的假设）时的降级。
final class TellomiFeedAuthNotDeployedTests: XCTestCase {
    private final class MissingFetcher: FeedAuthFetching, @unchecked Sendable {
        var calls = 0
        func fetch() async throws -> FeedAuthResponse {
            calls += 1
            throw FeedAuthFailure.classify(statusCode: 404)!
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testClassify() {
        XCTAssertTrue(FeedAuthFailure.classify(statusCode: 404)!.isAuthNotDeployed)
        XCTAssertTrue(FeedAuthFailure.classify(statusCode: 405)!.isAuthNotDeployed)
        XCTAssertTrue(FeedAuthFailure.classify(statusCode: 501)!.isAuthNotDeployed)
        XCTAssertNil(FeedAuthFailure.classify(statusCode: 401)) // 账号鉴权问题，不是没部署
        // 限速（I-21）：429 / 带 Retry-After 的 503 是节流错误，不是「没部署」；没带头的 503 仍是普通失败
        XCTAssertFalse(FeedAuthFailure.classify(statusCode: 429)!.isAuthNotDeployed)
        XCTAssertTrue(FeedAuthFailure.classify(statusCode: 429)!.isThrottle)
        XCTAssertNil(FeedAuthFailure.classify(statusCode: 503))
        XCTAssertNil(FeedAuthFailure.classify(statusCode: 500))
        XCTAssertNil(FeedAuthFailure.classify(statusCode: nil)) // 断网
        // 不能和引擎的 404 feed_hidden 混淆
        XCTAssertFalse(FeedAPIError(status: 404, code: "feed_hidden", retryAfterSeconds: nil).isAuthNotDeployed)
    }

    func testBacksOffInsteadOfHammeringTheServer() async {
        let fetcher = MissingFetcher()
        var now = t0
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { now })
        for _ in 0..<3 {
            do { _ = try await source.token(forceRefresh: false); XCTFail("should throw") } catch let error as FeedAPIError {
                XCTAssertTrue(error.isAuthNotDeployed)
            } catch { XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(fetcher.calls, 1)

        // 引擎 401 后的 forceRefresh 也不打网络
        _ = try? await source.token(forceRefresh: true)
        XCTAssertEqual(fetcher.calls, 1)

        // 退避过了：再问一次
        now = t0.addingTimeInterval(CachingFeedTokenSource.notDeployedBackoff + 1)
        _ = try? await source.token(forceRefresh: false)
        XCTAssertEqual(fetcher.calls, 2)
    }

    func testClearResetsTheBackoff() async {
        let fetcher = MissingFetcher()
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { self.t0 })
        _ = try? await source.token(forceRefresh: false)
        await source.clear() // 退出登录 / 切区 / 内部设置里手动重试
        _ = try? await source.token(forceRefresh: false)
        XCTAssertEqual(fetcher.calls, 2)
    }

    func testClockGoingBackwardsDoesNotLockUsOut() async {
        let fetcher = MissingFetcher()
        var now = t0
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { now })
        _ = try? await source.token(forceRefresh: false)
        now = t0.addingTimeInterval(-3600)
        _ = try? await source.token(forceRefresh: false)
        XCTAssertEqual(fetcher.calls, 2)
    }

    /// 其他失败（5xx、断网）不退避，下次照常再取。
    func testOtherFailuresAreNotBackedOff() async {
        final class Flaky: FeedAuthFetching, @unchecked Sendable {
            var calls = 0
            func fetch() async throws -> FeedAuthResponse {
                calls += 1
                throw FeedAPIError(status: 503, code: nil, retryAfterSeconds: nil)
            }
        }
        let fetcher = Flaky()
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { self.t0 })
        _ = try? await source.token(forceRefresh: false)
        _ = try? await source.token(forceRefresh: false)
        XCTAssertEqual(fetcher.calls, 2)
    }

    /// 入口检查：没部署 → 保持原样（默认不可见）、不更新「上次问的时间」。
    func testEntryCheckKeepsTheTabHiddenWhenAuthIsNotDeployed() async {
        final class State: FeedEntryCheckState {
            var visible = false
            var checkedAtMillis: Int64 = 0
        }
        let state = State()
        let check = FeedEntryCheck(
            shouldAsk: { true },
            isVisible: { throw FeedAuthFailure.classify(statusCode: 404)! },
            state: state,
            clockMillis: { 42 },
        )
        let changed = await check.refreshIfStale()
        XCTAssertFalse(changed)
        XCTAssertFalse(state.visible)
        XCTAssertEqual(state.checkedAtMillis, 0)
    }
}

final class TellomiFeedEntryCheckTests: XCTestCase {
    private final class MemoryState: FeedEntryCheckState {
        var visible = false
        var checkedAtMillis: Int64 = 0
    }

    private struct Boom: Error {}

    private func makeCheck(
        state: MemoryState,
        now: Int64,
        ask: Bool = true,
        result: @escaping () async throws -> Bool,
    ) -> FeedEntryCheck {
        return FeedEntryCheck(shouldAsk: { ask }, isVisible: result, state: state, clockMillis: { now })
    }

    func testFirstCheckRecordsVisibleAndReportsChange() async {
        let state = MemoryState()
        let check = makeCheck(state: state, now: 1_000) { true }
        let changed = await check.refreshIfStale()
        XCTAssertTrue(changed)
        XCTAssertTrue(state.visible)
        XCTAssertEqual(state.checkedAtMillis, 1_000)
    }

    func testFreshResultIsNotAskedAgain() async {
        let state = MemoryState()
        state.visible = true
        state.checkedAtMillis = 1_000
        var asked = false
        let check = makeCheck(state: state, now: 1_000 + FeedEntryCheck.staleAfterMillis - 1) { asked = true; return false }
        let changed = await check.refreshIfStale()
        XCTAssertFalse(changed)
        XCTAssertFalse(asked)
        XCTAssertTrue(state.visible)
    }

    func testStaleResultIsAskedAndFeedHiddenMeansNotVisible() async {
        let state = MemoryState()
        state.visible = true
        state.checkedAtMillis = 1_000
        let check = makeCheck(state: state, now: 1_000 + FeedEntryCheck.staleAfterMillis) {
            throw FeedAPIError(status: 404, code: "feed_hidden", retryAfterSeconds: nil)
        }
        let changed = await check.refreshIfStale()
        XCTAssertTrue(changed)
        XCTAssertFalse(state.visible)
    }

    /// 断网 / 5xx：不改记住的值，也不更新「上次问的时间」（下次回前台还会再问）。
    func testNetworkFailureKeepsWhatWeKnew() async {
        let state = MemoryState()
        state.visible = true
        state.checkedAtMillis = 1_000
        let check = makeCheck(state: state, now: 9_999_999) { throw Boom() }
        let changed = await check.refreshIfStale()
        XCTAssertFalse(changed)
        XCTAssertTrue(state.visible)
        XCTAssertEqual(state.checkedAtMillis, 1_000)
    }

    /// 时钟往回拨过（现在 < 上次问的时间）：当作过期，再问一次（Android `clock going backwards asks again`）。
    func testClockGoingBackwardsAsksAgain() async {
        let state = MemoryState()
        state.checkedAtMillis = 5_000_000
        var asked = false
        let check = makeCheck(state: state, now: 1_000) { asked = true; return true }
        _ = await check.refreshIfStale()
        XCTAssertTrue(asked)
    }

    func testNotAskingWhenSwitchedOff() async {
        let state = MemoryState()
        let check = makeCheck(state: state, now: 1, ask: false) { true }
        let changed = await check.refreshIfStale()
        XCTAssertFalse(changed)
        XCTAssertFalse(state.visible)
    }
}

/// 并发的请求只发一次换取（Android `CachingFeedTokenSourceTest.concurrent callers share one fetch`）。
final class TellomiFeedAuthSingleFlightTests: XCTestCase {
    private final class SlowFetcher: FeedAuthFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var failNext = false
        var expiresAt: String
        init(expiresAt: String) { self.expiresAt = expiresAt }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        private func begin() -> (Int, Bool) {
            lock.lock(); defer { lock.unlock() }
            _calls += 1
            return (_calls, failNext)
        }
        func fetch() async throws -> FeedAuthResponse {
            let (n, fail) = begin()
            try await Task.sleep(nanoseconds: 80_000_000)
            if fail { throw FeedAPIError(status: 503, code: nil, retryAfterSeconds: nil) }
            return FeedAuthResponse(token: "t\(n)", expiresAt: expiresAt, region: nil)
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func tokens(_ source: CachingFeedTokenSource, count: Int, force: Bool = false) async -> [String?] {
        return await withTaskGroup(of: String?.self) { group in
            for _ in 0..<count {
                group.addTask { try? await source.token(forceRefresh: force) }
            }
            var out = [String?]()
            for await token in group { out.append(token) }
            return out
        }
    }

    func testConcurrentCallersShareOneFetch() async {
        let fetcher = SlowFetcher(expiresAt: FeedDates.format(t0.addingTimeInterval(3600)))
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { self.t0 })
        let result = await tokens(source, count: 5)
        XCTAssertEqual(Set(result.map { $0 ?? "nil" }), ["t1"])
        XCTAssertEqual(fetcher.calls, 1)
        // 之后读缓存
        let again = try? await source.token(forceRefresh: false)
        XCTAssertEqual(again, "t1")
        XCTAssertEqual(fetcher.calls, 1)
    }

    func testForceRefreshCallersThatArriveDuringAFetchShareIt() async {
        let fetcher = SlowFetcher(expiresAt: FeedDates.format(t0.addingTimeInterval(3600)))
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { self.t0 })
        let result = await tokens(source, count: 4, force: true)
        XCTAssertEqual(Set(result.map { $0 ?? "nil" }), ["t1"])
        XCTAssertEqual(fetcher.calls, 1)
        // 没有在进行的换取时，forceRefresh 照样再换一次
        let forced = try? await source.token(forceRefresh: true)
        XCTAssertEqual(forced, "t2")
    }

    func testAFailedFetchFailsEveryoneWaitingAndTheNextCallTriesAgain() async {
        let fetcher = SlowFetcher(expiresAt: FeedDates.format(t0.addingTimeInterval(3600)))
        fetcher.failNext = true
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { self.t0 })
        let failed = await tokens(source, count: 3)
        XCTAssertEqual(failed.compactMap { $0 }.count, 0)
        XCTAssertEqual(fetcher.calls, 1)
        fetcher.failNext = false
        let ok = try? await source.token(forceRefresh: false)
        XCTAssertEqual(ok, "t2")
        XCTAssertEqual(fetcher.calls, 2)
    }

    /// 换取期间退出登录 / 切区：这次的 token 不进缓存。
    func testClearDuringAFetchKeepsTheResultOutOfTheCache() async throws {
        let fetcher = SlowFetcher(expiresAt: FeedDates.format(t0.addingTimeInterval(3600)))
        let source = CachingFeedTokenSource(fetcher: fetcher, clock: { self.t0 })
        let pending = Task { try await source.token(forceRefresh: false) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await source.clear()
        let first = try await pending.value
        XCTAssertEqual(first, "t1")
        let second = try await source.token(forceRefresh: false)
        XCTAssertEqual(second, "t2", "the token fetched before clear() must not have been cached")
    }
}
