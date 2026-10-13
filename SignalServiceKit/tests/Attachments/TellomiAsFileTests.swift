//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0068 (tellomi/tellomi#1263): `AttachmentPointer.tellomi = 1001`, `DataMessage.tellomi = 1000`,
/// and an attachment sent as a file (`RenderingFlag.tellomiAsFile`) on the receiving side.
class TellomiAsFileTests: XCTestCase {

    private var db: InMemoryDB!
    private var attachmentStore: AttachmentStore!

    override func setUp() async throws {
        db = InMemoryDB()
        attachmentStore = AttachmentStore()
    }

    // MARK: - Wire

    func testGoldenBytesSharedByTheThreeClients() throws {
        // key = 1001 << 3 | 2 = ca 3e; TellomiAttachment{asFile = true} = 08 01
        let tellomi = SSKProtoTellomiAttachment.builder()
        tellomi.setAsFile(true)
        let pointer = SSKProtoAttachmentPointer.builder()
        pointer.setTellomi(tellomi.buildInfallibly())
        XCTAssertEqual(try pointer.buildInfallibly().serializedData().hexadecimalString, "ca3e020801")

        // key = 1000 << 3 | 2 = c2 3e; TellomiDataMessage{captionAboveMedia = true} = 08 01
        let tellomiDataMessage = SSKProtoTellomiDataMessage.builder()
        tellomiDataMessage.setCaptionAboveMedia(true)
        let dataMessage = SSKProtoDataMessage.builder()
        dataMessage.setTellomi(tellomiDataMessage.buildInfallibly())
        XCTAssertEqual(try dataMessage.build().serializedData().hexadecimalString, "c23e020801")
    }

    func testAsFileWinsOverTheUpstreamFlags() throws {
        XCTAssertEqual(AttachmentReference.RenderingFlag.fromProto(try pointer(asFile: true, flags: .gif)), .tellomiAsFile)
        XCTAssertEqual(AttachmentReference.RenderingFlag.fromProto(try pointer(asFile: true, flags: nil)), .tellomiAsFile)
        XCTAssertEqual(AttachmentReference.RenderingFlag.fromProto(try pointer(asFile: false, flags: .gif)), .shouldLoop)
        XCTAssertEqual(AttachmentReference.RenderingFlag.fromProto(try pointer(asFile: nil, flags: .borderless)), .borderless)
        XCTAssertEqual(AttachmentReference.RenderingFlag.fromProto(try pointer(asFile: nil, flags: nil)), .default)
        // Written as tellomi.asFile instead of a flag.
        XCTAssertNil(AttachmentReference.RenderingFlag.tellomiAsFile.toProto())
    }

    func testTheStoredValueKeepsClearOfUpstreamCases() throws {
        XCTAssertEqual(AttachmentReference.RenderingFlag.tellomiAsFile.rawValue, 1001)
        XCTAssertEqual(try AttachmentReference.RenderingFlag(rawValue: UInt32(1001)), .tellomiAsFile)
    }

    func testFollowsTheDocumentsAutoDownloadSetting() {
        for mimeType in ["image/jpeg", "image/heic", "video/mp4"] {
            let policy = AutoDownloadPolicy.build(context: .body, mimeType: mimeType, renderingFlag: .tellomiAsFile, plaintextSize: 50_000)
            guard case .preference(mediaType: .document) = policy else {
                XCTFail("\(mimeType) sent as a file should follow the documents setting, got \(policy)")
                continue
            }
        }
    }

    // MARK: - Storage, gallery, previews

    func testStoredAndListedWithFilesNotPhotos() throws {
        let (threadRowId, messageRowId) = insertThreadAndInteraction()
        let asFileName = "IMG_0001.HEIC"
        try db.write { tx in
            for (order, flag, name) in [(UInt32(0), AttachmentReference.RenderingFlag.tellomiAsFile, asFileName), (1, .default, "IMG_0002.JPG")] {
                var record = Attachment.Record.mockStream()
                // The owner the way AttachmentManagerImpl builds it, so the reference gets filed the way the app files it.
                let owner = AttachmentReference.OwnerBuilder.messageBodyAttachment(.init(
                    messageRowId: messageRowId,
                    receivedAtTimestamp: Date().ows_millisecondsSince1970,
                    threadRowId: threadRowId,
                    isViewOnce: false,
                    isPastEditRevision: false,
                    orderInMessage: order,
                )).build(knownIdInOwner: .none, renderingFlag: flag, contentType: record.contentType, mimeType: record.mimeType)
                _ = try attachmentStore.insert(
                    &record,
                    reference: AttachmentReference.ConstructionParams(
                        owner: owner,
                        sourceFilename: name,
                        sourceUnencryptedByteCount: 100,
                        sourceMediaSizePixels: nil,
                    ),
                    tx: tx,
                )
            }
        }

        let (asFile, photo, listedPhotos, listedFiles) = db.read { tx in
            let referenced = attachmentStore.fetchReferencedAttachments(for: .messageBodyAttachment(messageRowId: messageRowId), tx: tx)
            let asFile = referenced.first { $0.reference.renderingFlag == .tellomiAsFile }
            let photo = referenced.first { $0.reference.renderingFlag == .default }
            func listed(_ filter: AllMediaFilter) -> [UInt32?] {
                MediaGalleryAttachmentFinder(threadId: threadRowId, filter: filter)
                    .galleryItemIds(excluding: [], offset: 0, ascending: true, tx: tx)
                    .map(\.orderInMessage)
            }
            return (asFile, photo, listed(.allPhotoVideoCategory) + listed(.photos), listed(.otherFiles))
        }

        // 1001 survives the round trip through MessageAttachmentReference.
        let asFileAttachment = try XCTUnwrap(asFile)
        let photoAttachment = try XCTUnwrap(photo)

        // Media tab: only the ordinary photo (order 1); files tab: only the one sent as a file (order 0).
        XCTAssertEqual(listedPhotos, [1, 1])
        XCTAssertEqual(listedFiles, [0])

        // Reads as a file in the chat list / notifications, whatever the content type.
        XCTAssertEqual(asFileAttachment.previewEmoji(), "📎")
        XCTAssertEqual(asFileAttachment.previewText(includeFileName: true, includeEmoji: false), asFileName)
        XCTAssertEqual(photoAttachment.previewEmoji(), "📷")
    }

    // MARK: - Helpers

    private func pointer(asFile: Bool?, flags: SSKProtoAttachmentPointerFlags?) throws -> SSKProtoAttachmentPointer {
        let builder = SSKProtoAttachmentPointer.builder()
        if let flags {
            builder.setFlags(UInt32(flags.rawValue))
        }
        if let asFile {
            let tellomi = SSKProtoTellomiAttachment.builder()
            tellomi.setAsFile(asFile)
            builder.setTellomi(tellomi.buildInfallibly())
        }
        // Through the bytes, as a receiver gets it.
        return try SSKProtoAttachmentPointer(serializedData: builder.buildInfallibly().serializedData())
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
