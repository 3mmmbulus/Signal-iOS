//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import MapKit
import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// spec attachment-files-location L-11：位置消息在会话里画成「地图（宽 × 半宽）+ 地点的名称 / 地址」，不画图片 + 原文。
/// 走会话页同一条渲染路径（`CVLoader.buildStandaloneRenderItem` + `CVCellView`，同 `TellomiAsFileCellTests`），在内存环境里，
/// 不连服务端。截图只在 `TELLOMI_SHOTS=1` 时存（xcodebuild 用 `TEST_RUNNER_TELLOMI_SHOTS=1`），写到 `TELLOMI_SHOTS_DIR/402/`。
///
/// Telegram 的数（`ChatMessageMapBubbleContentNode.swift`）：图宽 `min(可用宽, 300)`、高 `floor(宽 * 0.5)`；名称 medium 14 一行；
/// 地址 regular 14 两行、次要色；普通位置只有图，时间压在图的右下角。
final class TellomiLocationBubbleTests: XCTestCase {

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

    // Bodies as each client sends them (see `TellomiLocationMessage`).
    private static let tellomiPlaceBody = "星巴克臻选上海烘焙工坊\n静安区南京西路789号兴业太古汇\nhttps://maps.google.com/maps?q=31.2297%2C121.4560"
    private static let signalIOSBody = "中国\n上海市静安区\n南京西路789号\n\nhttps://maps.google.com/maps?q=31.2297%2C121.4560"
    private static let signalAndroidBody = "789 Nanjing West Road, Jing'an, Shanghai\nhttps://maps.google.com/maps?q=31.2297%2C121.4560"

    // MARK: - Recognising

    @MainActor
    func testAPlaceIsAMapWithItsNameAndAddress_notThePhotoAndTheLink() async throws {
        let thread = makeThread()
        let message = try await insertLocation(body: Self.tellomiPlaceBody, thread: thread)

        let hosted = try await host(message: message, thread: thread, width: 402)
        defer { hosted.tearDown() }
        let location = try XCTUnwrap(hosted.componentState.tellomiLocation)
        XCTAssertTrue(location.isPlace)
        XCTAssertFalse(hosted.componentState.tellomiCaptionAboveMedia)

        let texts = Self.texts(in: hosted.cellView)
        XCTAssertTrue(texts.contains("星巴克臻选上海烘焙工坊"))
        XCTAssertTrue(texts.contains("静安区南京西路789号兴业太古汇"))
        XCTAssertFalse(texts.contains { $0.contains("maps.google.com") }, "the link is not shown")
        XCTAssertNil(CVComponentBodyText.findBodyTextRootView(hosted.cellView), "the body text component is not drawn")
    }

    @MainActor
    func testAPlainLocationIsOnlyTheMap_timeOnTheMap() async throws {
        let thread = makeThread()
        for body in [Self.signalIOSBody, Self.signalAndroidBody, "https://maps.google.com/maps?q=31.2297%2C121.4560"] {
            let message = try await insertLocation(body: body, thread: thread)
            let hosted = try await host(message: message, thread: thread, width: 402)
            let location = try XCTUnwrap(hosted.componentState.tellomiLocation, body)
            XCTAssertFalse(location.isPlace, body)
            XCTAssertTrue(hosted.componentState.isBodyMediaOnlyMessage, body)
            XCTAssertNil(CVComponentBodyText.findBodyTextRootView(hosted.cellView), body)
            let texts = Self.texts(in: hosted.cellView)
            XCTAssertFalse(texts.contains { $0.contains("maps.google.com") || $0.contains("南京西路") || $0.contains("Nanjing") }, body)
            // The footer is drawn on the map (no row of its own under it).
            let map = try XCTUnwrap(Self.find(CVMediaAlbumView.self, in: hosted.cellView))
            let mapFrame = hosted.cellView.convert(map.bounds, from: map)
            let footer = try XCTUnwrap(Self.footer(in: hosted.cellView))
            let footerFrame = hosted.cellView.convert(footer.bounds, from: footer)
            XCTAssertTrue(mapFrame.contains(footerFrame), "\(body): footer \(footerFrame) on map \(mapFrame)")
            hosted.tearDown()
        }
    }

    @MainActor
    func testOtherMessagesAreNotLocations() async throws {
        let thread = makeThread()
        let photoWithCaption = try await insertLocation(body: "Look at this", thread: thread)
        let textWithLink = try insertMessage(thread: thread, body: Self.tellomiPlaceBody, incoming: true)
        for message in [photoWithCaption, textWithLink] as [TSMessage] {
            let hosted = try await host(message: message, thread: thread, width: 402)
            XCTAssertNil(hosted.componentState.tellomiLocation)
            hosted.tearDown()
        }
    }

