//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedRetryAfterTests.swift (new file)
// I-21: `Retry-After` parsing ([1, 3600] s), 429 / 503 handling in the feed engine client, the events queue, the feed/auth token
// source, the Signal-Server signer (friend-assertions, audience lists) and the capabilities cache. All with an injectable clock.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(_ seconds: TimeInterval) { lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock() }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: date)
}

// MARK: - parser

final class TellomiFeedRetryAfterParseTests: XCTestCase {
    private func parse(_ value: String?) -> Int? { FeedRetryAfter.parse(value, now: t0) }

    func testAbsentOrGarbageIsNil() {
        for value in [nil, "", "   ", "soon", "-5", "-0", "1.5", "+5", "5s", "1e3", "0x10", "５", "5 6", "Tue", "12:00", "NaN"] as [String?] {
            XCTAssertNil(parse(value), "\(String(describing: value)) 读不懂 ⇒ nil（走指数退避）")
        }
    }

    func testDeltaSecondsAreClampedToOneAndAnHour() {
        XCTAssertEqual(parse("0"), 1, "0 ⇒ 1")
        XCTAssertEqual(parse("00"), 1)
        XCTAssertEqual(parse("1"), 1)
        XCTAssertEqual(parse("7"), 7)
        XCTAssertEqual(parse(" 120 "), 120, "两头的空白不算")
        XCTAssertEqual(parse("3599"), 3599)
        XCTAssertEqual(parse("3600"), 3600)
        XCTAssertEqual(parse("3601"), 3600)
        XCTAssertEqual(parse("86400"), 3600)
        XCTAssertEqual(parse("999999999"), 3600)
    }

    func testHugeNumbersDoNotOverflow() {
        XCTAssertEqual(parse("9999999999"), 3600)
        XCTAssertEqual(parse("99999999999999999999999999999999"), 3600)
        XCTAssertEqual(parse("9223372036854775807"), 3600)
        XCTAssertEqual(parse("9223372036854775808"), 3600)
        XCTAssertEqual(parse(String(repeating: "0", count: 40) + "7"), 3600, "前导 0 堆得太长也只当「很大」（不会拿去转数字）")
    }

    func testHTTPDates() {
        XCTAssertEqual(parse(httpDate(t0.addingTimeInterval(90))), 90)
        XCTAssertEqual(parse(httpDate(t0.addingTimeInterval(1))), 1)
        XCTAssertEqual(parse(httpDate(t0.addingTimeInterval(3600))), 3600)
        XCTAssertEqual(parse(httpDate(t0.addingTimeInterval(86400))), 3600, "太远 ⇒ 3600")
        XCTAssertEqual(parse(httpDate(t0.addingTimeInterval(-500))), 1, "已经过去 ⇒ 1")
        XCTAssertEqual(parse(httpDate(t0)), 1)
        XCTAssertEqual(FeedRetryAfter.parse(httpDate(t0.addingTimeInterval(90.4)), now: t0.addingTimeInterval(0.3)), 90, "向上取整（日期只到秒）")
    }

    func testTheThreeHTTPDateFormats() {
        // 1994-11-06 08:49:37 GMT = 784111777
        let now = Date(timeIntervalSince1970: 784_111_777 - 100)
        XCTAssertEqual(FeedRetryAfter.parse("Sun, 06 Nov 1994 08:49:37 GMT", now: now), 100, "IMF-fixdate")
        XCTAssertEqual(FeedRetryAfter.parse("Sunday, 06-Nov-94 08:49:37 GMT", now: now), 100, "RFC 850")
        XCTAssertEqual(FeedRetryAfter.parse("Sun Nov  6 08:49:37 1994", now: now), 100, "asctime")
        XCTAssertEqual(FeedRetryAfter.parse("Sun Nov 6 08:49:37 1994", now: now), 100, "asctime（单空格）")
        XCTAssertNil(FeedRetryAfter.parse("Sun, 32 Nov 1994 08:49:37 GMT", now: now), "不存在的日子")
        XCTAssertNil(FeedRetryAfter.parse("Sun, 06 Nov 1994 08:49:37 PST", now: now), "只认 GMT")
    }

    func testClamp() {
        XCTAssertEqual([Int.min, -1, 0, 1, 2, 3600, 3601, Int.max].map(FeedRetryAfter.clamp), [1, 1, 1, 1, 2, 3600, 3600, 3600])
    }
}

// MARK: - backoff / gate

final class TellomiFeedRetryGateTests: XCTestCase {
    private func error(_ status: Int, _ retryAfter: Int? = nil) -> FeedAPIError {
        FeedAPIError(status: status, code: "x", retryAfterSeconds: retryAfter)
    }

    func testWhichErrorsAreThrottles() {
        XCTAssertTrue(error(429).isThrottle)
        XCTAssertTrue(error(429, 30).isThrottle)
        XCTAssertTrue(error(503, 30).isThrottle, "503 + Retry-After 也照头里的等")
        XCTAssertFalse(error(503).isThrottle, "503 没带头：和以前一样当普通失败")
        XCTAssertFalse(FeedAPIError(status: 429, code: "too_many_uploads", retryAfterSeconds: 60).isThrottle, "并发上限不算限速（和 Android 一样）")
        XCTAssertFalse(FeedAPIError(status: 429, code: "too_many_uploads", retryAfterSeconds: nil).isThrottle)
        for status in [0, 400, 401, 403, 404, 409, 500, 502, 504] {
            XCTAssertFalse(error(status, 30).isThrottle, "\(status)")
        }
    }

    func testBackoffGrowsCapsAndStaysInRange() {
        let lows = (1...10).map { FeedBackoff.delay(attempt: $0, random: 0) }
        let highs = (1...10).map { FeedBackoff.delay(attempt: $0, random: 1) }
        XCTAssertEqual(highs.prefix(7), [30, 60, 120, 240, 480, 960, 1920])
        XCTAssertEqual(highs.suffix(3), [3600, 3600, 3600], "封顶 3600 秒")
        XCTAssertEqual(lows.prefix(3), [15, 30, 60], "抖动取 [一半, 全部]")
        for (low, high) in zip(lows, highs) { XCTAssertTrue(1...3600 ~= low && low <= high) }
        XCTAssertEqual(FeedBackoff.delay(attempt: 0, random: 1), 30, "attempt 当 1")
        XCTAssertEqual(FeedBackoff.delay(attempt: Int.max, random: 1), 3600)
        XCTAssertEqual(FeedBackoff.delay(attempt: 3, random: 7), 120, "random 夹到 0…1")
        XCTAssertEqual(FeedBackoff.delay(attempt: 3, random: -7), 60)
    }

