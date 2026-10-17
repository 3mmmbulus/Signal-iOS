//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0068 §4.4, spec P-4 (tellomi/tellomi#1263): the send side of a live photo — the moving half is staged, uploaded as the
/// second upload before the message goes out, and sent as `AttachmentPointer.tellomi.livePhotoVideo` on the still.
class TellomiLivePhotoSendTests: SSKBaseTest {

    override func setUp() {
        super.setUp()
        TellomiLivePhoto.resetForTesting()
        try? FileManager.default.removeItem(at: TellomiLivePhoto.outgoingDirectory)
    }

    // MARK: - Wire

    func testTheStillCarriesAPointerTheReceiverAccepts() throws {
        let (threadRowId, messageRowId) = insertThreadAndInteraction()
        let still = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 0, mimeType: "image/jpeg")
        let video = Self.videoPointer()

        let proto = try XCTUnwrap(still.asProtoForSending(tellomiLivePhotoVideo: video))
        let received = try SSKProtoAttachmentPointer(serializedData: proto.serializedData())
        let nested = try XCTUnwrap(TellomiLivePhoto.videoPointer(received, mimeType: "image/jpeg"), "the receive side (Signal-iOS#178) takes it")
        XCTAssertEqual(nested.contentType, "video/mp4")
        XCTAssertEqual(nested.cdnKey, video.cdnKey)
        XCTAssertEqual(nested.size, video.size)
        XCTAssertFalse(received.tellomi?.spoiler ?? false)
    }

    func testCoveredLivePhotoCarriesBoth() throws {
        let (threadRowId, messageRowId) = insertThreadAndInteraction()
        let still = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 0, mimeType: "image/jpeg")

        // Telegram allows spoiler + live on both platforms, and ADR-0068 does not exclude it.
        let proto = try XCTUnwrap(still.asProtoForSending(tellomiSpoiler: true, tellomiLivePhotoVideo: Self.videoPointer()))
        XCTAssertEqual(proto.tellomi?.spoiler, true)
        XCTAssertNotNil(proto.tellomi?.livePhotoVideo)
    }

    func testNoLivePartOnAVideoOrAFile() throws {
        let (threadRowId, messageRowId) = insertThreadAndInteraction()
        let video = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 0, mimeType: "video/mp4")
        let file = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 1, mimeType: "image/jpeg", renderingFlag: .tellomiAsFile)

        XCTAssertNil(try XCTUnwrap(video.asProtoForSending(tellomiLivePhotoVideo: Self.videoPointer())).tellomi, "only on a still image (§4.1 rule 3)")
        let asFile = try XCTUnwrap(file.asProtoForSending(tellomiLivePhotoVideo: Self.videoPointer()))
        XCTAssertEqual(asFile.tellomi?.asFile, true)
        XCTAssertNil(asFile.tellomi?.livePhotoVideo, "sent as a file wins (§4.1 rule 1)")
    }

    // MARK: - Staging and the second upload

    func testStagedVideoIsUploadedOnceAndThenSentWithTheStill() throws {
        let (threadRowId, messageRowId) = insertThreadAndInteraction()
        let still = try insertBodyAttachment(messageRowId: messageRowId, threadRowId: threadRowId, order: 1, mimeType: "image/jpeg")
        let staged = try TellomiLivePhoto.stageOutgoingVideo(try Self.temporaryVideoFile())

        write { tx in
            TellomiLivePhoto.markOutgoing(messageRowId: messageRowId, videos: [1: staged], tx: tx)
        }
        let named = TellomiLivePhoto.outgoingDirectory.appendingPathComponent("b\(messageRowId).1.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: named.path), "named after its place in the message")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))

        let uploaded = AtomicValue<[URL]>([], lock: .init())
        let uploader: (DataSourcePath) async throws -> SSKProtoAttachmentPointer = { dataSource in
            uploaded.update { $0.append(dataSource.fileUrl) }
            return Self.videoPointer()
        }
        let operations = SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiLivePhoto.uploadOperations(messageRowId: messageRowId, uploader: uploader, tx: tx)
        }
        XCTAssertEqual(operations.count, 1)
        // The upload runs in a task, as the message sender runs it (and writes with awaitableWrite there).
        let done = expectation(description: "uploaded")
        Task {
            do {
                for operation in operations {
                    try await operation()
                }
            } catch {
                XCTFail("upload failed: \(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(uploaded.get(), [named])

        SSKEnvironment.shared.databaseStorageRef.read { tx in
            XCTAssertNotNil(TellomiLivePhoto.storedPointer(still.reference, tx: tx))
            XCTAssertTrue(TellomiLivePhoto.isLivePhoto(still.reference, tx: tx), "the sender's own bubble shows it as a live photo")
            // A resend within three days reuses the upload; after that it uploads again.
            XCTAssertTrue(TellomiLivePhoto.uploadOperations(messageRowId: messageRowId, uploader: uploader, tx: tx).isEmpty)
            let later = Date().addingTimeInterval(TellomiLivePhoto.reuploadAfter + 60)
            XCTAssertEqual(TellomiLivePhoto.uploadOperations(messageRowId: messageRowId, now: later, uploader: uploader, tx: tx).count, 1)
        }

        // The sender plays the local file rather than downloading it back, and a forward takes it along (§4.4).
        let video = try XCTUnwrap(SSKEnvironment.shared.databaseStorageRef.read { tx in TellomiLivePhoto.video(still.reference, tx: tx) })
        XCTAssertEqual(TellomiLivePhoto.localVideoFile(video), named)
        let fetched = expectation(description: "fetched")
        let playable = AtomicValue<URL?>(nil, lock: .init())
        Task {
            playable.set(try? await TellomiLivePhoto.fetchVideo(video))
            fetched.fulfill()
        }
        wait(for: [fetched], timeout: 10)
        XCTAssertEqual(playable.get(), named)
    }

    func testAMissingFileSendsTheStillOnly() throws {
        let (_, messageRowId) = insertThreadAndInteraction()
        let staged = try TellomiLivePhoto.stageOutgoingVideo(try Self.temporaryVideoFile())
        write { tx in
            TellomiLivePhoto.markOutgoing(messageRowId: messageRowId, videos: [0: staged], tx: tx)
        }
        try FileManager.default.removeItem(at: TellomiLivePhoto.outgoingDirectory.appendingPathComponent("b\(messageRowId).0.mp4"))
        read { tx in
            XCTAssertTrue(TellomiLivePhoto.uploadOperations(messageRowId: messageRowId, uploader: { _ in Self.videoPointer() }, tx: tx).isEmpty)
        }
    }

    func testOptionsFollowTheAttachmentOrder() {
        let url = URL(fileURLWithPath: "/tmp/x.mp4")
        let media = TellomiOutgoingMedia(spoilers: [false, false, true], livePhotoVideos: [nil, url, nil])
        XCTAssertEqual(media.livePhotoVideos, [1: url])
        XCTAssertEqual(media.spoilerOrders, [2])
        XCTAssertFalse(media.isEmpty)
    }

    // MARK: - Helpers

    private static func videoPointer() -> SSKProtoAttachmentPointer {
        TellomiLivePhoto.videoPointer(
            cdnNumber: 3,
            cdnKey: "live-\(UUID().uuidString)",
            key: Randomness.generateRandomBytes(64),
            digest: Randomness.generateRandomBytes(32),
            plaintextLength: 600_000,
            uploadTimestamp: Date().ows_millisecondsSince1970,
        )
    }

    private static func temporaryVideoFile() throws -> URL {
        let url = OWSFileSystem.temporaryFileUrl(fileExtension: "mp4", isAvailableWhileDeviceLocked: true)
        try Data(repeating: 7, count: 1024).write(to: url)
        return url
    }

    private func insertBodyAttachment(
        messageRowId: Int64,
        threadRowId: Int64,
        order: UInt32,
        mimeType: String,
        renderingFlag: AttachmentReference.RenderingFlag = .default,
    ) throws -> ReferencedAttachment {
        let attachmentStore = DependenciesBridge.shared.attachmentStore
        try write { tx in
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
        return try XCTUnwrap(SSKEnvironment.shared.databaseStorageRef.read { tx in
            attachmentStore.fetchReferencedAttachments(owners: [.messageBodyAttachment(messageRowId: messageRowId)], tx: tx)
                .first { $0.reference.orderInOwningMessage == order }
        })
    }

    private func insertThreadAndInteraction() -> (threadRowId: Int64, interactionRowId: Int64) {
        return write { tx in
            let thread = TSThread(uniqueId: UUID().uuidString)
            try! thread.insert(tx.database)
            let interaction = TSInteraction(timestamp: 0, receivedAtTimestamp: 0, thread: thread)
            try! interaction.asRecord().insert(tx.database)
            return (thread.sqliteRowId!, interaction.sqliteRowId!)
        }
    }
}