    // MARK: - Chat list, notifications (spec §3.3.1)

    /// 会话列表和通知里写「📍 Location」，不写名称、地址和链接（Telegram 两端：`Message.Location` / `AttachLocation`，
    /// 地点也一样）；搜索结果还是显示搜到的字；别的消息照旧。
    @MainActor
    func testTheChatListAndNotificationsSayLocation() async throws {
        let thread = makeThread()
        for (body, incoming) in [(Self.tellomiPlaceBody, true), (Self.signalIOSBody, true), (Self.signalAndroidBody, false)] {
            let location = try await insertLocation(body: body, thread: thread, incoming: incoming)
            read { tx in
                XCTAssertEqual(location.notificationPreviewText(tx), "📍 Location", body)
                XCTAssertEqual(location.conversationListPreviewText(tx).asPlaintext(), "📍 Location", body)
                XCTAssertEqual(location.conversationListSearchResultsBody(tx)?.text, body, body)
            }
        }

        let photoWithCaption = try await insertLocation(body: "Look at this", thread: thread)
        let textWithTheLink = try insertMessage(thread: thread, body: Self.tellomiPlaceBody, incoming: true)
        read { tx in
            XCTAssertEqual(photoWithCaption.notificationPreviewText(tx), "📷 Look at this")
            XCTAssertTrue(textWithTheLink.notificationPreviewText(tx).contains("maps.google.com"))
            XCTAssertTrue(textWithTheLink.conversationListPreviewText(tx).asPlaintext().contains("星巴克"))
        }
    }

    // MARK: - Layout (Telegram's numbers)

    @MainActor
    func testTheMapIsWidthByHalfWidth_atMost300() async throws {
        // 402: room for 326 pt of media → capped at 300; 320: 244 pt of media → the whole width; and the simulator's own width
        // (440 on a Pro Max). Never wider than the simulator's screen: a test window wider than the screen lays every media
        // bubble out 50 pt lower and 72 pt shorter (an ordinary photo too), which a chat on a device never is.
        let screenWidth = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.size.width ?? 402
        let widths = Set([320, 402, screenWidth].filter { $0 <= screenWidth }).sorted()
        XCTAssertTrue(widths.contains(320))
        for width: CGFloat in widths {
            let thread = makeThread()
            let message = try await insertLocation(body: Self.tellomiPlaceBody, thread: thread)
            let hosted = try await host(message: message, thread: thread, width: width)
            let map = try XCTUnwrap(Self.find(CVMediaAlbumView.self, in: hosted.cellView))
            let maxMediaWidth = hosted.renderItem.itemModel.conversationStyle.maxMediaMessageWidth
            XCTAssertEqual(map.bounds.size.width, min(300, maxMediaWidth), accuracy: 0.5, "screen \(width)")
            XCTAssertEqual(map.bounds.size.height, (map.bounds.size.width / 2).rounded(), accuracy: 1, "screen \(width)")
            // The name / address are never wider than the map.
            for label in Self.labels(in: hosted.cellView) where label.text?.contains("星巴克") == true || label.text?.contains("南京西路") == true {
                XCTAssertLessThanOrEqual(label.bounds.size.width, map.bounds.size.width - 24 + 0.5)
            }
            hosted.tearDown()
        }
    }

