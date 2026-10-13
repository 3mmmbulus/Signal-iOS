//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// ADR-0068 / tellomi/tellomi#1263（R-3）：按文件发送的图片在会话里是文件行——左边缩略图（到了是图、没到是模糊图 + 下载钮），
/// 右边原文件名和大小；普通图片照旧是图片气泡。走会话页同一条渲染路径（`CVLoader.buildStandaloneRenderItem` + `CVCellView`，
/// 同 `TellomiLinkCardScreenshotTests`），在内存环境里，不连服务端。
///
/// 收到的那条从 **proto** 建（`createAttachmentPointer`）：`AttachmentPointer.tellomi.asFile` → 存成 `.tellomiAsFile` → 文件行，
/// 一路都是真代码。截图只在 `TELLOMI_SHOTS=1` 时存（xcodebuild 用 `TEST_RUNNER_TELLOMI_SHOTS=1`），写到 `TELLOMI_SHOTS_DIR/<屏宽>/`。
final class TellomiAsFileCellTests: XCTestCase {

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
        MockSSKEnvironment.deactivate(oldContext: self.oldContext)
        super.tearDown()
    }

    private func read<T>(block: (DBReadTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.read(block: block)
    }

    private func write<T>(block: (DBWriteTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.write(block: block)
    }

    private static let blurHash = "LKO2?U%2Tw=w]~RBVZRi};RPxuwH"

    // MARK: - Cases

    @MainActor
    func testAPointerSentAsAFileIsAFileRow() async throws {
        let thread = makeThread()
        let message = try await insertPointer(asFile: true, thread: thread)

        let reference = try XCTUnwrap(bodyAttachments(of: message).first)
        XCTAssertEqual(reference.reference.renderingFlag, .tellomiAsFile)

        let hosted = try await host(message: message, thread: thread, width: 402)
        defer { hosted.tearDown() }
        XCTAssertNotNil(hosted.componentState.genericAttachment)
        XCTAssertNil(hosted.componentState.bodyMedia)
        // Before it is here: the blur hash in the thumbnail, the download control on top.
        XCTAssertNotNil(Self.thumbnail(in: hosted.cellView)?.image)
    }

    @MainActor
    func testADownloadedFileSentAsAFileShowsItsThumbnail() async throws {
        let thread = makeThread()
        let message = try await insertStream(renderingFlag: .tellomiAsFile, fileName: "IMG_0002.PNG", thread: thread)

        let hosted = try await host(message: message, thread: thread, width: 402)
        defer { hosted.tearDown() }
        XCTAssertNotNil(hosted.componentState.genericAttachment)
        XCTAssertNil(hosted.componentState.bodyMedia)
        XCTAssertNotNil(Self.thumbnail(in: hosted.cellView)?.image)
        XCTAssertTrue(Self.texts(in: hosted.cellView).contains("IMG_0002.PNG"))
    }

    @MainActor
    func testAnOrdinaryPhotoIsStillMedia() async throws {
        let thread = makeThread()
        let message = try await insertStream(renderingFlag: .default, fileName: "IMG_0003.PNG", thread: thread)

        let hosted = try await host(message: message, thread: thread, width: 402)
        defer { hosted.tearDown() }
        XCTAssertNotNil(hosted.componentState.bodyMedia)
        XCTAssertNil(hosted.componentState.genericAttachment)
        XCTAssertNil(Self.thumbnail(in: hosted.cellView))
    }

    /// 给人看的截图：普通图片 / 按文件（已下载）/ 按文件（没下载）/ 普通 PDF，浅色和深色各一张。
    @MainActor
    func testShots() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        let width: CGFloat = 402
        for dark in [false, true] {
            let thread = makeThread()
            let messages = [
                try await insertStream(renderingFlag: .default, fileName: "IMG_0003.PNG", thread: thread),
                try await insertStream(renderingFlag: .tellomiAsFile, fileName: "IMG_20261013_093012.PNG", thread: thread),
                try await insertPointer(asFile: true, thread: thread),
                try await insertDocument(thread: thread),
            ]
            var images = [UIImage]()
            for message in messages {
                let hosted = try await host(message: message, thread: thread, width: width, dark: dark)
                images.append(render(hosted))
                hosted.tearDown()
            }
            try save(stack(images, width: width, dark: dark), name: "as-file-rows-\(dark ? "dark" : "light").png")
        }
    }

    // MARK: - Building messages

    private func makeThread() -> TSContactThread {
        return write { tx in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
    }

    private func insertMessage(thread: TSContactThread) throws -> TSIncomingMessage {
        let authorAci = try XCTUnwrap(thread.contactAddress.aci)
        return write { tx in
            let message = TSIncomingMessageBuilder.withDefaultValues(
                thread: thread,
                timestamp: Date.ows_millisecondTimestamp(),
                authorAci: authorAci,
            ).build()
            message.anyInsert(transaction: tx)
            return message
        }
    }

    private func bodyOwner(_ message: TSMessage, thread: TSThread) -> AttachmentReference.OwnerBuilder {
        return .messageBodyAttachment(.init(
            messageRowId: message.sqliteRowId!,
            receivedAtTimestamp: message.receivedAtTimestamp,
            threadRowId: thread.sqliteRowId!,
            isViewOnce: false,
            isPastEditRevision: false,
            orderInMessage: 0,
        ))
    }

    /// Received and not downloaded yet: built from the proto, as MessageReceiver does.
    @MainActor
    private func insertPointer(asFile: Bool, thread: TSContactThread) async throws -> TSMessage {
        let message = try insertMessage(thread: thread)
        let proto = SSKProtoAttachmentPointer.builder()
        proto.setCdnKey("cdn-key-\(UUID().uuidString)")
        proto.setCdnNumber(3)
        proto.setContentType("image/jpeg")
        proto.setKey(Randomness.generateRandomBytes(64))
        proto.setDigest(Randomness.generateRandomBytes(32))
        proto.setSize(4_812_345)
        proto.setFileName("IMG_20261013_093013.JPG")
        proto.setBlurHash(Self.blurHash)
        proto.setWidth(4032)
        proto.setHeight(3024)
        if asFile {
            let tellomi = SSKProtoTellomiAttachment.builder()
            tellomi.setAsFile(true)
            proto.setTellomi(tellomi.buildInfallibly())
        }
        try write { tx in
            _ = try DependenciesBridge.shared.attachmentManager.createAttachmentPointer(
                from: OwnedAttachmentPointerProto(proto: proto.buildInfallibly(), owner: bodyOwner(message, thread: thread)),
                tx: tx,
            )
        }
        return message
    }

    /// Already here (downloaded, or sent from this device).
    @MainActor
    private func insertStream(renderingFlag: AttachmentReference.RenderingFlag, fileName: String, thread: TSContactThread) async throws -> TSMessage {
        let message = try insertMessage(thread: thread)
        let pending = try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
            gradientPng(size: CGSize(width: 1200, height: 900)),
            mimeType: "image/png",
            renderingFlag: renderingFlag,
            sourceFilename: fileName,
        )
        try write { tx in
            _ = try DependenciesBridge.shared.attachmentManager.createAttachmentStream(
                from: OwnedAttachmentDataSource(dataSource: .pendingAttachment(pending), owner: bodyOwner(message, thread: thread)),
                tx: tx,
            )
        }
        return message
    }

    @MainActor
    private func insertDocument(thread: TSContactThread) async throws -> TSMessage {
        let message = try insertMessage(thread: thread)
        let pending = try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
            Data("%PDF-1.4\n%local test\n".utf8),
            mimeType: "application/pdf",
            renderingFlag: .default,
            sourceFilename: "会议纪要.pdf",
        )
        try write { tx in
            _ = try DependenciesBridge.shared.attachmentManager.createAttachmentStream(
                from: OwnedAttachmentDataSource(dataSource: .pendingAttachment(pending), owner: bodyOwner(message, thread: thread)),
                tx: tx,
            )
        }
        return message
    }

    private func bodyAttachments(of message: TSMessage) -> [ReferencedAttachment] {
        return read { tx in
            DependenciesBridge.shared.attachmentStore.fetchReferencedAttachments(
                for: .messageBodyAttachment(messageRowId: message.sqliteRowId!),
                tx: tx,
            )
        }
    }

    private func gradientPng(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor.systemOrange.cgColor, UIColor.systemRed.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }.pngData()!
    }

    // MARK: - Hosting (same as TellomiLinkCardScreenshotTests)

    private struct Hosted {
        let window: UIWindow
        let cellView: CVCellView
        let componentState: CVComponentState
        let delegate: MockConversationView

        func tearDown() {
            cellView.isCellVisible = false
            window.isHidden = true
        }
    }

    @MainActor
    private func host(message: TSMessage, thread: TSThread, width: CGFloat, dark: Bool = false) async throws -> Hosted {
        let renderItem = try read { (tx: DBReadTransaction) throws -> CVRenderItem in
            let chatColor = DependenciesBridge.shared.chatColorSettingStore.resolvedChatColor(for: thread, tx: tx)
            let conversationStyle = ConversationStyle(
                type: .`default`,
                thread: thread,
                viewWidth: width,
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

        let delegate = MockConversationView(model: .init(items: []), hasWallpaper: false, customChatColor: nil)
        let cellHeight = renderItem.cellMeasurement.cellSize.height
        let window = UIWindow(frame: CGRect(x: 0, y: 150, width: width, height: cellHeight + 24))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.backgroundColor = dark ? .black : .white
        let cellView = CVCellView()
        cellView.configure(renderItem: renderItem, componentDelegate: delegate)
        cellView.frame = CGRect(x: 0, y: 12, width: width, height: cellHeight)
        window.addSubview(cellView)
        window.isHidden = false
        cellView.isCellVisible = true
        window.layoutIfNeeded()

        // The thumbnail of a downloaded file comes in asynchronously.
        for _ in 0..<8 {
            try await Task.sleep(nanoseconds: 150_000_000)
            window.layoutIfNeeded()
        }
        return Hosted(window: window, cellView: cellView, componentState: renderItem.componentState, delegate: delegate)
    }

    @MainActor
    private func render(_ hosted: Hosted) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: hosted.window.bounds, format: format).image { _ in
            hosted.window.drawHierarchy(in: hosted.window.bounds, afterScreenUpdates: true)
        }
    }

    private func stack(_ images: [UIImage], width: CGFloat, dark: Bool) -> UIImage {
        let height = images.reduce(0) { $0 + $1.size.height }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: max(1, height)), format: format).image { context in
            (dark ? UIColor.black : UIColor.white).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var y: CGFloat = 0
            for image in images {
                image.draw(at: CGPoint(x: 0, y: y))
                y += image.size.height
            }
        }
    }

    private func save(_ image: UIImage, name: String) throws {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("402")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }

    /// The file row's thumbnail, the image view the file icon makes way for.
    private static func thumbnail(in view: UIView) -> UIImageView? {
        if let imageView = view as? UIImageView, imageView.accessibilityIdentifier == CVComponentGenericAttachment.tellomiThumbnailIdentifier, imageView.superview != nil {
            return imageView
        }
        for subview in view.subviews {
            if let found = thumbnail(in: subview) {
                return found
            }
        }
        return nil
    }

    private static func texts(in view: UIView) -> [String] {
        var result = [String]()
        if let label = view as? UILabel, let text = label.attributedText?.string ?? label.text, !text.isEmpty {
            result.append(text)
        }
        for subview in view.subviews {
            result += texts(in: subview)
        }
        return result
    }
}
