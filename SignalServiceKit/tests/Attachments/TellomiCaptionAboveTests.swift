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

    // MARK: - ADR-0075 per-media captions

    func testPerMediaCaptionGoldenBytesSharedByTheThreeClients() throws {
        // TellomiAttachment{caption = "a"} = 22 01 61
        let tellomi = SSKProtoTellomiAttachment.builder()
        tellomi.setCaption("a")
        let pointer = SSKProtoAttachmentPointer.builder()
        pointer.setTellomi(tellomi.buildInfallibly())
        XCTAssertEqual(try pointer.buildInfallibly().serializedData().hexadecimalString, "ca3e03220161")

        // TellomiDataMessage{messageCaption = "a"} = 12 01 61
        let message = SSKProtoTellomiDataMessage.builder()
        message.setMessageCaption("a")
        let dataMessage = SSKProtoDataMessage.builder()
        dataMessage.setTellomi(message.buildInfallibly())
        XCTAssertEqual(try dataMessage.build().serializedData().hexadecimalString, "c23e03120161")
    }

    func testTheCaptionForTheWholeMessageIsKept_andAnEditReplacesIt() throws {
        db.write { tx in
            TellomiCaptionAbove.apply(from: try! dataMessage(captionAboveMedia: nil, messageCaption: "Trip"), messageUniqueId: "message", tx: tx)
        }
        db.read { tx in
            XCTAssertEqual(TellomiCaptionAbove.messageCaption(messageUniqueId: "message", tx: tx), "Trip")
            XCTAssertFalse(TellomiCaptionAbove.isCaptionAboveMedia(messageUniqueId: "message", tx: tx))
            XCTAssertNil(TellomiCaptionAbove.messageCaption(messageUniqueId: "ordinary", tx: tx))
        }

        // An edit carries the whole new DataMessage
        db.write { tx in
            TellomiCaptionAbove.apply(from: try! dataMessage(captionAboveMedia: true, messageCaption: ""), messageUniqueId: "message", tx: tx)
        }
        db.read { tx in
            XCTAssertNil(TellomiCaptionAbove.messageCaption(messageUniqueId: "message", tx: tx), "an empty one is none")
            XCTAssertTrue(TellomiCaptionAbove.isCaptionAboveMedia(messageUniqueId: "message", tx: tx))
        }
    }

    func testAnAttachmentsOwnCaptionComesAheadOfTheLegacyOne() throws {
        func pointer(tellomiCaption: String?, legacy: String?) -> SSKProtoAttachmentPointer {
            let builder = SSKProtoAttachmentPointer.builder()
            if let tellomiCaption {
                let tellomi = SSKProtoTellomiAttachment.builder()
                tellomi.setCaption(tellomiCaption)
                builder.setTellomi(tellomi.buildInfallibly())
            }
            if let legacy {
                builder.setCaption(legacy)
            }
            return builder.buildInfallibly()
        }
        XCTAssertEqual(TellomiCaptionAbove.attachmentCaption(pointer(tellomiCaption: "Sunset", legacy: nil)), "Sunset")
        XCTAssertEqual(TellomiCaptionAbove.attachmentCaption(pointer(tellomiCaption: "Sunset", legacy: "legacy")), "Sunset")
        XCTAssertEqual(TellomiCaptionAbove.attachmentCaption(pointer(tellomiCaption: "", legacy: "legacy")), "legacy")
        XCTAssertNil(TellomiCaptionAbove.attachmentCaption(pointer(tellomiCaption: nil, legacy: nil)))
    }

    private func dataMessage(captionAboveMedia: Bool?, messageCaption: String? = nil) throws -> SSKProtoDataMessage {
        let builder = SSKProtoDataMessage.builder()
        builder.setBody("caption")
        if captionAboveMedia != nil || messageCaption != nil {
            let tellomi = SSKProtoTellomiDataMessage.builder()
            if let captionAboveMedia {
                tellomi.setCaptionAboveMedia(captionAboveMedia)
            }
            if let messageCaption {
                tellomi.setMessageCaption(messageCaption)
            }
            builder.setTellomi(tellomi.buildInfallibly())
        }
        return try builder.build()
    }
}