    @MainActor
    func testNameAndAddressFonts_lines_colours_andSpacing() async throws {
        let thread = makeThread()
        let longAddress = String(repeating: "上海市静安区南京西路789号兴业太古汇", count: 4)
        let message = try await insertLocation(body: "星巴克\n\(longAddress)\nhttps://maps.google.com/maps?q=31.2297%2C121.4560", thread: thread)
        let hosted = try await host(message: message, thread: thread, width: 402)
        defer { hosted.tearDown() }

        let labels = Self.labels(in: hosted.cellView)
        let title = try XCTUnwrap(labels.first { $0.text == "星巴克" })
        let address = try XCTUnwrap(labels.first { $0.text == longAddress })
        XCTAssertEqual(title.font.pointSize, 14, accuracy: 0.01)
        XCTAssertEqual(title.font.fontDescriptor.object(forKey: .traits).flatMap { ($0 as? [UIFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat } ?? 0, UIFont.Weight.medium.rawValue, accuracy: 0.01)
        XCTAssertEqual(title.numberOfLines, 1)
        XCTAssertEqual(address.font.pointSize, 14, accuracy: 0.01)
        XCTAssertEqual(address.numberOfLines, 2)
        XCTAssertEqual(address.lineBreakMode, .byTruncatingTail)
        let style = hosted.renderItem.itemModel.conversationStyle
        XCTAssertEqual(title.textColor, style.bubbleTextColor(isIncoming: true))
        XCTAssertEqual(address.textColor, style.bubbleSecondaryTextColor(isIncoming: true))
        // Two lines of address at most.
        XCTAssertLessThanOrEqual(address.bounds.size.height, ceil(address.font.lineHeight * 2) + 1)

        let map = try XCTUnwrap(Self.find(CVMediaAlbumView.self, in: hosted.cellView))
        let mapFrame = hosted.cellView.convert(map.bounds, from: map)
        let titleFrame = hosted.cellView.convert(title.bounds, from: title)
        let addressFrame = hosted.cellView.convert(address.bounds, from: address)
        // Under the map: 7 pt like every caption in the chat (Telegram: 6); 12 pt from the bubble edge (Telegram: 9).
        XCTAssertEqual(titleFrame.minY - mapFrame.maxY, 7, accuracy: 0.5)
        XCTAssertEqual(titleFrame.minX - mapFrame.minX, 12, accuracy: 0.5)
        XCTAssertEqual(addressFrame.minY, titleFrame.maxY, accuracy: 0.5)
    }

    @MainActor
    func testTheTimeSitsOnTheLastLineWhenItFits() async throws {
        let thread = makeThread()
        let message = try await insertLocation(body: "星巴克\n南京西路789号\nhttps://maps.google.com/maps?q=31.2297%2C121.4560", thread: thread)
        let hosted = try await host(message: message, thread: thread, width: 402)
        defer { hosted.tearDown() }
        let address = try XCTUnwrap(Self.labels(in: hosted.cellView).first { $0.text == "南京西路789号" })
        let footer = try XCTUnwrap(Self.footer(in: hosted.cellView))
        let addressFrame = hosted.cellView.convert(address.bounds, from: address)
        let footerFrame = hosted.cellView.convert(footer.bounds, from: footer)
        XCTAssertLessThan(footerFrame.midY, addressFrame.maxY + 2, "footer on the address line: \(footerFrame) vs \(addressFrame)")
        // …and to the right of the address's last line.
        let time = try XCTUnwrap(Self.labels(in: footer).first)
        let timeFrame = hosted.cellView.convert(time.bounds, from: time)
        XCTAssertGreaterThan(timeFrame.minX, addressFrame.minX + address.intrinsicContentSize.width + 5, "\(timeFrame) vs \(addressFrame)")
    }

    // MARK: - Tapping

    @MainActor
    func testTappingTheMapOrTheTextOpensTheLocation() async throws {
        let thread = makeThread()
        let message = try await insertLocation(body: Self.tellomiPlaceBody, thread: thread)
        let hosted = try await host(message: message, thread: thread, width: 402)
        defer { hosted.tearDown() }
        var tapped = [TellomiLocationMessage]()
        hosted.delegate.tellomiOnTapLocation = { tapped.append($0) }

        let map = try XCTUnwrap(Self.find(CVMediaAlbumView.self, in: hosted.cellView))
        let onMap = FixedPointTap(pointInWindow: map.convert(CGPoint(x: map.bounds.midX, y: map.bounds.midY), to: nil))
        XCTAssertTrue(hosted.cellView.handleTap(sender: onMap, componentDelegate: hosted.delegate))

        let title = try XCTUnwrap(Self.labels(in: hosted.cellView).first { $0.text == "星巴克臻选上海烘焙工坊" })
        let onTitle = FixedPointTap(pointInWindow: title.convert(CGPoint(x: 10, y: title.bounds.midY), to: nil))
        XCTAssertTrue(hosted.cellView.handleTap(sender: onTitle, componentDelegate: hosted.delegate))

        XCTAssertEqual(tapped.count, 2)
        XCTAssertEqual(tapped.first?.name, "星巴克臻选上海烘焙工坊")
        XCTAssertEqual(tapped.first?.latitude, 31.2297)
    }

    // MARK: - Shots

    /// 给人看的截图：收到 / 发出 × 地点 / 普通位置，浅色和深色各一张。地图是真的 `MKMapSnapshotter`（模拟器能联网时），
    /// 按上游 Signal-iOS 的样子画：256 × 256、系统大头针尖在正中——看居中裁成 2:1 以后的样子。
    @MainActor
    func testShots() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        let snapshot = await Self.upstreamStyleSnapshot(latitude: 31.2297, longitude: 121.4560)
        let width: CGFloat = 402
        for dark in [false, true] {
            let thread = makeThread()
            let messages = [
                try await insertLocation(body: Self.tellomiPlaceBody, thread: thread, imageData: snapshot),
                try await insertLocation(body: Self.tellomiPlaceBody, thread: thread, imageData: snapshot, incoming: false),
                try await insertLocation(body: Self.signalIOSBody, thread: thread, imageData: snapshot),
                try await insertLocation(body: Self.signalAndroidBody, thread: thread, imageData: snapshot, incoming: false),
            ]
            var images = [UIImage]()
            for message in messages {
                let hosted = try await host(message: message, thread: thread, width: width, dark: dark)
                images.append(render(hosted))
                hosted.tearDown()
            }
            try save(stack(images, width: width, dark: dark), name: "location-bubbles-\(dark ? "dark" : "light").png")
        }
    }

    /// 给人看的截图：Tellomi 现在发出去的样子（`TellomiLocationSnapshot`：2:1、气球大头针，地点按类别配色）——收到的地点、
    /// 发出的普通位置；另存两张原图。拿不到地图（模拟器没网）时用一张灰底图，只看大头针。
    @MainActor
    func testShotsOfWhatTellomiSends() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        let coordinate = CLLocationCoordinate2D(latitude: 31.2297, longitude: 121.4560)
        var snapshots = [Data]()
        for (index, pin) in [TellomiLocationSnapshot.Pin.place(category: .cafe), .location].enumerated() {
            let image: UIImage
            if let real = try? await TellomiLocationSnapshot.generate(coordinate: coordinate, pin: pin) {
                image = real
            } else {
                let gray = UIGraphicsImageRenderer(size: TellomiLocationSnapshot.size).image { context in
                    UIColor(white: 0.92, alpha: 1).setFill()
                    context.fill(CGRect(origin: .zero, size: TellomiLocationSnapshot.size))
                }
                image = TellomiLocationSnapshot.render(map: gray, tip: TellomiLocationSnapshot.tipPoint, pin: pin)
            }
            try save(image, name: "location-snapshot-\(index == 0 ? "place" : "plain").png")
            snapshots.append(try XCTUnwrap(image.jpegData(compressionQuality: 0.9)))
        }
        for dark in [false, true] {
            let thread = makeThread()
            let messages = [
                try await insertLocation(body: Self.tellomiPlaceBody, thread: thread, imageData: snapshots[0]),
                try await insertLocation(body: Self.signalIOSBody, thread: thread, imageData: snapshots[1], incoming: false),
            ]
            var images = [UIImage]()
            for message in messages {
                let hosted = try await host(message: message, thread: thread, width: 402, dark: dark)
                images.append(render(hosted))
                hosted.tearDown()
            }
            try save(stack(images, width: 402, dark: dark), name: "location-bubbles-sent-format-\(dark ? "dark" : "light").png")
        }
    }