    func testTheHeaderBeatsBackoffAndClamps() {
        var gate = FeedRetryGate()
        XCTAssertEqual(gate.remaining(now: t0), 0)
        XCTAssertTrue(gate.record(error(429, 30), now: t0, random: 1))
        XCTAssertEqual(gate.remaining(now: t0), 30)
        XCTAssertEqual(gate.remaining(now: t0.addingTimeInterval(12)), 18)
        XCTAssertFalse(gate.isBlocked(now: t0.addingTimeInterval(30)))
        XCTAssertEqual(gate.remaining(now: t0.addingTimeInterval(31)), 0)

        var big = FeedRetryGate()
        big.record(error(429, 99999), now: t0, random: 0)
        XCTAssertEqual(big.remaining(now: t0), 3600)
        var zero = FeedRetryGate()
        zero.record(error(429, 0), now: t0, random: 0)
        XCTAssertEqual(zero.remaining(now: t0), 1)
    }

    func testNoHeaderFallsBackToExponentialBackoffWithJitter() {
        var gate = FeedRetryGate()
        var now = t0
        var waits = [TimeInterval]()
        for _ in 0..<4 {
            gate.record(error(429), now: now, random: 1)
            waits.append(gate.remaining(now: now))
            now = now.addingTimeInterval(gate.remaining(now: now))
        }
        XCTAssertEqual(waits, [30, 60, 120, 240])
        XCTAssertEqual(gate.consecutiveThrottles, 4)
        gate.reset()
        XCTAssertEqual(gate.consecutiveThrottles, 0)
        XCTAssertEqual(gate.remaining(now: now), 0)
        gate.record(error(429), now: now, random: 0)
        XCTAssertEqual(gate.remaining(now: now), 15, "reset 之后从头数")
    }

    func testAnEarlierWaitNeverShortensALaterOne() {
        var gate = FeedRetryGate()
        gate.record(error(429, 600), now: t0, random: 0)
        gate.record(error(429, 5), now: t0.addingTimeInterval(1), random: 0)
        XCTAssertEqual(gate.remaining(now: t0.addingTimeInterval(1)), 599)
    }

    func testNonThrottleErrorsDoNotTouchTheGate() {
        var gate = FeedRetryGate()
        XCTAssertFalse(gate.record(error(500, 30), now: t0, random: 0))
        XCTAssertFalse(gate.record(error(503), now: t0, random: 0))
        XCTAssertFalse(gate.record(error(404), now: t0, random: 0))
        XCTAssertEqual(gate.remaining(now: t0), 0)
        XCTAssertEqual(gate.consecutiveThrottles, 0)
    }

    /// 时钟被往回拨：当作等待已结束（和 Android `FeedCooldown` 一样），不会被一个坏时钟卡住一小时。
    func testAClockSetBackEndsTheWait() {
        var gate = FeedRetryGate()
        gate.record(error(429, 3600), now: t0, random: 0)
        XCTAssertEqual(gate.remaining(now: t0.addingTimeInterval(-1)), 0)
        XCTAssertEqual(gate.remaining(now: t0.addingTimeInterval(-86400)), 0)
        XCTAssertEqual(gate.remaining(now: t0), 3600, "回到记下的时刻之后又是正常的")
    }
}

// MARK: - FeedAPI

final class TellomiFeedRetryAfterApiTests: XCTestCase {
    private final class Transport: FeedHTTPTransport, @unchecked Sendable {
        struct Reply { var status: Int; var headers: [String: String]; var body: String }
        private let lock = NSLock()
        private var replies = [Reply]()
        private var _paths = [String]()
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
        func reply(_ status: Int, _ headers: [String: String] = [:], _ body: String = #"{"accepted":1}"#) {
            lock.lock(); replies.append(Reply(status: status, headers: headers, body: body)); lock.unlock()
        }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let next = lock.locked {
                _paths.append(request.url?.path ?? "")
                return replies.isEmpty ? Reply(status: 200, headers: [:], body: #"{"accepted":1}"#) : replies.removeFirst()
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: next.headers)!
            return (Data(next.body.utf8), response)
        }
    }

    private struct FixedTokens: FeedTokenSource {
        func token(forceRefresh: Bool) async throws -> String { "tok" }
    }

    private let event = FeedEventPayload.share(contentId: "c", surface: .recommend, at: t0)

