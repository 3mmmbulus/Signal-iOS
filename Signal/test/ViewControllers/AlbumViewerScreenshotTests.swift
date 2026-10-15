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

/// tellomi/tellomi#1257：相册 / 视频查看器的判据与截图，以及「聊天里的相册仍是 Signal 原来的宫格」。
///
/// SignalBaseTest 的内存环境里建会话和带真实图片数据的相册消息（不连服务端、不建真账号）。聊天里的相册用
/// `CVLoader.buildStandaloneRenderItem`（消息详情页、聊天颜色预览走的同一条路）按指定屏宽排版成**真实的消息 cell**。
///
/// 查看器的几条只在环境变量 `TELLOMI_SHOTS=1` 时跑（xcodebuild 用 `TEST_RUNNER_TELLOMI_SHOTS=1` 传进来）；宫格那条总是跑，截图只在 `TELLOMI_SHOTS=1` 时存。
/// 截图写到 `TELLOMI_SHOTS_DIR/<屏宽>/`，屏宽取 `TELLOMI_SHOT_WIDTHS`（逗号分隔，默认 402,440,375）。
final class AlbumViewerScreenshotTests: XCTestCase {

    private var report = ""
    private var oldContext: (any AppContext)!

    /// 同 SignalBaseTest，但通讯录与资料管理器用真的：群消息要画发送者头像，假的那两个在头像路径上会被强转崩掉。
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
        // 先把这个测试开的窗口摘下来，环境还在时让它们收尾（TellomiTestWindow.swift）。
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

    private var shotWidths: [CGFloat] {
        let raw = ProcessInfo.processInfo.environment["TELLOMI_SHOT_WIDTHS"] ?? "402,440,375"
        return raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { CGFloat($0) }
    }

