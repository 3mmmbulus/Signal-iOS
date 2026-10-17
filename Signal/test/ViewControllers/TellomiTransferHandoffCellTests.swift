//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（交互审计 A-13 iOS 半边）：走会话页同一条渲染路径（`CVLoader.buildStandaloneRenderItem` + `CVCellView`，
/// 同 `TellomiLocationBubbleTests`）。本机刚发出的一张图还在上传（有环）→ 传完，格子重建：新格子没有自己的环，
/// 接过旧格子的环让它缩小淡出。`reloadItems` 换格子时新旧格子进出窗口的先后不固定，两种都测。
final class TellomiTransferHandoffCellTests: XCTestCase {

    private var oldContext: (any AppContext)!

    @MainActor
    override func setUp() {
        super.setUp()
        let setupExpectation = expectation(description: "mock ssk environment setup completed")
        self.oldContext = CurrentAppContext()
        Task {
            let appReadiness = AppReadinessImpl()
            await MockSSKEnvironment.activate(
                appReadiness: appReadiness,
                testDependencies: AppSetup.TestDependencies(
                    groupV2Updates: MockGroupV2Updates(),
                    groupsV2: MockGroupsV2(),
                    messageSender: FakeMessageSender(),
                    networkManager: OWSFakeNetworkManager(appReadiness: appReadiness, netProvider: nil),
                    paymentsCurrencies: MockPaymentsCurrencies(),
                    paymentsHelper: MockPaymentsHelper(),
                    pendingReceiptRecorder: NoopPendingReceiptRecorder(),
                    reachabilityManager: MockSSKReachabilityManager(),
                    remoteConfigManager: StubbableRemoteConfigManager(),
                    signalService: OWSSignalServiceMock(),
                    storageServiceManager: FakeStorageServiceManager(),
                    syncManager: OWSMockSyncManager(),
                    systemStoryManager: SystemStoryManagerMock(),
                    versionedProfiles: MockVersionedProfiles(),
                    webSocketFactory: WebSocketFactoryMock(),
                ),
            )
            setupExpectation.fulfill()
        }
        waitForExpectations(timeout: 30)

        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    @MainActor
    override func tearDown() {
        UIWindow.tellomiDetachTestWindows()
        MockSSKEnvironment.deactivate(oldContext: self.oldContext)
        super.tearDown()
    }

    private func read<T>(block: (DBReadTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.read(block: block)
    }

    private func write<T>(block: (DBWriteTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.write(block: block)
    }

    // MARK: -

    @MainActor
    func testWhenTheUploadFinishes_theNewCellShrinksTheOldRingAway_newCellFirst() async throws {
        try await checkTheRingIsHandedOver(newCellEntersFirst: true)
    }

    @MainActor
    func testWhenTheUploadFinishes_theNewCellShrinksTheOldRingAway_oldCellFirst() async throws {
        try await checkTheRingIsHandedOver(newCellEntersFirst: false)
    }

    /// 没传完就重建（比如加了个回应）：新格子有自己的环，不接旧的。
    @MainActor
    func testStillUploading_theNewCellKeepsItsOwnRingOnly() async throws {
        let (thread, message) = try await insertUploadingImage()
        let delegate = MockConversationView(model: .init(items: []), hasWallpaper: false, customChatColor: nil)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 150, width: 390, height: 600))
        window.isHidden = false
        defer { window.isHidden = true }
        let old = try host(try renderItem(message: message, thread: thread), delegate: delegate, in: window)
        let new = try host(try renderItem(message: message, thread: thread), delegate: delegate, in: window)
        old.removeFromSuperview()

        let newMedia = try XCTUnwrap(Self.find(CVMediaView.self, in: new))
        XCTAssertNotNil(Self.find(CVAttachmentProgressView.self, in: newMedia), "still uploading: its own ring")
        XCTAssertNil(Self.fadingSnapshot(in: newMedia), "no second ring shrinking on top")
        TellomiTransferHandoff.shared.prune()
    }

    @MainActor
    private func checkTheRingIsHandedOver(newCellEntersFirst: Bool) async throws {
        let (thread, message) = try await insertUploadingImage()
        let delegate = MockConversationView(model: .init(items: []), hasWallpaper: false, customChatColor: nil)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 150, width: 390, height: 600))
        window.isHidden = false
        defer { window.isHidden = true }

        let oldCell = try host(try renderItem(message: message, thread: thread), delegate: delegate, in: window)
        let oldMedia = try XCTUnwrap(Self.find(CVMediaView.self, in: oldCell))
        let oldRing = try XCTUnwrap(Self.find(CVAttachmentProgressView.self, in: oldMedia), "uploading: the ring is up")
        XCTAssertFalse(oldRing.isHidden)
        // The photo comes in asynchronously; while uploading it's already shown under the ring.
        for _ in 0..<30 where !Self.hasImage(in: oldMedia) {
            try await Task.sleep(nanoseconds: 100_000_000)
            window.layoutIfNeeded()
        }
        XCTAssertTrue(Self.hasImage(in: oldMedia))

        // The upload finishes.
        try write { tx in
            let rowId = try XCTUnwrap(message.sqliteRowId)
            let referenced = try XCTUnwrap(DependenciesBridge.shared.attachmentStore.fetchAnyReferencedAttachment(
                for: .messageBodyAttachment(messageRowId: rowId),
                tx: tx,
            ))
            let stream = try XCTUnwrap(referenced.attachment.asStream())
            DependenciesBridge.shared.attachmentStore.saveLatestTransitTierInfo(
                attachmentStream: stream,
                transitTierInfo: .mock(),
                tx: tx,
            )
        }
        let finished = try renderItem(message: message, thread: thread)

