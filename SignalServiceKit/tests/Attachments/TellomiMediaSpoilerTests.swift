//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0068 §4.1 / §4.3, spec R-1 (tellomi/tellomi#1263): an image / video received with `AttachmentPointer.tellomi.spoiler`
/// stays covered until this device uncovers it, and the protocol version that says this client can show it.
class TellomiMediaSpoilerTests: XCTestCase {

    private var db: InMemoryDB!
    private var attachmentStore: AttachmentStore!

    override func setUp() async throws {
        db = InMemoryDB()
        attachmentStore = AttachmentStore()
    }

    // MARK: - Wire

    func testThisClientAcceptsMessagesThatNeedTheSpoilerVersion() {
        XCTAssertEqual(SSKProtoDataMessageProtocolVersion.tellomiMediaSpoiler.rawValue, 9)
        XCTAssertEqual(SSKProtos.currentProtocolVersion, 9)
    }

    func testGoldenBytesSharedByTheThreeClients() throws {
        // key = 1001 << 3 | 2 = ca 3e; TellomiAttachment{spoiler = true} = 10 01
        XCTAssertEqual(try pointer(spoiler: true, asFile: nil).serializedData().hexadecimalString, "ca3e021001")
    }

    func testOnlyImagesAndVideosCountAndAsFileWins() throws {
        XCTAssertTrue(TellomiMediaSpoiler.isSpoiler(try pointer(spoiler: true, asFile: nil), mimeType: "image/jpeg"))
        XCTAssertTrue(TellomiMediaSpoiler.isSpoiler(try pointer(spoiler: true, asFile: false), mimeType: "video/mp4"))
        // Sent as a file: a file row, never covered.
        XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(try pointer(spoiler: true, asFile: true), mimeType: "image/jpeg"))
        // Not an image / video: ignored, the message is still received.
        XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(try pointer(spoiler: true, asFile: nil), mimeType: "application/pdf"))
        XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(try pointer(spoiler: true, asFile: nil), mimeType: "audio/aac"))
        XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(try pointer(spoiler: false, asFile: nil), mimeType: "image/jpeg"))
        XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(try pointer(spoiler: nil, asFile: nil), mimeType: "image/jpeg"))
    }

    // MARK: - On this device

    func testCoveredUntilUncoveredHereAndOnlyTheOneThatWasMarked() throws {
        let (threadRowId, messageRowId) = insertThreadAndInteraction()
        let covered = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 0, spoiler: true)
        let plain = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 1, spoiler: false)

        db.read { tx in
            XCTAssertTrue(TellomiMediaSpoiler.isCovered(covered, tx: tx))
            XCTAssertTrue(TellomiMediaSpoiler.isSpoiler(covered, tx: tx))
            XCTAssertFalse(TellomiMediaSpoiler.isCovered(plain, tx: tx))
            XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(plain, tx: tx))
        }

        db.write { tx in
            XCTAssertTrue(TellomiMediaSpoiler.markRevealed(covered, tx: tx))
            // Already uncovered / never covered: nothing to write (no extra redraw).
            XCTAssertFalse(TellomiMediaSpoiler.markRevealed(covered, tx: tx))
            XCTAssertFalse(TellomiMediaSpoiler.markRevealed(plain, tx: tx))
        }

        db.read { tx in
            XCTAssertFalse(TellomiMediaSpoiler.isCovered(covered, tx: tx))
            // Still a spoiler: quotes of it stay blurred.
            XCTAssertTrue(TellomiMediaSpoiler.isSpoiler(covered, tx: tx))
            XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(plain, tx: tx))
        }
    }

    func testAQuoteOfACoveredImageStaysCovered() throws {
        let (threadRowId, messageRowId) = insertThreadAndInteraction()
        let quote = try insertQuotedReplyThumbnail(messageRowId: messageRowId, threadRowId: threadRowId, spoiler: true)

        db.write { tx in
            XCTAssertFalse(TellomiMediaSpoiler.markRevealed(quote, tx: tx))
        }
        db.read { tx in
            XCTAssertTrue(TellomiMediaSpoiler.isSpoiler(quote, tx: tx))
            XCTAssertTrue(TellomiMediaSpoiler.isCovered(quote, tx: tx))
        }
    }

    func testThePastRevisionOfAnEditedMessageKeepsTheState() throws {
        let (threadRowId, latestRowId) = insertThreadAndInteraction()
        let (_, priorRowId) = insertThreadAndInteraction()
        let latest = try insertBodyAttachment(messageRowId: latestRowId, threadRowId: threadRowId, order: 0, spoiler: true)
        let prior = try insertBodyAttachment(messageRowId: priorRowId, threadRowId: threadRowId, order: 0, spoiler: false)

        db.write { tx in
            TellomiMediaSpoiler.copyForPastRevision(latestRevisionRowId: latestRowId, priorRevisionRowId: priorRowId, orderInMessage: 0, tx: tx)
        }
        db.read { tx in
            XCTAssertTrue(TellomiMediaSpoiler.isCovered(latest, tx: tx))
            XCTAssertTrue(TellomiMediaSpoiler.isCovered(prior, tx: tx))
        }
    }

    // MARK: - Helpers

    private func pointer(spoiler: Bool?, asFile: Bool?) throws -> SSKProtoAttachmentPointer {
        let builder = SSKProtoAttachmentPointer.builder()
        if spoiler != nil || asFile != nil {
            let tellomi = SSKProtoTellomiAttachment.builder()
            if let spoiler {
                tellomi.setSpoiler(spoiler)
            }
            if let asFile {
                tellomi.setAsFile(asFile)
            }
            builder.setTellomi(tellomi.buildInfallibly())
        }
        // Through the bytes, as a receiver gets it.
        return try SSKProtoAttachmentPointer(serializedData: builder.buildInfallibly().serializedData())
    }

    /// The way an incoming pointer is stored (`AttachmentManagerImpl`): the reference, then the cover mark.
    private func insertBodyAttachment(messageRowId: Int64, threadRowId: Int64, order: UInt32, spoiler: Bool) throws -> AttachmentReference {
        let owner = AttachmentReference.OwnerBuilder.messageBodyAttachment(.init(
            messageRowId: messageRowId,
            receivedAtTimestamp: Date().ows_millisecondsSince1970,
            threadRowId: threadRowId,
            isViewOnce: false,
            isPastEditRevision: false,
            orderInMessage: order,
        ))
        return try insert(owner: owner, spoiler: spoiler) { tx in
            self.attachmentStore.fetchReferences(owner: .messageBodyAttachment(messageRowId: messageRowId), tx: tx)
                .first { $0.orderInOwningMessage == order }
        }
    }

    private func insertQuotedReplyThumbnail(messageRowId: Int64, threadRowId: Int64, spoiler: Bool) throws -> AttachmentReference {
        let owner = AttachmentReference.OwnerBuilder.quotedReplyAttachment(.init(
            messageRowId: messageRowId,
            receivedAtTimestamp: Date().ows_millisecondsSince1970,
            threadRowId: threadRowId,
            isPastEditRevision: false,
        ))
        return try insert(owner: owner, spoiler: spoiler) { tx in
            self.attachmentStore.fetchAnyReference(owner: .quotedReplyAttachment(messageRowId: messageRowId), tx: tx)
        }
    }

    private func insert(
        owner: AttachmentReference.OwnerBuilder,
        spoiler: Bool,
        fetch: (DBReadTransaction) -> AttachmentReference?,
    ) throws -> AttachmentReference {
        let proto = try pointer(spoiler: spoiler, asFile: nil)
        try db.write { tx in
            var record = Attachment.Record.mockStream()
            _ = try attachmentStore.insert(
                &record,
                reference: AttachmentReference.ConstructionParams(
                    owner: owner.build(knownIdInOwner: .none, renderingFlag: .default, contentType: record.contentType, mimeType: "image/jpeg"),
                    sourceFilename: "IMG_0001.JPG",
                    sourceUnencryptedByteCount: 100,
                    sourceMediaSizePixels: nil,
                ),
                tx: tx,
            )
            TellomiMediaSpoiler.markReceived(proto, mimeType: "image/jpeg", owner: owner, tx: tx)
        }
        return try XCTUnwrap(db.read { tx in fetch(tx) })
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