    private func shotsDirectory(width: CGFloat) throws -> URL {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: root).appendingPathComponent("\(Int(width))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func requireShots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时跑")
    }

    // MARK: - 聊天里的相册：Signal 原来的宫格（owner 2026-09-25 撤回横滑）

    /// owner 2026-09-25：聊天里一行横滑会接住横向滑动，挡住右滑返回一级导航，撤回；照旧用 Signal 原来的宫格
    /// （`CVMediaAlbumView`：最多露 5 格，多的在第 5 格上显示 +N）。横滑的实现留在存档分支，给以后的动态用。
    /// 判据：2 / 5 / 12 张都画成宫格；cell 里没有能横向滚动的视图；在相册上横向拖动照旧归消息自己（同上游）。
    @MainActor
    func testChatAlbumsUseTheOriginalGrid() async throws {
        let width = shotWidths.first ?? 402
        let shooting = ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1"
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        var shots = [UIImage]()
        for (count, incoming) in [(2, true), (5, false), (12, true), (12, false)] {
            let label = "\(incoming ? "in" : "out")\(count)"
            let message = try await insertAlbum(thread: thread, incoming: incoming, sizes: sizes(count), body: nil)
            let hosted = try await host(message: message, thread: thread, width: width)

            let album = try XCTUnwrap(findView(CVMediaAlbumView.self, in: hosted.cellView), "\(label)：没有宫格")
            report += "  \(label): items=\(album.itemViews.count) more=\(album.moreItemsView != nil) frame=\(NSCoder.string(for: hosted.cellView.convert(album.bounds, from: album)))\n"
            XCTAssertEqual(album.itemViews.count, min(count, 5), "\(label)：最多露 5 格")
            XCTAssertEqual(album.moreItemsView != nil, count > 5, "\(label)：超过 5 张才有 +N")

            let scrollable = horizontallyScrollableViews(in: hosted.cellView)
            XCTAssertTrue(scrollable.isEmpty, "\(label)：聊天里不能有横向滚动的视图（会挡住右滑返回）：\(scrollable)")

            let pan = FakePan()
            pan.locationInWindow = hosted.window.convert(CGPoint(x: album.bounds.midX, y: album.bounds.midY), from: album)
            let panHandler = hosted.cellView.findPanHandler(
                sender: pan,
                componentDelegate: hosted.delegate,
                messageSwipeActionState: CVMessageSwipeActionState(),
            )
            XCTAssertNotNil(panHandler, "\(label)：相册上的横向拖动照旧归消息（同上游）")

            if shooting {
                shots.append(render(hosted))
            }
            hosted.tearDown()
        }
        if shooting {
            try save(stack(shots, width: width), name: "albums-grid.png", width: width)
            try report.write(to: shotsDirectory(width: width).deletingLastPathComponent().appendingPathComponent("metrics-albums-grid.txt"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 查看器（owner 2026-09-25，对照 Telegram）

    /// 打开时什么都不显示，轻点后四角按钮与本组缩略条一起出现（「3 / 5」）；在缩略条上拖，指到哪张查看器就切到哪张；
    /// 转发、删除都先问「这张 / 全部 5 张」；只有一张时没有缩略条。系统浅色模式下查看器也是深色（按钮深色玻璃 + 白图标，照 Telegram）。
    @MainActor
    func testViewerHiddenChromeScrubberAndAlbumChoices() async throws {
        try requireShots()
        let width = shotWidths.first ?? 402

        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let album = try await insertAlbum(thread: thread, incoming: true, sizes: sizes(5), body: nil)
        let single = try await insertAlbum(thread: thread, incoming: true, sizes: [CGSize(width: 1200, height: 1600)], body: nil)

        let third = try bodyAttachments(of: album)[2]
        let viewer = try XCTUnwrap(MediaPageViewController(initialMediaAttachment: third, thread: thread, spoilerState: SpoilerRenderState(), showingSingleMessage: true))
        let window = UIWindow.tellomiTestWindow(frame: UIScreen.main.bounds)
        // 系统是浅色模式时查看器也要是深色（照 Telegram：浅色玻璃按钮放在亮的图片上看不清）。
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = viewer
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 1_500_000_000)

        report += "viewer: opened toolbarsHidden=\(viewer.areToolbarsHiddenForTesting) current=\(viewer.currentItemForTesting.albumIndex) style=\(viewer.traitCollection.userInterfaceStyle.rawValue)\n"
        XCTAssertEqual(viewer.traitCollection.userInterfaceStyle, .dark, "系统浅色模式下查看器也是深色")
        XCTAssertTrue(viewer.areToolbarsHiddenForTesting, "打开时什么都不显示")
        XCTAssertEqual(viewer.currentItemForTesting.albumIndex, 2)
        try save(renderWindow(window), name: "viewer-1-opened.png", width: width)

        viewer.tapMediaForTesting()
        try await Task.sleep(nanoseconds: 800_000_000)
        let scrubber = viewer.albumScrubberForTesting
        report += "viewer: afterTap toolbarsHidden=\(viewer.areToolbarsHiddenForTesting) scrubberHidden=\(scrubber.isHidden) counter=\(scrubber.counterTextForTesting ?? "nil")\n"
        XCTAssertFalse(viewer.areToolbarsHiddenForTesting, "轻点后四角按钮出现")
        XCTAssertFalse(scrubber.isHidden, "轻点后缩略条出现")
        XCTAssertEqual(scrubber.counterTextForTesting, "3  /  5")
        try save(renderWindow(window), name: "viewer-2-tapped.png", width: width)

        // 在缩略条上从第 3 张往右拖到第 5 张
        let frames = scrubber.thumbnailFramesForTesting
        let y = frames[2].midY
        scrubber.scrubForTesting(through: [
            CGPoint(x: frames[2].midX, y: y),
            CGPoint(x: frames[3].midX, y: y),
            CGPoint(x: frames[4].midX, y: y),
        ])
        try await Task.sleep(nanoseconds: 800_000_000)
        report += "viewer: afterScrub current=\(viewer.currentItemForTesting.albumIndex) counter=\(scrubber.counterTextForTesting ?? "nil")\n"
        XCTAssertEqual(viewer.currentItemForTesting.albumIndex, 4, "拖缩略条能切到后面的图")
        XCTAssertEqual(scrubber.counterTextForTesting, "5  /  5")
        try save(renderWindow(window), name: "viewer-3-scrubbed.png", width: width)

        // 转发：先问「这张 / 全部 5 张」
        viewer.requestForwardForTesting()
        try await Task.sleep(nanoseconds: 800_000_000)
        let forwardSheet = try XCTUnwrap(viewer.presentedViewController as? ActionSheetController)
        let forwardTitles = labelTexts(in: forwardSheet.view)
        report += "viewer: forwardChoices=\(forwardTitles)\n"
        XCTAssertTrue(forwardTitles.contains("This Photo") && forwardTitles.contains("All 5 Photos"), "\(forwardTitles)")
        try save(renderWindow(window), name: "viewer-4-forward-choice.png", width: width)
        forwardSheet.dismiss(animated: false)
        try await Task.sleep(nanoseconds: 400_000_000)

        // 删除：同样先问，两项都是红色
        viewer.requestDeleteForTesting()
        try await Task.sleep(nanoseconds: 800_000_000)
        let deleteSheet = try XCTUnwrap(viewer.presentedViewController as? ActionSheetController)
        let deleteTitles = labelTexts(in: deleteSheet.view)
        report += "viewer: deleteChoices=\(deleteTitles)\n"
        XCTAssertTrue(deleteTitles.contains("This Photo") && deleteTitles.contains("All 5 Photos"), "\(deleteTitles)")
        try save(renderWindow(window), name: "viewer-5-delete-choice.png", width: width)
        deleteSheet.dismiss(animated: false)
        window.isHidden = true

        // 只有一张：轻点后也没有缩略条
        let singleAttachment = try bodyAttachments(of: single)[0]
        let singleViewer = try XCTUnwrap(MediaPageViewController(initialMediaAttachment: singleAttachment, thread: thread, spoilerState: SpoilerRenderState(), showingSingleMessage: true))
        let singleWindow = UIWindow.tellomiTestWindow(frame: UIScreen.main.bounds)
        singleWindow.rootViewController = singleViewer
        singleWindow.isHidden = false
        singleWindow.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        singleViewer.tapMediaForTesting()
        try await Task.sleep(nanoseconds: 800_000_000)
        report += "viewer: single scrubberHidden=\(singleViewer.albumScrubberForTesting.isHidden)\n"
        XCTAssertTrue(singleViewer.albumScrubberForTesting.isHidden, "只有一张时不显示缩略条")
        try save(renderWindow(singleWindow), name: "viewer-6-single.png", width: width)
        singleWindow.isHidden = true

        // 白底的图（截图、文档）上：按钮照样看得清——深色玻璃 + 白图标（照 Telegram）。
        let whitePage = try await insertMediaMessage(thread: thread, incoming: true, media: [(data: whitePageJpeg(), mimeType: "image/jpeg")], body: nil)
        let whiteViewer = try XCTUnwrap(MediaPageViewController(initialMediaAttachment: try bodyAttachments(of: whitePage)[0], thread: thread, spoilerState: SpoilerRenderState(), showingSingleMessage: true))
        let whiteWindow = UIWindow.tellomiTestWindow(frame: UIScreen.main.bounds)
        whiteWindow.overrideUserInterfaceStyle = .light
        whiteWindow.rootViewController = whiteViewer
        whiteWindow.isHidden = false
        whiteWindow.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        whiteViewer.tapMediaForTesting()
        try await Task.sleep(nanoseconds: 800_000_000)
        let whiteShot = renderWindow(whiteWindow)
        let deleteButton = whiteViewer.deleteButtonForTesting
        let header = whiteViewer.headerViewForTesting
        // 量按钮底色：取圆钮 / 胶囊里面、左侧避开图标和文字的一小块（整块方形会把圆外的白角也算进去）。
        func backgroundPatch(of view: UIView) -> CGRect {
            let frame = view.convert(view.bounds, to: whiteWindow)
            return CGRect(x: frame.minX + frame.size.width * 0.12, y: frame.midY - 2, width: 4, height: 4)
        }
        let deleteLuma = try XCTUnwrap(averageLuma(of: whiteShot, in: backgroundPatch(of: deleteButton)))
        let headerLuma = try XCTUnwrap(averageLuma(of: whiteShot, in: backgroundPatch(of: header)))
        let backButton = try XCTUnwrap(whiteViewer.leftBarButtonItemForTesting?.customView, "返回键是自定义的深色圆钮")
        let backLuma = try XCTUnwrap(averageLuma(of: whiteShot, in: backgroundPatch(of: backButton)))
        let moreButton = try XCTUnwrap(whiteViewer.rightBarButtonItemsForTesting.first?.customView, "「···」是自定义的深色圆钮")
        let moreLuma = try XCTUnwrap(averageLuma(of: whiteShot, in: backgroundPatch(of: moreButton)))
        // 取屏幕正中：图片按比例放进屏幕，比例不同的屏（375 = iPhone SE，667 高）左右会留黑边，贴边取样会落在黑边上。
        let pageLuma = try XCTUnwrap(averageLuma(of: whiteShot, in: CGRect(x: whiteWindow.bounds.midX - 2, y: whiteWindow.bounds.midY, width: 4, height: 4)))
        report += "viewer: whitePage style=\(whiteViewer.traitCollection.userInterfaceStyle.rawValue) pageLuma=\(pageLuma) deleteLuma=\(deleteLuma) headerLuma=\(headerLuma) backLuma=\(backLuma) moreLuma=\(moreLuma)\n"
        XCTAssertEqual(whiteViewer.traitCollection.userInterfaceStyle, .dark, "白底的图上也是深色按钮")
        XCTAssertGreaterThan(pageLuma, 0.9, "背后确实是白底")
        XCTAssertLessThan(deleteLuma, 0.3, "白底的图上，底栏删除键是深色的（不是跟着背景变浅的白玻璃）")
        XCTAssertLessThan(headerLuma, 0.3, "白底的图上，标题胶囊是深色的")
        XCTAssertLessThan(backLuma, 0.3, "白底的图上，返回键是深色的")
        XCTAssertLessThan(moreLuma, 0.3, "白底的图上，「···」是深色的")
        try save(whiteShot, name: "viewer-7-white-page.png", width: width)
        whiteWindow.isHidden = true

        try report.write(to: shotsDirectory(width: width).deletingLastPathComponent().appendingPathComponent("metrics-viewer.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - 开合的底色、翻到视频就播（移动会话审查 2026-09-26；这两条总是跑）

    /// 查看器一律深色：系统浅色模式下，开合动画的底色也是黑的。动画在转场容器里画这个颜色，那里跟着系统的浅色模式——
    /// 给会随模式变的 mediaBackground，浅色模式下就取成白，开合时闪一下白。
    @MainActor
    func testOpenAndCloseAnimationsUseABlackBackgroundInLightMode() async throws {
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let album = try await insertAlbum(thread: thread, incoming: true, sizes: sizes(2), body: nil)
        let viewer = try XCTUnwrap(MediaPageViewController(initialMediaAttachment: try bodyAttachments(of: album)[0], thread: thread, spoilerState: SpoilerRenderState(), showingSingleMessage: true))
        let window = UIWindow.tellomiTestWindow(frame: UIScreen.main.bounds)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = viewer
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let context = try XCTUnwrap(viewer.mediaPresentationContext(item: .gallery(viewer.currentItemForTesting), in: window))
        let resolvedInLightMode = context.backgroundColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        XCTAssertEqual(resolvedInLightMode, UIColor.black, "浅色模式下开合动画的底色")
    }

    /// 照 Telegram iOS（`UniversalVideoGalleryItemNode.centralityUpdated`：成为当前那一项、文件在本地就播）：
    /// 手指横滑到下载好的视频就开始播——不会停在第一帧、画面上又没有播放键（四角按钮这时还收着）。
    @MainActor
    func testSwipingToADownloadedVideoPlaysIt() async throws {
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let video = try await makeVideo(size: CGSize(width: 320, height: 180), duration: 6, framesPerSecond: 10)
        let message = try await insertMediaMessage(
            thread: thread,
            incoming: true,
            media: [(data: jpeg(size: CGSize(width: 1200, height: 1600), number: 1), mimeType: "image/jpeg"), (data: video, mimeType: "video/mp4")],
            body: nil,
        )
        let attachments = try bodyAttachments(of: message)
        let viewer = try XCTUnwrap(MediaPageViewController(initialMediaAttachment: attachments[0], thread: thread, spoilerState: SpoilerRenderState(), showingSingleMessage: true))
        let window = UIWindow.tellomiTestWindow(frame: UIScreen.main.bounds)
        window.rootViewController = viewer
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertNil(viewer.currentVideoPlayerForTesting, "先停在图片上")

        viewer.swipeToNextPageForTesting()
        let playing = await waitUntil(timeout: 3) { viewer.currentVideoPlayerForTesting?.isPlaying == true }
        XCTAssertNotNil(viewer.currentVideoPlayerForTesting, "翻到了视频")
        XCTAssertTrue(viewer.areToolbarsHiddenForTesting, "四角按钮还收着")
        XCTAssertTrue(playing, "横滑到下载好的视频就播")
    }

    // MARK: - 回复（owner 2026-09-26：回复整条，收件方照上游防伪）

    /// 在查看器里看相册的第 3 张时点「回复」：和聊天里长按回复一样，引用整条消息，缩略图照上游取第一张。
    @MainActor
    func testViewerReplyQuotesTheWholeMessage() async throws {
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let album = try await insertAlbum(thread: thread, incoming: true, sizes: sizes(3), body: nil)
        let attachments = try bodyAttachments(of: album)
        let viewer = try XCTUnwrap(MediaPageViewController(initialMediaAttachment: attachments[2], thread: thread, spoilerState: SpoilerRenderState(), showingSingleMessage: true))
        let window = UIWindow.tellomiTestWindow(frame: UIScreen.main.bounds)
        window.rootViewController = viewer
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        XCTAssertEqual(viewer.currentItemForTesting.referencedAttachment.attachment.id, attachments[2].attachment.id, "正在看第 3 张")

        let draft = viewer.replyDraftForTesting()

        XCTAssertEqual(quotedAttachmentId(draft), attachments[0].attachment.id, "引用整条相册，缩略图是第一张（不是正在看的第 3 张）")
    }

    /// 对方回复了我发的相册：不管对方带来的缩略图是哪一张，都照上游用本地原消息里的图（防伪）；单张同样。
    @MainActor
    func testIncomingQuoteOfAnAlbumUsesTheLocalOriginal() async throws {
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let album = try await insertAlbum(thread: thread, incoming: false, sizes: sizes(3), body: nil)
        let single = try await insertAlbum(thread: thread, incoming: false, sizes: [CGSize(width: 1200, height: 1600)], body: nil)
        let localAci = try XCTUnwrap(read { tx in DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci })
        let manager = DependenciesBridge.shared.quotedReplyManager

        func quoteProto(of message: TSMessage) throws -> SSKProtoDataMessageQuote {
            let pointer = SSKProtoAttachmentPointer.builder()
            pointer.setCdnKey("tellomi-album-item")
            pointer.setCdnNumber(3)
            pointer.setKey(Randomness.generateRandomBytes(64))
            pointer.setDigest(Randomness.generateRandomBytes(32))
            pointer.setSize(2048)
            pointer.setContentType("image/jpeg")
            let quoted = SSKProtoDataMessageQuoteQuotedAttachment.builder()
            quoted.setContentType("image/jpeg")
            quoted.setThumbnail(pointer.buildInfallibly())
            let quote = SSKProtoDataMessageQuote.builder(id: message.timestamp)
            quote.setAuthorAciBinary(localAci.serviceIdBinary)
            quote.addAttachments(quoted.buildInfallibly())
            return try quote.build()
        }

        let albumProto = try quoteProto(of: album)
        let singleProto = try quoteProto(of: single)
        let (albumResult, singleResult) = try read { tx in
            (
                try manager.validateAndBuildQuotedReply(from: albumProto, threadUniqueId: thread.uniqueId, tx: tx),
                try manager.validateAndBuildQuotedReply(from: singleProto, threadUniqueId: thread.uniqueId, tx: tx),
            )
        }
        if case .originalAttachment? = albumResult.thumbnailDataSource {} else {
            XCTFail("相册：应该照上游用本地原图，实际 \(String(describing: albumResult.thumbnailDataSource))")
        }
        if case .originalAttachment? = singleResult.thumbnailDataSource {} else {
            XCTFail("单张：应该照上游用本地原图，实际 \(String(describing: singleResult.thumbnailDataSource))")
        }
    }

    // MARK: - 视频查看器（owner 2026-09-25「多个视频点开时完全参考 Telegram 的设计」）

    /// 一条消息里两段现做的视频（6 秒横的：前一半红、后一半蓝；40 秒竖的）：
    /// - 打开时什么都不显示、照常自动播放；轻点后正中是暂停键（6 秒的没有 ±15），进度胶囊右边是总时长「0:06」且不随播放变；
    ///   底栏从左到右 转发 · 倍速 · 删除，分享在右上角「···」里；
    /// - 30 秒以内的放完接着从头放；
    /// - 拖进度条不暂停，拇指正上方出现那一帧（拖到前面是红、后面是蓝；横的 160×90，底边在胶囊上方 6），左边时间跟着手指，
    ///   松手才跳过去、预览消失；
    /// - 齿轮弹出「速度」+ 0.5x / 正常 / 1.5x / 2x，面板在齿轮正上方；选 1.5x 立刻生效、齿轮角标 1.5x、面板收起；滑杆按 0.1 取整；
    /// - 转发 / 删除先问「这个视频 / 全部 2 个视频」；
    /// - 翻到 40 秒的那个：沿用 1.5x、两侧有 ±15、右边「0:40」、竖的预览帧 90×160；放完停下并把控件叫出来，正中换成播放键。
    @MainActor
    func testVideoViewerTelegramControls() async throws {
        try requireShots()
        let width = shotWidths.first ?? 402
        // 本用例不测自动收起（见 testVideoControlsAutoHideWhilePlaying）：中途要停好几秒，别让控件自己收起。
        let savedAutoHideDelay = MediaPageViewController.autoHideControlsDelay
        MediaPageViewController.autoHideControlsDelay = 3600
        defer { MediaPageViewController.autoHideControlsDelay = savedAutoHideDelay }

        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let shortVideo = try await makeVideo(size: CGSize(width: 320, height: 180), duration: 6, framesPerSecond: 10)
        let longVideo = try await makeVideo(size: CGSize(width: 180, height: 320), duration: 40, framesPerSecond: 2)
        let message = try await insertMediaMessage(
            thread: thread,
            incoming: true,
            media: [(data: shortVideo, mimeType: "video/mp4"), (data: longVideo, mimeType: "video/mp4")],
            body: nil,
        )
        let attachments = try bodyAttachments(of: message)

        let viewer = try XCTUnwrap(MediaPageViewController(initialMediaAttachment: attachments[0], thread: thread, spoilerState: SpoilerRenderState(), showingSingleMessage: true))
        let window = UIWindow.tellomiTestWindow(frame: UIScreen.main.bounds)
        window.rootViewController = viewer
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 打开：什么都不显示，照常自动播放
        let player = try XCTUnwrap(viewer.currentVideoPlayerForTesting)
        report += "video: opened toolbarsHidden=\(viewer.areToolbarsHiddenForTesting) centerShown=\(viewer.isShowingVideoCenterControlsForTesting) playing=\(player.isPlaying)\n"
        XCTAssertTrue(viewer.areToolbarsHiddenForTesting, "打开时什么都不显示")
        XCTAssertFalse(viewer.isShowingVideoCenterControlsForTesting, "打开时正中也没有播放键")
        XCTAssertTrue(player.isPlaying, "照常自动播放")
        try save(renderWindow(window), name: "video-1-opened.png", width: width)

        // 轻点：正中暂停键、进度胶囊（右边总时长）、底栏 转发 · 倍速 · 删除
        viewer.tapMediaForTesting()
        try await Task.sleep(nanoseconds: 800_000_000)
        let center = viewer.videoCenterControlsForTesting
        let panel = viewer.bottomPanelForTesting
        let progress = try XCTUnwrap(panel.progressViewForTesting)
        let durationBefore = progress.durationTextForTesting
        try await Task.sleep(nanoseconds: 1_000_000_000)
        report += "video: tapped centerShown=\(viewer.isShowingVideoCenterControlsForTesting) pause=\(center.isShowingPauseButton) skip=\(center.showsSkipButtonsForTesting) "
            + "time=\(progress.positionTextForTesting ?? "nil")/\(durationBefore ?? "nil")→\(progress.durationTextForTesting ?? "nil") "
            + "bottom=\(panel.visibleBottomButtonLabelsForTesting) menu=\(viewer.contextMenuTitlesForTesting)\n"
        XCTAssertTrue(viewer.isShowingVideoCenterControlsForTesting, "轻点后正中出现播放控件")
        XCTAssertTrue(center.isShowingPauseButton, "正在播：正中是暂停键")
        XCTAssertFalse(center.showsSkipButtonsForTesting, "30 秒以内没有 ±15")
        XCTAssertEqual(durationBefore, "0:06", "右边是总时长")
        XCTAssertEqual(progress.durationTextForTesting, "0:06", "总时长不随播放变（不是剩余时间）")
        XCTAssertEqual(panel.visibleBottomButtonLabelsForTesting, ["Forward", "Playback Speed", "Delete"])
        XCTAssertTrue(viewer.contextMenuTitlesForTesting.contains("Share"), "分享挪进「···」：\(viewer.contextMenuTitlesForTesting)")
        try save(renderWindow(window), name: "video-2-controls.png", width: width)

        // 30 秒以内：放完接着从头放
        player.seek(to: CMTime(seconds: 5.3, preferredTimescale: 600))
        try await Task.sleep(nanoseconds: 1_800_000_000)
        report += "video: loop time=\(player.currentTimeSeconds) playing=\(player.isPlaying)\n"
        XCTAssertTrue(player.isPlaying, "30 秒以内的放完接着放")
        XCTAssertLessThan(player.currentTimeSeconds, 1.8, "从头放")

        // 拖进度条：不暂停，拇指上方是那一帧，松手才跳
        let preview = panel.scrubPreviewForTesting
        progress.scrubForTesting(toFraction: 0.25, isMove: false)
        let redShown = await waitUntil(timeout: 3) { preview.isShowingFrameForTesting && Self.dominantChannel(of: preview.image) == .red }
        let pillTop = progress.convert(progress.bounds, to: panel).minY
        let thumbX = progress.thumbCenterX(in: panel)
        let expectedMidX = min(max(thumbX - 80, 10), panel.bounds.size.width - 10 - 160) + 80
        report += "video: scrub25 preview=\(preview.frame) pillTop=\(pillTop) thumbX=\(thumbX) position=\(progress.positionTextForTesting ?? "nil") playing=\(player.isPlaying)\n"
        XCTAssertTrue(redShown, "拖到前面：拇指上方是前面那一帧（红）")
        XCTAssertEqual(preview.frame.size.width, 160, accuracy: 0.5)
        XCTAssertEqual(preview.frame.size.height, 90, accuracy: 0.5)
        XCTAssertEqual(preview.frame.maxY, pillTop - 6, accuracy: 0.5, "底边在胶囊上方 6")
        XCTAssertEqual(preview.frame.midX, expectedMidX, accuracy: 1, "水平中心对着拇指")
        XCTAssertEqual(progress.positionTextForTesting, "0:01", "左边时间跟着手指")
        XCTAssertTrue(player.isPlaying, "拖动时不暂停")

        progress.scrubForTesting(toFraction: 0.75, isMove: true)
        let blueShown = await waitUntil(timeout: 3) { preview.isShowingFrameForTesting && Self.dominantChannel(of: preview.image) == .blue }
        report += "video: scrub75 preview=\(preview.frame) position=\(progress.positionTextForTesting ?? "nil") playing=\(player.isPlaying)\n"
        XCTAssertTrue(blueShown, "拖到后面：换成后面那一帧（蓝）")
        XCTAssertEqual(progress.positionTextForTesting, "0:04")
        XCTAssertTrue(player.isPlaying, "拖动时不暂停")
        try save(renderWindow(window), name: "video-3-scrub-preview.png", width: width)

        progress.endScrubForTesting()
        try await Task.sleep(nanoseconds: 500_000_000)
        report += "video: released previewShown=\(preview.isShowingFrameForTesting) time=\(player.currentTimeSeconds)\n"
        XCTAssertFalse(preview.isShowingFrameForTesting, "松手后预览消失")
        XCTAssertEqual(player.currentTimeSeconds, 5.0, accuracy: 0.6, "松手才跳到 4.5 秒（再播了半秒）")

        // 倍速：齿轮正上方弹出「速度」+ 四档
        player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600))
        let gear = panel.playbackSpeedButtonForTesting
        gear.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(nanoseconds: 500_000_000)
        let menu = try XCTUnwrap(viewer.playbackSpeedMenuForTesting)
        let gearFrame = gear.convert(gear.bounds, to: menu)
        report += "video: speedMenu title=\(menu.titleTextForTesting ?? "nil") value=\(menu.valueTextForTesting ?? "nil") options=\(menu.optionTitlesForTesting) "
            + "checked=\(menu.checkedOptionTitleForTesting ?? "nil") panel=\(menu.panelFrameForTesting) gear=\(gearFrame)\n"
        XCTAssertEqual(menu.titleTextForTesting, "Speed")
        XCTAssertEqual(menu.valueTextForTesting, "1x")
        XCTAssertEqual(menu.optionTitlesForTesting, ["0.5x", "Normal", "1.5x", "2x"])
        XCTAssertEqual(menu.checkedOptionTitleForTesting, "Normal")
        XCTAssertEqual(menu.panelFrameForTesting.maxY, gearFrame.minY - 8, accuracy: 0.5, "面板在齿轮正上方")
        XCTAssertEqual(menu.panelFrameForTesting.midX, gearFrame.midX, accuracy: 0.5)
        try save(renderWindow(window), name: "video-4-speed-menu.png", width: width)

        menu.selectOptionForTesting(at: 2)
        try await Task.sleep(nanoseconds: 600_000_000)
        report += "video: speed=1.5 rate=\(player.avPlayer.rate) badge=\(panel.playbackSpeedBadgeTextForTesting ?? "nil") menuClosed=\(menu.superview == nil)\n"
        XCTAssertEqual(player.avPlayer.rate, 1.5, accuracy: 0.01, "选 1.5x 立刻生效")
        XCTAssertEqual(panel.playbackSpeedBadgeTextForTesting, "1.5x", "齿轮角标")
        XCTAssertNil(menu.superview, "选一档就收起")
        try save(renderWindow(window), name: "video-5-speed-badge.png", width: width)

        gear.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(nanoseconds: 500_000_000)
        let menu2 = try XCTUnwrap(viewer.playbackSpeedMenuForTesting)
        XCTAssertEqual(menu2.checkedOptionTitleForTesting, "1.5x")
        menu2.setSliderValueForTesting(1.23)
        report += "video: slider=1.23 value=\(menu2.valueTextForTesting ?? "nil") rate=\(player.avPlayer.rate) badge=\(panel.playbackSpeedBadgeTextForTesting ?? "nil")\n"
        XCTAssertEqual(menu2.valueTextForTesting, "1.2x", "滑杆按 0.1 取整")
        XCTAssertEqual(player.avPlayer.rate, 1.2, accuracy: 0.01, "拖滑杆即生效")
        XCTAssertEqual(panel.playbackSpeedBadgeTextForTesting, "1.2x")
        XCTAssertNil(menu2.checkedOptionTitleForTesting, "1.2x 不是四档之一")
        menu2.selectOptionForTesting(at: 2)
        try await Task.sleep(nanoseconds: 500_000_000)

        // 转发 / 删除：先问「这个视频 / 全部 2 个视频」
        try XCTUnwrap(findButton(labeled: "Forward", in: panel)).sendActions(for: .primaryActionTriggered)
        try await Task.sleep(nanoseconds: 800_000_000)
        let forwardSheet = try XCTUnwrap(viewer.presentedViewController as? ActionSheetController)
        let forwardTitles = labelTexts(in: forwardSheet.view)
        report += "video: forwardChoices=\(forwardTitles)\n"
        XCTAssertTrue(forwardTitles.contains("This Video") && forwardTitles.contains("All 2 Videos"), "\(forwardTitles)")
        try save(renderWindow(window), name: "video-6-forward-choice.png", width: width)
        forwardSheet.dismiss(animated: false)
        try await Task.sleep(nanoseconds: 400_000_000)

        try XCTUnwrap(findButton(labeled: "Delete", in: panel)).sendActions(for: .primaryActionTriggered)
        try await Task.sleep(nanoseconds: 800_000_000)
        let deleteSheet = try XCTUnwrap(viewer.presentedViewController as? ActionSheetController)
        let deleteTitles = labelTexts(in: deleteSheet.view)
        report += "video: deleteChoices=\(deleteTitles)\n"
        XCTAssertTrue(deleteTitles.contains("This Video") && deleteTitles.contains("All 2 Videos"), "\(deleteTitles)")
        deleteSheet.dismiss(animated: false)
        try await Task.sleep(nanoseconds: 400_000_000)

        // 翻到 40 秒的那个（在缩略条上拖过去）：沿用倍速、两侧有 ±15、右边「0:40」
        let scrubber = viewer.albumScrubberForTesting
        let stripFrames = scrubber.thumbnailFramesForTesting
        scrubber.scrubForTesting(through: [
            CGPoint(x: stripFrames[0].midX, y: stripFrames[0].midY),
            CGPoint(x: stripFrames[1].midX, y: stripFrames[1].midY),
        ])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let longPlayer = try XCTUnwrap(viewer.currentVideoPlayerForTesting)
        report += "video: long current=\(viewer.currentItemForTesting.albumIndex) playing=\(longPlayer.isPlaying) rate=\(longPlayer.avPlayer.rate) "
            + "skip=\(center.showsSkipButtonsForTesting) duration=\(progress.durationTextForTesting ?? "nil") badge=\(panel.playbackSpeedBadgeTextForTesting ?? "nil")\n"
        XCTAssertEqual(viewer.currentItemForTesting.albumIndex, 1)
        XCTAssertFalse(longPlayer === player)
        XCTAssertTrue(longPlayer.isPlaying, "翻过去照常自动播放")
        XCTAssertEqual(longPlayer.avPlayer.rate, 1.5, accuracy: 0.01, "翻到下一个视频沿用倍速")
        XCTAssertEqual(panel.playbackSpeedBadgeTextForTesting, "1.5x")
        XCTAssertTrue(center.showsSkipButtonsForTesting, "30 秒以上两侧有 ±15")
        XCTAssertEqual(progress.durationTextForTesting, "0:40")
        try save(renderWindow(window), name: "video-7-long-video.png", width: width)

        // 竖的视频：预览帧放进 90×160
        progress.scrubForTesting(toFraction: 0.5, isMove: false)
        let portraitShown = await waitUntil(timeout: 3) { preview.isShowingFrameForTesting }
        report += "video: long scrub50 preview=\(preview.frame)\n"
        XCTAssertTrue(portraitShown)
        XCTAssertEqual(preview.frame.size.width, 90, accuracy: 0.5)
        XCTAssertEqual(preview.frame.size.height, 160, accuracy: 0.5)
        progress.endScrubForTesting()
        try await Task.sleep(nanoseconds: 400_000_000)

        // 30 秒以上的放完：停下，把控件叫出来，正中换成播放键
        viewer.tapMediaForTesting()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(viewer.areToolbarsHiddenForTesting)
        longPlayer.seek(to: CMTime(seconds: 38.8, preferredTimescale: 600))
        let chromeBack = await waitUntil(timeout: 4) { !viewer.areToolbarsHiddenForTesting }
        try await Task.sleep(nanoseconds: 400_000_000)
        report += "video: long ended chromeBack=\(chromeBack) playing=\(longPlayer.isPlaying) pause=\(center.isShowingPauseButton) centerShown=\(viewer.isShowingVideoCenterControlsForTesting)\n"
        XCTAssertTrue(chromeBack, "放完把控件叫出来")
        XCTAssertFalse(longPlayer.isPlaying, "30 秒以上的不循环")
        XCTAssertFalse(center.isShowingPauseButton, "正中换成播放键")
        XCTAssertTrue(viewer.isShowingVideoCenterControlsForTesting)
        try save(renderWindow(window), name: "video-8-ended.png", width: width)

        window.isHidden = true
        try report.write(to: shotsDirectory(width: width).deletingLastPathComponent().appendingPathComponent("metrics-video.txt"), atomically: true, encoding: .utf8)
    }

    private enum ColorChannel {
        case red
        case green
        case blue
    }

    /// 缩成 1 个像素后哪个通道最大。
    private static func dominantChannel(of image: UIImage?) -> ColorChannel? {
        guard let cgImage = image?.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
                )
            else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let red = pixel[0]
        let green = pixel[1]
        let blue = pixel[2]
        if red > green, red > blue { return .red }
        if blue > red, blue > green { return .blue }
        return .green
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func findButton(labeled label: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, !button.isHidden, button.accessibilityLabel == label {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(labeled: label, in: subview) {
                return button
            }
        }
        return nil
    }

    /// 现做一段 H.264 小视频（每帧都是关键帧）：前一半红、后一半蓝。
    private func makeVideo(size: CGSize, duration: Double, framesPerSecond: Int32) async throws -> Data {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tellomi-video-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(duration * Double(framesPerSecond))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            // BGRA：红 = (0, 0, 255)，蓝 = (255, 0, 0)
            let bgra: (UInt8, UInt8, UInt8) = frame < frameCount / 2 ? (0, 0, 255) : (255, 0, 0)
            let pixelBuffer = try XCTUnwrap(Self.solidPixelBuffer(size: size, pool: adaptor.pixelBufferPool, bgr: bgra))
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return try Data(contentsOf: url)
    }

    private static func solidPixelBuffer(size: CGSize, pool: CVPixelBufferPool?, bgr: (UInt8, UInt8, UInt8)) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        } else {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        }
        guard let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<CVPixelBufferGetHeight(pixelBuffer) {
            let rowPointer = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0..<CVPixelBufferGetWidth(pixelBuffer) {
                rowPointer[column * 4] = bgr.0
                rowPointer[column * 4 + 1] = bgr.1
                rowPointer[column * 4 + 2] = bgr.2
                rowPointer[column * 4 + 3] = 255
            }
        }
        return pixelBuffer
    }

    private func quotedAttachmentId(_ draft: DraftQuotedReplyModel?) -> Attachment.IDType? {
        guard case .attachment(_, _, let attachment, _)? = draft?.content else {
            return nil
        }
        return attachment.id
    }

    private func bodyAttachments(of message: TSMessage) throws -> [ReferencedAttachment] {
        let rowId = try XCTUnwrap(message.sqliteRowId)
        let attachments = read { tx in
            DependenciesBridge.shared.attachmentStore.fetchReferencedAttachments(for: .messageBodyAttachment(messageRowId: rowId), tx: tx)
        }
        func order(_ attachment: ReferencedAttachment) -> UInt32 {
            if case .message(.bodyAttachment(let metadata)) = attachment.reference.owner {
                return metadata.orderInMessage
            }
            return .max
        }
        return attachments.sorted { order($0) < order($1) }
    }

    private func labelTexts(in view: UIView) -> [String] {
        var texts = [String]()
        if let label = view as? UILabel, let text = label.text {
            texts.append(text)
        }
        if let button = view as? UIButton, let text = button.title(for: .normal) ?? button.configuration?.title {
            texts.append(text)
        }
        for subview in view.subviews {
            texts += labelTexts(in: subview)
        }
        return texts
    }

    @MainActor
    private func renderWindow(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    // MARK: - 播放中控件自动收起（#1257 欠账，照 Telegram iOS 的 4 秒）

    /// 照 Telegram iOS（UniversalVideoGalleryItem 的 shouldHideControlsSignal）：正在播、没被打断，控件过一会儿自动收起（产品里 4 秒，测试里 0.6 秒、每 0.1 秒看一次）。
    /// 暂停、倍速菜单 / 「···」菜单开着、拖着进度条、开着 VoiceOver 时不收；打断结束后再等满时间才收；碰一下屏幕计时从头来。不需要 TELLOMI_SHOTS。
    @MainActor
    func testVideoControlsAutoHideWhilePlaying() async throws {
        let savedDelay = MediaPageViewController.autoHideControlsDelay
        let savedTick = MediaPageViewController.autoHideControlsTickInterval
        let savedVoiceOver = MediaPageViewController.isVoiceOverRunning
        MediaPageViewController.autoHideControlsDelay = 0.6
        MediaPageViewController.autoHideControlsTickInterval = 0.1
        defer {
            MediaPageViewController.autoHideControlsDelay = savedDelay
            MediaPageViewController.autoHideControlsTickInterval = savedTick
            MediaPageViewController.isVoiceOverRunning = savedVoiceOver
        }

        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let video = try await makeVideo(size: CGSize(width: 320, height: 180), duration: 6, framesPerSecond: 10)
        let message = try await insertMediaMessage(thread: thread, incoming: true, media: [(data: video, mimeType: "video/mp4")], body: nil)
        let viewer = try XCTUnwrap(MediaPageViewController(initialMediaAttachment: try bodyAttachments(of: message)[0], thread: thread, spoilerState: SpoilerRenderState(), showingSingleMessage: true))
        let window = UIWindow.tellomiTestWindow(frame: UIScreen.main.bounds)
        window.rootViewController = viewer
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let player = try XCTUnwrap(viewer.currentVideoPlayerForTesting)
        XCTAssertTrue(player.isPlaying, "照常自动播放")

        func showControls() {
            if viewer.areToolbarsHiddenForTesting {
                viewer.tapMediaForTesting()
            }
            XCTAssertFalse(viewer.areToolbarsHiddenForTesting)
        }
        func staysShown(_ reason: String) async throws {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            report += "autohide: \(reason) hidden=\(viewer.areToolbarsHiddenForTesting)\n"
            XCTAssertFalse(viewer.areToolbarsHiddenForTesting, reason)
        }
        func hidesAfterDelay(_ reason: String, timeout: TimeInterval = 3) async {
            let start = Date()
            let hidden = await waitUntil(timeout: timeout) { viewer.areToolbarsHiddenForTesting }
            let elapsed = Date().timeIntervalSince(start)
            report += "autohide: \(reason) hidden=\(hidden) after=\(String(format: "%.2f", elapsed))s\n"
            XCTAssertTrue(hidden, reason)
            XCTAssertGreaterThanOrEqual(elapsed, 0.5, "\(reason)：等满时间才收，不是一放开就收")
        }

        // 播放中：轻点叫出控件，没再碰就自动收起
        showControls()
        await hidesAfterDelay("播放中没碰就自动收起")

        // 暂停：不收；接着放，等满时间再收
        showControls()
        viewer.videoCenterControlsForTesting.tapPlayPauseForTesting()
        XCTAssertFalse(player.isPlaying)
        try await staysShown("暂停时不收")
        viewer.videoCenterControlsForTesting.tapPlayPauseForTesting()
        // 刚恢复时 timeControlStatus 会先是「等待以指定速率播放」，等它真的播起来再判。
        let resumed = await waitUntil(timeout: 2) { player.isPlaying }
        XCTAssertTrue(resumed, "接着放")
        await hidesAfterDelay("接着放，等满时间再收")

        // 倍速菜单开着：不收；关掉后再等满时间
        showControls()
        viewer.openPlaybackSpeedMenuForTesting()
        try await staysShown("倍速菜单开着不收")
        viewer.playbackSpeedMenuForTesting?.dismiss(animated: false)
        await hidesAfterDelay("倍速菜单关掉后再等满时间收")

        // 拖着进度条：不收；松手后再等满时间
        showControls()
        let progress = try XCTUnwrap(viewer.bottomPanelForTesting.progressViewForTesting)
        progress.scrubForTesting(toFraction: 0.5, isMove: false)
        try await staysShown("拖着进度条不收")
        progress.endScrubForTesting()
        await hidesAfterDelay("松手后再等满时间收")

        // 「···」菜单开着：不收（iOS 26 起顶栏是自定义深色圆钮，能知道菜单开没开）
        if #available(iOS 26, *) {
            showControls()
            let menuButton = try XCTUnwrap(viewer.contextMenuButtonForTesting, "「···」是能报告菜单开关的圆钮")
            menuButton.setMenuVisibleForTesting(true)
            try await staysShown("「···」菜单开着不收")
            menuButton.setMenuVisibleForTesting(false)
            await hidesAfterDelay("「···」菜单关掉后再等满时间收")
        }

        // 开着 VoiceOver：不收
        showControls()
        MediaPageViewController.isVoiceOverRunning = { true }
        try await staysShown("开着 VoiceOver 不收")
        MediaPageViewController.isVoiceOverRunning = { false }
        await hidesAfterDelay("关掉 VoiceOver 后再等满时间收")

        // 碰一下屏幕：计时从头来。这一段时间放长到 3 秒，判据只用下限——收起离「碰」那一下至少满 3 秒；
        // 机器忙只会让它更晚收、不会更早（原来「2.4 秒时还在」那种定点看，Android 440dp 在机器忙时红过一次，两端一起改）。
        // 没清零的话，从叫出控件（上一次清零）算满 3 秒就收，离「碰」只有约 2 秒，这条就红。
        MediaPageViewController.autoHideControlsDelay = 3
        showControls()
        let shownAt = Date()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(viewer.areToolbarsHiddenForTesting, "碰之前控件还在（离叫出 \(String(format: "%.2f", Date().timeIntervalSince(shownAt)))s）")
        let touchedAt = Date()
        XCTAssertTrue(viewer.noteTouchForTesting(), "查看器根视图上挂着「碰过屏幕」识别器")
        let hiddenAfterTouch = await waitUntil(timeout: 8) { viewer.areToolbarsHiddenForTesting }
        let sinceTouch = Date().timeIntervalSince(touchedAt)
        report += "autohide: touched \(String(format: "%.2f", touchedAt.timeIntervalSince(shownAt)))s after shown, hidden=\(hiddenAfterTouch) after=\(String(format: "%.2f", sinceTouch))s\n"
        XCTAssertTrue(hiddenAfterTouch, "碰过之后再等满时间收")
        XCTAssertGreaterThanOrEqual(sinceTouch, 3, "碰过屏幕，计时从头来（收起离「碰」\(String(format: "%.2f", sinceTouch))s）")

        try report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("metrics-autohide.txt"), atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" {
            try report.write(to: shotsDirectory(width: shotWidths.first ?? 402).deletingLastPathComponent().appendingPathComponent("metrics-autohide.txt"), atomically: true, encoding: .utf8)
        }
        // 收尾：这个视频结束时还在循环播放。先停下、摘掉查看器、等它释放完，别让它拖到下一个用例（那时测试环境已经拆了，释放时会崩）。
        player.pause()
        window.isHidden = true
        window.rootViewController = nil
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - Hosting

    private struct Hosted {
        let window: UIWindow
        let cellView: CVCellView
        let delegate: MockConversationView

        func tearDown() {
            cellView.isCellVisible = false
            window.isHidden = true
        }
    }

    @MainActor
    private func host(message: TSMessage, thread: TSThread, width: CGFloat) async throws -> Hosted {
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
        // 窗口放在状态栏以下：否则 cell 落在安全区里，布局边距会被加上安全区（会话页里 cell 不会这样）
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 150, width: width, height: cellHeight + 24))
        window.backgroundColor = Theme.backgroundColor
        let cellView = CVCellView()
        cellView.configure(renderItem: renderItem, componentDelegate: delegate)
        cellView.frame = CGRect(x: 0, y: 12, width: width, height: cellHeight)
        window.addSubview(cellView)
        window.isHidden = false
        cellView.isCellVisible = true
        window.layoutIfNeeded()
        report += "    window.safeAreaInsets=\(NSCoder.string(for: window.safeAreaInsets)) cell.safeAreaInsets=\(NSCoder.string(for: cellView.safeAreaInsets))\n"

        let hosted = Hosted(window: window, cellView: cellView, delegate: delegate)
        try await settle(hosted)
        return hosted
    }

    @MainActor
    private func settle(_ hosted: Hosted) async throws {
        // 缩略图是异步解出来的
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 150_000_000)
            hosted.window.layoutIfNeeded()
        }
    }

    @MainActor
    private func render(_ hosted: Hosted) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: hosted.window.bounds, format: format).image { _ in
            hosted.window.drawHierarchy(in: hosted.window.bounds, afterScreenUpdates: true)
        }
    }

    private func stack(_ images: [UIImage], width: CGFloat) -> UIImage {
        let height = images.reduce(0) { $0 + $1.size.height }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: max(1, height)), format: format).image { context in
            Theme.backgroundColor.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var y: CGFloat = 0
            for image in images {
                image.draw(at: CGPoint(x: 0, y: y))
                y += image.size.height
            }
        }
    }

    private func save(_ image: UIImage, name: String, width: CGFloat) throws {
        let url = try shotsDirectory(width: width).appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: url)
        report += "saved \(url.path)\n"
    }

    // MARK: - Finding views

    private func findView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let found = view as? T {
            return found
        }
        for subview in view.subviews {
            if let found = findView(type, in: subview) {
                return found
            }
        }
        return nil
    }

    /// 能横向滚动的视图（内容比自己宽、且允许滚动）。
    private func horizontallyScrollableViews(in view: UIView) -> [UIScrollView] {
        var result = [UIScrollView]()
        if let scrollView = view as? UIScrollView, scrollView.isScrollEnabled, scrollView.contentSize.width > scrollView.bounds.size.width + 0.5 {
            result.append(scrollView)
        }
        for subview in view.subviews {
            result += horizontallyScrollableViews(in: subview)
        }
        return result
    }

    // MARK: - Messages with real image data

    /// 宽高轮换：竖 3:4、横 4:3、16:9、9:16、1:1。
    private func sizes(_ count: Int) -> [CGSize] {
        let cycle = [CGSize(width: 1200, height: 1600), CGSize(width: 1600, height: 1200), CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1200, height: 1200)]
        return (0..<count).map { cycle[$0 % cycle.count] }
    }

    @MainActor
    private func insertAlbum(thread: TSThread, incoming: Bool, sizes: [CGSize], body: String?, author: Aci? = nil) async throws -> TSMessage {
        let media = sizes.enumerated().map { index, size in (data: jpeg(size: size, number: index + 1), mimeType: "image/jpeg") }
        return try await insertMediaMessage(thread: thread, incoming: incoming, media: media, body: body, author: author)
    }

    @MainActor
    private func insertMediaMessage(
        thread: TSThread,
        incoming: Bool,
        media: [(data: Data, mimeType: String)],
        body: String?,
        author: Aci? = nil,
    ) async throws -> TSMessage {
        let message: TSMessage = write { tx in
            if incoming {
                let factory = IncomingMessageFactory()
                factory.threadCreator = { _ in thread }
                factory.messageBodyBuilder = { body ?? "" }
                if let author {
                    factory.authorAciBuilder = { _ in author }
                }
                return factory.create(transaction: tx)
            } else {
                // 「已发出」的样子：附件没有上传记录时，本机建的外发消息会一直显示上传进度圈；
                // 这里当作另一台设备发的（wasNotCreatedLocally），画出来就是发完之后的稳定状态
                let message = TSOutgoingMessageBuilder(
                    thread: thread,
                    timestamp: NSDate.ows_millisecondTimeStamp(),
                    receivedAtTimestamp: NSDate.ows_millisecondTimeStamp(),
                    messageBody: DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                        MessageBody(text: body ?? "", ranges: .empty),
                        tx: tx,
                    ),
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
                if let recipientAci = (thread as? TSContactThread)?.contactAddress.aci {
                    message.updateWithSentRecipients([recipientAci], wasSentByUD: false, tx: tx)
                }
                return message
            }
        }

        var pendingAttachments = [PendingAttachment]()
        for item in media {
            pendingAttachments.append(try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
                item.data,
                mimeType: item.mimeType,
                renderingFlag: .default,
                sourceFilename: nil,
            ))
        }

        try write { tx in
            for (index, pending) in pendingAttachments.enumerated() {
                _ = try DependenciesBridge.shared.attachmentManager.createAttachmentStream(
                    from: OwnedAttachmentDataSource(
                        dataSource: .pendingAttachment(pending),
                        owner: .messageBodyAttachment(.init(
                            messageRowId: message.sqliteRowId!,
                            receivedAtTimestamp: message.receivedAtTimestamp,
                            threadRowId: thread.sqliteRowId!,
                            isViewOnce: false,
                            isPastEditRevision: false,
                            orderInMessage: UInt32(index),
                        )),
                    ),
                    tx: tx,
                )
            }
        }
        return message
    }

    /// 截图里某块区域的平均亮度（0 黑 … 1 白）。
    private func averageLuma(of image: UIImage, in rect: CGRect) -> CGFloat? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = image.scale
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.size.width * scale, height: rect.size.height * scale).integral
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        let width = cropped.width
        let height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total: CGFloat = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * CGFloat(pixels[index]) + 0.7152 * CGFloat(pixels[index + 1]) + 0.0722 * CGFloat(pixels[index + 2])
        }
        return total / CGFloat(width * height) / 255
    }

    /// 一张白底的「文档截图」（竖屏整页、几行浅灰字块），看查看器按钮在亮图上清不清楚。
    private func whitePageJpeg() -> Data {
        let size = CGSize(width: 402, height: 874)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.93, alpha: 1).setFill()
            for (index, y) in stride(from: 150.0, to: 700.0, by: 70.0).enumerated() {
                let width: CGFloat = index % 3 == 2 ? 220 : 350
                context.cgContext.addPath(UIBezierPath(roundedRect: CGRect(x: 26, y: y, width: width, height: 44), cornerRadius: 12).cgPath)
                context.cgContext.fillPath()
            }
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    private func jpeg(size: CGSize, number: Int) -> Data {
        let imageSize = CGSize(width: size.width / 4, height: size.height / 4)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { context in
            let hue = CGFloat((number * 47) % 360) / 360
            let colors = [
                UIColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
                UIColor(hue: (hue + 0.11).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.65, alpha: 1).cgColor,
            ] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: imageSize.width, y: imageSize.height), options: [])

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let numberFont = UIFont.systemFont(ofSize: min(imageSize.width, imageSize.height) * 0.42, weight: .regular)
            let numberText = NSAttributedString(string: "\(number)", attributes: [.font: numberFont, .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
            let numberHeight = numberFont.lineHeight
            numberText.draw(in: CGRect(x: 0, y: (imageSize.height - numberHeight) / 2, width: imageSize.width, height: numberHeight))

            let sizeFont = UIFont.systemFont(ofSize: min(imageSize.width, imageSize.height) * 0.09)
            let sizeText = NSAttributedString(string: "\(Int(size.width))×\(Int(size.height))", attributes: [.font: sizeFont, .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
            sizeText.draw(in: CGRect(x: 0, y: imageSize.height - sizeFont.lineHeight * 1.8, width: imageSize.width, height: sizeFont.lineHeight))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }
}

// MARK: - Fake gestures（只用来喂「落点」给消息 cell 的手势分派）

private final class FakePan: UIPanGestureRecognizer {
    var locationInWindow: CGPoint = .zero

    override func location(in view: UIView?) -> CGPoint {
        guard let view else {
            return locationInWindow
        }
        return view.convert(locationInWindow, from: nil)
    }
}