    private func make(_ transport: Transport, _ clock: TestClock, jitter: Double = 1) -> FeedAPI {
        let api = FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens())
        api.clock = { clock.now }
        api.jitter = { jitter }
        return api
    }

    private func thrown(_ work: () async throws -> Void) async -> FeedAPIError? {
        do { try await work(); return nil } catch { return error as? FeedAPIError }
    }

    func testTheHeaderBecomesRetryAfterSeconds() async {
        let clock = TestClock()
        let cases: [(String?, Int?)] = [
            ("30", 30), ("0", 1), ("99999", 3600), (nil, nil), ("soon", nil), ("-1", nil),
            (httpDate(t0.addingTimeInterval(75)), 75), (httpDate(t0.addingTimeInterval(-10)), 1),
        ]
        for (header, expected) in cases {
            let transport = Transport()
            transport.reply(429, header.map { ["Retry-After": $0] } ?? [:], #"{"error":"rate_limited"}"#)
            let error = await thrown { try await make(transport, clock).events([event]) }
            XCTAssertEqual(error?.status, 429)
            XCTAssertEqual(error?.code, "rate_limited")
            XCTAssertEqual(error?.retryAfterSeconds, expected, "\(String(describing: header))")
        }
    }

    func testAfterA429TheSameKindOfRequestWaitsWithoutTouchingTheNetwork() async {
        let clock = TestClock()
        let transport = Transport()
        let api = make(transport, clock)
        transport.reply(429, ["Retry-After": "30"], #"{"error":"rate_limited"}"#)
        _ = await thrown { try await api.events([event]) }
        XCTAssertEqual(transport.paths.count, 1)

        clock.advance(10)
        let early = await thrown { try await api.events([event]) }
        XCTAssertEqual(early?.status, 429)
        XCTAssertEqual(early?.code, FeedAPI.backoffCode)
        XCTAssertEqual(early?.retryAfterSeconds, 20, "还要等 20 秒")
        XCTAssertEqual(transport.paths.count, 1, "没发请求")

        clock.advance(20)
        let ok = await thrown { try await api.events([event]) }
        XCTAssertNil(ok)
        XCTAssertEqual(transport.paths.count, 2)
        // 成功一次就解开，下一次不再等
        let again = await thrown { try await api.events([event]) }
        XCTAssertNil(again)
        XCTAssertEqual(transport.paths.count, 3)
    }

    func testOtherKindsOfRequestAreNotBlocked() async {
        let clock = TestClock()
        let transport = Transport()
        let api = make(transport, clock)
        transport.reply(429, ["Retry-After": "60"], #"{"error":"rate_limited"}"#)
        _ = await thrown { try await api.events([event]) }
        transport.reply(200, [:], "{}")
        let config = await thrown { _ = try await api.config() }
        XCTAssertNil(config, "/v1/feed/config 和 /v1/feed/events 各算各的")
        XCTAssertEqual(transport.paths.last, "/v1/feed/config")
        XCTAssertEqual(FeedAPI.throttleScope(of: URL(string: "https://h/v1/feed/media/uploads/u1")!), "media")
        XCTAssertEqual(FeedAPI.throttleScope(of: URL(string: "https://h/p/v1/feed/events")!), "events")
        XCTAssertEqual(FeedAPI.throttleScope(of: URL(string: "https://h/v1/capabilities")!), "other")
    }

    func testA429WithoutAHeaderBacksOffExponentially() async {
        let clock = TestClock()
        let transport = Transport()
        let api = make(transport, clock, jitter: 1)
        var waits = [Int?]()
        for _ in 0..<3 {
            transport.reply(429, [:], #"{"error":"rate_limited"}"#)
            _ = await thrown { try await api.events([event]) }
            let blocked = await thrown { try await api.events([event]) }
            waits.append(blocked?.retryAfterSeconds)
            clock.advance(TimeInterval(blocked?.retryAfterSeconds ?? 0))
        }
        XCTAssertEqual(waits, [30, 60, 120])
    }

    /// 成功一次之后指数退避从头数。
    func testASuccessRestartsTheBackoffCount() async {
        let clock = TestClock()
        let transport = Transport()
        let api = make(transport, clock, jitter: 1)
        transport.reply(429)
        _ = await thrown { try await api.events([event]) }
        clock.advance(30)
        let ok = await thrown { try await api.events([event]) }
        XCTAssertNil(ok)
        transport.reply(429)
        _ = await thrown { try await api.events([event]) }
        let blocked = await thrown { try await api.events([event]) }
        XCTAssertEqual(blocked?.retryAfterSeconds, 30, "成功之后又被限速，从头数：30 秒，不是 60")
    }

    func testA503NeedsTheHeaderToCount() async {
        let clock = TestClock()
        let withHeader = Transport(), without = Transport()
        withHeader.reply(503, ["Retry-After": "45"], #"{"error":"media_unavailable"}"#)
        without.reply(503, [:], #"{"error":"media_unavailable"}"#)

        let api1 = make(withHeader, clock)
        _ = await thrown { try await api1.events([event]) }
        let blocked = await thrown { try await api1.events([event]) }
        XCTAssertEqual(blocked?.code, FeedAPI.backoffCode)
        XCTAssertEqual(withHeader.paths.count, 1)

        let api2 = make(without, clock)
        _ = await thrown { try await api2.events([event]) }
        let next = await thrown { try await api2.events([event]) }
        XCTAssertNil(next, "503 没带头：照旧，下一次照发")
        XCTAssertEqual(without.paths.count, 2)
    }

    func testOtherErrorsNeverBlock() async {
        let clock = TestClock()
        for status in [400, 403, 404, 409, 413, 500, 502, 504] { // 401 另有一次换 token 重试，不在这里
            let transport = Transport()
            transport.reply(status, ["Retry-After": "60"], #"{"error":"x"}"#)
            let api = make(transport, clock)
            _ = await thrown { try await api.events([event]) }
            _ = await thrown { try await api.events([event]) }
            XCTAssertEqual(transport.paths.count, 2, "\(status)")
        }
    }
}

// MARK: - events queue

@MainActor
final class TellomiFeedEventsThrottleTests: XCTestCase {
    private struct Boom: Error {}

    private final class Source: FeedSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _attempts = [[FeedEventPayload]]()
        private var _succeeded = [[FeedEventPayload]]()
        /// 第几次调用（从 0 数）抛什么；没写的成功。
        var script = [Int: Error]()
        var attempts: [[FeedEventPayload]] { lock.lock(); defer { lock.unlock() }; return _attempts }
        var succeeded: [[FeedEventPayload]] { lock.lock(); defer { lock.unlock() }; return _succeeded }

        func config() async throws -> FeedConfig { FeedConfig() }
        func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
        func setLiked(contentId: String, liked: Bool) async throws {}
        func notInterested(contentId: String) async throws {}
        func undoNotInterested(contentId: String) async throws {}
        func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
        func reportEvents(_ events: [FeedEventPayload]) async throws {
            let failure = lock.locked {
                let index = _attempts.count
                _attempts.append(events)
                let failure = script[index]
                if failure == nil { _succeeded.append(events) }
                return failure
            }
            if let failure { throw failure }
        }
    }

    private func throttle(_ retryAfter: Int?, status: Int = 429) -> FeedAPIError {
        FeedAPIError(status: status, code: "rate_limited", retryAfterSeconds: retryAfter)
    }

    /// `count` 张卡露出满 1 秒 ⇒ `count` 条曝光（满 50 条会自己 flush）。
    private func addImpressions(_ store: FeedStore, _ clock: TestClock, prefix: String, count: Int) {
        let ids = Set((0..<count).map { "\(prefix)\($0)" })
        store.onCardsVisible(.recommend, ids)
        clock.advance(1)
        store.onCardsVisible(.recommend, ids)
    }

    private func ids(_ batches: [[FeedEventPayload]]) -> [String] { batches.flatMap { $0.map(\.contentId) } }

    private func make(_ source: Source, _ clock: TestClock, jitter: Double = 1) -> FeedStore {
        FeedStore(source: source, now: { clock.now }, jitter: { jitter })
    }

    func testBatchesStopAfterA429AndNothingIsDropped() async {
        let clock = TestClock(), source = Source()
        source.script[0] = throttle(30)
        let store = make(source, clock)
        addImpressions(store, clock, prefix: "a", count: 120) // 3 批：50 + 50 + 20
        await store.waitForEventFlushes()

        XCTAssertEqual(source.attempts.count, 1, "第一批 429 之后不再发后面的批次")
        XCTAssertEqual(source.attempts[0].count, 50)
        XCTAssertEqual(source.succeeded.count, 0)
        XCTAssertEqual(store.pendingEventCount, 120, "一条都没丢：这一批和后面两批都还在队里")
        XCTAssertEqual(store.eventsBackoffRemaining, 30)
    }

    func testNothingIsSentInsideTheDelayAndTheOldestGoFirstAfterIt() async {
        let clock = TestClock(), source = Source()
        source.script[0] = throttle(30)
        let store = make(source, clock)
        addImpressions(store, clock, prefix: "a", count: 120)
        await store.waitForEventFlushes()
        let firstAttempt = source.attempts[0]

        clock.advance(10)
        store.flushEvents()
        store.onFeedHidden()
        await store.waitForEventFlushes()
        XCTAssertEqual(source.attempts.count, 1, "30 秒里不发（定时器、退到后台、攒满都一样）")
        XCTAssertEqual(store.pendingEventCount, 120)

        // 等的时候新来的事件排在后面
        addImpressions(store, clock, prefix: "b", count: 50) // 攒满 50 也不发
        await store.waitForEventFlushes()
        XCTAssertEqual(source.attempts.count, 1)
        XCTAssertEqual(store.pendingEventCount, 170)

        clock.advance(20) // 到点（10 + 1 + 20 > 30）
        store.flushEvents()
        await store.waitForEventFlushes()
        XCTAssertEqual(source.attempts.count, 1 + 4, "170 条 = 4 批：重发被拒的第一批 + 两批旧的 + 新的")
        XCTAssertEqual(source.succeeded.count, 4)
        XCTAssertEqual(source.succeeded[0], firstAttempt, "被拒的那批最先重发")
        let all = ids(source.succeeded)
        XCTAssertEqual(all.count, 170)
        XCTAssertEqual(Set(all).count, 170, "没重复也没少")
        XCTAssertTrue(all.prefix(120).allSatisfy { $0.hasPrefix("a") }, "旧的 120 条在新的 50 条前面")
        XCTAssertEqual(store.pendingEventCount, 0)
        XCTAssertEqual(store.eventsBackoffRemaining, 0)
    }

    func testAStillBlockedFlushDoesNotConsumeTheQueue() async {
        let clock = TestClock(), source = Source()
        source.script[0] = throttle(60)
        let store = make(source, clock)
        addImpressions(store, clock, prefix: "a", count: 50)
        await store.waitForEventFlushes()
        for _ in 0..<3 {
            clock.advance(5)
            store.flushEvents()
            await store.waitForEventFlushes()
        }
        XCTAssertEqual(source.attempts.count, 1)
        XCTAssertEqual(store.pendingEventCount, 50)
        XCTAssertEqual(store.eventsBackoffRemaining, 45)
    }

    func testAThrottleInTheMiddleKeepsTheRestOfTheBatches() async {
        let clock = TestClock(), source = Source()
        source.script[1] = throttle(20)
        let store = make(source, clock)
        addImpressions(store, clock, prefix: "a", count: 120)
        await store.waitForEventFlushes()
        XCTAssertEqual(source.attempts.count, 2, "第一批成功，第二批 429 ⇒ 停")
        XCTAssertEqual(source.succeeded.count, 1)
        XCTAssertEqual(store.pendingEventCount, 70, "第二批和第三批留着")
        XCTAssertEqual(store.eventsBackoffRemaining, 20)

        clock.advance(20)
        store.flushEvents()
        await store.waitForEventFlushes()
        XCTAssertEqual(source.succeeded.count, 3)
        XCTAssertEqual(Set(ids(source.succeeded)).count, 120)
        XCTAssertEqual(store.pendingEventCount, 0)
    }

    func testWithoutAHeaderTheDelayIsExponentialAndResetsOnSuccess() async {
        let clock = TestClock(), source = Source()
        source.script = [0: throttle(nil), 1: throttle(nil), 2: throttle(nil)]
        let store = make(source, clock, jitter: 1)
        addImpressions(store, clock, prefix: "a", count: 50)
        await store.waitForEventFlushes()
        XCTAssertEqual(store.eventsBackoffRemaining, 30)
        clock.advance(30)
        store.flushEvents()
        await store.waitForEventFlushes()
        XCTAssertEqual(store.eventsBackoffRemaining, 60)
        clock.advance(60)
        store.flushEvents()
        await store.waitForEventFlushes()
        XCTAssertEqual(store.eventsBackoffRemaining, 120)
        XCTAssertEqual(store.pendingEventCount, 50)

        clock.advance(120)
        store.flushEvents()
        await store.waitForEventFlushes()
        XCTAssertEqual(source.succeeded.count, 1)
        XCTAssertEqual(store.pendingEventCount, 0)

        // 成功之后再被限速，又从头数
        source.script[4] = throttle(nil)
        addImpressions(store, clock, prefix: "b", count: 50)
        await store.waitForEventFlushes()
        XCTAssertEqual(store.eventsBackoffRemaining, 30)
    }

    func testHeaderEdgeCases() async {
        for (header, expected) in [(0, 1.0), (1, 1), (99999, 3600)] as [(Int, TimeInterval)] {
            let clock = TestClock(), source = Source()
            source.script[0] = throttle(header)
            let store = make(source, clock)
            addImpressions(store, clock, prefix: "a", count: 50)
            await store.waitForEventFlushes()
            XCTAssertEqual(store.eventsBackoffRemaining, expected, "Retry-After \(header)")
        }
    }

    func testA503WithTheHeaderIsHonouredAndWithoutItIsDropped() async {
        let clock = TestClock(), source = Source()
        source.script[0] = throttle(40, status: 503)
        let store = make(source, clock)
        addImpressions(store, clock, prefix: "a", count: 50)
        await store.waitForEventFlushes()
        XCTAssertEqual(store.pendingEventCount, 50)
        XCTAssertEqual(store.eventsBackoffRemaining, 40)

        let clock2 = TestClock(), source2 = Source()
        source2.script[0] = throttle(nil, status: 503)
        let store2 = make(source2, clock2)
        addImpressions(store2, clock2, prefix: "a", count: 50)
        await store2.waitForEventFlushes()
        XCTAssertEqual(store2.pendingEventCount, 0, "503 没带头：和以前一样丢掉这一批")
        XCTAssertEqual(store2.eventsBackoffRemaining, 0)
    }

    func testOrdinaryFailuresAreStillDroppedAndDoNotBlock() async {
        let errors: [Error] = [Boom(), FeedAPIError(status: 500, code: "internal", retryAfterSeconds: 30), FeedAPIError(status: 400, code: "bad", retryAfterSeconds: nil), URLError(.notConnectedToInternet)]
        for error in errors {
            let clock = TestClock(), source = Source()
            source.script[0] = error
            let store = make(source, clock)
            addImpressions(store, clock, prefix: "a", count: 120)
            await store.waitForEventFlushes()
            XCTAssertEqual(source.attempts.count, 3, "一批失败不影响后面的批次: \(error)")
            XCTAssertEqual(source.succeeded.count, 2)
            XCTAssertEqual(store.pendingEventCount, 0, "普通失败的批次丢掉（契约 6.1）")
            XCTAssertEqual(store.eventsBackoffRemaining, 0)
        }
    }

    /// 被限速时队里最多留 1000 条（和 Android 一样），超过的丢最旧的；留下的是最新的 1000 条，顺序不变。
    func testTheHeldQueueIsCappedAtAThousandDroppingTheOldest() async {
        let clock = TestClock(), source = Source()
        source.script[0] = throttle(60)
        let store = make(source, clock)
        addImpressions(store, clock, prefix: "a", count: 1100) // 22 批
        await store.waitForEventFlushes()
        XCTAssertEqual(source.attempts.count, 1)
        XCTAssertEqual(store.pendingEventCount, 1000)
        let rejected = Set(source.attempts[0].map(\.contentId))

        // 等的时候再来 1100 条：并进队里，总数还是 1000
        addImpressions(store, clock, prefix: "b", count: 1100)
        await store.waitForEventFlushes()
        XCTAssertEqual(store.pendingEventCount, 1000)
        XCTAssertEqual(source.attempts.count, 1, "等待期里不发")

        clock.advance(61)
        store.flushEvents()
        await store.waitForEventFlushes()
        let sent = ids(source.succeeded)
        XCTAssertEqual(sent.count, 1000)
        XCTAssertTrue(sent.allSatisfy { $0.hasPrefix("b") }, "最旧的（a…）先被丢掉")
        XCTAssertTrue(rejected.isDisjoint(with: sent))
        XCTAssertEqual(store.pendingEventCount, 0)
    }

    func testUnderTheCapNothingIsDropped() async {
        let clock = TestClock(), source = Source()
        source.script[0] = throttle(60)
        let store = make(source, clock)
        addImpressions(store, clock, prefix: "a", count: 1000)
        await store.waitForEventFlushes()
        XCTAssertEqual(store.pendingEventCount, 1000)
    }
}

// MARK: - feed/auth

final class TellomiFeedAuthThrottleTests: XCTestCase {
    private final class Fetcher: FeedAuthFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var script = [Error?]()
        let expiresAt: String
        init(expiresAt: String) { self.expiresAt = expiresAt }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func fetch() async throws -> FeedAuthResponse {
            let (index, failure) = lock.locked {
                let index = _calls
                _calls += 1
                return (index, index < script.count ? script[index] : nil)
            }
            if let failure { throw failure }
            return FeedAuthResponse(token: "t\(index)", expiresAt: expiresAt, region: nil)
        }
    }

    private func make(_ fetcher: Fetcher, _ clock: TestClock, jitter: Double = 1) -> CachingFeedTokenSource {
        CachingFeedTokenSource(fetcher: fetcher, clock: { clock.now }, jitter: { jitter })
    }

    private let expires = FeedDates.format(t0.addingTimeInterval(86400))

    func testClassify() {
        let now = t0
        XCTAssertEqual(FeedAuthFailure.classify(statusCode: 429, retryAfter: "30", now: now)?.retryAfterSeconds, 30)
        XCTAssertEqual(FeedAuthFailure.classify(statusCode: 429, retryAfter: "30", now: now)?.code, "auth_throttled", "和 Android 同名")
        XCTAssertNil(FeedAuthFailure.classify(statusCode: 429, retryAfter: nil, now: now)?.retryAfterSeconds)
        XCTAssertEqual(FeedAuthFailure.classify(statusCode: 429, retryAfter: "0", now: now)?.retryAfterSeconds, 1)
        XCTAssertEqual(FeedAuthFailure.classify(statusCode: 429, retryAfter: "999999", now: now)?.retryAfterSeconds, 3600)
        XCTAssertEqual(FeedAuthFailure.classify(statusCode: 429, retryAfter: httpDate(t0.addingTimeInterval(50)), now: now)?.retryAfterSeconds, 50)
        XCTAssertEqual(FeedAuthFailure.classify(statusCode: 503, retryAfter: "15", now: now)?.isThrottle, true)
        XCTAssertNil(FeedAuthFailure.classify(statusCode: 503, retryAfter: nil, now: now), "503 没带头 = 普通失败")
        XCTAssertNil(FeedAuthFailure.classify(statusCode: 503, retryAfter: "soon", now: now))
        XCTAssertNil(FeedAuthFailure.classify(statusCode: 500, retryAfter: "15", now: now))
        XCTAssertTrue(FeedAuthFailure.classify(statusCode: 404, retryAfter: "15", now: now)!.isAuthNotDeployed, "没部署还是没部署")
    }

    func testAThrottledAuthEndpointIsNotAskedAgainUntilTheDelayPasses() async throws {
        let clock = TestClock()
        let fetcher = Fetcher(expiresAt: expires)
        fetcher.script = [FeedAPIError(status: 429, code: "auth_unavailable", retryAfterSeconds: 30)]
        let source = make(fetcher, clock)

        do { _ = try await source.token(forceRefresh: false); XCTFail() } catch let error as FeedAPIError { XCTAssertEqual(error.status, 429) }
        XCTAssertEqual(fetcher.calls, 1)

        clock.advance(10)
        for force in [false, true] {
            do { _ = try await source.token(forceRefresh: force); XCTFail() } catch let error as FeedAPIError {
                XCTAssertEqual(error.status, 429)
                XCTAssertEqual(error.retryAfterSeconds, 20)
                XCTAssertEqual(error.code, "auth_throttled")
            }
        }
        XCTAssertEqual(fetcher.calls, 1, "等待期里（包括 forceRefresh）不打网络")

        clock.advance(20)
        let token = try await source.token(forceRefresh: false)
        XCTAssertEqual(token, "t1")
        XCTAssertEqual(fetcher.calls, 2)
        _ = try await source.token(forceRefresh: true)
        XCTAssertEqual(fetcher.calls, 3, "成功之后不再等")
    }

    func testWithoutAHeaderTheAuthBackoffIsExponential() async {
        let clock = TestClock()
        let fetcher = Fetcher(expiresAt: expires)
        fetcher.script = Array(repeating: FeedAPIError(status: 429, code: "auth_unavailable", retryAfterSeconds: nil), count: 3)
        let source = make(fetcher, clock, jitter: 1)
        var waits = [Int?]()
        for _ in 0..<3 {
            _ = try? await source.token(forceRefresh: false)
            do { _ = try await source.token(forceRefresh: false) } catch let error as FeedAPIError {
                waits.append(error.retryAfterSeconds)
                clock.advance(TimeInterval(error.retryAfterSeconds ?? 0))
            } catch {}
        }
        XCTAssertEqual(waits, [30, 60, 120])
        XCTAssertEqual(fetcher.calls, 3)
    }

    func testAnOrdinaryFailureDoesNotBlockAndAValidCachedTokenIsStillUsed() async throws {
        let clock = TestClock()
        let fetcher = Fetcher(expiresAt: expires)
        fetcher.script = [nil, FeedAPIError(status: 503, code: "auth_unavailable", retryAfterSeconds: 30), FeedAPIError(status: 500, code: "x", retryAfterSeconds: 30), URLError(.timedOut)]
        let source = make(fetcher, clock)
        let first = try await source.token(forceRefresh: false)
        XCTAssertEqual(first, "t0")
        // 限速之后，缓存里还有效的 token 照用（不用问）
        do { _ = try await source.token(forceRefresh: true); XCTFail() } catch {}
        let cached = try await source.token(forceRefresh: false)
        XCTAssertEqual(cached, "t0")
        XCTAssertEqual(fetcher.calls, 2)

        // 500 / 网络错误：不是限速，下一次照问
        let other = make(fetcher, clock)
        _ = try? await other.token(forceRefresh: false)   // 第 3 次调用：500
        _ = try? await other.token(forceRefresh: false)   // 第 4 次调用：超时
        XCTAssertEqual(fetcher.calls, 4)
    }

    /// 成功一次之后，指数退避从头数（不然下一次限速直接等 60 秒）。
    func testASuccessRestartsTheBackoffCount() async throws {
        let clock = TestClock()
        let fetcher = Fetcher(expiresAt: expires)
        let limited = FeedAPIError(status: 429, code: "auth_unavailable", retryAfterSeconds: nil)
        fetcher.script = [limited, nil, limited]
        let source = make(fetcher, clock, jitter: 1)
        _ = try? await source.token(forceRefresh: false)
        clock.advance(30)
        _ = try await source.token(forceRefresh: true)   // 成功
        _ = try? await source.token(forceRefresh: true)  // 又 429
        do { _ = try await source.token(forceRefresh: true); XCTFail() } catch let error as FeedAPIError {
            XCTAssertEqual(error.retryAfterSeconds, 30, "成功之后又被限速，从头数：30 秒，不是 60")
        }
    }

    func testClearForgetsTheThrottle() async throws {
        let clock = TestClock()
        let fetcher = Fetcher(expiresAt: expires)
        fetcher.script = [FeedAPIError(status: 429, code: "auth_unavailable", retryAfterSeconds: 600)]
        let source = make(fetcher, clock)
        _ = try? await source.token(forceRefresh: false)
        await source.clear() // 退出登录 / 切区：新账号不该等旧账号的限速
        _ = try await source.token(forceRefresh: false)
        XCTAssertEqual(fetcher.calls, 2)
    }
}

// MARK: - Signal-Server signer (friend-assertions, audience lists)

final class TellomiFeedSignerThrottleTests: XCTestCase {
    private final class Transport: FeedSignerTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies = [FeedSignerHTTPResponse]()
        private var _requests = [String]()
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
        func reply(_ status: Int, _ headers: [String: String] = [:], _ body: String = "") {
            lock.lock(); replies.append(FeedSignerHTTPResponse(status: status, headers: headers, body: Data(body.utf8))); lock.unlock()
        }
        func send(method: String, path: String, json: Data?) async throws -> FeedSignerHTTPResponse {
            return lock.locked {
                _requests.append("\(method) \(path)")
                return replies.isEmpty ? FeedSignerHTTPResponse(status: 200, headers: [:], body: Data(#"{"assertion":"s","audience_token":"tok"}"#.utf8)) : replies.removeFirst()
            }
        }
    }

    private let aci = "11111111-2222-3333-4444-555555555555"
    private func make(_ transport: Transport, _ clock: TestClock, jitter: Double = 1) -> FeedHTTPFriendSigner {
        FeedHTTPFriendSigner(transport: transport, clock: { clock.now }, jitter: { jitter })
    }
    private func friend(_ signer: FeedHTTPFriendSigner, add: Bool = true) async -> FeedAPIError? {
        do { _ = try await signer.friendAssertion(peerAci: aci, add: add); return nil } catch { return error as? FeedAPIError }
    }
    private func audience(_ signer: FeedHTTPFriendSigner) async -> FeedAPIError? {
        do { _ = try await signer.audienceToken(kind: "include", peerAcis: [aci]); return nil } catch { return error as? FeedAPIError }
    }

    func testTheHeaderIsReadAndFriendAssertionsWaitWithoutTouchingTheNetwork() async {
        let clock = TestClock(), transport = Transport()
        let signer = make(transport, clock)
        transport.reply(429, ["Retry-After": "45"])
        let first = await friend(signer)
        XCTAssertEqual(first, FeedAPIError(status: 429, code: "assertion_unavailable", retryAfterSeconds: 45))

        clock.advance(15)
        let early = await friend(signer)
        XCTAssertEqual(early?.status, 429)
        XCTAssertEqual(early?.retryAfterSeconds, 30)
        let withdraw = await friend(signer, add: false)
        XCTAssertEqual(withdraw?.status, 429, "撤回走同一条路由，也在等")
        XCTAssertEqual(transport.requests.count, 1)

        clock.advance(30)
        let ok = await friend(signer)
        XCTAssertNil(ok)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testAudienceListsAreThrottledSeparately() async {
        let clock = TestClock(), transport = Transport()
        let signer = make(transport, clock)
        transport.reply(429, ["Retry-After": "60"])
        let throttled = await audience(signer)
        XCTAssertEqual(throttled, FeedAPIError(status: 429, code: "audience_throttled", retryAfterSeconds: 60))
        let again = await audience(signer)
        XCTAssertEqual(again?.retryAfterSeconds, 60)
        XCTAssertEqual(again?.code, "audience_throttled", "本地挡下的也是同一个码")
        XCTAssertEqual(transport.requests.count, 1)
        // 好友声明那条路由没被限速
        let other = await friend(signer)
        XCTAssertNil(other)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testHeaderFormsAndEdgeCases() async {
        let clock = TestClock()
        let cases: [(String?, Int?)] = [("0", 1), ("86400", 3600), (nil, nil), ("garbage", nil), (httpDate(t0.addingTimeInterval(120)), 120), (httpDate(t0.addingTimeInterval(-5)), 1)]
        for (header, expected) in cases {
            let transport = Transport()
            transport.reply(429, header.map { ["Retry-After": $0] } ?? [:])
            let error = await friend(make(transport, clock))
            XCTAssertEqual(error?.retryAfterSeconds, expected, "\(String(describing: header))")
        }
        // 头名不分大小写
        let transport = Transport()
        transport.reply(429, ["retry-after": "9"])
        let lower = await friend(make(transport, clock))
        XCTAssertEqual(lower?.retryAfterSeconds, 9)
    }

    func testNoHeaderMeansExponentialBackoff() async {
        let clock = TestClock(), transport = Transport()
        let signer = make(transport, clock, jitter: 1)
        var waits = [Int?]()
        for _ in 0..<3 {
            transport.reply(429)
            _ = await friend(signer)
            let blocked = await friend(signer)
            waits.append(blocked?.retryAfterSeconds)
            clock.advance(TimeInterval(blocked?.retryAfterSeconds ?? 0))
        }
        XCTAssertEqual(waits, [30, 60, 120])
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testA503NeedsTheHeader() async {
        let clock = TestClock()
        let with = Transport(), without = Transport()
        with.reply(503, ["Retry-After": "20"])
        without.reply(503)
        let a = make(with, clock), b = make(without, clock)
        _ = await friend(a)
        let blocked = await friend(a)
        XCTAssertEqual(blocked?.retryAfterSeconds, 20)
        XCTAssertEqual(with.requests.count, 1)
        _ = await friend(b)
        let free = await friend(b)
        XCTAssertNil(free)
        XCTAssertEqual(without.requests.count, 2)
    }

    func testOtherFailuresAndTheNotFoundMarkerNeverBlock() async {
        let clock = TestClock()
        for status in [400, 401, 403, 409, 422, 500, 502] {
            let transport = Transport()
            transport.reply(status, ["Retry-After": "60"])
            let signer = make(transport, clock)
            let first = await friend(signer)
            XCTAssertEqual(first?.status, status)
            XCTAssertEqual(first?.retryAfterSeconds, 60, "头照样读出来，只是不是限速")
            _ = await friend(signer)
            XCTAssertEqual(transport.requests.count, 2, "\(status)")
        }
        let transport = Transport()
        transport.reply(404, ["Content-Type": "application/json", "Retry-After": "60"], #"{"error":"account_not_found"}"#)
        let signer = make(transport, clock)
        let marker = try? await signer.friendAssertion(peerAci: aci, add: true)
        XCTAssertNil(marker)
        _ = await friend(signer)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testFriendSyncStopsOnAThrottleAndStaysQuietUntilTheDelayPasses() async {
        let clock = TestClock(), transport = Transport()
        let signer = make(transport, clock)
        let sent = SentLog()
        let state = InMemoryFeedFriendSyncState()
        let a = "aaaaaaaa-0000-0000-0000-000000000001", b = "bbbbbbbb-0000-0000-0000-000000000002"
        let sync = FeedFriendSync(
            enabled: { true },
            engineKey: { "cn https://feed.example.test" },
            friends: { [a, b] },
            signer: signer,
            engine: { sent.append($0) },
            state: state,
            features: StaticFeedFeatureGate([FeedFeature.friendAssertions]),
            clock: { clock.now }
        )
        transport.reply(429, ["Retry-After": "3600"])
        let first = await sync.syncIfStale()
        XCTAssertEqual(first, .failed)
        XCTAssertEqual(transport.requests.count, 1, "第一个 429 就停，不对别的好友再试")
        XCTAssertEqual(state.reported(engineKey: "cn https://feed.example.test"), [], "限速不是「没账号」，不能记成已报")

        clock.advance(FeedFriendSync.interval + 1) // 15 分钟的间隔过了，但 3600 秒还没
        _ = await sync.syncIfStale()
        XCTAssertEqual(transport.requests.count, 1, "还在 Retry-After 里：不发请求")
        XCTAssertEqual(state.reported(engineKey: "cn https://feed.example.test"), [])

        clock.advance(3600)
        let later = await sync.syncIfStale()
        XCTAssertEqual(later, .done)
        XCTAssertEqual(state.reported(engineKey: "cn https://feed.example.test"), [a, b])
        XCTAssertEqual(sent.all.count, 2)
    }
}

/// 引擎调用记录：`engine` 闭包是 `@Sendable`，不能直接改外面的 `var`。
private final class SentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [String]()
    func append(_ item: String) { lock.locked { items.append(item) } }
    var all: [String] { lock.locked { items } }
}

// MARK: - capabilities

final class TellomiFeedCapabilitiesThrottleTests: XCTestCase {
    private final class Transport: FeedHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies = [(Int, [String: String])]()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func reply(_ status: Int, _ headers: [String: String] = [:]) { lock.lock(); replies.append((status, headers)); lock.unlock() }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (status, headers) = lock.locked {
                _count += 1
                return replies.isEmpty ? (200, [String: String]()) : replies.removeFirst()
            }
            let body = status == 200 ? #"{"version":1,"features":["feed"]}"# : ""
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    private func fetcher(_ transport: Transport, _ clock: TestClock) -> FeedCapabilitiesFetcher {
        FeedCapabilitiesFetcher(baseURL: URL(string: "https://feed.example.test")!, transport: transport, clock: { clock.now })
    }

    private func error(_ transport: Transport, _ clock: TestClock) async -> FeedCapabilitiesError? {
        do { _ = try await fetcher(transport, clock).fetch(); return nil } catch { return error as? FeedCapabilitiesError }
    }

    func testFetcherMapsThrottles() async {
        let clock = TestClock()
        let cases: [(Int, [String: String], FeedCapabilitiesError)] = [
            (429, ["Retry-After": "120"], .throttled(retryAfterSeconds: 120)),
            (429, [:], .throttled(retryAfterSeconds: nil)),
            (429, ["Retry-After": "0"], .throttled(retryAfterSeconds: 1)),
            (429, ["Retry-After": "999999"], .throttled(retryAfterSeconds: 3600)),
            (429, ["Retry-After": "nope"], .throttled(retryAfterSeconds: nil)),
            (429, ["Retry-After": httpDate(t0.addingTimeInterval(80))], .throttled(retryAfterSeconds: 80)),
            (503, ["Retry-After": "30"], .throttled(retryAfterSeconds: 30)),
            (503, [:], .http(503)),
            (500, ["Retry-After": "30"], .http(500)),
            (404, ["Retry-After": "30"], .notFound),
        ]
        for (status, headers, expected) in cases {
            let transport = Transport()
            transport.reply(status, headers)
            let actual = await error(transport, clock)
            XCTAssertEqual(actual, expected, "\(status) \(headers)")
        }
    }

    func testCacheRemembersAThrottleForTheRetryAfter() async {
        let clock = TestClock(), transport = Transport()
        let cache = FeedCapabilitiesCache(fetcher: fetcher(transport, clock), clock: { clock.now }, jitter: { 1 })
        transport.reply(429, ["Retry-After": "120"])
        let first = await cache.current()
        XCTAssertEqual(first, .unavailable(.throttled(retryAfterSeconds: 120)))
        XCTAssertFalse(first.has("feed"))

        clock.advance(119)
        _ = await cache.current()
        XCTAssertEqual(transport.count, 1, "119 秒里不再问（普通失败只记 30 秒）")
        clock.advance(2)
        let second = await cache.current()
        XCTAssertEqual(transport.count, 2)
        XCTAssertTrue(second.has("feed"))
    }

    func testAShortRetryAfterStillWaitsForTheFailureTTL() async {
        let clock = TestClock(), transport = Transport()
        let cache = FeedCapabilitiesCache(fetcher: fetcher(transport, clock), clock: { clock.now })
        transport.reply(429, ["Retry-After": "1"])
        _ = await cache.current()
        clock.advance(29)
        _ = await cache.current()
        XCTAssertEqual(transport.count, 1)
        clock.advance(2)
        _ = await cache.current()
        XCTAssertEqual(transport.count, 2)
    }

    func testNoHeaderBacksOffExponentiallyAcrossRefetches() async {
        let clock = TestClock(), transport = Transport()
        let cache = FeedCapabilitiesCache(fetcher: fetcher(transport, clock), failureTTL: 1, clock: { clock.now }, jitter: { 1 })
        for _ in 0..<3 { transport.reply(429) }
        // 每过 1 秒问一次缓存，记下真正去问服务端的那几秒
        var fetchTimes = [Int]()
        var seen = 0
        for second in 0...300 {
            _ = await cache.current()
            if transport.count > seen { seen = transport.count; fetchTimes.append(second) }
            clock.advance(1)
        }
        let lifetimes = zip(fetchTimes, fetchTimes.dropFirst()).map { $1 - $0 }
        XCTAssertEqual(Array(lifetimes.prefix(3)), [30, 60, 120], "第 n 次连续限速等 30、60、120 秒（抖动取满）")
        XCTAssertGreaterThanOrEqual(fetchTimes.count, 4, "第 3 次 429 之后是成功的默认回答")
    }

    func testOrdinaryFailuresKeepTheShortTTL() async {
        let clock = TestClock(), transport = Transport()
        let cache = FeedCapabilitiesCache(fetcher: fetcher(transport, clock), clock: { clock.now })
        transport.reply(503)
        _ = await cache.current()
        clock.advance(31)
        _ = await cache.current()
        XCTAssertEqual(transport.count, 2)
    }
}

// MARK: - uploads

final class TellomiFeedUploadThrottleTests: XCTestCase {
    private final class Transport: FeedHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies = [(Int, [String: String], String)]()
        private var _methods = [String]()
        var methods: [String] { lock.lock(); defer { lock.unlock() }; return _methods }
        func reply(_ status: Int, _ headers: [String: String] = [:], _ body: String = "") { lock.lock(); replies.append((status, headers, body)); lock.unlock() }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (status, headers, body) = lock.locked {
                _methods.append(request.httpMethod ?? "?")
                return replies.removeFirst()
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    private struct FixedTokens: FeedTokenSource {
        func token(forceRefresh: Bool) async throws -> String { "t" }
    }

    private final class Sleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var _all = [TimeInterval]()
        let clock: TestClock
        init(_ clock: TestClock) { self.clock = clock }
        var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _all }
        func sleep(_ seconds: TimeInterval) { lock.lock(); _all.append(seconds); lock.unlock(); clock.advance(seconds) }
    }

    func testA503WithRetryAfterWaitsBeforeAskingWhereToResume() async throws {
        let clock = TestClock(), transport = Transport(), sleeps = Sleeps(clock)
        transport.reply(201, ["Media-Key": "m/k"], #"{"id":"u1","key":"m/k"}"#)
        transport.reply(503, ["Retry-After": "7"], #"{"error":"media_unavailable"}"#)
        transport.reply(200, ["Upload-Offset": "0"])
        transport.reply(204, ["Upload-Offset": "3"])
        let api = FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens())
        api.clock = { clock.now }
        var uploader = FeedImageUploader(api: api, chunkSize: 4)
        uploader.sleep = { sleeps.sleep($0) }

        let key = try await uploader.upload(Data(count: 3))
        XCTAssertEqual(key, "m/k")
        XCTAssertEqual(sleeps.all, [7], "先等 Retry-After，再 HEAD（不然 HEAD 也被限速门拦下）")
        XCTAssertEqual(transport.methods, ["POST", "PATCH", "HEAD", "PATCH"])
    }

    func testA503WithoutTheHeaderResumesRightAway() async throws {
        let clock = TestClock(), transport = Transport(), sleeps = Sleeps(clock)
        transport.reply(201, ["Media-Key": "m/k"], #"{"id":"u1","key":"m/k"}"#)
        transport.reply(503, [:], #"{"error":"media_unavailable"}"#)
        transport.reply(200, ["Upload-Offset": "0"])
        transport.reply(204, ["Upload-Offset": "3"])
        let api = FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens())
        api.clock = { clock.now }
        var uploader = FeedImageUploader(api: api, chunkSize: 4)
        uploader.sleep = { sleeps.sleep($0) }
        _ = try await uploader.upload(Data(count: 3))
        XCTAssertEqual(sleeps.all, [])
        XCTAssertEqual(transport.methods, ["POST", "PATCH", "HEAD", "PATCH"])
    }

    /// 引擎的并发上限（429 `too_many_uploads` + `Retry-After: 60`）：不算限速，不续传、不等、不挡下一次（和 Android 一样）。
    func testTooManyUploadsIsNotRetriedAndDoesNotBlock() async {
        let clock = TestClock(), transport = Transport(), sleeps = Sleeps(clock)
        transport.reply(429, ["Retry-After": "60"], #"{"error":"too_many_uploads"}"#)
        transport.reply(429, ["Retry-After": "60"], #"{"error":"too_many_uploads"}"#)
        let api = FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens())
        api.clock = { clock.now }
        var uploader = FeedImageUploader(api: api, chunkSize: 4)
        uploader.sleep = { sleeps.sleep($0) }
        for _ in 0..<2 {
            do { _ = try await uploader.upload(Data(count: 3)); XCTFail() } catch let error as FeedAPIError {
                XCTAssertEqual(error.status, 429)
                XCTAssertEqual(error.code, "too_many_uploads")
                XCTAssertEqual(error.retryAfterSeconds, 60, "头照样读出来，界面可以用")
            } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(transport.methods, ["POST", "POST"])
        XCTAssertEqual(sleeps.all, [])
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
