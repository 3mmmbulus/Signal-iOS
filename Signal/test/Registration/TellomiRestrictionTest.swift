//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest
@testable import Signal
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi ADR-0078 §3.4）：服务端处置说明的解析、存取格式、节流、注册时的 422 和说明文字。
final class TellomiRestrictionTest: XCTestCase {

    private func body(level: String = "stranger", until: Int64 = 1_792_000_000, caseId: String? = "20261017-abcd1234") -> Data {
        var raw: [String: Any] = ["level": level, "until": until, "appeal": "abuse@tellomi.app", "extra": 1]
        if let caseId {
            raw["case"] = caseId
        }
        return try! JSONSerialization.data(withJSONObject: ["tellomiRestriction": raw])
    }

    func testParsesTheServerBody() {
        XCTAssertEqual(
            TellomiRestriction.parse(body()),
            TellomiRestriction(level: .stranger, until: Date(timeIntervalSince1970: 1_792_000_000), appeal: "abuse@tellomi.app", caseId: "20261017-abcd1234"),
        )
        XCTAssertNil(TellomiRestriction.parse(body(caseId: nil))?.caseId)
        XCTAssertNil(TellomiRestriction.parse(body(caseId: "has spaces"))?.caseId)
    }

    func testAnythingMalformedIsIgnored() {
        for bad in [nil, Data(), Data("Forbidden".utf8), Data("{}".utf8), Data(#"{"tellomiRestriction":null}"#.utf8), body(level: "terminated"), body(until: 0)] {
            XCTAssertNil(TellomiRestriction.parse(bad))
        }
        XCTAssertNil(TellomiRestriction.parse(Data(#"{"tellomiRestriction":{"level":"all","until":1,"appeal":"nope"}}"#.utf8)))
    }

    func testStorageRoundTripsAndLapsesAtTheDeadline() throws {
        let restriction = try XCTUnwrap(TellomiRestriction.parse(body(level: "all")))
        XCTAssertEqual(TellomiRestriction.parse(restriction.jsonData()), restriction)
        XCTAssertTrue(restriction.isActive(now: restriction.until.addingTimeInterval(-1)))
        XCTAssertFalse(restriction.isActive(now: restriction.until))
    }

    func testAsksAtMostEverySixHours() {
        let now = Date()
        XCTAssertTrue(TellomiRestrictions.shouldCheck(now: now, lastChecked: nil))
        XCTAssertFalse(TellomiRestrictions.shouldCheck(now: now, lastChecked: now.addingTimeInterval(-5 * .hour)))
        XCTAssertTrue(TellomiRestrictions.shouldCheck(now: now, lastChecked: now.addingTimeInterval(-6 * .hour)))
        XCTAssertTrue(TellomiRestrictions.shouldCheck(now: now, lastChecked: now.addingTimeInterval(.hour)), "clock went backwards")
        // 有处置时每 15 分钟问一次，提前解除时提示不会多挂几个小时
        XCTAssertTrue(TellomiRestrictions.shouldCheck(now: now, lastChecked: now.addingTimeInterval(-16 * .minute), isRestricted: true))
        XCTAssertFalse(TellomiRestrictions.shouldCheck(now: now, lastChecked: now.addingTimeInterval(-5 * .minute), isRestricted: true))
    }

    func testRecognisesTheForbiddenSendFromLibsignal() {
        // libsignal 把没处理的状态码变成 networkProtocolError("unexpected response status <n>")；只有 403 才去问服务端
        XCTAssertTrue(TellomiRestrictions.isForbiddenSend(SignalError.networkProtocolError("unexpected response status 403")))
        XCTAssertFalse(TellomiRestrictions.isForbiddenSend(SignalError.networkProtocolError("unexpected response status 500")))
        XCTAssertFalse(TellomiRestrictions.isForbiddenSend(SignalError.requestUnauthorized("401")))
        XCTAssertFalse(TellomiRestrictions.isForbiddenSend(NSError(domain: "test", code: 403)))
    }

    /// 被暂停的号码重新注册：422 + 说明 → 专门的错误；别的 422 照旧是通用错误。
    func testSuspendedNumberAtRegistration() {
        func response(_ data: Data) -> RegistrationCoordinatorImpl.AccountResponse {
            return RegistrationCoordinatorImpl.Service.handleCreateAccountResponse(
                authPassword: "password",
                statusCode: 422,
                retryAfterHeader: nil,
                bodyData: data,
                logger: PrefixedLogger(prefix: "[Test]"),
            )
        }
        guard case .tellomiSuspended(let restriction) = response(body(level: "suspended")) else {
            return XCTFail("a suspended number should get its own error")
        }
        XCTAssertEqual(restriction.caseId, "20261017-abcd1234")
        guard case .genericError = response(Data("Bad request".utf8)) else {
            return XCTFail("other 422s stay generic")
        }
        guard case .genericError = response(body(level: "stranger")) else {
            return XCTFail("only a suspension explains a refused registration")
        }
    }

    func testNoticeNamesTheDeadlineTheAppealAddressAndTheCase() throws {
        let restriction = try XCTUnwrap(TellomiRestriction.parse(body()))
        let notice = TellomiRestrictionUI.notice(restriction)
        XCTAssertTrue(notice.contains("abuse@tellomi.app"))
        XCTAssertTrue(notice.contains("20261017-abcd1234"))
        XCTAssertTrue(notice.contains(TellomiRestrictionUI.untilText(restriction.until)))
        let withoutCase = try XCTUnwrap(TellomiRestriction.parse(body(level: "suspended", caseId: nil)))
        XCTAssertFalse(TellomiRestrictionUI.suspendedAtRegistration(withoutCase).contains("%"))
    }
}
