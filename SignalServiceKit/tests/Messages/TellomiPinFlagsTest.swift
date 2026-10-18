//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0081 (tellomi/tellomi#1197): `DataMessage.tellomi.pinForSelfOnly = 4` (a pin / unpin for my own devices only, sent
/// only in a sync transcript) and `pinSilent = 5` (a group pin for everyone without notifying). No protocol version bump.
class TellomiPinFlagsTest: XCTestCase {

    func testGoldenBytesSharedByTheThreeClients() throws {
        // key = 1000 << 3 | 2 = c2 3e; TellomiDataMessage{pinForSelfOnly = true} = 20 01, {pinSilent = true} = 28 01
        XCTAssertEqual(try dataMessage { $0.setPinForSelfOnly(true) }.serializedData().hexadecimalString, "c23e022001")
        XCTAssertEqual(try dataMessage { $0.setPinSilent(true) }.serializedData().hexadecimalString, "c23e022801")
    }

    func testTheFlagsDecodeBack() throws {
        let selfOnly = try SSKProtoDataMessage(serializedData: try XCTUnwrap(Data.data(fromHex: "c23e022001")))
        XCTAssertTrue(try XCTUnwrap(selfOnly.tellomi).pinForSelfOnly)
        XCTAssertFalse(try XCTUnwrap(selfOnly.tellomi).hasPinSilent)

        let silent = try SSKProtoDataMessage(serializedData: try XCTUnwrap(Data.data(fromHex: "c23e022801")))
        XCTAssertTrue(try XCTUnwrap(silent.tellomi).pinSilent)
    }

    private func dataMessage(_ configure: (SSKProtoTellomiDataMessageBuilder) -> Void) throws -> SSKProtoDataMessage {
        let tellomi = SSKProtoTellomiDataMessage.builder()
        configure(tellomi)
        let builder = SSKProtoDataMessage.builder()
        builder.setTellomi(tellomi.buildInfallibly())
        return try builder.build()
    }
}
