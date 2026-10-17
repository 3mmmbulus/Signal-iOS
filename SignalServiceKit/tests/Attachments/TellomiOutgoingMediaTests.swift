//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0068 §4.4, spec P-5 (tellomi/tellomi#1263): the send side of "Hide with Spoiler" — which outgoing attachments are
/// marked, the bytes they go out with, and the protocol version a covered message needs.
class TellomiOutgoingMediaTests: XCTestCase {

    private var db: InMemoryDB!
    private var attachmentStore: AttachmentStore!

    override func setUp() async throws {
        db = InMemoryDB()
        attachmentStore = AttachmentStore()
        TellomiMediaSpoiler.resetRevealedInMemoryForTesting()
    }

    // MARK: - Wire

    func testACoveredPointerCarriesOnlyTheSpoilerFlag() throws {
        let (threadRowId, messageRowId) = insertThreadAndInteraction()
        let image = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 0, mimeType: "image/jpeg")

        let covered = try XCTUnwrap(image.asProtoForSending(tellomiSpoiler: true))
        // Same bytes the receive side's golden `ca3e021001` decodes: TellomiAttachment{spoiler = true}.
        XCTAssertEqual(try XCTUnwrap(covered.tellomi).serializedData().hexadecimalString, "1001")
        XCTAssertTrue(TellomiMediaSpoiler.isSpoiler(try roundTrip(covered), mimeType: "image/jpeg"))