    /// 上游 `Location.generateSnapshot` 的样子：256 pt 见方、跨度 300 m、系统大头针（尖在坐标上）。拿不到地图时画一张格子图。
    @MainActor
    private static func upstreamStyleSnapshot(latitude: Double, longitude: Double) async -> Data {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 300, longitudinalMeters: 300)
        options.size = CGSize(square: 256)
        let mapImage: UIImage
        if let snapshot = try? await MKMapSnapshotter(options: options).start() {
            mapImage = snapshot.image
        } else {
            mapImage = UIGraphicsImageRenderer(size: options.size).image { context in
                UIColor(rgbHex: 0xF2EFE9).setFill()
                context.fill(CGRect(origin: .zero, size: options.size))
                UIColor(rgbHex: 0xFFFFFF).setFill()
                for i in stride(from: 0, to: 256, by: 40) {
                    context.fill(CGRect(x: CGFloat(i), y: 0, width: 8, height: 256))
                    context.fill(CGRect(x: 0, y: CGFloat(i) + 13, width: 256, height: 8))
                }
            }
        }
        let image = UIGraphicsImageRenderer(size: options.size).image { _ in
            mapImage.draw(at: .zero)
            let pinView = MKPinAnnotationView(annotation: nil, reuseIdentifier: nil)
            pinView.pinTintColor = .Signal.accent
            var point = CGPoint(x: 128, y: 128)
            point.x -= pinView.bounds.size.width / 2 - pinView.centerOffset.x
            point.y -= pinView.bounds.size.height / 2 - pinView.centerOffset.y
            pinView.image?.draw(at: point)
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    // MARK: - Building messages

    private final class FixedPointTap: UITapGestureRecognizer {
        private let pointInWindow: CGPoint

        init(pointInWindow: CGPoint) {
            self.pointInWindow = pointInWindow
            super.init(target: nil, action: nil)
        }

        override func location(in view: UIView?) -> CGPoint {
            guard let view else { return pointInWindow }
            return view.convert(pointInWindow, from: nil)
        }
    }

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

    private func insertMessage(thread: TSContactThread, body: String, incoming: Bool) throws -> TSMessage {
        let authorAci = try XCTUnwrap(thread.contactAddress.aci)
        return write { tx in
            let messageBody = DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                MessageBody(text: body, ranges: .empty),
                tx: tx,
            )
            if incoming {
                let message = TSIncomingMessageBuilder.withDefaultValues(
                    thread: thread,
                    timestamp: Date.ows_millisecondTimestamp(),
                    authorAci: authorAci,
                    messageBody: messageBody,
                ).build()
                message.anyInsert(transaction: tx)
                return message
            }
            // Sent from another device: drawn as delivered, no upload progress (same as AlbumViewerScreenshotTests).
            let message = TSOutgoingMessageBuilder(
                thread: thread,
                timestamp: NSDate.ows_millisecondTimeStamp(),
                receivedAtTimestamp: NSDate.ows_millisecondTimeStamp(),
                messageBody: messageBody,
                editState: .none,
                expiresInSeconds: nil,
                expireTimerVersion: nil,
                expireStartedAt: nil,
                isVoiceMessage: false,
                isSmsMessageRestoredFromBackup: false,
                isViewOnceMessage: false,
                isViewOnceComplete: false,
                wasRemotelyDeleted: false,
                wasNotCreatedLocally: true,
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
            message.updateWithSentRecipients([authorAci], wasSentByUD: false, tx: tx)
            return message
        }
    }

    /// One downloaded image + the body, as a location message arrives (or is sent from this device).
    @MainActor
    private func insertLocation(body: String, thread: TSContactThread, imageData: Data? = nil, incoming: Bool = true) async throws -> TSMessage {
        let message = try insertMessage(thread: thread, body: body, incoming: incoming)
        let pending = try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
            imageData ?? Self.squareMapStandIn(),
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
        return message
    }

    /// 768 × 768 px (upstream's 256 pt at 3x): a square "map" with a dot in the middle.
    private static func squareMapStandIn() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(square: 768)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemRed.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 374, y: 374, width: 20, height: 20))
        }.jpegData(compressionQuality: 0.9)!
    }

    // MARK: - Hosting (same as TellomiAsFileCellTests)

    private struct Hosted {
        let window: UIWindow
        let cellView: CVCellView
        let renderItem: CVRenderItem
        let delegate: MockConversationView

        var componentState: CVComponentState { renderItem.componentState }

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
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 150, width: width, height: cellHeight + 24))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.backgroundColor = dark ? .black : .white
        let cellView = CVCellView()
        cellView.configure(renderItem: renderItem, componentDelegate: delegate)
        cellView.frame = CGRect(x: 0, y: 12, width: width, height: cellHeight)
        window.addSubview(cellView)
        window.isHidden = false
        cellView.isCellVisible = true
        window.layoutIfNeeded()

        // The image comes in asynchronously (the first one in a run takes longest).
        for attempt in 0..<30 {
            try await Task.sleep(nanoseconds: 150_000_000)
            window.layoutIfNeeded()
            if attempt >= 7, let album = Self.find(CVMediaAlbumView.self, in: cellView), Self.hasImage(in: album) {
                break
            }
        }
        return Hosted(window: window, cellView: cellView, renderItem: renderItem, delegate: delegate)
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

    private static func hasImage(in view: UIView) -> Bool {
        if let imageView = view as? UIImageView, imageView.image != nil {
            return true
        }
        return view.subviews.contains { hasImage(in: $0) }
    }

    /// The footer (time / status): `CVComponentFooter`'s outer stack.
    private static func footer(in view: UIView) -> UIView? {
        if let stack = view as? ManualStackView, stack.name == "footer.outerStack", stack.superview != nil {
            return stack
        }
        for subview in view.subviews {
            if let found = footer(in: subview) {
                return found
            }
        }
        return nil
    }

    private static func labels(in view: UIView) -> [UILabel] {
        var result = [UILabel]()
        if let label = view as? UILabel, label.superview != nil, !label.isHidden {
            result.append(label)
        }
        for subview in view.subviews {
            result += labels(in: subview)
        }
        return result
    }

    private static func texts(in view: UIView) -> [String] {
        labels(in: view).compactMap { label in
            let text = label.attributedText?.string ?? label.text
            return text?.isEmpty == false ? text : nil
        }
    }
}
