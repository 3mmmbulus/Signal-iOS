//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0068 §4.1, spec R-2 (tellomi/tellomi#1263): a live photo's moving half (`AttachmentPointer.tellomi.livePhotoVideo`)
/// is kept with the still, not as its own attachment, and only when it is valid.
class TellomiLivePhotoTests: XCTestCase {

    private var db: InMemoryDB!
    private var attachmentStore: AttachmentStore!

    override func setUp() async throws {
        db = InMemoryDB()
        attachmentStore = AttachmentStore()
    }

    // MARK: - Wire

    func testGoldenBytesSharedByTheThreeClients() throws {
        // key = 1001 << 3 | 2 = ca 3e; TellomiAttachment{livePhotoVideo = {}} = 1a 00
        let tellomi = SSKProtoTellomiAttachment.builder()
        tellomi.setLivePhotoVideo(SSKProtoAttachmentPointer.builder().buildInfallibly())
        let pointer = SSKProtoAttachmentPointer.builder()
        pointer.setTellomi(tellomi.buildInfallibly())
        XCTAssertEqual(try pointer.buildInfallibly().serializedData().hexadecimalString, "ca3e021a00")
    }

    func testOnlyAValidVideoOnAStillCounts() throws {
        XCTAssertNotNil(TellomiLivePhoto.videoPointer(try still(video: video()), mimeType: "image/heic"))
        // A covered live photo is fine
        XCTAssertNotNil(TellomiLivePhoto.videoPointer(try still(video: video(), spoiler: true), mimeType: "image/jpeg"))

        XCTAssertNil(TellomiLivePhoto.videoPointer(try still(video: video(), asFile: true), mimeType: "image/heic"), "asFile wins")
        XCTAssertNil(TellomiLivePhoto.videoPointer(try still(video: video()), mimeType: "video/mp4"), "only on a still")
        XCTAssertNil(TellomiLivePhoto.videoPointer(try still(video: video(contentType: "image/jpeg")), mimeType: "image/heic"), "the moving half is a video")
        XCTAssertNil(TellomiLivePhoto.videoPointer(try still(video: video(nested: true)), mimeType: "image/heic"), "one level only")
        XCTAssertNil(TellomiLivePhoto.videoPointer(try still(video: video(cdnKey: nil)), mimeType: "image/heic"), "needs where it is")
        XCTAssertNil(TellomiLivePhoto.videoPointer(try still(video: nil), mimeType: "image/heic"))
    }

    // MARK: - On this device

    func testKeptWithTheStillAndReadyToDownload() throws {
        let (threadRowId, messageRowId) = insertThreadAndInteraction()
        let live = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 0, still: try still(video: video()))
        let plain = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 1, still: try still(video: nil))

        db.read { tx in
            XCTAssertTrue(TellomiLivePhoto.isLivePhoto(live, tx: tx))
            XCTAssertNotNil(TellomiLivePhoto.video(live, tx: tx))
            XCTAssertFalse(TellomiLivePhoto.isLivePhoto(plain, tx: tx))
            XCTAssertNil(TellomiLivePhoto.video(plain, tx: tx))
            // Still one attachment per picture
            XCTAssertEqual(attachmentStore.fetchReferences(owner: .messageBodyAttachment(messageRowId: messageRowId), tx: tx).count, 2)
        }
    }

    func testThePastRevisionOfAnEditedMessageKeepsIt() throws {
        let (threadRowId, latestRowId) = insertThreadAndInteraction()
        let (_, priorRowId) = insertThreadAndInteraction()
        _ = try insertBodyAttachment(messageRowId: latestRowId, threadRowId: threadRowId, order: 0, still: try still(video: video()))
        let prior = try insertBodyAttachment(messageRowId: priorRowId, threadRowId: threadRowId, order: 0, still: try still(video: nil))

        db.write { tx in
            TellomiLivePhoto.copyForPastRevision(latestRevisionRowId: latestRowId, priorRevisionRowId: priorRowId, orderInMessage: 0, tx: tx)
        }
        db.read { tx in XCTAssertTrue(TellomiLivePhoto.isLivePhoto(prior, tx: tx)) }
    }

    // MARK: - Helpers

    private func video(contentType: String = "video/mp4", cdnKey: String? = "cdn-key-video", nested: Bool = false) -> SSKProtoAttachmentPointer {
        let builder = SSKProtoAttachmentPointer.builder()
        builder.setCdnNumber(3)
        if let cdnKey {
            builder.setCdnKey(cdnKey)
        }
        builder.setContentType(contentType)
        builder.setKey(Data(repeating: 7, count: 64))
        builder.setDigest(Data(repeating: 9, count: 32))
        builder.setSize(456_789)
        if nested {
            let tellomi = SSKProtoTellomiAttachment.builder()
            tellomi.setLivePhotoVideo(video())
            builder.setTellomi(tellomi.buildInfallibly())
        }
        return builder.buildInfallibly()
    }

    private func still(video: SSKProtoAttachmentPointer?, asFile: Bool = false, spoiler: Bool = false) throws -> SSKProtoAttachmentPointer {
        let builder = SSKProtoAttachmentPointer.builder()
        builder.setContentType("image/heic")
        if video != nil || asFile || spoiler {
            let tellomi = SSKProtoTellomiAttachment.builder()
            if let video {
                tellomi.setLivePhotoVideo(video)
            }
            if asFile {
                tellomi.setAsFile(true)
            }
            if spoiler {
                tellomi.setSpoiler(true)
            }
            builder.setTellomi(tellomi.buildInfallibly())
        }
        // Through the bytes, as a receiver gets it.
        return try SSKProtoAttachmentPointer(serializedData: builder.buildInfallibly().serializedData())
    }

    /// The way an incoming pointer is stored (`AttachmentManagerImpl`): the reference, then what the pointer carries.
    private func insertBodyAttachment(messageRowId: Int64, threadRowId: Int64, order: UInt32, still: SSKProtoAttachmentPointer) throws -> AttachmentReference {
        let owner = AttachmentReference.OwnerBuilder.messageBodyAttachment(.init(
            messageRowId: messageRowId,
            receivedAtTimestamp: Date().ows_millisecondsSince1970,
            threadRowId: threadRowId,
            isViewOnce: false,
            isPastEditRevision: false,
            orderInMessage: order,
        ))
        try db.write { tx in
            var record = Attachment.Record.mockStream()
            _ = try attachmentStore.insert(
                &record,
                reference: AttachmentReference.ConstructionParams(
                    owner: owner.build(knownIdInOwner: .none, renderingFlag: .default, contentType: record.contentType, mimeType: "image/heic"),
                    sourceFilename: "IMG_0001.HEIC",
                    sourceUnencryptedByteCount: 100,
                    sourceMediaSizePixels: nil,
                ),
                tx: tx,
            )
            TellomiLivePhoto.markReceived(still, mimeType: "image/heic", owner: owner, tx: tx)
        }
        return try XCTUnwrap(db.read { tx in
            attachmentStore.fetchReferences(owner: .messageBodyAttachment(messageRowId: messageRowId), tx: tx)
                .first { $0.orderInOwningMessage == order }
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