        // Not covered: no field 1001 at all, the pointer is byte-identical to upstream's.
        let plain = try XCTUnwrap(image.asProtoForSending())
        XCTAssertNil(plain.tellomi)
        XCTAssertFalse(try roundTrip(plain).serializedData().hexadecimalString.contains("ca3e"))
    }

    func testSentAsAFileWinsOverTheSpoiler() throws {
        let (threadRowId, messageRowId) = insertThreadAndInteraction()
        let file = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 0, mimeType: "image/jpeg", renderingFlag: .tellomiAsFile)

        let proto = try XCTUnwrap(file.asProtoForSending(tellomiSpoiler: true))
        XCTAssertEqual(proto.tellomi?.asFile, true)
        XCTAssertEqual(proto.tellomi?.hasSpoiler, false)
    }

    func testOnlyACoveredPointerAsksForTheSpoilerVersion() throws {
        let covered = try pointer(spoiler: true)
        let plain = try pointer(spoiler: false)
        XCTAssertTrue(TellomiMediaSpoiler.needsSpoilerProtocolVersion(attachments: [plain, covered], quote: nil))
        XCTAssertFalse(TellomiMediaSpoiler.needsSpoilerProtocolVersion(attachments: [plain], quote: nil))
        XCTAssertFalse(TellomiMediaSpoiler.needsSpoilerProtocolVersion(attachments: [], quote: nil))

        // A reply to a covered picture: only the quote's thumbnail is covered, and that is enough (§4.4 "any AttachmentPointer").
        XCTAssertTrue(TellomiMediaSpoiler.needsSpoilerProtocolVersion(attachments: [], quote: try quote(thumbnail: covered)))
        XCTAssertFalse(TellomiMediaSpoiler.needsSpoilerProtocolVersion(attachments: [], quote: try quote(thumbnail: plain)))
    }

    // MARK: - Marking the message

    func testMarksOnlyThePickedImagesAndVideosAndCoversThemHereToo() throws {
        let (threadRowId, messageRowId) = insertThreadAndInteraction()
        let image = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 0, mimeType: "image/jpeg")
        let pdf = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 1, mimeType: "application/pdf")
        let video = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 2, mimeType: "video/mp4")
        let asFile = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 3, mimeType: "image/jpeg", renderingFlag: .tellomiAsFile)
        let notPicked = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 4, mimeType: "image/jpeg")

        db.write { tx in
            TellomiMediaSpoiler.markOutgoing(messageRowId: messageRowId, orders: [0, 1, 2, 3], attachmentStore: attachmentStore, tx: tx)
        }

        db.read { tx in
            XCTAssertTrue(TellomiMediaSpoiler.isSpoiler(image.reference, tx: tx))
            XCTAssertTrue(TellomiMediaSpoiler.isSpoiler(video.reference, tx: tx))
            XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(pdf.reference, tx: tx), "only images and videos (ADR-0068 §4.1)")
            XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(asFile.reference, tx: tx), "a file row is never covered")
            XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(notPicked.reference, tx: tx))
            // Like Telegram on both platforms: the sender's own copy is covered until tapped.
            XCTAssertTrue(TellomiMediaSpoiler.isCovered(image.reference, tx: tx))
        }
    }

    func testAReplyToACoveredPictureKeepsItsThumbnailCovered() throws {
        let (threadRowId, originalRowId) = insertThreadAndInteraction()
        let original = try insertBodyAttachment(messageRowId: originalRowId, threadRowId: threadRowId, order: 0, mimeType: "image/jpeg")
        let plainOriginal = try insertBodyAttachment(messageRowId: originalRowId, threadRowId: threadRowId, order: 1, mimeType: "image/jpeg")
        let (_, replyRowId) = insertThreadAndInteraction()
        let (_, otherReplyRowId) = insertThreadAndInteraction()
        let replyQuote = try insertQuotedReplyThumbnail(messageRowId: replyRowId, threadRowId: threadRowId)
        let otherReplyQuote = try insertQuotedReplyThumbnail(messageRowId: otherReplyRowId, threadRowId: threadRowId)

        db.write { tx in
            TellomiMediaSpoiler.markOutgoing(messageRowId: originalRowId, orders: [0], attachmentStore: attachmentStore, tx: tx)
            TellomiMediaSpoiler.markOutgoingQuote(messageRowId: replyRowId, quoting: original.reference, tx: tx)
            TellomiMediaSpoiler.markOutgoingQuote(messageRowId: otherReplyRowId, quoting: plainOriginal.reference, tx: tx)
        }

        db.read { tx in
            XCTAssertTrue(TellomiMediaSpoiler.isSpoiler(replyQuote.reference, tx: tx))
            XCTAssertTrue(TellomiMediaSpoiler.isCovered(replyQuote.reference, tx: tx))
            XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(otherReplyQuote.reference, tx: tx))
        }
    }

    func testOptionsFollowTheAttachmentOrder() {
        XCTAssertEqual(TellomiOutgoingMedia(spoilers: [true, false, true]).spoilerOrders, [0, 2])
        XCTAssertTrue(TellomiOutgoingMedia(spoilers: [false, false]).isEmpty)
    }

    // MARK: - Helpers

    private func roundTrip(_ proto: SSKProtoAttachmentPointer) throws -> SSKProtoAttachmentPointer {
        try SSKProtoAttachmentPointer(serializedData: proto.serializedData())
    }

    private func pointer(spoiler: Bool) throws -> SSKProtoAttachmentPointer {
        let builder = SSKProtoAttachmentPointer.builder()
        builder.setContentType("image/jpeg")
        if spoiler {
            let tellomi = SSKProtoTellomiAttachment.builder()
            tellomi.setSpoiler(true)
            builder.setTellomi(tellomi.buildInfallibly())
        }
        return try roundTrip(builder.buildInfallibly())
    }

    private func quote(thumbnail: SSKProtoAttachmentPointer) throws -> SSKProtoDataMessageQuote {
        let attachment = SSKProtoDataMessageQuoteQuotedAttachment.builder()
        attachment.setContentType("image/jpeg")
        attachment.setThumbnail(thumbnail)
        let builder = SSKProtoDataMessageQuote.builder(id: 1)
        builder.addAttachments(attachment.buildInfallibly())
        return try builder.build()
    }

    private func insertBodyAttachment(
        messageRowId: Int64,
        threadRowId: Int64,
        order: UInt32,
        mimeType: String,
        renderingFlag: AttachmentReference.RenderingFlag = .default,
    ) throws -> ReferencedAttachment {
        try db.write { tx in
            var record = Attachment.Record.mockPointer(mimeType: mimeType)
            _ = try attachmentStore.insert(
                &record,
                reference: .mockMessageBodyAttachmentReference(
                    attachmentRecord: record,
                    messageRowId: messageRowId,
                    threadRowId: threadRowId,
                    renderingFlag: renderingFlag,
                    orderInMessage: order,
                ),
                tx: tx,
            )
        }
        return try XCTUnwrap(db.read { tx in
            attachmentStore.fetchReferencedAttachments(owners: [.messageBodyAttachment(messageRowId: messageRowId)], tx: tx)
                .first { $0.reference.orderInOwningMessage == order }
        })
    }

    private func insertQuotedReplyThumbnail(messageRowId: Int64, threadRowId: Int64) throws -> ReferencedAttachment {
        try db.write { tx in
            var record = Attachment.Record.mockPointer()
            let owner = AttachmentReference.OwnerBuilder.quotedReplyAttachment(.init(
                messageRowId: messageRowId,
                receivedAtTimestamp: Date().ows_millisecondsSince1970,
                threadRowId: threadRowId,
                isPastEditRevision: false,
            ))
            _ = try attachmentStore.insert(
                &record,
                reference: AttachmentReference.ConstructionParams(
                    owner: owner.build(knownIdInOwner: .none, renderingFlag: .default, contentType: record.contentType, mimeType: record.mimeType),
                    sourceFilename: nil,
                    sourceUnencryptedByteCount: 100,
                    sourceMediaSizePixels: nil,
                ),
                tx: tx,
            )
        }
        return try XCTUnwrap(db.read { tx in
            attachmentStore.fetchReferencedAttachments(owners: [.quotedReplyAttachment(messageRowId: messageRowId)], tx: tx).first
        })
    }

    private func insertThreadAndInteraction() -> (threadRowId: Int64, interactionRowId: Int64) {
        return db.write { tx in
            let thread = TSThread(uniqueId: UUID().uuidString)
            try! thread.insert(tx.database)
            let interaction = TSInteraction(timestamp: 0, receivedAtTimestamp: 0, thread: thread)
            try! interaction.asRecord().insert(tx.database)
            return (thread.sqliteRowId!, interaction.sqliteRowId!)
        }
    }
}
