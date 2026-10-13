//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
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
/// 同一套也验收到的被罩住（spoiler，spec R-1）的图片：`AttachmentPointer.tellomi.spoiler` → 会话里罩着 → 点一下揭示、记住。
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
        TellomiMediaSpoiler.resetRevealedInMemoryForTesting()
        TellomiLivePhoto.resetForTesting()
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

    // MARK: - 说明文字在媒体上方（ADR-0068 §4.7）

    /// 标记为真：正文在图上面（同一个气泡里），时间压在图上。
    @MainActor
    func testCaptionAboveMediaPutsTheTextAboveThePhoto() async throws {
        let thread = makeThread()
        let message = try await insertStream(renderingFlag: .default, fileName: "IMG_0004.PNG", thread: thread, body: "说明在图上面")
        write { tx in TellomiCaptionAbove.setCaptionAboveMedia(true, messageUniqueId: message.uniqueId, tx: tx) }

        let hosted = try await host(message: message, thread: thread, width: 402)
        defer { hosted.tearDown() }
        XCTAssertTrue(hosted.componentState.tellomiCaptionAboveMedia)
        let (text, media) = try Self.textAndMediaFrames(in: hosted.cellView)
        XCTAssertLessThanOrEqual(text.maxY, media.minY + 0.5, "说明在图上面")
    }

    /// 没有标记：和上游一样，正文在图下面。
    @MainActor
    func testWithoutTheFlagTheCaptionStaysBelow() async throws {
        let thread = makeThread()
        let message = try await insertStream(renderingFlag: .default, fileName: "IMG_0005.PNG", thread: thread, body: "说明在图下面")

        let hosted = try await host(message: message, thread: thread, width: 402)
        defer { hosted.tearDown() }
        XCTAssertFalse(hosted.componentState.tellomiCaptionAboveMedia)
        let (text, media) = try Self.textAndMediaFrames(in: hosted.cellView)
        XCTAssertGreaterThanOrEqual(text.minY, media.maxY - 0.5, "说明在图下面")
    }

    /// 只有文字（或按文件发的图）：标记没有意义，照常画。
    @MainActor
    func testTheFlagMeansNothingWithoutMediaShownAsMedia() async throws {
        let thread = makeThread()
        let textOnly = try insertMessage(thread: thread, body: "只有文字")
        let asFile = try await insertStream(renderingFlag: .tellomiAsFile, fileName: "IMG_0006.PNG", thread: thread, body: "按文件发的")
        write { tx in
            TellomiCaptionAbove.setCaptionAboveMedia(true, messageUniqueId: textOnly.uniqueId, tx: tx)
            TellomiCaptionAbove.setCaptionAboveMedia(true, messageUniqueId: asFile.uniqueId, tx: tx)
        }

        for message in [textOnly, asFile] as [TSMessage] {
            let hosted = try await host(message: message, thread: thread, width: 402)
            XCTAssertFalse(hosted.componentState.tellomiCaptionAboveMedia)
            hosted.tearDown()
        }
    }

    /// 给人看的截图：说明在上方 / 在下方，浅色。
    @MainActor
    func testCaptionAboveShots() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        let thread = makeThread()
        let above = try await insertStream(renderingFlag: .default, fileName: "IMG_0007.PNG", thread: thread, body: "说明文字在图片上方")
        let below = try await insertStream(renderingFlag: .default, fileName: "IMG_0008.PNG", thread: thread, body: "说明文字在图片下方（默认）")
        write { tx in TellomiCaptionAbove.setCaptionAboveMedia(true, messageUniqueId: above.uniqueId, tx: tx) }
        var images = [UIImage]()
        for message in [above, below] {
            let hosted = try await host(message: message, thread: thread, width: 402)
            images.append(render(hosted))
            hosted.tearDown()
        }
        try save(stack(images, width: 402, dark: false), name: "caption-above-light.png")
    }

    /// 正文和图在 cell 里的位置。
    private static func textAndMediaFrames(in cellView: UIView) throws -> (text: CGRect, media: CGRect) {
        let textView = try XCTUnwrap(CVComponentBodyText.findBodyTextRootView(cellView))
        let mediaView = try XCTUnwrap(find(CVMediaAlbumView.self, in: cellView))
        return (cellView.convert(textView.bounds, from: textView), cellView.convert(mediaView.bounds, from: mediaView))
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
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

    // MARK: - 被罩住的图片 / 视频（spec R-1）

    /// 收到的指针带 spoiler：从 proto 一路落库，会话里罩着（模糊 + 粒子），下载钮照常在上面。
    @MainActor
    func testACoveredPointerIsCoveredInTheChat() async throws {
        let thread = makeThread()
        let message = try await insertPointer(asFile: false, spoiler: true, thread: thread)

        let hosted = try await host(message: message, thread: thread, width: 402)
        defer { hosted.tearDown() }
        let item = try XCTUnwrap(hosted.componentState.bodyMedia?.items.first)
        XCTAssertTrue(item.isTellomiSpoilerCovered)
        let cover = try XCTUnwrap(Self.find(TellomiSpoilerCoverView.self, in: hosted.cellView))
        XCTAssertTrue(cover.isCovering)
        XCTAssertFalse(cover.isHidden)
    }

    /// spoiler 和 asFile 一起：按文件，文件行，不罩（ADR-0068 §4.1）。
    @MainActor
    func testSpoilerOnSomethingSentAsAFileIsIgnored() async throws {
        let thread = makeThread()
        let message = try await insertPointer(asFile: true, spoiler: true, thread: thread)

        let hosted = try await host(message: message, thread: thread, width: 402)
        defer { hosted.tearDown() }
        XCTAssertNotNil(hosted.componentState.genericAttachment)
        XCTAssertNil(hosted.componentState.bodyMedia)
        let reference = try XCTUnwrap(bodyAttachments(of: message).first)
        read { tx in XCTAssertFalse(TellomiMediaSpoiler.isSpoiler(reference.reference, tx: tx)) }
    }

    /// 到了的图：点一下从点的位置揭示，揭示中再点不算；揭示记在这台设备上，重画后不再罩。
    @MainActor
    func testTappingUncoversFromTheTapAndIsRemembered() async throws {
        let thread = makeThread()
        let message = try await insertStream(renderingFlag: .default, fileName: "IMG_0009.PNG", thread: thread, spoiler: true)
        let reference = try XCTUnwrap(bodyAttachments(of: message).first).reference

        let hosted = try await host(message: message, thread: thread, width: 402)
        let cover = try XCTUnwrap(Self.find(TellomiSpoilerCoverView.self, in: hosted.cellView))
        let mediaView = try XCTUnwrap(Self.find(CVMediaView.self, in: hosted.cellView))
        XCTAssertTrue(mediaView.isTellomiSpoilerCovering)

        let tap = FixedPointTap(pointInWindow: mediaView.convert(CGPoint(x: 40, y: 30), to: nil))
        XCTAssertTrue(hosted.cellView.handleTap(sender: tap, componentDelegate: hosted.delegate))
        XCTAssertTrue(cover.isRevealing)
        XCTAssertTrue(hosted.cellView.handleTap(sender: tap, componentDelegate: hosted.delegate))
        XCTAssertTrue(cover.isRevealing)

        try await Task.sleep(nanoseconds: UInt64((TellomiSpoilerCoverView.revealDuration + 0.4) * 1_000_000_000))
        XCTAssertFalse(cover.isCovering)
        XCTAssertTrue(cover.isHidden)
        XCTAssertFalse(mediaView.isTellomiSpoilerCovering)

        // Written to the database in the background.
        var isCovered = true
        for _ in 0..<20 where isCovered {
            try await Task.sleep(nanoseconds: 100_000_000)
            isCovered = read { tx in TellomiMediaSpoiler.isCovered(reference, tx: tx) }
        }
        XCTAssertFalse(isCovered)
        hosted.tearDown()

        TellomiMediaSpoiler.resetRevealedInMemoryForTesting()
        let again = try await host(message: message, thread: thread, width: 402)
        defer { again.tearDown() }
        XCTAssertEqual(again.componentState.bodyMedia?.items.first?.isTellomiSpoilerCovered, false)
        XCTAssertNil(Self.find(TellomiSpoilerCoverView.self, in: again.cellView))
    }

    // MARK: - 实况照片（spec R-2）

    /// 收到的实况：气泡左上角有实况角标，会话列表 / 通知写「实况照片」；普通图片都没有。
    @MainActor
    func testALivePhotoHasItsBadgeAndReadsAsALivePhoto() async throws {
        let thread = makeThread()
        let live = try await insertStream(renderingFlag: .default, fileName: "IMG_0012.PNG", thread: thread, livePhoto: true)
        let plain = try await insertStream(renderingFlag: .default, fileName: "IMG_0013.PNG", thread: thread)
        // Showing it plays the moving half once; there is nothing to download from here.
        try cacheLiveVideo(of: live)

        let hostedLive = try await host(message: live, thread: thread, width: 402)
        XCTAssertNotNil(hostedLive.componentState.bodyMedia?.items.first?.tellomiLiveVideo)
        let liveView = try XCTUnwrap(Self.find(TellomiLivePhotoView.self, in: hostedLive.cellView))
        XCTAssertTrue(Self.hasLiveBadge(in: hostedLive.cellView))
        // Playing, it covers the whole picture, not the video's own size (64 × 96)
        liveView.play(try Self.makeTestVideo(), loopWithSound: true)
        hostedLive.cellView.layoutIfNeeded()
        let player = try XCTUnwrap(Self.find(VideoPlayerView.self, in: liveView))
        XCTAssertEqual(liveView.frame.size, try XCTUnwrap(liveView.superview).bounds.size)
        XCTAssertEqual(player.frame.size, liveView.bounds.size)
        XCTAssertGreaterThan(player.frame.size.width, 200)
        liveView.stop(animated: false)
        hostedLive.tearDown()

        let hostedPlain = try await host(message: plain, thread: thread, width: 402)
        XCTAssertNil(hostedPlain.componentState.bodyMedia?.items.first?.tellomiLiveVideo)
        XCTAssertNil(Self.find(TellomiLivePhotoView.self, in: hostedPlain.cellView))
        XCTAssertFalse(Self.hasLiveBadge(in: hostedPlain.cellView))
        hostedPlain.tearDown()

        read { tx in
            XCTAssertTrue(live.notificationPreviewText(tx).contains("Live Photo"))
            XCTAssertFalse(plain.notificationPreviewText(tx).contains("Live Photo"))
        }
    }

    /// 动态部分：会话里静音放一遍，放完自己停（淡回静态图）；查看器里带声循环，不会自己停。
    @MainActor
    func testTheLiveViewPlaysOnceMutedOrLoopsWithSound() async throws {
        let url = try Self.makeTestVideo()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        window.isHidden = false
        defer { window.isHidden = true }
        let liveView = TellomiLivePhotoView(fill: true)
        liveView.frame = window.bounds
        window.addSubview(liveView)
        var stopped = 0
        liveView.onStopped = { stopped += 1 }

        liveView.play(url, loopWithSound: false)
        XCTAssertTrue(liveView.isPlaying)
        XCTAssertFalse(liveView.isHidden)
        for _ in 0..<50 where stopped == 0 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(stopped, 1)
        XCTAssertFalse(liveView.isPlaying)
        XCTAssertTrue(liveView.isHidden)

        liveView.play(url, loopWithSound: true)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(liveView.isPlaying, "loops until stopped")
        liveView.stop(animated: false)
        XCTAssertFalse(liveView.isPlaying)
        XCTAssertEqual(stopped, 2)
    }

    /// 照 Telegram（owner 2026-10-13）：会话里每次出现都静音放一遍；格子马上重建（消息更新）不算新出现，不重放。
    @MainActor
    func testTheBubblePlaysEachTimeItComesOnScreen() async throws {
        let thread = makeThread()
        let live = try await insertStream(renderingFlag: .default, fileName: "IMG_0016.PNG", thread: thread, livePhoto: true)
        try cacheLiveVideo(of: live)
        let hosted = try await host(message: live, thread: thread, width: 402)
        defer { hosted.tearDown() }
        let liveView = try XCTUnwrap(Self.find(TellomiLivePhotoView.self, in: hosted.cellView))

        try await Self.wait(until: { liveView.isPlaying }, seconds: 2)
        try await Self.wait(until: { !liveView.isPlaying }, seconds: 5)

        // Rebuilt in place: not a new appearance
        hosted.cellView.isCellVisible = false
        hosted.cellView.isCellVisible = true
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(liveView.isPlaying)

        // Off screen and back: plays again
        hosted.cellView.isCellVisible = false
        try await Task.sleep(nanoseconds: UInt64((TellomiLivePhoto.reappearanceGrace + 0.1) * 1_000_000_000))
        hosted.cellView.isCellVisible = true
        try await Self.wait(until: { liveView.isPlaying }, seconds: 2)
    }

    @MainActor
    private static func wait(until condition: () -> Bool, seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    /// 查看器：实况那一页左上角有「实况」按钮（跟着顶栏出现），点一下带声循环、再点停；打开时先静音放一遍。
    @MainActor
    func testTheViewerHasTheLiveButton() async throws {
        let thread = makeThread()
        let live = try await insertStream(renderingFlag: .default, fileName: "IMG_0014.PNG", thread: thread, livePhoto: true)
        try cacheLiveVideo(of: live)
        let (window, viewer, page) = try await hostViewer(live, thread: thread)

        // Opening plays it once, muted
        XCTAssertNotNil(Self.find(TellomiLivePhotoView.self, in: page.view))
        XCTAssertTrue(try XCTUnwrap(Self.find(TellomiLivePhotoView.self, in: page.view)).isPlaying)

        viewer.mediaItemViewControllerDidTapMedia(page)
        try await Task.sleep(nanoseconds: 500_000_000)
        let button = viewer.tellomiLiveButtonForTesting
        XCTAssertFalse(button.isHidden)
        XCTAssertFalse(button.isSelected)

        page.toggleTellomiLive()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(page.isTellomiLiveActive)
        XCTAssertTrue(button.isSelected)

        page.toggleTellomiLive()
        XCTAssertFalse(page.isTellomiLiveActive)
        XCTAssertFalse(button.isSelected)

        // Take the viewer down and let what it scheduled run while the environment is still here
        window.rootViewController = nil
        window.isHidden = true
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    /// 给人看的截图：会话里的实况（角标、放到一半）、查看器的「实况」按钮。
    @MainActor
    func testLivePhotoShots() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        let thread = makeThread()
        let live = try await insertStream(renderingFlag: .default, fileName: "IMG_0015.PNG", thread: thread, livePhoto: true)
        try cacheLiveVideo(of: live)

        let hosted = try await host(message: live, thread: thread, width: 402)
        try save(render(hosted), name: "live-bubble-playing.png")
        try await Task.sleep(nanoseconds: 1_600_000_000)
        try save(render(hosted), name: "live-bubble-still.png")
        hosted.tearDown()

        let (window, viewer, page) = try await hostViewer(live, thread: thread)
        viewer.mediaItemViewControllerDidTapMedia(page)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        page.toggleTellomiLive()
        try await Task.sleep(nanoseconds: 500_000_000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let shot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try save(shot, name: "live-viewer.png")
        page.toggleTellomiLive()
        window.isHidden = true
    }

    private func cacheLiveVideo(of message: TSMessage) throws {
        let reference = try XCTUnwrap(bodyAttachments(of: message).first).reference
        let video = try XCTUnwrap(read { tx in TellomiLivePhoto.video(reference, tx: tx) })
        TellomiLivePhoto.cacheVideoForTesting(video, url: try Self.makeTestVideo())
    }

    @MainActor
    private func hostViewer(_ message: TSMessage, thread: TSThread) async throws -> (UIWindow, MediaPageViewController, MediaItemViewController) {
        let attachment = try XCTUnwrap(bodyAttachments(of: message).first)
        let viewer = try XCTUnwrap(MediaPageViewController(initialMediaAttachment: attachment, thread: thread, spoilerState: SpoilerRenderState()))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = viewer
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 600_000_000)
        let page = try XCTUnwrap(viewer.viewControllers?.first as? MediaItemViewController)
        return (window, viewer, page)
    }

    private static func hasLiveBadge(in view: UIView) -> Bool {
        if let imageView = view as? UIImageView, imageView.accessibilityLabel == "Live Photo" {
            return true
        }
        return view.subviews.contains { hasLiveBadge(in: $0) }
    }

    /// 两秒的小视频（AVAssetWriter 现做，不进仓库）。
    private static func makeTestVideo() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tellomi-live-\(UUID().uuidString).mp4")
        let size = CGSize(width: 64, height: 96)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frameCount = 60
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                usleep(1000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            // 紫底 + 一个往右下走的白方块，截图里一眼看得出是视频在放
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    let isDot = abs(x - 8 - frame * 48 / frameCount) < 6 && abs(y - 12 - frame * 72 / frameCount) < 6
                    let argb: [UInt8] = isDot ? [255, 255, 255, 255] : [255, 120, 60, 200]
                    for channel in 0..<4 {
                        base[y * bytesPerRow + x * 4 + channel] = argb[channel]
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    /// 给人看的截图：罩着（到了）和揭示以后，浅色和深色各一张。没下载的不截：这个整窗截图里没下载的图（罩不罩都一样）画成黑的。
    @MainActor
    func testSpoilerShots() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        for dark in [false, true] {
            let thread = makeThread()
            let uncovered = try await insertStream(renderingFlag: .default, fileName: "IMG_0011.PNG", thread: thread, spoiler: true)
            write { tx in
                for reference in DependenciesBridge.shared.attachmentStore.fetchReferences(owner: .messageBodyAttachment(messageRowId: uncovered.sqliteRowId!), tx: tx) {
                    TellomiMediaSpoiler.markRevealed(reference, tx: tx)
                }
            }
            let messages = [
                try await insertStream(renderingFlag: .default, fileName: "IMG_0010.PNG", thread: thread, spoiler: true),
                uncovered,
            ]
            var images = [UIImage]()
            for message in messages {
                let hosted = try await host(message: message, thread: thread, width: 402, dark: dark)
                images.append(render(hosted))
                hosted.tearDown()
            }
            try save(stack(images, width: 402, dark: dark), name: "spoiler-\(dark ? "dark" : "light").png")
        }
    }

    /// 一个固定在某一点的点按（`location(in:)` 是这一点换到那个视图里）。
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

    private func insertMessage(thread: TSContactThread, body: String? = nil) throws -> TSIncomingMessage {
        let authorAci = try XCTUnwrap(thread.contactAddress.aci)
        return write { tx in
            let messageBody = body.map {
                DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(MessageBody(text: $0, ranges: .empty), tx: tx)
            }
            let message = TSIncomingMessageBuilder.withDefaultValues(
                thread: thread,
                timestamp: Date.ows_millisecondTimestamp(),
                authorAci: authorAci,
                messageBody: messageBody,
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
    private func insertPointer(asFile: Bool, spoiler: Bool = false, thread: TSContactThread) async throws -> TSMessage {
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
        if asFile || spoiler {
            let tellomi = SSKProtoTellomiAttachment.builder()
            if asFile {
                tellomi.setAsFile(true)
            }
            if spoiler {
                tellomi.setSpoiler(true)
            }
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
    private func insertStream(
        renderingFlag: AttachmentReference.RenderingFlag,
        fileName: String,
        thread: TSContactThread,
        body: String? = nil,
        spoiler: Bool = false,
        livePhoto: Bool = false,
    ) async throws -> TSMessage {
        let message = try insertMessage(thread: thread, body: body)
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
            if spoiler {
                // As if it had come in covered and then downloaded: the mark the incoming pointer leaves.
                let tellomi = SSKProtoTellomiAttachment.builder()
                tellomi.setSpoiler(true)
                let pointer = SSKProtoAttachmentPointer.builder()
                pointer.setTellomi(tellomi.buildInfallibly())
                TellomiMediaSpoiler.markReceived(pointer.buildInfallibly(), mimeType: "image/png", owner: bodyOwner(message, thread: thread), tx: tx)
            }
            if livePhoto {
                // As if it had come in as a live photo: the still's pointer carries the moving half.
                let video = SSKProtoAttachmentPointer.builder()
                video.setCdnNumber(3)
                video.setCdnKey("cdn-key-live-\(UUID().uuidString)")
                video.setContentType("video/mp4")
                video.setKey(Randomness.generateRandomBytes(64))
                video.setDigest(Randomness.generateRandomBytes(32))
                video.setSize(456_789)
                let tellomi = SSKProtoTellomiAttachment.builder()
                tellomi.setLivePhotoVideo(video.buildInfallibly())
                let still = SSKProtoAttachmentPointer.builder()
                still.setContentType("image/png")
                still.setTellomi(tellomi.buildInfallibly())
                TellomiLivePhoto.markReceived(still.buildInfallibly(), mimeType: "image/png", owner: bodyOwner(message, thread: thread), tx: tx)
            }
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
