//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0068 §4.7（tellomi/tellomi#1263）：说明文字在媒体上方。按消息的 uniqueId 记在本机（为真才有），
/// 收到 / 编辑时照 DataMessage 改，发出去时只在为真时写 `tellomi = 1000`。
class TellomiCaptionAboveTests: XCTestCase {

    private var db: InMemoryDB!

    override func setUp() async throws {
        db = InMemoryDB()
    }

    func testOnlyAMarkedMessageGoesOutWithTheField() throws {
        db.write { tx in
            TellomiCaptionAbove.setCaptionAboveMedia(true, messageUniqueId: "above", tx: tx)
        }

        try db.read { tx in
            XCTAssertTrue(TellomiCaptionAbove.isCaptionAboveMedia(messageUniqueId: "above", tx: tx))
            XCTAssertFalse(TellomiCaptionAbove.isCaptionAboveMedia(messageUniqueId: "ordinary", tx: tx))
            XCTAssertNil(TellomiCaptionAbove.proto(messageUniqueId: "ordinary", tx: tx))

            let tellomi = try XCTUnwrap(TellomiCaptionAbove.proto(messageUniqueId: "above", tx: tx))
            let dataMessage = SSKProtoDataMessage.builder()
            dataMessage.setTellomi(tellomi)
            // Same golden bytes as the other two clients (docs/signal/VERSIONS.md).
            XCTAssertEqual(try dataMessage.build().serializedData().hexadecimalString, "c23e020801")
        }
    }

    func testAReceivedMessageKeepsWhatItSays_andAnEditCanMoveItBack() throws {
        db.write { tx in
            TellomiCaptionAbove.apply(from: try! dataMessage(captionAboveMedia: true), messageUniqueId: "message", tx: tx)
        }
        db.read { tx in
            XCTAssertTrue(TellomiCaptionAbove.isCaptionAboveMedia(messageUniqueId: "message", tx: tx))
        }

        // An edit carries the whole new DataMessage: without the flag, the caption goes back below.
        db.write { tx in
            TellomiCaptionAbove.apply(from: try! dataMessage(captionAboveMedia: nil), messageUniqueId: "message", tx: tx)
        }
        db.read { tx in
            XCTAssertFalse(TellomiCaptionAbove.isCaptionAboveMedia(messageUniqueId: "message", tx: tx))
        }
    }

    func testFalseOnTheWireIsNotAbove() throws {
        db.write { tx in
            TellomiCaptionAbove.apply(from: try! dataMessage(captionAboveMedia: false), messageUniqueId: "message", tx: tx)
        }
        db.read { tx in
            XCTAssertFalse(TellomiCaptionAbove.isCaptionAboveMedia(messageUniqueId: "message", tx: tx))
        }
    }

    private func dataMessage(captionAboveMedia: Bool?) throws -> SSKProtoDataMessage {
        let builder = SSKProtoDataMessage.builder()
        builder.setBody("caption")
        if let captionAboveMedia {
            let tellomi = SSKProtoTellomiDataMessage.builder()
            tellomi.setCaptionAboveMedia(captionAboveMedia)
            builder.setTellomi(tellomi.buildInfallibly())
        }
        return try builder.build()
    }
}
