//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0079 (tellomi/tellomi#1714): a timed view-once photo / video is `isViewOnce = true` plus
/// `DataMessage.tellomi.viewOnceSeconds` (3 / 10 / 30), kept on this device per message, with no protocol version bump.
class TellomiViewOnceTimerTests: XCTestCase {

    private var db: InMemoryDB!

    override func setUp() async throws {
        db = InMemoryDB()
    }

    // MARK: - Wire

    func testGoldenBytesSharedByTheThreeClients() throws {
        // key = 1000 << 3 | 2 = c2 3e; TellomiDataMessage{viewOnceSeconds = 3} = 18 03 (field 3, varint)
        XCTAssertEqual(try dataMessage(seconds: 3, isViewOnce: nil).serializedData().hexadecimalString, "c23e021803")
        XCTAssertEqual(try dataMessage(seconds: 30, isViewOnce: nil).serializedData().hexadecimalString, "c23e02181e")
    }

    func testOnlyTheAllowedSecondsOnAViewOnceMessageCount() throws {
        XCTAssertEqual(TellomiViewOnceTimer.seconds(from: try dataMessage(seconds: 10, isViewOnce: true)), 10)
        // Not view once: ignored (shown as an ordinary message).
        XCTAssertNil(TellomiViewOnceTimer.seconds(from: try dataMessage(seconds: 10, isViewOnce: false)))
        XCTAssertNil(TellomiViewOnceTimer.seconds(from: try dataMessage(seconds: 10, isViewOnce: nil)))
        // Other values: ignored, plain view once.
        for odd: UInt32 in [0, 5, 60] {
            XCTAssertNil(TellomiViewOnceTimer.seconds(from: try dataMessage(seconds: odd, isViewOnce: true)))
        }
        XCTAssertNil(TellomiViewOnceTimer.seconds(from: try dataMessage(seconds: nil, isViewOnce: true)))
    }

    func testTheOutgoingFieldCarriesTheSecondsAndTheCaptionFlagTogether() throws {
        db.write { tx in
            TellomiCaptionAbove.setCaptionAboveMedia(true, messageUniqueId: "above", tx: tx)
        }
        try db.read { tx in
            XCTAssertNil(TellomiCaptionAbove.proto(messageUniqueId: "ordinary", viewOnceSeconds: nil, tx: tx), "bytes stay upstream's")
            XCTAssertNil(TellomiCaptionAbove.proto(messageUniqueId: "ordinary", viewOnceSeconds: 7, tx: tx), "not an allowed value")

            let timed = try XCTUnwrap(TellomiCaptionAbove.proto(messageUniqueId: "ordinary", viewOnceSeconds: 3, tx: tx))
            XCTAssertEqual(timed.viewOnceSeconds, 3)
            XCTAssertFalse(timed.hasCaptionAboveMedia)

            let both = try XCTUnwrap(TellomiCaptionAbove.proto(messageUniqueId: "above", viewOnceSeconds: 30, tx: tx))
            XCTAssertTrue(both.captionAboveMedia)
            XCTAssertEqual(both.viewOnceSeconds, 30)
        }
    }

    // MARK: - On this device

    func testAReceivedTimedViewOnceIsRemembered() throws {
        db.write { tx in
            TellomiViewOnceTimer.markReceived(try! dataMessage(seconds: 10, isViewOnce: true), messageUniqueId: "timed", tx: tx)
            TellomiViewOnceTimer.markReceived(try! dataMessage(seconds: nil, isViewOnce: true), messageUniqueId: "plain", tx: tx)
            TellomiViewOnceTimer.markReceived(try! dataMessage(seconds: 10, isViewOnce: false), messageUniqueId: "ordinary", tx: tx)
        }
        db.read { tx in
            XCTAssertEqual(TellomiViewOnceTimer.seconds(messageUniqueId: "timed", tx: tx), 10)
            XCTAssertNil(TellomiViewOnceTimer.seconds(messageUniqueId: "plain", tx: tx))
            XCTAssertNil(TellomiViewOnceTimer.seconds(messageUniqueId: "ordinary", tx: tx))
        }
    }

    func testTheViewerStaysOpenForTheSecondsOrTheWholeVideo() {
        XCTAssertEqual(TellomiViewOnceTimer.viewerDuration(seconds: 10, videoDuration: nil), 10)
        XCTAssertEqual(TellomiViewOnceTimer.viewerDuration(seconds: 10, videoDuration: 4), 10)
        XCTAssertEqual(TellomiViewOnceTimer.viewerDuration(seconds: 3, videoDuration: 12.5), 12.5, "max(duration, N), as Telegram iOS")
    }

    func testOutgoingMediaCarriesTheSeconds() {
        let media = TellomiOutgoingMedia(spoilers: [false], viewOnceSeconds: 30)
        XCTAssertEqual(media.viewOnceSeconds, 30)
        XCTAssertFalse(media.isEmpty)
        XCTAssertTrue(TellomiOutgoingMedia().isEmpty)
    }

    // MARK: - Helpers

    private func dataMessage(seconds: UInt32?, isViewOnce: Bool?) throws -> SSKProtoDataMessage {
        let builder = SSKProtoDataMessage.builder()
        if let isViewOnce {
            builder.setIsViewOnce(isViewOnce)
        }
        if let seconds {
            let tellomi = SSKProtoTellomiDataMessage.builder()
            tellomi.setViewOnceSeconds(seconds)
            builder.setTellomi(tellomi.buildInfallibly())
        }
        return try builder.build()
    }
}