        // The reload swaps the cells in one layout pass.
        let newCell: CVCellView
        if newCellEntersFirst {
            newCell = try host(finished, delegate: delegate, in: window)
            oldCell.removeFromSuperview()
        } else {
            oldCell.removeFromSuperview()
            newCell = try host(finished, delegate: delegate, in: window)
        }

        let newMedia = try XCTUnwrap(Self.find(CVMediaView.self, in: newCell))
        XCTAssertNil(Self.find(CVAttachmentProgressView.self, in: newMedia), "uploaded: no ring of its own")
        let ring = try XCTUnwrap(Self.fadingSnapshot(in: newMedia), "the old ring, handed over")
        XCTAssertEqual(ring.bounds.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(ring.center.x, newMedia.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(ring.center.y, newMedia.bounds.midY, accuracy: 0.5)
        XCTAssertTrue(TellomiTransferHandoff.shared.isEmpty, "handed over, nothing kept")
        XCTAssertTrue(Self.hasImage(in: newMedia), "the image stays (same image view, already loaded)")

        try await Task.sleep(nanoseconds: UInt64((TellomiMotion.fadeOutDuration + 0.4) * 1_000_000_000))
        XCTAssertNil(ring.superview, "gone once faded")
    }

    // MARK: - Making the message

    @MainActor
    private func insertUploadingImage() async throws -> (TSContactThread, TSOutgoingMessage) {
        let thread = write { tx in
            ContactThreadFactory().create(transaction: tx)
        }
        // Sent from this device and not yet uploaded: `CVAttachment.stream(isUploading: true)`.
        let message = write { tx in
            let message = TSOutgoingMessageBuilder(
                thread: thread,
                timestamp: NSDate.ows_millisecondTimeStamp(),
                receivedAtTimestamp: NSDate.ows_millisecondTimeStamp(),
                messageBody: nil,
                editState: .none,
                expiresInSeconds: nil,
                expireTimerVersion: nil,
                expireStartedAt: nil,
                isVoiceMessage: false,
                isSmsMessageRestoredFromBackup: false,
                isViewOnceMessage: false,
                isViewOnceComplete: false,
                wasRemotelyDeleted: false,
                wasNotCreatedLocally: false,
                groupChangeProtoData: nil,
                storyAuthorAci: nil,
                storyTimestamp: nil,
                storyReactionEmoji: nil,
                quotedMessage: nil,
                contactShare: nil,
                linkPreview: nil,
                messageSticker: nil,
                giftBadge: nil,
                isPoll: false,
            ).build(transaction: tx)
            message.anyInsert(transaction: tx)
            return message
        }
        let pending = try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
            Self.photo(),
            mimeType: "image/jpeg",
            renderingFlag: .default,
            sourceFilename: nil,
        )
        try write { tx in
            _ = try DependenciesBridge.shared.attachmentManager.createAttachmentStream(
                from: OwnedAttachmentDataSource(
                    dataSource: .pendingAttachment(pending),
                    owner: .messageBodyAttachment(.init(
                        messageRowId: message.sqliteRowId!,
                        receivedAtTimestamp: message.receivedAtTimestamp,
                        threadRowId: thread.sqliteRowId!,
                        isViewOnce: false,
                        isPastEditRevision: false,
                        orderInMessage: 0,
                    )),
                ),
                tx: tx,
            )
        }
        return (thread, message)
    }

    private static func photo() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 800, height: 600)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.9)!
    }

    // MARK: - Hosting

    @MainActor
    private func renderItem(message: TSMessage, thread: TSThread) throws -> CVRenderItem {
        try read { (tx: DBReadTransaction) throws -> CVRenderItem in
            let chatColor = DependenciesBridge.shared.chatColorSettingStore.resolvedChatColor(for: thread, tx: tx)
            let conversationStyle = ConversationStyle(
                type: .`default`,
                thread: thread,
                viewWidth: 390,
                hasWallpaper: false,
                shouldDimWallpaperInDarkMode: false,
                chatColor: chatColor,
            )
            let latest = try XCTUnwrap(TSMessage.anyFetch(uniqueId: message.uniqueId, transaction: tx) as? TSMessage)
            return try XCTUnwrap(CVLoader.buildStandaloneRenderItem(
                interaction: latest,
                thread: thread,
                conversationStyle: conversationStyle,
                spoilerState: SpoilerRenderState(),
                groupNameColors: GroupNameColors.forThread(thread),
                transaction: tx,
            ))
        }
    }

    /// One cell in [window], laid out and visible (loads its media), like the conversation's `cellForItemAt` + display.
    @MainActor
    private func host(_ renderItem: CVRenderItem, delegate: MockConversationView, in window: UIWindow) throws -> CVCellView {
        let cellView = CVCellView()
        cellView.configure(renderItem: renderItem, componentDelegate: delegate)
        cellView.frame = CGRect(x: 0, y: 12, width: 390, height: renderItem.cellMeasurement.cellSize.height)
        window.addSubview(cellView)
        cellView.isCellVisible = true
        window.layoutIfNeeded()
        return cellView
    }

    // MARK: - Finding

    private static func find<T: AnyObject>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = find(type, in: subview) {
                return match
            }
        }
        return nil
    }

    /// The handed-over ring: on top of the media view, not touchable, fading (model alpha 0).
    private static func fadingSnapshot(in media: CVMediaView) -> UIView? {
        media.subviews.last { !$0.isUserInteractionEnabled && $0.alpha == 0 && !($0 is CVAttachmentProgressView) }
    }

    private static func hasImage(in view: UIView) -> Bool {
        if let imageView = view as? UIImageView, imageView.image != nil, imageView.bounds.size.width > 100 {
            return true
        }
        return view.subviews.contains { hasImage(in: $0) }
    }
}
