//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import ImageIO
import LibSignalClient
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// tellomi/tellomi#1261：选图网格（`TellomiPhotoPickerViewController`）的判据与截图。
///
/// 相册用内存里的假图（不读系统相册、不要权限）；发送只看交给会话页的 `ApprovedAttachments`，
/// 会话页那一头「单独发送」的拆条规则见 `TellomiPhotoPickerSending`。
/// 截图只在 `TELLOMI_SHOTS=1` 时拍：屏宽取 `TELLOMI_SHOT_WIDTHS`（默认 402,440,375），写到 `TELLOMI_SHOTS_DIR/<屏宽>/picker-*.png`。
final class TellomiPhotoPickerTests: SignalBaseTest {

    // MARK: - P-1 / P-2 顶栏

    /// 没选中：只有 ✕ 和「最近」；选中 1 张：✕ 右边出现「✓1」（高 44）、右边出现「···」、底部出现说明栏；全取消又收回去。
    @MainActor
    func testTopBarBeforeAndAfterSelecting() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        XCTAssertEqual(picker.titleForTesting, "Recents")
        XCTAssertFalse(picker.isCountPillShownForTesting)
        XCTAssertFalse(picker.isMoreButtonShownForTesting)
        XCTAssertFalse(picker.isSendBarShownForTesting)
        XCTAssertFalse(picker.isModalInPresentation)

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertTrue(picker.isCountPillShownForTesting)
        XCTAssertEqual(picker.countPillTextForTesting, "1")
        XCTAssertEqual(picker.countPillFrameForTesting.size.height, 44, accuracy: 0.01)
        XCTAssertTrue(picker.isMoreButtonShownForTesting)
        XCTAssertTrue(picker.isSendBarShownForTesting)
        XCTAssertEqual(picker.sendBarFrameForTesting.maxY, picker.view.bounds.size.height, accuracy: 0.01, "说明栏底色铺到底，不露出下面的网格")
        XCTAssertTrue(picker.isModalInPresentation, "有选中时不能一拉就关")

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertFalse(picker.isCountPillShownForTesting)
        XCTAssertFalse(picker.isMoreButtonShownForTesting)
        XCTAssertFalse(picker.isSendBarShownForTesting)
    }

    // MARK: - P-8 网格

    /// 编号勾：按勾的顺序编号；取消中间一张，后面的往前补；勾在右上角、29 的触摸区、离上右各 3。
    @MainActor
    func testNumberedChecksFollowTapOrder() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        for index in [3, 0, 5] {
            picker.tapCheckForTesting(itemIndex: index)
        }
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r0", "r5"])
        XCTAssertEqual(picker.cellForTesting(itemIndex: 3)?.numberTextForTesting, "1")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 0)?.numberTextForTesting, "2")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 5)?.numberTextForTesting, "3")
        XCTAssertNil(picker.cellForTesting(itemIndex: 1)?.numberTextForTesting)
        XCTAssertEqual(picker.countPillTextForTesting, "3")

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r5"])
        XCTAssertEqual(picker.cellForTesting(itemIndex: 3)?.numberTextForTesting, "1")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 5)?.numberTextForTesting, "2")
        XCTAssertNil(picker.cellForTesting(itemIndex: 0)?.numberTextForTesting)

        let cell = try XCTUnwrap(picker.cellForTesting(itemIndex: 0))
        let check = cell.checkFrameForTesting
        XCTAssertEqual(check.size, CGSize(width: 29, height: 29))
        XCTAssertEqual(check.minY, 3, accuracy: 0.01)
        XCTAssertEqual(cell.bounds.size.width - check.maxX, 3, accuracy: 0.01)
    }

    /// owner 2026-09-28：「点右上角的勾，有时会跳到发送预览」——勾只有 29 的触摸区，手指落在圆旁边一点就算点了照片。
    /// 照 Telegram Android `PhotoAttachPhotoCell` 的 checkFrame（42dp 角区），iOS 取 44：右上角 44 × 44 整块都算点勾，
    /// 看得见的圆不动；角区外才是点照片（进单张预览）。
    @MainActor
    func testCheckHitAreaCoversTheTopTrailingCorner() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let cell = try XCTUnwrap(hosted.picker.cellForTesting(itemIndex: 0))
        let cellWidth: CGFloat = cell.bounds.size.width
        // 离右边、离上边各多少
        let insideCorner: [CGPoint] = [CGPoint(x: 40, y: 38), CGPoint(x: 43, y: 5), CGPoint(x: 5, y: 43), CGPoint(x: 1, y: 1)]
        let outsideCorner: [CGPoint] = [CGPoint(x: 46, y: 20), CGPoint(x: 20, y: 46), CGPoint(x: cellWidth / 2, y: cellWidth / 2)]

        for offset in insideCorner {
            XCTAssertTrue(cell.isCheckHitForTesting(at: CGPoint(x: cellWidth - offset.x, y: offset.y)), "\(offset)")
        }
        for offset in outsideCorner {
            XCTAssertFalse(cell.isCheckHitForTesting(at: CGPoint(x: cellWidth - offset.x, y: offset.y)), "\(offset)")
        }
    }

    /// 竖屏 3 列、横屏 5 列，间距 1，正方形；三种屏宽都一样。
    /// 边长按屏幕像素（1/scale pt：3x 是 1/3、SE 这类 2x 是 1/2）向下取整，除不尽时剩下的不到每列 1 像素，
    /// 由 flow layout 摊进列间距（3x 最多 1.34、2x 最多 1.5）。
    @MainActor
    func testGridColumnsSpacingAndSquareCells() async throws {
        for (width, height) in [(375, 812), (402, 874), (440, 956)] as [(CGFloat, CGFloat)] {
            for (w, h, columns) in [(width, height, 3), (height, width, 5)] {
                let hosted = host(width: w, height: h)
                defer { hosted.tearDown() }
                let frames = (0...columns).map { frame(of: $0, in: hosted.picker) }
                let label = "\(Int(w))×\(Int(h))"
                XCTAssertEqual(frames[0].size.width, frames[0].size.height, accuracy: 0.01, "\(label) 正方形")
                let pixel = 1 / hosted.window.screen.scale
                let gap = frames[1].minX - frames[0].maxX
                XCTAssertGreaterThanOrEqual(gap, 0.99, "\(label) 列间距 1")
                XCTAssertLessThanOrEqual(gap, 1 + pixel + 0.01, "\(label) 列间距 1（最多再摊 1 像素）")
                XCTAssertEqual(frames[columns - 1].minY, frames[0].minY, accuracy: 0.01, "\(label) 第一行有 \(columns) 格")
                XCTAssertEqual(frames[columns].minX, frames[0].minX, accuracy: 0.01, "\(label) 第 \(columns + 1) 格换行")
                XCTAssertEqual(frames[columns].minY - frames[0].maxY, 1, accuracy: 0.01, "\(label) 行间距 1")
                let leftover = hosted.picker.collectionViewForTesting.bounds.size.width - (CGFloat(columns) * frames[0].size.width + CGFloat(columns - 1))
                XCTAssertGreaterThanOrEqual(leftover, -0.01, "\(label) 一行放得下")
                XCTAssertLessThan(leftover, CGFloat(columns) * pixel, "\(label) 铺满一行（剩下的不到每列 1 像素）")
            }
        }
    }

    /// 视频右下角时长（m:ss，一小时以上 h:mm:ss），实况照片左上角小图标，普通照片两样都没有。
    @MainActor
    func testVideoDurationAndLivePhotoBadge() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        XCTAssertEqual(picker.cellForTesting(itemIndex: 1)?.durationTextForTesting, "1:15")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 7)?.durationTextForTesting, "1:02:05")
        XCTAssertNil(picker.cellForTesting(itemIndex: 0)?.durationTextForTesting)

        let live = try XCTUnwrap(picker.cellForTesting(itemIndex: 2))
        XCTAssertTrue(live.isShowingLivePhotoBadgeForTesting)
        XCTAssertEqual(live.typeBadgeSymbol, "livephoto")
        XCTAssertEqual(live.livePhotoBadgeFrameForTesting.origin, CGPoint(x: 6, y: 6))
        XCTAssertFalse(try XCTUnwrap(picker.cellForTesting(itemIndex: 0)).isShowingLivePhotoBadgeForTesting)

        // G-4：视频左上角也有种类图标（照 Telegram iOS `MediaPickerGridItem` typeIconNode）。
        let video = try XCTUnwrap(picker.cellForTesting(itemIndex: 1))
        XCTAssertTrue(video.isShowingLivePhotoBadgeForTesting)
        XCTAssertEqual(video.typeBadgeSymbol, "video.fill")
    }

    /// G-4：慢动作、延时摄影用各自的图标（`PHAssetMediaSubtype.videoHighFrameRate` / `.videoTimelapse`）。
    func testVideoKindBadgeSymbols() {
        func item(_ kind: TellomiPhotoPickerItem.VideoKind, isVideo: Bool = true, isLivePhoto: Bool = false) -> TellomiPhotoPickerItem {
            TellomiPhotoPickerItem(id: "x", isVideo: isVideo, duration: 3, isLivePhoto: isLivePhoto, isAnimatedImage: false, pixelSize: .zero, asset: nil, videoKind: kind)
        }
        XCTAssertEqual(TellomiPhotoPickerCell.typeBadgeSymbol(for: item(.normal)), "video.fill")
        XCTAssertEqual(TellomiPhotoPickerCell.typeBadgeSymbol(for: item(.slowMotion)), "slowmo")
        XCTAssertEqual(TellomiPhotoPickerCell.typeBadgeSymbol(for: item(.timelapse)), "timelapse")
        XCTAssertEqual(TellomiPhotoPickerCell.typeBadgeSymbol(for: item(.normal, isVideo: false, isLivePhoto: true)), "livephoto")
        XCTAssertNil(TellomiPhotoPickerCell.typeBadgeSymbol(for: item(.normal, isVideo: false)))
        for name in ["video.fill", "slowmo", "timelapse", "livephoto"] {
            XCTAssertNotNil(UIImage(systemName: name), name)
        }
    }

    /// 横着滑过格子连续多选：起手那格没选就一路选上，已选就一路取消；先竖着动超过 5 就让给滚动；滑动期间网格不滚。
    @MainActor
    func testSwipeAcrossCellsSelectsAndDeselects() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        let start = center(of: 0, in: picker)
        let progress = picker.swipeForTesting(through: [
            start,
            CGPoint(x: start.x + 4, y: start.y + 1),
            CGPoint(x: start.x + 12, y: start.y + 2),
            center(of: 1, in: picker),
            center(of: 2, in: picker),
        ])
        XCTAssertEqual(progress, .swiping)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r1", "r2"])

        let back = center(of: 2, in: picker)
        picker.swipeForTesting(through: [back, CGPoint(x: back.x - 12, y: back.y), center(of: 1, in: picker)])
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0"], "起手在已选的格子上：一路取消")

        let vertical = center(of: 4, in: picker)
        XCTAssertEqual(
            picker.swipeForTesting(through: [vertical, CGPoint(x: vertical.x + 3, y: vertical.y + 6), CGPoint(x: vertical.x + 60, y: vertical.y + 6)]),
            .failed,
        )
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0"], "先竖着动就是滚动，不选")

        let gesture = picker.swipeSelectGestureForTesting
        let third = center(of: 3, in: picker)
        XCTAssertEqual(gesture.track(from: third, to: CGPoint(x: third.x + 9, y: third.y)), .swiping)
        XCTAssertFalse(picker.isGridScrollEnabledForTesting, "滑动选择期间网格不滚")
        gesture.finishSwipe()
        XCTAssertTrue(picker.isGridScrollEnabledForTesting)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r3"])
    }

    // MARK: - P-7 受限访问横幅

    /// 权限是「有限」：网格顶上一条横幅（跟着网格滚），文字 +「管理」；不是「有限」就没有，第一格贴顶。
    @MainActor
    func testLimitedAccessBanner() async throws {
        let limited = FakePhotoLibrary()
        limited.isAccessLimited = true
        let hosted = host(library: limited)
        defer { hosted.tearDown() }
        XCTAssertEqual(hosted.picker.limitedAccessBannerTextForTesting, "You’ve limited Tellomi’s access to your photos.")
        XCTAssertEqual(frame(of: 0, in: hosted.picker).minY, 56, accuracy: 0.01, "横幅在网格里，第一格在它下面")
        let manage = try XCTUnwrap(hosted.picker.limitedAccessManageButtonFrameForTesting)
        XCTAssertEqual(manage.size.height, 28, accuracy: 0.01, "「管理」胶囊高 28")
        XCTAssertLessThan(manage.size.width, 100, "「管理」按内容宽，不被拉伸")

        let full = host()
        defer { full.tearDown() }
        XCTAssertNil(full.picker.limitedAccessBannerTextForTesting)
        XCTAssertEqual(frame(of: 0, in: full.picker).minY, 0, accuracy: 0.01)
    }

    // MARK: - P-5「···」

    /// 已选全是静态图才有「以高清质量发送」（默认已是高就换成「以标准质量发送」；V-7 / O4）；已选 ≥ 2 才有「单独发送」；只有视频时没有画质项。
    @MainActor
    func testMoreMenuItems() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertEqual(picker.moreMenuItemsForTesting, [.sendHighQuality])
        XCTAssertEqual(picker.moreMenuTitlesForTesting, ["Send in High Quality"])

        picker.tapCheckForTesting(itemIndex: 3)
        XCTAssertEqual(picker.moreMenuItemsForTesting, [.sendHighQuality, .sendSeparately])
        XCTAssertEqual(picker.moreMenuTitlesForTesting, ["Send in High Quality", "Send Separately"])

        let high = host(defaultImageQuality: .high)
        defer { high.tearDown() }
        high.picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertEqual(high.picker.moreMenuItemsForTesting, [.sendStandardQuality])
        XCTAssertEqual(high.picker.moreMenuTitlesForTesting, ["Send in Standard Quality"])

        let videos = host()
        defer { videos.tearDown() }
        videos.picker.tapCheckForTesting(itemIndex: 1)
        XCTAssertEqual(videos.picker.moreMenuItemsForTesting, [])
        XCTAssertFalse(videos.picker.isMoreButtonShownForTesting, "只有一个视频：「···」里什么都没有就不出现")
        videos.picker.tapCheckForTesting(itemIndex: 7)
        XCTAssertEqual(videos.picker.moreMenuItemsForTesting, [.sendSeparately])
        XCTAssertTrue(videos.picker.isMoreButtonShownForTesting)

        // V-7 / O4：照片和视频一起选时没有画质项（全是静态图才有）；动图也不算。
        let mixed = host()
        defer { mixed.tearDown() }
        mixed.picker.tapCheckForTesting(itemIndex: 0)
        mixed.picker.tapCheckForTesting(itemIndex: 1)
        XCTAssertEqual(mixed.picker.moreMenuItemsForTesting, [.sendSeparately])
        let animated = host()
        defer { animated.tearDown() }
        animated.picker.tapCheckForTesting(itemIndex: 5)
        XCTAssertEqual(animated.picker.moreMenuItemsForTesting, [])

        let noSeparate = host(canSendSeparately: false)
        defer { noSeparate.tearDown() }
        noSeparate.picker.tapCheckForTesting(itemIndex: 0)
        noSeparate.picker.tapCheckForTesting(itemIndex: 3)
        XCTAssertEqual(noSeparate.picker.moreMenuItemsForTesting, [.sendHighQuality])
    }

    /// 「···」里三项都是点了立即发：高清 / 标准只管这一次（带在这次发送里，不写设置），单独发送带上 separately。
    @MainActor
    func testMoreMenuItemsSendRightAway() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCheckForTesting(itemIndex: 3)

        picker.performMoreMenuItemForTesting(.sendHighQuality)
        let first = try await nextSend(hosted, count: 1)
        XCTAssertEqual(first.approved.imageQuality, .high)
        XCTAssertFalse(first.separately)
        XCTAssertEqual(hosted.library.ids(of: first.approved), ["r0", "r3"])

        picker.performMoreMenuItemForTesting(.sendSeparately)
        let second = try await nextSend(hosted, count: 2)
        XCTAssertTrue(second.separately)
        XCTAssertEqual(second.approved.imageQuality, .standard, "单独发送按默认画质")
        XCTAssertEqual(hosted.library.ids(of: second.approved), ["r0", "r3"])

        let high = host(defaultImageQuality: .high)
        defer { high.tearDown() }
        high.picker.tapCheckForTesting(itemIndex: 0)
        high.picker.performMoreMenuItemForTesting(.sendStandardQuality)
        let standard = try await nextSend(high, count: 1)
        XCTAssertEqual(standard.approved.imageQuality, .standard)
    }

    // MARK: - P-5「以文件发送」（#1263）

    /// 会话里「···」第一项是「以文件发送」，多张时「以文件发送（N 个）」；只有视频也有（视频也能按文件发）。不是会话的没有。
    @MainActor
    func testSendAsFileMenuItem() async throws {
        let hosted = host(canSendAsFile: true)
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertEqual(picker.moreMenuItemsForTesting, [.sendAsFile, .sendHighQuality])
        XCTAssertEqual(picker.moreMenuTitlesForTesting, ["Send as File", "Send in High Quality"])

        picker.tapCheckForTesting(itemIndex: 3)
        XCTAssertEqual(picker.moreMenuItemsForTesting, [.sendAsFile, .sendHighQuality, .sendSeparately])
        XCTAssertEqual(picker.moreMenuTitlesForTesting, ["Send as 2 Files", "Send in High Quality", "Send Separately"])

        let videos = host(canSendAsFile: true)
        defer { videos.tearDown() }
        videos.picker.tapCheckForTesting(itemIndex: 1)
        XCTAssertEqual(videos.picker.moreMenuItemsForTesting, [.sendAsFile])
        XCTAssertTrue(videos.picker.isMoreButtonShownForTesting)

        let notConversation = host()
        defer { notConversation.tearDown() }
        notConversation.picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertFalse(notConversation.picker.moreMenuItemsForTesting.contains(.sendAsFile))
    }

    /// 以文件发送：按勾的顺序、一个一条（说明挂最后一条由会话页做），每个都是按文件发、带原文件名；没有 HEIC 不问。
    @MainActor
    func testSendAsFilesSendsOriginalFilesSeparately() async throws {
        let hosted = host(canSendAsFile: true, initialText: "原图")
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 3)
        picker.tapCheckForTesting(itemIndex: 0)

        picker.performMoreMenuItemForTesting(.sendAsFile)
        XCTAssertFalse(picker.isAskingAboutHeicForTesting)
        let sent = try await nextSend(hosted, count: 1)

        XCTAssertTrue(sent.separately)
        XCTAssertEqual(sent.body?.text, "原图")
        XCTAssertEqual(hosted.library.ids(of: sent.approved), ["r3", "r0"])
        XCTAssertEqual(sent.approved.attachments.map(\.renderingFlag), [.tellomiAsFile, .tellomiAsFile])
        XCTAssertEqual(sent.approved.attachments.map(\.dataSource.sourceFilename), ["IMG_r3.JPG", "IMG_r0.JPG"])
        XCTAssertEqual(hosted.library.fileRequests.map { $0.convertHeicToJpeg }, [false, false])
    }

    /// 已选里有 HEIC 先问「是否把照片转成 JPEG？」：选「转成 JPEG」就转、文件名改 .JPG；选「保留 HEIC」原样发。
    @MainActor
    func testSendAsFilesAsksAboutHeic() async throws {
        let library = FakePhotoLibrary()
        library.heicIds = ["r3"]
        let hosted = host(library: library, canSendAsFile: true)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCheckForTesting(itemIndex: 3)

        picker.performMoreMenuItemForTesting(.sendAsFile)
        XCTAssertTrue(picker.isAskingAboutHeicForTesting)
        XCTAssertTrue(hosted.delegate.sent.isEmpty, "选之前不发")

        picker.chooseHeicForTesting(convert: true)
        let converted = try await nextSend(hosted, count: 1)
        XCTAssertEqual(converted.approved.attachments.map(\.dataSource.sourceFilename), ["IMG_r0.JPG", "IMG_r3.JPG"])
        XCTAssertEqual(library.fileRequests.map { $0.convertHeicToJpeg }, [true, true])

        picker.performMoreMenuItemForTesting(.sendAsFile)
        picker.chooseHeicForTesting(convert: false)
        let kept = try await nextSend(hosted, count: 2)
        XCTAssertEqual(kept.approved.attachments.map(\.dataSource.sourceFilename), ["IMG_r0.JPG", "IMG_r3.HEIC"])
    }

    /// 超过上限的不发：先提示「文件太大」，点了「好」再发剩下的。
    @MainActor
    func testSendAsFilesSkipsFilesOverTheLimit() async throws {
        let library = FakePhotoLibrary()
        library.tooLargeIds = ["r3"]
        let hosted = host(library: library, canSendAsFile: true)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCheckForTesting(itemIndex: 3)

        picker.performMoreMenuItemForTesting(.sendAsFile)
        let shown = await waitUntil { picker.isShowingTooLargeForTesting }
        XCTAssertTrue(shown)
        XCTAssertTrue(hosted.delegate.sent.isEmpty)

        picker.acknowledgeTooLargeForTesting()
        let sent = try await nextSend(hosted, count: 1)
        XCTAssertEqual(hosted.library.ids(of: sent.approved), ["r0"])
    }

    /// 文件名的后缀跟着内容走（IMG_1234.HEIC 转成 JPEG → IMG_1234.JPG），对得上的不动。
    func testFileNameMatchesContent() {
        XCTAssertEqual(TellomiHeicConversion.fileName("IMG_1234.HEIC", matching: UTType.jpeg.identifier), "IMG_1234.JPG")
        XCTAssertEqual(TellomiHeicConversion.fileName("img_1234.heic", matching: UTType.jpeg.identifier), "img_1234.jpg")
        XCTAssertEqual(TellomiHeicConversion.fileName("IMG_1234.JPG", matching: UTType.jpeg.identifier), "IMG_1234.JPG")
        XCTAssertEqual(TellomiHeicConversion.fileName("IMG_1234.HEIC", matching: UTType.heic.identifier), "IMG_1234.HEIC")
        XCTAssertEqual(TellomiHeicConversion.fileName("photo", matching: UTType.png.identifier), "photo.png")
        XCTAssertTrue(TellomiHeicConversion.isHeic(uti: UTType.heic.identifier))
        XCTAssertTrue(TellomiHeicConversion.isHeic(uti: UTType.heif.identifier))
        XCTAssertFalse(TellomiHeicConversion.isHeic(uti: UTType.jpeg.identifier))
    }

    /// 转 JPEG：像素大小不变、方向照原图带过去。
    func testConvertHeicToJpegKeepsSizeAndOrientation() throws {
        let heic = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".heic")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        guard let destination = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("This simulator can't write HEIC")
        }
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("This simulator can't write HEIC")
        }

        let jpeg = try XCTUnwrap(TellomiHeicConversion.convertToJpeg(at: heic))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 40)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 30)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
    }

    /// M-2（ADR-0068 §4.7）：写了说明才有「说明文字上移」，在最后；点了换成「下移」；之后发出去带着它，按文件发的不带。
    @MainActor
    func testCaptionCanBeMovedAbove() async throws {
        let hosted = host(canSendAsFile: true, initialText: "说明")
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertEqual(picker.moreMenuItemsForTesting.last, .moveCaptionUp)
        XCTAssertEqual(picker.moreMenuTitlesForTesting.last, "Move Caption Up")

        picker.performMoreMenuItemForTesting(.moveCaptionUp)
        XCTAssertEqual(picker.moreMenuItemsForTesting.last, .moveCaptionDown)
        XCTAssertEqual(picker.moreMenuTitlesForTesting.last, "Move Caption Down")
        XCTAssertTrue(hosted.delegate.sent.isEmpty, "开关不发送")

        picker.performMoreMenuItemForTesting(.sendHighQuality)
        let sent = try await nextSend(hosted, count: 1)
        XCTAssertTrue(sent.captionAboveMedia)

        picker.performMoreMenuItemForTesting(.sendAsFile)
        let asFile = try await nextSend(hosted, count: 2)
        XCTAssertFalse(asFile.captionAboveMedia, "按文件发的不适用")
    }

    @MainActor
    func testNoCaptionNoCaptionItem() async throws {
        let hosted = host(canSendAsFile: true)
        defer { hosted.tearDown() }
        hosted.picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertFalse(hosted.picker.moreMenuItemsForTesting.contains(.moveCaptionUp))
        XCTAssertEqual(hosted.picker.sendMenuTitlesForTesting, ["Schedule Message"], "没有说明时长按只有定时发送（M-4）")
    }

    /// #1263（ADR-0068 §4.7 P3）：发送键长按菜单的「说明文字上移 / 下移」——条件同「···」那项，和它是同一个开关；
    /// 写了说明才有、删了说明就没有；预览 / 编辑页的发送键挂同一个菜单，跟着变。
    @MainActor
    func testLongPressSendMovesTheCaptionToo() async throws {
        let hosted = host(canSendAsFile: true)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertEqual(picker.sendMenuTitlesForTesting, ["Schedule Message"])

        picker.typeCaptionForTesting("说明")
        XCTAssertEqual(picker.sendMenuTitlesForTesting, ["Move Caption Up", "Schedule Message"])

        picker.performSendMenuCaptionItemForTesting()
        XCTAssertEqual(picker.sendMenuTitlesForTesting, ["Move Caption Down", "Schedule Message"])
        XCTAssertEqual(picker.moreMenuItemsForTesting.last, .moveCaptionDown, "和「···」里那项是同一个开关")
        XCTAssertTrue(hosted.delegate.sent.isEmpty, "开关不发送")

        // 预览 / 编辑页的发送键挂同一个长按：弹出来的菜单跟着「···」里那项变（#1519 M-5 起是预览 + 菜单）。
        let editor = try await openEditor(picker, onCard: "r0")
        XCTAssertTrue(editor.tellomiSendLongPressEnabledForTesting)
        editor.tellomiLongPressSendForTesting()
        let preview = try await presentedPreview(picker)
        XCTAssertTrue(preview.presentingViewController === editor.navigationController, "盖在预览 / 编辑页上面")
        XCTAssertEqual(preview.actionTitlesForTesting, ["Move Caption Down", "Schedule Message"])
        picker.performMoreMenuItemForTesting(.moveCaptionDown)
        XCTAssertEqual(preview.actionTitlesForTesting, ["Move Caption Up", "Schedule Message"])
        preview.tapBackgroundForTesting()
        let previewClosed = await waitUntil { picker.sendPreviewForTesting == nil }
        XCTAssertTrue(previewClosed)
        await closeEditor(picker)

        picker.typeCaptionForTesting("")
        XCTAssertEqual(picker.sendMenuTitlesForTesting, ["Schedule Message"])
    }

    /// #1519 M-5（照 Telegram iOS `ChatSendMessageContextScreen`）：长按发送键 = 发送键左边一个「发出去是什么样」的气泡、下面是菜单，
    /// 发送键留在原处；菜单里切说明位置，菜单不收、气泡当场重排；点空白处收起，不发。
    @MainActor
    func testLongPressSendPreviewsTheMessageAboveTheMenu() async throws {
        let hosted = host(canSendAsFile: true)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        for index in 0..<3 {
            picker.tapCheckForTesting(itemIndex: index)
        }
        picker.typeCaptionForTesting("Trip")

        picker.longPressSendForTesting()
        let preview = try await presentedPreview(picker)
        XCTAssertEqual(preview.actionTitlesForTesting, ["Move Caption Up", "Schedule Message"])
        XCTAssertEqual(preview.captionTextForTesting, "Trip")
        XCTAssertEqual(preview.captionIsAboveMediaForTesting, false)

        let layout = preview.layoutForTesting
        let sendButton = picker.sendButtonFrameForTesting
        XCTAssertEqual(layout.tiles.count, 3)
        XCTAssertEqual(layout.sendButton.size, sendButton.size)
        XCTAssertEqual(layout.sendButton.minX, sendButton.minX, "发送键横向不动")
        XCTAssertLessThanOrEqual(layout.message.maxX, layout.sendButton.minX, "气泡在发送键左边")
        XCTAssertEqual(layout.message.maxY, layout.sendButton.maxY - 6, accuracy: 0.5, "底边比发送键高 6 pt（同 Telegram）")
        XCTAssertEqual(layout.menu.maxX, layout.message.maxX, accuracy: 0.5, "菜单和气泡右边对齐")
        XCTAssertGreaterThan(layout.menu.minY, layout.message.maxY, "菜单在气泡下面")
        // 同 Telegram：菜单放不下就三样一起往上挪，菜单底边停在安全区里。
        let safeBottom = hosted.window.bounds.inset(by: hosted.window.safeAreaInsets).maxY
        XCTAssertEqual(layout.menu.maxY, safeBottom - 8, accuracy: 0.5)
        XCTAssertLessThan(layout.sendButton.maxY, sendButton.maxY)

        preview.performActionForTesting(at: 0)
        XCTAssertTrue(picker.sendPreviewForTesting === preview, "点了不收")
        XCTAssertEqual(preview.actionTitlesForTesting, ["Move Caption Down", "Schedule Message"])
        XCTAssertEqual(preview.captionIsAboveMediaForTesting, true)
        XCTAssertEqual(picker.moreMenuItemsForTesting.last, .moveCaptionDown, "和「···」里那项是同一个开关")

        preview.tapBackgroundForTesting()
        let closed = await waitUntil { picker.presentedViewController == nil }
        XCTAssertTrue(closed)
        XCTAssertTrue(hosted.delegate.sent.isEmpty, "收起不发")
    }

    /// 预览里的发送键：点了就发（说明位置是预览里刚切的），预览收起。
    @MainActor
    func testTheSendButtonInThePreviewSends() async throws {
        let hosted = host(canSendAsFile: true)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.typeCaptionForTesting("Trip")
        picker.longPressSendForTesting()
        let preview = try await presentedPreview(picker)
        preview.performActionForTesting(at: 0)

        preview.tapSendForTesting()
        let sent = try await nextSend(hosted, count: 1)
        XCTAssertTrue(sent.captionAboveMedia)
        XCTAssertNil(picker.sendPreviewForTesting)
    }

    /// 气泡里的相册排法同会话：5 张以上只排 5 格，多的写在第 5 格上。
    @MainActor
    func testThePreviewLaysTheAlbumOutAsTheConversationDoes() async throws {
        let hosted = host(canSendAsFile: true)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        for index in 0..<6 {
            picker.tapCheckForTesting(itemIndex: index)
        }
        picker.typeCaptionForTesting("Trip")
        picker.longPressSendForTesting()
        let preview = try await presentedPreview(picker)
        XCTAssertEqual(preview.layoutForTesting.tiles.count, 5)
        XCTAssertEqual(preview.moreTextForTesting, "+1")
        preview.tapBackgroundForTesting()
        _ = await waitUntil { picker.presentedViewController == nil }

        let width: CGFloat = 260
        let one = TellomiSendPreviewViewController.mosaicFrames(count: 1, width: width, firstAspectRatio: 3)
        let cappedHeight: CGFloat = (width / 1.8).rounded()
        XCTAssertEqual(one.map(\.size), [CGSize(width: width, height: cappedHeight)], "很宽的图按 1.8 封顶")
        let three = TellomiSendPreviewViewController.mosaicFrames(count: 3, width: width, firstAspectRatio: 1)
        XCTAssertEqual(three[0].size.height, three[2].maxY, "左大右二")
        XCTAssertEqual(three[1].minX, three[2].minX)
        let four = TellomiSendPreviewViewController.mosaicFrames(count: 4, width: width, firstAspectRatio: 1)
        XCTAssertEqual(Set(four.map(\.minY)).count, 2, "2 × 2")
        let five = TellomiSendPreviewViewController.mosaicFrames(count: 7, width: width, firstAspectRatio: 1)
        XCTAssertEqual(five.count, 5)
        XCTAssertEqual(five.filter { $0.minY == 0 }.count, 2, "上 2 下 3")
        for frames in [one, three, four, five] {
            XCTAssertEqual(frames.map(\.maxX).max() ?? 0, width, accuracy: 0.5, "铺满气泡宽")
        }
    }

    @MainActor
    func testLongPressSendHasNoCaptionItemOutsideAConversation() async throws {
        let hosted = host(canSendAsFile: false, initialText: "说明")
        defer { hosted.tearDown() }
        hosted.picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertNil(hosted.picker.sendMenuTitlesForTesting)
    }

    // MARK: - M-4 定时发送

    /// #1519 M-4（照 Telegram 两端）：长按发送 →「定时发送」→ 底部弹出选时间 → 点「… 发送」：照常发送，只是交给会话页时带着时间；
    /// 之后普通的发送不带时间。
    @MainActor
    func testLongPressSendSchedulesTheMessage() async throws {
        let hosted = host(canSendAsFile: true)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCheckForTesting(itemIndex: 1)
        picker.typeCaptionForTesting("Later")

        picker.longPressSendForTesting()
        let preview = try await presentedPreview(picker)
        XCTAssertEqual(preview.actionTitlesForTesting.last, "Schedule Message")
        preview.performActionForTesting(at: preview.actionTitlesForTesting.count - 1)
        let sheet = try await presentedScheduleSheet(over: picker)
        XCTAssertNil(picker.sendPreviewForTesting, "预览收起，换成选时间")

        let at = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 3, to: TellomiScheduleTimeSheet.defaultDate(now: Date())))
        sheet.datePickerForTesting.date = at
        sheet.tapConfirmForTesting()

        let sent = try await nextSend(hosted, count: 1)
        XCTAssertEqual(sent.scheduledAt, at)
        XCTAssertEqual(sent.body?.text, "Later")
        XCTAssertEqual(sent.approved.attachments.count, 2)
        XCTAssertFalse(sent.separately)

        picker.tapSendForTesting()
        let next = try await nextSend(hosted, count: 2)
        XCTAssertNil(next.scheduledAt, "普通发送不带时间")
    }

    /// 上游预览 / 编辑页的发送键长按里选「定时发送」：那一页照常发送，交回来时带着时间；之后在同一页普通发送不带时间。
    @MainActor
    func testSchedulingFromTheEditorThenSendingNormally() async throws {
        let hosted = host(canSendAsFile: true)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        let editor = try await openEditor(picker, onCard: "r0")
        XCTAssertTrue(editor.tellomiSendLongPressEnabledForTesting, "没写说明也能长按（有定时发送）")
        editor.tellomiLongPressSendForTesting()
        let preview = try await presentedPreview(picker)
        XCTAssertEqual(preview.actionTitlesForTesting, ["Schedule Message"])
        preview.performActionForTesting(at: 0)
        let sheet = try await presentedScheduleSheet(over: picker)
        let at = TellomiScheduleTimeSheet.defaultDate(now: Date()).addingTimeInterval(3600)
        sheet.datePickerForTesting.date = at
        sheet.tapConfirmForTesting()

        let sent = try await nextSend(hosted, count: 1)
        XCTAssertEqual(sent.scheduledAt, at)
        XCTAssertEqual(sent.approved.attachments.count, 1)

        // 还在这一页（测试里的会话页不收起它）：普通发送不带上一次的时间。
        editor.tellomiTapSendForTesting()
        let next = try await nextSend(hosted, count: 2)
        XCTAssertNil(next.scheduledAt)
    }

    /// 这个会话已经排满 100 条：选「定时发送」时就说，不弹选时间、什么都不发。
    @MainActor
    func testAFullChatIsToldBeforeChoosingATime() async throws {
        let hosted = host(canSendAsFile: true)
        defer { hosted.tearDown() }
        hosted.delegate.scheduledMessageCapacity = 0
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.longPressSendForTesting()
        let preview = try await presentedPreview(picker)
        preview.performActionForTesting(at: preview.actionTitlesForTesting.count - 1)
        let alerted = await waitUntil {
            var top: UIViewController? = picker
            while let presented = top?.presentedViewController { top = presented }
            return top is ActionSheetController
        }
        XCTAssertTrue(alerted)
        XCTAssertTrue(hosted.delegate.sent.isEmpty)
    }

    /// 收藏（给自己）里叫「设置提醒」（同 Telegram 两端 `SetReminder`）。
    @MainActor
    func testSavedMessagesSaysSetAReminder() async throws {
        let hosted = host(canSendAsFile: true, isNoteToSelf: true)
        defer { hosted.tearDown() }
        hosted.picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertEqual(hosted.picker.sendMenuTitlesForTesting, ["Set a Reminder"])
    }

    // MARK: - P-9 / P-10 在网格里直接发

    /// 会话输入框里已打的字带过来当说明；发送按勾的顺序、默认画质、不是一次性查看，说明随这次发出去。
    @MainActor
    func testSendFromGridKeepsTapOrderAndCaption() async throws {
        let hosted = host(initialText: "今天的照片")
        defer { hosted.tearDown() }
        let picker = hosted.picker
        XCTAssertEqual(picker.captionTextForTesting, "今天的照片")
        picker.tapCheckForTesting(itemIndex: 1)
        picker.view.layoutIfNeeded()
        XCTAssertLessThan(picker.captionFieldHeightForTesting, 50, "一行字的说明框就是一行高")
        picker.tapCheckForTesting(itemIndex: 1)

        picker.tapCheckForTesting(itemIndex: 5)
        picker.tapCheckForTesting(itemIndex: 2)
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapSendForTesting()

        let sent = try await nextSend(hosted, count: 1)
        XCTAssertEqual(hosted.library.ids(of: sent.approved), ["r5", "r2", "r0"])
        XCTAssertEqual(sent.approved.imageQuality, .standard)
        XCTAssertFalse(sent.approved.isViewOnce)
        XCTAssertFalse(sent.separately)
        XCTAssertEqual(sent.body?.text, "今天的照片")
    }

    /// P-9 表情键：说明框右下角 32 的键（离框右、下各 4），字不压到它下面；点了说明框换成表情键盘并进入编辑、键变成「键盘」；
    /// 再点回到文字键盘（仍在编辑）；在表情键盘时收起键盘，下次就是文字键盘（同 Telegram）。
    @MainActor
    func testCaptionEmojiButtonSwitchesTheKeyboard() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        hosted.window.makeKey()
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.view.layoutIfNeeded()

        let field = picker.captionFieldFrameForTesting
        let button = picker.captionEmojiButtonFrameForTesting
        XCTAssertEqual(button.size.width, 32, accuracy: 0.01)
        XCTAssertEqual(button.size.height, 32, accuracy: 0.01)
        XCTAssertEqual(field.maxX - button.maxX, 4, accuracy: 0.5)
        XCTAssertEqual(field.maxY - button.maxY, 4, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(picker.captionTextContainerInsetForTesting.right, field.maxX - button.minX, "字不压到表情键下面")
        XCTAssertEqual(picker.captionEmojiButtonAccessibilityLabelForTesting, "Emoji")
        XCTAssertNil(picker.captionInputViewForTesting)
        XCTAssertFalse(picker.isCaptionEditingForTesting)

        picker.tapCaptionEmojiButtonForTesting()
        XCTAssertNotNil(picker.captionEmojiKeyboardForTesting, "说明框换成表情键盘")
        XCTAssertTrue(picker.isCaptionEditingForTesting, "点表情键直接进入编辑")
        XCTAssertEqual(picker.captionEmojiButtonAccessibilityLabelForTesting, "Keyboard")

        picker.tapCaptionEmojiButtonForTesting()
        XCTAssertNil(picker.captionInputViewForTesting, "再点回到文字键盘")
        XCTAssertTrue(picker.isCaptionEditingForTesting)
        XCTAssertEqual(picker.captionEmojiButtonAccessibilityLabelForTesting, "Emoji")

        picker.tapCaptionEmojiButtonForTesting()
        XCTAssertNotNil(picker.captionEmojiKeyboardForTesting)
        picker.endCaptionEditingForTesting()
        XCTAssertNil(picker.captionInputViewForTesting, "收起键盘后回到文字键盘")
        XCTAssertEqual(picker.captionEmojiButtonAccessibilityLabelForTesting, "Emoji")
    }

    /// 表情键盘里点一个 emoji：插在光标处（不是接在末尾），会话输入框跟着变；退格删掉光标前的整个 emoji。
    @MainActor
    func testEmojiKeyboardInsertsAtTheCursorAndDeletes() async throws {
        let hosted = host(initialText: "ab")
        defer { hosted.tearDown() }
        hosted.window.makeKey()
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCaptionEmojiButtonForTesting()
        let keyboard = try XCTUnwrap(picker.captionEmojiKeyboardForTesting)

        picker.setCaptionCursorForTesting(1)
        let emoji = try XCTUnwrap(keyboard.tapEmojiForTesting(at: IndexPath(item: 0, section: 0)))
        XCTAssertEqual(picker.captionTextForTesting, "a" + emoji + "b")
        XCTAssertEqual(hosted.delegate.bodies.last??.text, "a" + emoji + "b", "会话输入框跟着变")

        let second = try XCTUnwrap(keyboard.tapEmojiForTesting(at: IndexPath(item: 1, section: 0)))
        XCTAssertEqual(picker.captionTextForTesting, "a" + emoji + second + "b", "光标跟在刚插的后面")

        keyboard.tapDeleteForTesting()
        XCTAssertEqual(picker.captionTextForTesting, "a" + emoji + "b", "退格删掉整个 emoji")
        keyboard.tapDeleteForTesting()
        keyboard.tapDeleteForTesting()
        XCTAssertEqual(picker.captionTextForTesting, "b")
        XCTAssertEqual(hosted.delegate.bodies.last??.text, "b")
    }

    /// 表情键盘照 Telegram 的排法：分类在上面（占满宽）、emoji 在中间、底栏左边「键盘」右边退格；点「键盘」回到文字键盘（仍在编辑）。
    @MainActor
    func testEmojiKeyboardLayoutAndSwitchBack() async throws {
        // 键盘窗口按模拟器真实的屏幕排（375 那台是 SE），宿主窗口也用真实屏幕大小，不然键盘永远比窗口窄
        let screen = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first)
        let hosted = host(width: screen.width, height: screen.height)
        defer { hosted.tearDown() }
        hosted.window.makeKey()
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCaptionEmojiButtonForTesting()
        let keyboard = try XCTUnwrap(picker.captionEmojiKeyboardForTesting)
        // 键盘是系统异步放上屏的（在 UIRemoteKeyboardWindow 里），等它有了真实宽度再量。
        let onScreen = await waitUntil { keyboard.window != nil && keyboard.bounds.size.width >= picker.view.bounds.size.width - 0.5 }
        XCTAssertTrue(onScreen, "表情键盘上屏")
        keyboard.layoutIfNeeded()

        let toolbar = keyboard.sectionToolbarFrameForTesting
        let grid = keyboard.emojiViewFrameForTesting
        let switchButton = keyboard.keyboardButtonFrameForTesting
        let delete = keyboard.deleteButtonFrameForTesting
        XCTAssertEqual(toolbar.size.width, keyboard.bounds.size.width, accuracy: 0.5, "分类条占满宽，不和退格挤一行")
        XCTAssertLessThanOrEqual(toolbar.maxY, grid.minY + 0.5, "分类在 emoji 上面")
        XCTAssertLessThanOrEqual(grid.maxY, delete.minY + 0.5, "底栏在 emoji 下面")
        XCTAssertEqual(switchButton.minY, delete.minY, accuracy: 0.5, "「键盘」和退格在同一条底栏")
        XCTAssertLessThan(switchButton.midX, keyboard.bounds.midX, "「键盘」在左")
        XCTAssertGreaterThan(delete.midX, keyboard.bounds.midX, "退格在右")
        XCTAssertGreaterThan(grid.size.height, 150, "emoji 区不被挤没")

        keyboard.tapKeyboardForTesting()
        XCTAssertNil(picker.captionInputViewForTesting, "点「键盘」回到文字键盘")
        XCTAssertTrue(picker.isCaptionEditingForTesting)
        XCTAssertEqual(picker.captionEmojiButtonAccessibilityLabelForTesting, "Emoji")
    }

    /// 按住退格连着删（先删一个，0.5 秒后每 0.1 秒一个），松手就停。
    @MainActor
    func testHoldingDeleteKeepsDeleting() async throws {
        let hosted = host(initialText: String(repeating: "x", count: 40))
        defer { hosted.tearDown() }
        hosted.window.makeKey()
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCaptionEmojiButtonForTesting()
        let keyboard = try XCTUnwrap(picker.captionEmojiKeyboardForTesting)
        picker.setCaptionCursorForTesting(40)

        try await keyboard.holdDeleteForTesting(seconds: 1.2)
        let afterHold = picker.captionTextForTesting.count
        XCTAssertLessThanOrEqual(afterHold, 40 - 3, "按住 1.2 秒删了好几个")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(picker.captionTextForTesting.count, afterHold, "松手就停")
    }

    /// 网格里点照片进整本相册的查看器（不自动选中）；查看器里「编辑」才进上游的预览 / 编辑页（盖在网格上面），先看到当前这张。
    /// 那里删掉一张，网格里也取消；那里取消回到网格、选中的还在；那里改说明，网格的说明和会话输入框跟着变；那里发送照常交给会话页。
    @MainActor
    func testAlbumViewerEditOpensUpstreamEditorOverTheGrid() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapCheckForTesting(itemIndex: 3)
        picker.tapItemForTesting(itemIndex: 4)
        let viewed = await waitUntil { self.albumViewer(over: picker) != nil }
        XCTAssertTrue(viewed, "点照片进了整本相册的查看器")
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3"], "点开查看不自动选中")
        try XCTUnwrap(albumViewer(over: picker)).tapEditForTesting()

        let opened = await waitUntil { self.approvalViewController(over: picker) != nil }
        XCTAssertTrue(opened, "编辑进了上游的预览 / 编辑页")
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r4"], "编辑会先选上当前这张")
        let approval = try XCTUnwrap(approvalViewController(over: picker))
        XCTAssertTrue(
            approval.currentItem?.attachment.rawValue === hosted.library.attachmentsById["r4"]?.rawValue,
            "点的是 r4，进来先看到 r4（不是已选里的第一张 r3）",
        )

        let removed = try XCTUnwrap(hosted.library.attachmentsById["r3"])
        picker.attachmentApproval(approval, didRemoveAttachment: AttachmentApprovalItem(attachment: removed, canSave: false))
        XCTAssertEqual(picker.selectedIdsForTesting, ["r4"], "预览页里删掉的，网格里也取消")

        picker.attachmentApproval(approval, didChangeMessageBody: MessageBody(text: "改过的说明", ranges: .empty))
        XCTAssertEqual(picker.captionTextForTesting, "改过的说明")
        XCTAssertEqual(hosted.delegate.bodies.last??.text, "改过的说明")

        picker.attachmentApprovalDidCancel()
        let closed = await waitUntil { picker.presentedViewController == nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r4"], "取消回到网格，选中的还在")
        XCTAssertEqual(hosted.delegate.cancels, 0, "只关预览页，不关选图")

        let edited = try XCTUnwrap(hosted.library.attachmentsById["r4"])
        picker.attachmentApproval(approval, didApproveAttachments: ApprovedAttachments(nonViewOnceAttachments: [edited], imageQuality: .high), messageBody: nil)
        let sent = try XCTUnwrap(hosted.delegate.sent.last)
        XCTAssertEqual(hosted.library.ids(of: sent.approved), ["r4"])
        XCTAssertEqual(sent.approved.imageQuality, .high)
        XCTAssertFalse(sent.separately)
    }

    /// 查看器底部「绘制」「裁剪」：和「编辑」一样先选上当前这张、进上游的预览 / 编辑页，并直接打开对应的工具。
    @MainActor
    func testAlbumViewerPenAndCropShortcutsOpenTheMatchingUpstreamTool() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapCheckForTesting(itemIndex: 3)
        picker.tapItemForTesting(itemIndex: 4)
        let viewed = await waitUntil { self.albumViewer(over: picker) != nil }
        XCTAssertTrue(viewed)
        let viewer = try XCTUnwrap(albumViewer(over: picker))
        XCTAssertTrue(viewer.isCropShownForTesting, "图片上有「裁剪」")
        XCTAssertTrue(viewer.isPenShownForTesting, "图片上有「绘制」")

        viewer.tapToolForTesting(.pen)
        let penOpened = await waitUntil { self.approvalViewController(over: picker) != nil }
        XCTAssertTrue(penOpened, "绘制进了上游的预览 / 编辑页")
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r4"], "和「编辑」一样先选上当前这张")
        let penApproval = try XCTUnwrap(approvalViewController(over: picker))
        XCTAssertTrue(penApproval.currentItem?.attachment.rawValue === hosted.library.attachmentsById["r4"]?.rawValue)
        let penToolOnScreen = await waitUntil { penApproval.currentPageViewController?.presentedViewController is ImageEditorViewController }
        XCTAssertTrue(penToolOnScreen, "直接打开了上游的涂鸦工具")

        picker.attachmentApprovalDidCancel()
        let penClosed = await waitUntil { picker.presentedViewController == nil }
        XCTAssertTrue(penClosed)

        picker.tapItemForTesting(itemIndex: 4)
        let reviewed = await waitUntil { self.albumViewer(over: picker) != nil }
        XCTAssertTrue(reviewed)
        try XCTUnwrap(albumViewer(over: picker)).tapToolForTesting(.crop)
        let cropOpened = await waitUntil { self.approvalViewController(over: picker) != nil }
        XCTAssertTrue(cropOpened, "裁剪进了上游的预览 / 编辑页")
        let cropApproval = try XCTUnwrap(approvalViewController(over: picker))
        let cropToolOnScreen = await waitUntil { cropApproval.currentPageViewController?.presentedViewController is ImageEditorCropViewController }
        XCTAssertTrue(cropToolOnScreen, "直接打开了上游的裁剪工具")

        // tellomi/tellomi#1593 E5-3：「调整」在绘制后面（照 Telegram iOS 编辑底栏），直接打开调色页。
        picker.attachmentApprovalDidCancel()
        let cropClosed = await waitUntil { picker.presentedViewController == nil }
        XCTAssertTrue(cropClosed)
        picker.tapItemForTesting(itemIndex: 4)
        let viewedAgain = await waitUntil { self.albumViewer(over: picker) != nil }
        XCTAssertTrue(viewedAgain)
        let adjustViewer = try XCTUnwrap(albumViewer(over: picker))
        XCTAssertTrue(adjustViewer.isAdjustShownForTesting, "图片上有「调整」")
        adjustViewer.tapToolForTesting(.adjust)
        let adjustOpened = await waitUntil { self.approvalViewController(over: picker) != nil }
        XCTAssertTrue(adjustOpened)
        let adjustApproval = try XCTUnwrap(approvalViewController(over: picker))
        let adjustToolOnScreen = await waitUntil { adjustApproval.currentPageViewController?.presentedViewController is TellomiImageAdjustViewController }
        XCTAssertTrue(adjustToolOnScreen, "直接打开了调色页")
    }

    /// 视频没有「裁剪」「绘制」（上游对视频没有这两个工具），底部只剩「编辑」。
    @MainActor
    func testAlbumViewerHidesImageToolsForVideos() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapItemForTesting(itemIndex: 1)
        let viewed = await waitUntil { self.albumViewer(over: picker) != nil }
        XCTAssertTrue(viewed)
        let viewer = try XCTUnwrap(albumViewer(over: picker))
        XCTAssertFalse(viewer.isCropShownForTesting, "视频不显示「裁剪」")
        XCTAssertFalse(viewer.isPenShownForTesting, "视频不显示「绘制」")
        XCTAssertFalse(viewer.isAdjustShownForTesting, "视频不显示「调整」")
    }

    /// 动图（GIF）：上游预览页不支持裁剪 / 绘制，底部和视频一样只剩「编辑」。
    @MainActor
    func testAlbumViewerHidesImageToolsForAnimatedImages() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapItemForTesting(itemIndex: 5)
        let viewed = await waitUntil { self.albumViewer(over: picker) != nil }
        XCTAssertTrue(viewed)
        let viewer = try XCTUnwrap(albumViewer(over: picker))
        XCTAssertFalse(viewer.isCropShownForTesting, "动图不显示「裁剪」")
        XCTAssertFalse(viewer.isPenShownForTesting, "动图不显示「绘制」")
    }

    /// 网格点照片：进整本相册的查看器，先看到点的那张，点开不自动选中。
    @MainActor
    func testTapPhotoOpensAlbumViewerAtThatPhotoWithoutSelecting() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapItemForTesting(itemIndex: 4)
        let opened = await waitUntil { self.albumViewer(over: picker) != nil }
        XCTAssertTrue(opened, "点照片进了整本相册的查看器")
        let viewer = try XCTUnwrap(albumViewer(over: picker))
        XCTAssertEqual(viewer.pageIndexForTesting, 4)
        XCTAssertEqual(picker.selectedIdsForTesting, [])
    }

    /// 查看器里：右上角勾选即时增减；计数点开切出已选，网格收起。
    @MainActor
    func testAlbumViewerCheckTogglesAndCountShowsSelected() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapItemForTesting(itemIndex: 4)
        let opened = await waitUntil { self.albumViewer(over: picker) != nil }
        XCTAssertTrue(opened)
        let viewer = try XCTUnwrap(albumViewer(over: picker))

        viewer.tapCheckForTesting()
        XCTAssertEqual(picker.selectedIdsForTesting, ["r4"])
        XCTAssertEqual(viewer.checkNumberTextForTesting, "1")
        XCTAssertTrue(viewer.isCountShownForTesting)

        viewer.tapCheckForTesting()
        XCTAssertEqual(picker.selectedIdsForTesting, [])
        XCTAssertFalse(viewer.isCountShownForTesting)

        viewer.tapCheckForTesting()
        viewer.tapCountForTesting()
        let switched = await waitUntil { picker.presentedViewController == nil && picker.collectionViewForTesting.isHidden }
        XCTAssertTrue(switched, "计数点开切出已选，网格收起")
        XCTAssertEqual(picker.selectedIdsForTesting, ["r4"])
    }

    /// 查看器里单击照片：切换选中，和右上角勾选一样即时增减（照 Telegram `TGMediaPickerGalleryPhotoItemView` 单击）。
    @MainActor
    func testAlbumViewerSingleTapOnPhotoTogglesSelection() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapItemForTesting(itemIndex: 4)
        let opened = await waitUntil { self.albumViewer(over: picker) != nil }
        XCTAssertTrue(opened)
        let viewer = try XCTUnwrap(albumViewer(over: picker))

        viewer.tapPhotoForTesting()
        XCTAssertEqual(picker.selectedIdsForTesting, ["r4"])
        XCTAssertEqual(viewer.checkNumberTextForTesting, "1")

        viewer.tapPhotoForTesting()
        XCTAssertEqual(picker.selectedIdsForTesting, [])
        XCTAssertNil(viewer.checkNumberTextForTesting)
    }

    /// 查看器：照片在 iCloud、要下载时中间一个进度圈，下完收起；本机就有的不出（tellomi/tellomi#1521 G-3，
    /// 照 Telegram 聊天选图查看器 `TGMediaPickerGalleryPhotoItemView` 的 `setProgressVisible`）。
    @MainActor
    func testAlbumViewerShowsICloudDownloadProgress() async throws {
        let library = FakePhotoLibrary()
        let hosted = host(library: library)
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapItemForTesting(itemIndex: 4)
        let opened = await waitUntil { self.albumViewer(over: picker) != nil && library.viewerProgress["r4"] != nil }
        XCTAssertTrue(opened)
        let viewer = try XCTUnwrap(albumViewer(over: picker))
        XCTAssertFalse(viewer.isDownloadProgressShownForTesting, "本机就有的不出圈")

        library.viewerProgress["r4"]?(0)
        XCTAssertTrue(viewer.isDownloadProgressShownForTesting, "开始下载就出圈")
        library.viewerProgress["r4"]?(0.4)
        XCTAssertTrue(viewer.isDownloadProgressShownForTesting)
        library.viewerProgress["r4"]?(1)
        XCTAssertFalse(viewer.isDownloadProgressShownForTesting, "下完收起")
    }

    /// 截图（TELLOMI_SHOTS=1）：查看器里一张照片正在从 iCloud 下载（G-3）。
    @MainActor
    func testAlbumViewerDownloadProgressScreenshot() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let library = FakePhotoLibrary()
        let hosted = host(library: library)
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapItemForTesting(itemIndex: 4)
        let opened = await waitUntil { self.albumViewer(over: picker) != nil && library.viewerProgress["r4"] != nil }
        XCTAssertTrue(opened)
        library.viewerProgress["r4"]?(0.35)
        try await settle()
        try save(render(hosted.window), name: "picker-viewer-icloud-progress.png", width: 402)
    }

    // MARK: - P-11 上限

    /// 下滑关闭：距离 128 或速度 700 任一达到即关。
    @MainActor
    func testAlbumViewerDismissRuleMatchesTelegramThresholds() {
        XCTAssertFalse(TellomiPhotoPickerAlbumViewer.shouldDismiss(distance: 127, velocity: 699))
        XCTAssertTrue(TellomiPhotoPickerAlbumViewer.shouldDismiss(distance: 128, velocity: 0))
        XCTAssertTrue(TellomiPhotoPickerAlbumViewer.shouldDismiss(distance: 10, velocity: -700))
        XCTAssertEqual(TellomiPhotoPickerAlbumViewer.dismissProgress(distance: -75), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TellomiPhotoPickerAlbumViewer.dismissProgress(distance: 400), 1)
    }

    func testAlbumViewerZoomLimitsFollowTelegramFormula() {
        let bounds = CGSize(width: 400, height: 800)
        let wide = TellomiPhotoPickerAlbumViewer.zoomLimits(bounds: bounds, content: CGSize(width: 4000, height: 2000))
        XCTAssertEqual(wide.normal, 0.1, accuracy: 0.0001)
        XCTAssertEqual(wide.minimum, 0.05, accuracy: 0.0001)
        XCTAssertEqual(wide.maximum, 0.4, accuracy: 0.0001)

        let tiny = TellomiPhotoPickerAlbumViewer.zoomLimits(bounds: bounds, content: CGSize(width: 10000, height: 1000))
        XCTAssertEqual(tiny.minimum, 0.04, accuracy: 0.0001)
        XCTAssertEqual(tiny.maximum, 0.8, accuracy: 0.0001)
    }

    /// 选满之后再勾（或滑过去）选不上，并提示「一次最多选 N 张」。
    @MainActor
    func testSelectionLimit() async throws {
        let hosted = host(maxSelection: 3)
        defer { hosted.tearDown() }
        let picker = hosted.picker

        for index in 0..<4 {
            picker.tapCheckForTesting(itemIndex: index)
        }
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r1", "r2"])
        XCTAssertEqual(toastTexts(in: picker.view), ["You can select up to 3 items at a time"])
        XCTAssertNil(picker.cellForTesting(itemIndex: 3)?.numberTextForTesting)

        let rowTwo = center(of: 3, in: picker)
        picker.swipeForTesting(through: [rowTwo, CGPoint(x: rowTwo.x + 12, y: rowTwo.y), center(of: 4, in: picker), center(of: 5, in: picker)])
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r1", "r2"], "滑过去也选不上")
    }

    // MARK: - 关闭（照 Telegram requestDismiss）

    /// 没选中：✕ 直接关。有选中：✕ 先问「丢弃媒体」，不直接关。
    @MainActor
    func testCloseAsksFirstOnlyWhenSomethingIsSelected() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker

        picker.tapCloseForTesting()
        XCTAssertEqual(hosted.delegate.cancels, 1)

        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCloseForTesting()
        XCTAssertEqual(hosted.delegate.cancels, 1, "有选中不直接关")
        let asked = await waitUntil { picker.presentedViewController is ActionSheetController }
        XCTAssertTrue(asked)
        let sheet = try XCTUnwrap(picker.presentedViewController as? ActionSheetController)
        XCTAssertEqual(sheet.actions.map { $0.button.configuration?.title }, ["Discard Media", CommonStrings.cancelButton])
    }

    // MARK: - 相册

    /// 「最近 ⌄」换相册：标题跟着换、网格换内容；别的相册里勾过的不丢。
    @MainActor
    func testSwitchAlbumKeepsSelection() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        XCTAssertEqual(picker.albumTitlesForTesting, ["Recents", "Screenshots"])

        picker.tapCheckForTesting(itemIndex: 0)
        picker.switchAlbumForTesting(title: "Screenshots")
        picker.collectionViewForTesting.layoutIfNeeded()
        XCTAssertEqual(picker.titleForTesting, "Screenshots")
        XCTAssertEqual(picker.collectionViewForTesting.numberOfItems(inSection: 0), 3)
        picker.tapCheckForTesting(itemIndex: 1)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "s1"])
        XCTAssertEqual(picker.cellForTesting(itemIndex: 1)?.numberTextForTesting, "2")
        XCTAssertEqual(picker.countPillTextForTesting, "2")
    }

    // MARK: - 单独发送的拆条（会话页那一头）

    /// 一张一条、按顺序；说明只挂最后一条；画质照原样；上一条没发出去就不发后面的。
    /// 时间戳不重复靠上游 `MessageTimestampGenerator`：连着取三次严格递增。
    @MainActor
    func testSendSeparatelyOnePerMessageCaptionOnLast() async throws {
        let library = FakePhotoLibrary()
        var attachments = [PreviewableAttachment]()
        for index in [2, 0, 5] {
            attachments.append(try await library.attachment(for: library.recents[index], attachmentLimits: .currentLimits()))
        }
        let approved = ApprovedAttachments(nonViewOnceAttachments: attachments, imageQuality: .high)
        let body = MessageBody(text: "今天的照片", ranges: .empty)

        struct Call: Equatable {
            let ids: [String]
            let body: String?
            let isHigh: Bool
        }
        var calls = [Call]()
        await TellomiPhotoPickerSending.sendSeparately(approved, messageBody: body) { part, partBody in
            calls.append(Call(ids: library.ids(of: part), body: partBody?.text, isHigh: part.imageQuality == .high))
            return true
        }
        XCTAssertEqual(calls, [
            Call(ids: ["r2"], body: nil, isHigh: true),
            Call(ids: ["r0"], body: nil, isHigh: true),
            Call(ids: ["r5"], body: "今天的照片", isHigh: true),
        ])

        calls.removeAll()
        await TellomiPhotoPickerSending.sendSeparately(approved, messageBody: body) { part, partBody in
            calls.append(Call(ids: library.ids(of: part), body: partBody?.text, isHigh: part.imageQuality == .high))
            return calls.count < 2
        }
        XCTAssertEqual(calls.map(\.ids), [["r2"], ["r0"]], "第二条没发出去，第三条不发")

        let timestamps = (0..<3).map { _ in MessageTimestampGenerator.sharedInstance.generateTimestamp() }
        XCTAssertEqual(timestamps, timestamps.sorted())
        XCTAssertEqual(Set(timestamps).count, 3)
    }

    // MARK: - P-3 只看已选

    /// 点「✓N」：网格换成「只看已选」——✕ 变返回、「✓N」「最近 ⌄」隐藏，「···」和说明栏照旧；顶部只有「拖动可调整顺序」（没有「消息预览」）；
    /// 卡片按勾的顺序、编号 1…N，行高与每张的宽照 AlbumCarouselGeometry（放得下时靠右）；有说明时下面一个靠右的气泡；
    /// 铺的是会话的聊天背景。返回回到网格（不是关闭）。
    @MainActor
    func testCountPillShowsSelectedOnlyPreview() async throws {
        let background = UIView()
        background.backgroundColor = .systemTeal
        let hosted = host(initialText: "今天的照片", chatBackground: background)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        for index in [3, 0, 5] {
            picker.tapCheckForTesting(itemIndex: index)
        }

        picker.tapCountPillForTesting()
        XCTAssertEqual(picker.displayMode, .selected)
        XCTAssertFalse(picker.isCountPillShownForTesting)
        XCTAssertFalse(picker.isTitleShownForTesting)
        XCTAssertEqual(picker.closeButtonAccessibilityLabelForTesting, CommonStrings.backButton)
        XCTAssertTrue(picker.isMoreButtonShownForTesting)
        XCTAssertTrue(picker.isSendBarShownForTesting)

        let preview = picker.selectedViewForTesting
        preview.layoutIfNeeded()
        XCTAssertTrue(preview.backgroundViewForTesting === background, "铺会话的聊天背景")
        XCTAssertEqual(preview.chipTextsForTesting, ["Drag to reorder"])
        XCTAssertEqual(preview.cardIdsForTesting, ["r3", "r0", "r5"])
        XCTAssertEqual(preview.cardNumbersForTesting, ["1", "2", "3"])

        let expected = AlbumCarouselGeometry.layout(
            viewportWidth: 402,
            startInset: 16,
            endMargin: AlbumCarouselGeometry.endMargin,
            spacing: AlbumCarouselGeometry.itemSpacing,
            minNextPeek: AlbumCarouselGeometry.nextItemMinPeek,
            rowHeight: AlbumCarouselGeometry.rowHeight(screenWidth: 402, screenHeight: 874, capByScreenHeight: false),
            aspectRatios: [3, 0, 5].map { AlbumCarouselGeometry.aspectRatio(FakePhotoLibrary.pixelSizes[$0 % FakePhotoLibrary.pixelSizes.count]) },
            alignEndWhenFits: true,
        )
        XCTAssertEqual(preview.rowLayoutForTesting, expected, "排序行的几何照 AlbumCarouselGeometry")
        XCTAssertEqual(preview.cardFramesForTesting, (0..<3).map { expected.itemFrame($0) })
        XCTAssertEqual(preview.captionBubbleTextForTesting, "今天的照片")
        XCTAssertEqual(preview.captionBubbleFrameForTesting.maxX, 402 - AlbumCarouselGeometry.endMargin, accuracy: 0.01, "说明气泡靠右")
        XCTAssertGreaterThan(preview.captionBubbleFrameForTesting.minY, preview.rowFrameForTesting.maxY, "说明在那一行下面")

        picker.typeCaptionForTesting("改过的说明")
        XCTAssertEqual(preview.captionBubbleTextForTesting, "改过的说明", "说明改了，预览跟着变")
        XCTAssertEqual(hosted.delegate.bodies.last??.text, "改过的说明", "会话输入框也跟着变")

        picker.tapCloseForTesting()
        XCTAssertEqual(picker.displayMode, .all)
        XCTAssertTrue(picker.isCountPillShownForTesting)
        XCTAssertTrue(picker.isTitleShownForTesting)
        XCTAssertEqual(picker.closeButtonAccessibilityLabelForTesting, CommonStrings.dismissButton)
        XCTAssertEqual(hosted.delegate.cancels, 0, "返回不是关闭")
    }

    /// 只选一张：没有「拖动可调整顺序」（顶部什么小字都没有），也拿不起来排序；卡片靠右。
    @MainActor
    func testSingleSelectionPreviewHasNoDragHint() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        hosted.picker.tapCheckForTesting(itemIndex: 2)
        hosted.picker.tapCountPillForTesting()
        let preview = hosted.picker.selectedViewForTesting
        preview.layoutIfNeeded()

        XCTAssertEqual(preview.chipTextsForTesting, [])
        XCTAssertNil(preview.captionBubbleTextForTesting, "没有说明就没有气泡")
        let card = try XCTUnwrap(preview.cardFramesForTesting.first)
        XCTAssertEqual(card.maxX, 402 - AlbumCarouselGeometry.endMargin, accuracy: 0.01)
        XCTAssertFalse(preview.beginReorder(at: try XCTUnwrap(preview.cardCenterForTesting("r2"))))
    }

    /// 长按 0.3 秒拖动排序：拿起的那张跟着手指，越过别的卡片就换位，松手放下；新的顺序就是发出去的顺序（编号、网格、发送都照它）。
    @MainActor
    func testLongPressDragReordersSelection() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        for index in [3, 0, 5] {
            picker.tapCheckForTesting(itemIndex: index)
        }
        picker.tapCountPillForTesting()
        let preview = picker.selectedViewForTesting
        preview.layoutIfNeeded()
        XCTAssertEqual(preview.reorderPressDurationForTesting, 0.3, accuracy: 0.001)

        let start = try XCTUnwrap(preview.cardCenterForTesting("r3"))
        XCTAssertTrue(preview.beginReorder(at: start))
        XCTAssertTrue(preview.isReorderingForTesting)
        let over = try XCTUnwrap(preview.cardCenterForTesting("r0"))
        preview.moveReorder(to: CGPoint(x: over.x + 20, y: start.y + 30))
        XCTAssertEqual(preview.cardIdsForTesting, ["r0", "r3", "r5"])
        XCTAssertEqual(preview.cardNumbersForTesting, ["1", "2", "3"])
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r3", "r5"], "排序就是发出去的顺序")
        preview.endReorder()
        XCTAssertFalse(preview.isReorderingForTesting)

        picker.tapCloseForTesting()
        picker.collectionViewForTesting.layoutIfNeeded()
        XCTAssertEqual(picker.cellForTesting(itemIndex: 0)?.numberTextForTesting, "1")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 3)?.numberTextForTesting, "2")
        XCTAssertEqual(picker.cellForTesting(itemIndex: 5)?.numberTextForTesting, "3")

        picker.tapSendForTesting()
        let sent = try await nextSend(hosted, count: 1)
        XCTAssertEqual(hosted.library.ids(of: sent.approved), ["r0", "r3", "r5"])
    }

    /// 拖到这一行的右端附近：整行自动往右滚，拿着的那张跟着往后排。
    @MainActor
    func testDragNearTheEndAutoScrollsTheRow() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        for index in [3, 0, 5, 9, 6] {
            picker.tapCheckForTesting(itemIndex: index)
        }
        picker.tapCountPillForTesting()
        let preview = picker.selectedViewForTesting
        preview.layoutIfNeeded()
        XCTAssertEqual(preview.rowLayoutForTesting?.isScrollable, true)

        let start = try XCTUnwrap(preview.cardCenterForTesting("r3"))
        XCTAssertTrue(preview.beginReorder(at: start))
        preview.moveReorder(to: CGPoint(x: preview.rowFrameForTesting.maxX - 10, y: start.y))
        for _ in 0..<120 {
            preview.autoScrollTick()
        }
        XCTAssertGreaterThan(preview.rowContentOffsetForTesting, 0, "整行往右滚了")
        XCTAssertEqual(preview.cardIdsForTesting.last, "r3", "拿着的那张一路排到最后")
        preview.endReorder()
        XCTAssertEqual(picker.selectedIdsForTesting.last, "r3")
    }

    /// 这一行松手吸附（AlbumCarouselGeometry：某一张的左边对齐起点）。
    @MainActor
    func testPreviewRowSnapsLikeTheChatAlbum() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        for index in [3, 0, 5, 9] {
            hosted.picker.tapCheckForTesting(itemIndex: index)
        }
        hosted.picker.tapCountPillForTesting()
        let preview = hosted.picker.selectedViewForTesting
        preview.layoutIfNeeded()
        let layout = try XCTUnwrap(preview.rowLayoutForTesting)

        XCTAssertEqual(preview.scrollViewWillEndDraggingForTesting(projectedOffset: layout.snapOffsets[1] + 30, velocity: 0), layout.snapOffsets[1])
        XCTAssertEqual(preview.scrollViewWillEndDraggingForTesting(projectedOffset: 10, velocity: 1), layout.snapOffsets[1], "往右甩至少走一格")
    }

    /// 在「只看已选」里点某张的勾：取消它，说明栏上面弹「已取消选择 N 张 · 撤销」；再取消一张数字累加；撤销把它们放回原来的位置。
    @MainActor
    func testDeselectInPreviewOffersUndo() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        for index in [3, 0, 5] {
            picker.tapCheckForTesting(itemIndex: index)
        }
        picker.tapCountPillForTesting()
        let preview = picker.selectedViewForTesting
        preview.layoutIfNeeded()

        preview.tapCheckForTesting("r0")
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r5"])
        XCTAssertEqual(picker.undoBarTextForTesting, "1 deselected")
        XCTAssertEqual(picker.undoBarFrameForTesting.maxY, picker.sendBarFrameForTesting.minY - 8, accuracy: 0.01, "在说明栏上面")

        preview.tapCheckForTesting("r5")
        XCTAssertEqual(picker.undoBarTextForTesting, "2 deselected")
        XCTAssertEqual(preview.cardIdsForTesting, ["r3"])
        XCTAssertEqual(preview.chipTextsForTesting, [], "只剩一张就不提示拖动")

        picker.tapUndoForTesting()
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r0", "r5"], "放回原来的位置")
        XCTAssertEqual(preview.cardIdsForTesting, ["r3", "r0", "r5"])
        let hidden = await waitUntil { picker.undoBarTextForTesting == nil }
        XCTAssertTrue(hidden)

        preview.tapCheckForTesting("r3")
        picker.expireUndoForTesting()
        picker.tapUndoForTesting()
        XCTAssertEqual(picker.selectedIdsForTesting, ["r0", "r5"], "过了时间就不能撤销")
    }

    /// 全部取消：自动回网格（撤销条还在，说明栏收起）；这时撤销，选中的回来、留在网格。
    @MainActor
    func testDeselectingEverythingReturnsToTheGrid() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 2)
        picker.tapCountPillForTesting()
        picker.selectedViewForTesting.layoutIfNeeded()

        picker.selectedViewForTesting.tapCheckForTesting("r2")
        XCTAssertEqual(picker.selectedIdsForTesting, [])
        let back = await waitUntil { picker.displayMode == .all }
        XCTAssertTrue(back, "全部取消自动回网格")
        XCTAssertEqual(picker.undoBarTextForTesting, "1 deselected")
        XCTAssertFalse(picker.isSendBarShownForTesting)

        picker.tapUndoForTesting()
        XCTAssertEqual(picker.selectedIdsForTesting, ["r2"])
        XCTAssertEqual(picker.displayMode, .all, "撤销后留在网格")
        XCTAssertTrue(picker.isCountPillShownForTesting)
    }

    /// 点卡片本身：进上游预览 / 编辑页，先看到点的那张（编辑页里仍是全部已选、顺序不变）；在那里取消，回到「只看已选」。
    @MainActor
    func testTapCardOpensTheUpstreamEditor() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 3)
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCountPillForTesting()
        picker.selectedViewForTesting.layoutIfNeeded()

        picker.selectedViewForTesting.tapCardForTesting("r0")
        let opened = await waitUntil { self.approvalViewController(over: picker) != nil }
        XCTAssertTrue(opened)
        let approval = try XCTUnwrap(approvalViewController(over: picker))
        XCTAssertTrue(
            approval.currentItem?.attachment.rawValue === hosted.library.attachmentsById["r0"]?.rawValue,
            "点的是第 2 张卡片 r0，进来先看到它",
        )
        XCTAssertEqual(approval.attachmentApprovalItems.count, 2, "编辑页里仍是全部已选，顺序不变")
        XCTAssertTrue(approval.attachmentApprovalItems.first?.attachment.rawValue === hosted.library.attachmentsById["r3"]?.rawValue)
        picker.attachmentApprovalDidCancel()
        let closed = await waitUntil { picker.presentedViewController == nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(picker.displayMode, .selected, "取消回到「只看已选」")
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r0"])
    }

    /// E-6：预览 / 编辑页里改过的照片，回到网格再进来编辑还在（同一个编辑项）；取消选中再选上也还在（同 Telegram 的编辑上下文）；
    /// 从网格直接发送时发的是改过的样子，没改过的照发原图。
    @MainActor
    func testEditsSurviveLeavingTheEditorAndAreSentFromTheGrid() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        let picker = hosted.picker
        picker.tapCheckForTesting(itemIndex: 3)
        picker.tapCheckForTesting(itemIndex: 0)

        let first = try await openEditor(picker, onCard: "r0")
        let edited = try XCTUnwrap(first.attachmentApprovalItems.last)
        XCTAssertTrue(edited.attachment.rawValue === hosted.library.attachmentsById["r0"]?.rawValue)
        let model = try XCTUnwrap(edited.imageEditorModel)
        let transform = model.currentTransform()
        model.replace(transform: ImageEditorTransform(
            outputSizePixels: transform.outputSizePixels,
            unitTranslation: transform.unitTranslation,
            rotationRadians: transform.rotationRadians,
            scaling: transform.scaling,
            isFlipped: !transform.isFlipped,
        ))
        XCTAssertTrue(model.isDirty)
        await closeEditor(picker)

        let second = try await openEditor(picker, onCard: "r0")
        XCTAssertTrue(second.attachmentApprovalItems.last === edited, "回到网格再进来，还是同一个编辑项，翻转还在")
        await closeEditor(picker)

        picker.tapCloseForTesting()
        XCTAssertEqual(picker.displayMode, .all)
        picker.tapCheckForTesting(itemIndex: 0)
        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertEqual(picker.selectedIdsForTesting, ["r3", "r0"])
        let third = try await openEditor(picker, onCard: "r0")
        XCTAssertTrue(third.attachmentApprovalItems.last === edited, "取消选中再选上，编辑还在")
        await closeEditor(picker)

        picker.tapCloseForTesting()
        picker.tapSendForTesting()
        let sent = try await nextSend(hosted, count: 1)
        XCTAssertEqual(hosted.library.ids(of: sent.approved), ["r3", "?"], "r3 没改，发原图；r0 改过，发重新画出来的那张")
    }

    /// V-4（owner 2026-10-13 定 O3，照 Telegram）：裁出的片段最短 1 秒；视频本身短于 1.5 秒不给裁。
    func testVideoTrimThresholdsFollowTelegram() {
        XCTAssertEqual(VideoEditorModel.minimumDurationSeconds, 1)
        XCTAssertFalse(VideoEditorModel.canTrim(untrimmedDurationSeconds: 1.0))
        XCTAssertFalse(VideoEditorModel.canTrim(untrimmedDurationSeconds: 1.49))
        XCTAssertTrue(VideoEditorModel.canTrim(untrimmedDurationSeconds: 1.5))
        XCTAssertTrue(VideoEditorModel.canTrim(untrimmedDurationSeconds: 75))
    }

    // MARK: - P-8 相机格

    /// 「最近」左上角是一格宽、两行高（含中间 1 的间距）的相机实时取景，其它格子绕开它排；换到别的相册就没有。
    @MainActor
    func testCameraCellSpansTwoRowsInRecents() async throws {
        let camera = FakeCamera(access: .authorized)
        let hosted = host(camera: camera)
        defer { hosted.tearDown() }
        let picker = hosted.picker

        let cameraFrame = try XCTUnwrap(picker.cameraFrameForTesting)
        let first = frame(of: 0, in: picker)
        XCTAssertEqual(cameraFrame.origin, .zero)
        XCTAssertEqual(cameraFrame.size.width, first.size.width, accuracy: 0.01, "一格宽")
        XCTAssertEqual(cameraFrame.size.height, first.size.height * 2 + 1, accuracy: 0.01, "两行高（含 1 的间距）")
        // 前两行的第 0 列让给相机：第 0、1 张在第一行第 1、2 列，第 2、3 张在第二行，第 4 张回到第三行第 0 列。
        XCTAssertEqual(first.minY, 0, accuracy: 0.01)
        XCTAssertGreaterThan(first.minX, cameraFrame.maxX)
        XCTAssertEqual(frame(of: 1, in: picker).minY, 0, accuracy: 0.01)
        XCTAssertEqual(frame(of: 2, in: picker).minY, first.maxY + 1, accuracy: 0.01)
        XCTAssertEqual(frame(of: 2, in: picker).minX, first.minX, accuracy: 0.01)
        XCTAssertEqual(frame(of: 4, in: picker).minX, 0, accuracy: 0.01)
        XCTAssertEqual(frame(of: 4, in: picker).minY, cameraFrame.maxY + 1, accuracy: 0.01)

        let cell = try XCTUnwrap(picker.cameraCellForTesting)
        XCTAssertTrue(cell.isShowingLivePreviewForTesting, "已授权：实时取景")
        XCTAssertTrue(cell.isShowingCornerIconForTesting, "右上角小相机图标")
        XCTAssertFalse(cell.isShowingPlaceholderForTesting)
        XCTAssertGreaterThanOrEqual(camera.starts, 1, "露出来就取景")

        let stopsBefore = camera.stops
        picker.switchAlbumForTesting(title: "Screenshots")
        picker.collectionViewForTesting.layoutIfNeeded()
        XCTAssertNil(picker.cameraFrameForTesting, "只在「最近」里")
        XCTAssertEqual(frame(of: 0, in: picker).origin, .zero)
        XCTAssertGreaterThan(camera.stops, stopsBefore, "看不见就停")

        let startsBefore = camera.starts
        picker.switchAlbumForTesting(title: "Recents")
        picker.collectionViewForTesting.layoutIfNeeded()
        XCTAssertNotNil(picker.cameraFrameForTesting)
        XCTAssertGreaterThan(camera.starts, startsBefore, "又露出来就重新取景")
    }

    /// 横屏 5 列：前两行每行 4 张在相机右边，第 8 张回到第三行第 0 列。
    @MainActor
    func testCameraCellInLandscape() async throws {
        let hosted = host(width: 874, height: 402, camera: FakeCamera(access: .authorized))
        defer { hosted.tearDown() }
        let picker = hosted.picker
        let cameraFrame = try XCTUnwrap(picker.cameraFrameForTesting)
        XCTAssertEqual(frame(of: 3, in: picker).minY, 0, accuracy: 0.01)
        XCTAssertEqual(frame(of: 4, in: picker).minX, frame(of: 0, in: picker).minX, accuracy: 0.01)
        XCTAssertEqual(frame(of: 8, in: picker).minX, 0, accuracy: 0.01)
        XCTAssertEqual(frame(of: 8, in: picker).minY, cameraFrame.maxY + 1, accuracy: 0.01)
    }

    /// 相机权限没问过：这一格只放相机图标，不取景；点了交给会话页去开相机（权限由上游相机流程问）。
    @MainActor
    func testCameraNotDeterminedShowsIconAndTapOpensCamera() async throws {
        let camera = FakeCamera(access: .notDetermined)
        let hosted = host(camera: camera)
        defer { hosted.tearDown() }
        let cell = try XCTUnwrap(hosted.picker.cameraCellForTesting)
        XCTAssertTrue(cell.isShowingPlaceholderForTesting)
        XCTAssertFalse(cell.isShowingLivePreviewForTesting)
        XCTAssertFalse(cell.isShowingCornerIconForTesting)

        cell.tapForTesting()
        XCTAssertEqual(hosted.delegate.cameraRequests, 1)
    }

    /// 没有相机或相机权限被拒：不挖这一格，第一张照片在左上角。
    @MainActor
    func testNoCameraCellWhenUnavailable() async throws {
        let hosted = host(camera: FakeCamera(access: .unavailable))
        defer { hosted.tearDown() }
        XCTAssertNil(hosted.picker.cameraFrameForTesting)
        XCTAssertNil(hosted.picker.cameraCellForTesting)
        XCTAssertEqual(frame(of: 0, in: hosted.picker).origin, .zero)
    }

    /// 有选中时点相机格：不问「丢弃媒体」，直接开相机（盖在面板上面，同 Telegram），已选不动；先停网格里的取景，相机关掉后接着取景。
    @MainActor
    func testCameraTapKeepsTheSelection() async throws {
        let camera = FakeCamera(access: .authorized)
        let hosted = host(camera: camera)
        defer { hosted.tearDown() }
        hosted.picker.tapCheckForTesting(itemIndex: 0)
        hosted.picker.tapCheckForTesting(itemIndex: 2)
        let startsBefore = camera.starts
        let stopsBefore = camera.stops
        try XCTUnwrap(hosted.picker.cameraCellForTesting).tapForTesting()

        XCTAssertEqual(hosted.delegate.cameraRequests, 1, "直接开相机")
        XCTAssertNil(hosted.picker.presentedViewController, "不先问「丢弃媒体」")
        XCTAssertEqual(hosted.picker.selectedIdsForTesting, ["r0", "r2"])
        XCTAssertEqual(camera.stops, stopsBefore + 1, "先停网格里的取景")

        hosted.picker.cameraDidClose()
        XCTAssertEqual(camera.starts, startsBefore + 1, "相机关掉后接着取景")
    }

    /// 相机格打开的相机（`TellomiPickerCameraRoute`）取消：只关相机这一层，选图面板还在、已选还在，面板接着取景。
    @MainActor
    func testCameraRouteCancelClosesOnlyTheCamera() async throws {
        let camera = FakeCamera(access: .authorized)
        let hosted = host(camera: camera, presentedFromRoot: true)
        defer { hosted.tearDown() }
        let root = try XCTUnwrap(hosted.window.rootViewController)
        XCTAssertTrue(root.presentedViewController === hosted.picker)
        let pickerOnScreen = await waitUntil { hosted.picker.view.window != nil && !hosted.picker.isBeingPresented }
        XCTAssertTrue(pickerOnScreen)
        hosted.picker.tapCheckForTesting(itemIndex: 1)

        let cameraScreen = UIViewController()
        hosted.picker.present(cameraScreen, animated: false)
        let cameraOnScreen = await waitUntil { hosted.picker.presentedViewController === cameraScreen && cameraScreen.view.window != nil }
        XCTAssertTrue(cameraOnScreen, "相机盖在面板上面")
        let startsBefore = camera.starts

        TellomiPickerCameraRoute(picker: hosted.picker, conversation: nil).closeCamera(cameraScreen)
        let closed = await waitUntil { hosted.picker.presentedViewController == nil }
        XCTAssertTrue(closed, "相机关了")
        XCTAssertTrue(root.presentedViewController === hosted.picker, "选图面板还在")
        XCTAssertEqual(hosted.picker.selectedIdsForTesting, ["r1"], "已选还在")
        let resumed = await waitUntil { camera.starts > startsBefore }
        XCTAssertTrue(resumed, "面板接着取景")
    }

    // MARK: - 截图

    @MainActor
    func testScreenshots() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时跑")
        let heights: [CGFloat: CGFloat] = [375: 812, 402: 874, 440: 956]
        for width in shotWidths {
            let height = heights[width] ?? 874

            let empty = host(width: width, height: height)
            try save(render(empty.window), name: "picker-1-empty.png", width: width)
            empty.tearDown()

            let selected = host(width: width, height: height, initialText: "今天的照片")
            for index in [3, 0, 5] {
                selected.picker.tapCheckForTesting(itemIndex: index)
            }
            try await settle()
            try save(render(selected.window), name: "picker-2-selected.png", width: width)
            selected.tearDown()

            let library = FakePhotoLibrary()
            library.isAccessLimited = true
            let limited = host(width: width, height: height, library: library)
            limited.picker.tapCheckForTesting(itemIndex: 1)
            try await settle()
            try save(render(limited.window), name: "picker-3-limited.png", width: width)
            limited.tearDown()

            let preview = host(width: width, height: height, initialText: "今天的照片", chatBackground: Self.shotChatBackground())
            for index in [3, 0, 5, 9] {
                preview.picker.tapCheckForTesting(itemIndex: index)
            }
            preview.picker.tapCountPillForTesting()
            try await settle()
            try save(render(preview.window), name: "picker-5-selected-preview.png", width: width)
            let view = preview.picker.selectedViewForTesting
            if let start = view.cardCenterForTesting("r3"), view.beginReorder(at: start) {
                view.moveReorder(to: CGPoint(x: start.x + 60, y: start.y + 24))
                try await settle()
                try save(render(preview.window), name: "picker-6-reordering.png", width: width)
                view.endReorder()
            }
            view.tapCheckForTesting("r0")
            try await settle()
            try save(render(preview.window), name: "picker-7-undo.png", width: width)
            preview.tearDown()

            let withCamera = host(width: width, height: height, camera: FakeCamera(access: .authorized))
            withCamera.picker.tapCheckForTesting(itemIndex: 1)
            try await settle()
            try save(render(withCamera.window), name: "picker-8-camera.png", width: width)
            withCamera.tearDown()

            // 键盘窗口按模拟器真实的屏幕排，这一张的窗口也用真实屏幕高（375 那台是 iPhone SE，667 高）。
            let screenSize = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first
            let emojiHeight = screenSize.map { $0.width == width ? $0.height : height } ?? height
            let emoji = host(width: width, height: emojiHeight, initialText: "今天的照片")
            emoji.window.makeKey()
            emoji.picker.tapCheckForTesting(itemIndex: 1)
            emoji.picker.tapCaptionEmojiButtonForTesting()
            try await settle()
            try save(renderScreen(over: emoji.window, keyboard: emoji.picker.captionEmojiKeyboardForTesting), name: "picker-9-emoji-keyboard.png", width: width)
            emoji.picker.endCaptionEditingForTesting()
            emoji.tearDown()

            let landscape = host(width: height, height: width)
            landscape.picker.tapCheckForTesting(itemIndex: 2)
            try await settle()
            try save(render(landscape.window), name: "picker-4-landscape.png", width: width)
            landscape.tearDown()
        }
    }

    // MARK: - Hosting

    private struct Hosted {
        let window: UIWindow
        let picker: TellomiPhotoPickerViewController
        let delegate: RecordingPickerDelegate
        let dataSource: FakeApprovalDataSource
        let library: FakePhotoLibrary

        func tearDown() {
            window.isHidden = true
        }
    }

    // MARK: - 附件 Sheet（#1115）

    /// dock = 相册 · 文件 · 位置 · 投票 · 联系人（owner 2026-09-23 定），GIF 开着时最后再加一格 GIF（owner 2026-09-26 定临时加回：
    /// 「+」改成 Sheet 后附件面板打不开了，面板上的 GIF 键是 iPhone 上唯一的 GIF 入口；表情面板 #1012 做好之前先放在 dock 里）。
    /// 「相册」选中；没选照片时在，选了让位给说明 + 发送，取消选择又回来。
    @MainActor
    func testDockShowsTheItemsAndGivesWayToTheSendBar() async throws {
        try setRemoteConfig(["global.gifSearch": "true"])
        XCTAssertTrue(RemoteConfig.current.isGifAvailable)
        let hosted = host(dockItems: TellomiAttachmentDockItem.attachmentSheetItems)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        let dock = try XCTUnwrap(picker.dockForTesting)
        XCTAssertEqual(dock.items.map(\.title), ["Gallery", "File", "Location", "Poll", "Contact", "GIF"])
        XCTAssertEqual(
            dock.items.map(\.imageName),
            ["album-tilt-28", "file-28", "location-28", "poll-28", "person-circle-28", "gif-28"],
            "图标都是 Signal 自己的（GIF 用上游附件面板 GIF 键那一个）",
        )
        XCTAssertEqual(dock.selectedItem, .gallery)
        XCTAssertTrue(picker.isDockShownForTesting)
        XCTAssertFalse(picker.isSendBarShownForTesting)
        XCTAssertGreaterThanOrEqual(picker.gridBottomInsetForTesting, TellomiAttachmentDock.height, "网格底部让出 dock")

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertFalse(picker.isDockShownForTesting, "选了照片：dock 让位")
        XCTAssertTrue(picker.isSendBarShownForTesting, "选了照片：说明 + 发送")

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertTrue(picker.isDockShownForTesting, "全部取消：dock 回来")
        XCTAssertFalse(picker.isSendBarShownForTesting)
    }

    /// G-6（照 Telegram `AttachmentPanel.update`）：选上第一张时 dock 淡出缩小（截图在动）、说明栏淡入；全部取消时 dock 淡入、说明栏淡出。
    @MainActor
    func testDockAndSendBarSwapIsAnimated() async throws {
        let hosted = host(dockItems: TellomiAttachmentDockItem.attachmentSheetItems)
        defer { hosted.tearDown() }
        let picker = hosted.picker
        // 截图要画过一次的视图（在 App 里 dock 一直在屏幕上）。
        try await settle()
        XCTAssertEqual(picker.bottomBarFadingOutCountForTesting, 0)

        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertFalse(picker.isDockShownForTesting)
        XCTAssertEqual(picker.bottomBarFadingOutCountForTesting, 1, "dock 的截图在淡出")
        XCTAssertTrue(picker.isSendBarFadingInForTesting, "说明栏在淡入")

        try await settle()
        XCTAssertEqual(picker.bottomBarFadingOutCountForTesting, 0, "淡出完了截图拿掉")
        picker.tapCheckForTesting(itemIndex: 0)
        XCTAssertTrue(picker.isDockShownForTesting)
        XCTAssertTrue(picker.isDockFadingInForTesting, "dock 在淡入")
        XCTAssertGreaterThanOrEqual(picker.bottomBarFadingOutCountForTesting, 1, "说明栏的截图在淡出")
    }

    /// GIF 关着（上游开关 `global.gifSearch` 关了，或者这个部署没有 GIF 源 `global.gif.provider = none`，大陆包）：dock 里没有 GIF，
    /// 同上游附件面板（`AttachmentFormatPickerView`，#1078 `isGifAvailable`）——入口一起关，包里才不会有连境外内容代理的地方。
    @MainActor
    func testDockHasNoGifWhenGifIsUnavailable() throws {
        for flags in [["global.gif.provider": "none"], ["global.gifSearch": "false"]] {
            try setRemoteConfig(flags)
            XCTAssertFalse(RemoteConfig.current.isGifAvailable, "\(flags)")
            let hosted = host(dockItems: TellomiAttachmentDockItem.attachmentSheetItems)
            defer { hosted.tearDown() }
            let dock = try XCTUnwrap(hosted.picker.dockForTesting)
            XCTAssertEqual(dock.items.map(\.title), ["Gallery", "File", "Location", "Poll", "Contact"], "\(flags)")
        }
    }

    /// 旧的整页打开（不是从「+」进来）没有 dock。
    @MainActor
    func testNoDockWithoutDockItems() {
        let picker = host().picker
        XCTAssertNil(picker.dockForTesting)
        XCTAssertFalse(picker.isDockShownForTesting)
    }

    /// 点「文件 / 位置 / 投票 / 联系人 / GIF」交给会话页（它先收起 Sheet 再打开对应页面，GIF 是上游的 GIF 选择器）；
    /// 点「相册」只是回到网格顶上，不交出去。
    @MainActor
    func testDockTapsReachTheDelegateExceptGallery() throws {
        try setRemoteConfig(["global.gifSearch": "true"])
        let hosted = host(dockItems: TellomiAttachmentDockItem.attachmentSheetItems)
        defer { hosted.tearDown() }
        let dock = try XCTUnwrap(hosted.picker.dockForTesting)
        for item in dock.items where item != .gallery {
            dock.tapForTesting(item)
        }
        dock.tapForTesting(.gallery)
        XCTAssertEqual(hosted.delegate.dockSelections.map(\.title), ["File", "Location", "Poll", "Contact", "GIF"])
    }

    /// 重复点「相册」：Sheet 从收起展开到全屏（同 Telegram 重复点当前格），不交给会话页。
    @MainActor
    func testRetappingGalleryExpandsTheSheet() async throws {
        guard #available(iOS 16, *) else {
            throw XCTSkip("自定义档位要 iOS 16")
        }
        let hosted = host(dockItems: TellomiAttachmentDockItem.allCases, asAttachmentSheet: true)
        try await settle()
        let sheet = try XCTUnwrap(hosted.picker.sheetPresentationController)
        XCTAssertEqual(sheet.selectedDetentIdentifier, ConversationViewController.attachmentSheetHalfDetent, "打开时停在收起那一档")
        try XCTUnwrap(hosted.picker.dockForTesting).tapForTesting(.gallery)
        XCTAssertEqual(sheet.selectedDetentIdentifier, .large)
        XCTAssertTrue(hosted.delegate.dockSelections.isEmpty)
        hosted.window.isHidden = true
    }

    /// 拒绝了照片权限：Sheet 照样能用，网格换成一句去「设置」的说明（上游同一句）+「照片」（系统选择器，见下一条）「设置」「相机」
    /// （设置、相机照 Telegram 的占位）；相机格不在网格里（说明不压在它上面）；没有相机就没有「相机」；有权限时不出现。
    @MainActor
    func testNoPhotoAccessShowsTheSettingsHint() async throws {
        let denied = FakePhotoLibrary()
        denied.isAccessDenied = true
        let photos = OWSLocalizedString("ATTACHMENT_KEYBOARD_PHOTOS", comment: "")
        let hosted = host(library: denied, camera: FakeCamera(access: .authorized), dockItems: TellomiAttachmentDockItem.allCases)
        try await settle()
        let picker = hosted.picker
        XCTAssertTrue(picker.isNoAccessHintShownForTesting)
        XCTAssertTrue(picker.isNoAccessIllustrationShownForTesting, "说明上面有插画（G-1，照 Telegram 两端的占位）")
        XCTAssertEqual(picker.noAccessHintTextForTesting, OWSLocalizedString("ATTACHMENT_KEYBOARD_NO_PHOTO_ACCESS", comment: ""))
        XCTAssertEqual(picker.noAccessButtonTitlesForTesting, [photos, CommonStrings.openSystemSettingsButton, OWSLocalizedString("CAMERA_BUTTON_LABEL", comment: "")])
        XCTAssertNil(picker.cameraFrameForTesting, "相机格不在网格里")
        picker.tapNoAccessCameraForTesting()
        XCTAssertEqual(hosted.delegate.cameraRequests, 1, "占位里的「相机」走相机格同一条路")
        XCTAssertTrue(picker.isDockShownForTesting, "没权限也能用 dock 的别的格子")
        hosted.window.isHidden = true

        XCTAssertEqual(host(library: denied, dockItems: TellomiAttachmentDockItem.allCases).picker.noAccessButtonTitlesForTesting, [photos, CommonStrings.openSystemSettingsButton])
        XCTAssertFalse(host(dockItems: TellomiAttachmentDockItem.allCases).picker.isNoAccessHintShownForTesting)
    }

    /// 拒绝了照片权限，占位里照样有「照片」（上游附件面板上打开整个相册的那个键，同一个词）：点了交给会话页，
    /// 由它收起 Sheet 再弹上游的系统选择器——不要照片权限就能选、能发（系统选择器取消了回到 Sheet）。
    /// 已发布的《系统权限调用清单》（TLM-LEGAL-PERMISSIONS-CN 1.0.2 §7.2）写的是：「如果您拒绝照片读取权限，附件面板仍然提供
    /// “全部相册”入口，通过系统选择器完成选择与发送，不需要该权限」。有没有相机都在。
    @MainActor
    func testNoPhotoAccessStillOffersTheSystemPicker() async throws {
        let denied = FakePhotoLibrary()
        denied.isAccessDenied = true
        let photos = OWSLocalizedString("ATTACHMENT_KEYBOARD_PHOTOS", comment: "")
        XCTAssertEqual(photos, "Photos")
        let cameras: [TellomiPhotoPickerCamera?] = [FakeCamera(access: .authorized), nil]
        for camera in cameras {
            let hosted = host(library: denied, camera: camera, dockItems: TellomiAttachmentDockItem.attachmentSheetItems)
            defer { hosted.tearDown() }
            try await settle()
            XCTAssertTrue(hosted.picker.isNoAccessHintShownForTesting)
            XCTAssertEqual(hosted.picker.noAccessButtonTitlesForTesting.first, photos, "占位里第一个就是「照片」（有相机：\(camera != nil)）")
            hosted.picker.tapNoAccessButtonForTesting(title: photos)
            XCTAssertEqual(hosted.delegate.systemPickerRequests, 1, "交给会话页开系统选择器（有相机：\(camera != nil)）")
            XCTAssertEqual(hosted.delegate.cameraRequests, 0)
            XCTAssertTrue(hosted.delegate.dockSelections.isEmpty)
        }
    }

    /// 附件 Sheet 两档：先停在半屏（聊天露在上面、变暗），往上拖到全屏；网格滚到顶再往上拖就展开。
    @MainActor
    func testAttachmentSheetHasHalfAndLargeDetents() throws {
        guard #available(iOS 16, *) else {
            throw XCTSkip("自定义档位要 iOS 16（iOS 15 是系统的半屏 / 全屏）")
        }
        let viewController = UIViewController()
        viewController.modalPresentationStyle = .pageSheet
        let sheet = try XCTUnwrap(viewController.sheetPresentationController)
        ConversationViewController.configureAttachmentSheet(sheet)
        XCTAssertEqual(sheet.detents.map(\.identifier), [ConversationViewController.attachmentSheetHalfDetent, .large])
        XCTAssertEqual(sheet.selectedDetentIdentifier, ConversationViewController.attachmentSheetHalfDetent)
        let collapsed = try XCTUnwrap(sheet.detents.first?.resolvedValue(in: FakeDetentContext(maximumDetentValue: 800)))
        XCTAssertEqual(collapsed, 584, accuracy: 0.5, "收起时是全屏高度的 73%（Telegram iOS 顶边低 0.2488）")
        XCTAssertTrue(sheet.prefersScrollingExpandsWhenScrolledToEdge)
        XCTAssertNil(sheet.largestUndimmedDetentIdentifier, "两档都把聊天压暗")
    }

    /// 截图（TELLOMI_SHOTS=1）：附件 Sheet 半屏、选了两张（dock 换成说明 + 发送）、全屏、没有照片权限。
    /// 窗口接在模拟器真实的屏幕上（dock 离底部的距离要算上安全区），所以每台只截自己那个屏宽；同真机，网格第一格是相机。
    @MainActor
    func testAttachmentSheetScreenshots() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let screenSize = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first)
        for width in shotWidths where width == screenSize.width {
            let height = screenSize.height
            let hosted = host(width: width, height: height, camera: FakeCamera(access: .authorized), dockItems: TellomiAttachmentDockItem.allCases, asAttachmentSheet: true)
            try await settle()
            try save(render(hosted.window), name: "attach-sheet-half.png", width: width)

            hosted.picker.tapCheckForTesting(itemIndex: 1)
            hosted.picker.tapCheckForTesting(itemIndex: 3)
            try await settle()
            try save(render(hosted.window), name: "attach-sheet-selected.png", width: width)

            hosted.picker.sheetPresentationController?.animateChanges {
                hosted.picker.sheetPresentationController?.selectedDetentIdentifier = .large
            }
            try await settle()
            try save(render(hosted.window), name: "attach-sheet-large.png", width: width)
            hosted.window.isHidden = true

            let denied = FakePhotoLibrary()
            denied.isAccessDenied = true
            let deniedHost = host(width: width, height: height, library: denied, camera: FakeCamera(access: .authorized), dockItems: TellomiAttachmentDockItem.allCases, asAttachmentSheet: true)
            try await settle()
            try save(render(deniedHost.window), name: "attach-sheet-no-access.png", width: width)
            deniedHost.window.isHidden = true
        }
    }

    /// 截图（TELLOMI_SHOTS=1）：长按发送的预览（#1519 M-5）——三张 + 说明在下、切到上面之后；再点「定时发送」的选时间（M-4）。
    /// 窗口接在真实屏幕上（要安全区）。
    @MainActor
    func testSendPreviewScreenshots() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let screenSize = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first)
        for width in shotWidths where width == screenSize.width {
            // 会话的气泡颜色（这里用绿色，和发送键的强调色分得开）
            let hosted = host(width: width, height: screenSize.height, canSendAsFile: true, bubbleColor: .solidColor(color: UIColor(red: 0.23, green: 0.47, blue: 0.27, alpha: 1)), dockItems: TellomiAttachmentDockItem.attachmentSheetItems, asAttachmentSheet: true)
            for index in [0, 2, 3] {
                hosted.picker.tapCheckForTesting(itemIndex: index)
            }
            hosted.picker.typeCaptionForTesting("Trip to the coast")
            try await settle()
            hosted.picker.longPressSendForTesting()
            let preview = try await presentedPreview(hosted.picker)
            try await settle()
            XCTAssertTrue(preview.bubbleColorFillsTheBubbleForTesting)
            try save(render(hosted.window), name: "send-preview-caption-below.png", width: width)
            preview.performActionForTesting(at: 0)
            try await settle()
            try save(render(hosted.window), name: "send-preview-caption-above.png", width: width)
            // M-4：菜单里的「定时发送」→ 底部弹出选时间。
            preview.performActionForTesting(at: preview.actionTitlesForTesting.count - 1)
            let sheet = try await presentedScheduleSheet(over: hosted.picker)
            try await settle()
            try save(render(hosted.window), name: "schedule-time-sheet.png", width: width)
            sheet.dismiss(animated: false)
            _ = await waitUntil { sheet.presentingViewController == nil }
            hosted.window.isHidden = true
        }
    }

    @MainActor
    private func host(
        width: CGFloat = 402,
        height: CGFloat = 874,
        library: FakePhotoLibrary = FakePhotoLibrary(),
        defaultImageQuality: ImageQuality = .standard,
        canSendSeparately: Bool = true,
        canSendAsFile: Bool = false,
        isNoteToSelf: Bool = false,
        maxSelection: Int = 32,
        initialText: String? = nil,
        chatBackground: UIView? = nil,
        bubbleColor: ColorOrGradientValue? = nil,
        camera: TellomiPhotoPickerCamera? = nil,
        presentedFromRoot: Bool = false,
        dockItems: [TellomiAttachmentDockItem] = [],
        asAttachmentSheet: Bool = false,
    ) -> Hosted {
        let delegate = RecordingPickerDelegate()
        let dataSource = FakeApprovalDataSource()
        let picker = TellomiPhotoPickerViewController(
            library: library,
            initialMessageBody: initialText.map { MessageBody(text: $0, ranges: .empty) },
            defaultImageQuality: defaultImageQuality,
            canSendSeparately: canSendSeparately,
            canSendAsFile: canSendAsFile,
            isNoteToSelf: isNoteToSelf,
            hasQuotedReplyDraft: false,
            attachmentLimits: .currentLimits(),
            approvalDataSource: dataSource,
            stickerSheetDelegate: nil,
            chatBackground: chatBackground,
            bubbleColor: bubbleColor,
            camera: camera,
            maxSelection: maxSelection,
            dockItems: dockItems,
        )
        picker.delegate = delegate
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window: UIWindow
        if asAttachmentSheet, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            // 附件 Sheet 的窗口接到真实屏幕上：安全区（底部横条）要算进 dock 的位置。
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.backgroundColor = .Signal.background
        if asAttachmentSheet {
            // 同真机（#1115）：会话页把选图面板当附件 Sheet 弹出来，聊天在后面。
            let root = UIViewController()
            root.view.addSubview(Self.shotChatBackground())
            root.view.subviews.first?.autoPinEdgesToSuperviewEdges()
            window.rootViewController = root
            window.isHidden = false
            picker.modalPresentationStyle = .pageSheet
            if let sheet = picker.sheetPresentationController {
                ConversationViewController.configureAttachmentSheet(sheet)
            }
            root.present(picker, animated: false)
        } else if presentedFromRoot {
            // 同真机：会话页把选图面板弹出来。
            let root = UIViewController()
            window.rootViewController = root
            window.isHidden = false
            picker.modalPresentationStyle = .fullScreen
            root.present(picker, animated: false)
        } else {
            window.rootViewController = picker
            window.isHidden = false
        }
        window.layoutIfNeeded()
        picker.view.layoutIfNeeded()
        picker.collectionViewForTesting.layoutIfNeeded()
        return Hosted(window: window, picker: picker, delegate: delegate, dataSource: dataSource, library: library)
    }

    /// 截图用的「聊天背景」：一张浅色渐变（真机上是会话的壁纸）。
    @MainActor
    private static func shotChatBackground() -> UIView {
        let view = UIView()
        let gradient = CAGradientLayer()
        gradient.colors = [UIColor(rgbHex: 0xDCE8F5).cgColor, UIColor(rgbHex: 0xF3E7F0).cgColor]
        gradient.frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        view.layer.addSublayer(gradient)
        return view
    }

    @MainActor
    private func frame(of item: Int, in picker: TellomiPhotoPickerViewController) -> CGRect {
        picker.collectionViewForTesting.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame ?? .null
    }

    @MainActor
    private func center(of item: Int, in picker: TellomiPhotoPickerViewController) -> CGPoint {
        let frame = frame(of: item, in: picker)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    @MainActor
    private func albumViewer(over picker: TellomiPhotoPickerViewController) -> TellomiPhotoPickerAlbumViewer? {
        picker.presentedViewController as? TellomiPhotoPickerAlbumViewer
    }

    @MainActor
    private func approvalViewController(over picker: TellomiPhotoPickerViewController) -> AttachmentApprovalViewController? {
        (picker.presentedViewController as? UINavigationController)?.viewControllers.first as? AttachmentApprovalViewController
    }

    /// 从「只看已选」点卡片进上游的预览 / 编辑页。
    @MainActor
    private func openEditor(_ picker: TellomiPhotoPickerViewController, onCard itemId: String) async throws -> AttachmentApprovalViewController {
        if picker.displayMode != .selected {
            picker.tapCountPillForTesting()
        }
        picker.selectedViewForTesting.layoutIfNeeded()
        picker.selectedViewForTesting.tapCardForTesting(itemId)
        let opened = await waitUntil { self.approvalViewController(over: picker) != nil }
        XCTAssertTrue(opened)
        return try XCTUnwrap(approvalViewController(over: picker))
    }

    /// 盖在最上面的「定时发送」选时间页。
    @MainActor
    private func presentedScheduleSheet(over picker: TellomiPhotoPickerViewController) async throws -> TellomiScheduleTimeSheet {
        func topmost() -> UIViewController? {
            var top: UIViewController? = picker
            while let presented = top?.presentedViewController {
                top = presented
            }
            return top
        }
        let shown = await waitUntil {
            guard let sheet = topmost() as? TellomiScheduleTimeSheet else { return false }
            return sheet.viewIfLoaded?.window != nil && !sheet.isBeingPresented
        }
        XCTAssertTrue(shown, "弹出选时间")
        return try XCTUnwrap(topmost() as? TellomiScheduleTimeSheet)
    }

    @MainActor
    private func presentedPreview(_ picker: TellomiPhotoPickerViewController) async throws -> TellomiSendPreviewViewController {
        let shown = await waitUntil { picker.sendPreviewForTesting?.viewIfLoaded?.window != nil }
        XCTAssertTrue(shown, "长按发送弹出预览")
        let preview = try XCTUnwrap(picker.sendPreviewForTesting)
        preview.view.layoutIfNeeded()
        return preview
    }

    @MainActor
    private func closeEditor(_ picker: TellomiPhotoPickerViewController) async {
        picker.attachmentApprovalDidCancel()
        let closed = await waitUntil { picker.presentedViewController == nil }
        XCTAssertTrue(closed)
    }

    @MainActor
    private func nextSend(_ hosted: Hosted, count: Int) async throws -> RecordingPickerDelegate.Sent {
        let arrived = await waitUntil { hosted.delegate.sent.count >= count }
        XCTAssertTrue(arrived, "发送交给了会话页")
        return try XCTUnwrap(hosted.delegate.sent.last)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    @MainActor
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    /// 换掉 `RemoteConfig.current`（会话页按它决定 dock 里有没有 GIF，#1078 `isGifAvailable`）；每条用例重建环境，不串到别的用例。
    private func setRemoteConfig(_ valueFlags: [String: String]) throws {
        let manager = try XCTUnwrap(SSKEnvironment.shared.remoteConfigManagerRef as? StubbableRemoteConfigManager)
        manager._currentConfig = RemoteConfig(clockSkew: 0, valueFlags: valueFlags)
    }

    private func toastTexts(in view: UIView) -> [String] {
        var texts = [String]()
        if let toast = view as? ToastView, let text = toast.text {
            texts.append(text)
        }
        for subview in view.subviews {
            texts += toastTexts(in: subview)
        }
        return texts
    }

    // MARK: - Screenshots

    private var shotWidths: [CGFloat] {
        let raw = ProcessInfo.processInfo.environment["TELLOMI_SHOT_WIDTHS"] ?? "402,440,375"
        return raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { CGFloat($0) }
    }

    @MainActor
    private func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// 连同键盘一起拍：键盘在另外的窗口里（表情键盘在 UIRemoteKeyboardWindow，它不在 scene 的 windows 里），
    /// 按层级把测试窗口、它上面的窗口和键盘所在的窗口都画上（测试窗口盖住宿主 App 的窗口）。
    @MainActor
    private func renderScreen(over window: UIWindow, keyboard: UIView?) -> UIImage {
        var windows = (window.windowScene?.windows ?? [window])
            .filter { !$0.isHidden && ($0 === window || $0.windowLevel > window.windowLevel) }
        if let keyboardWindow = keyboard?.window, !windows.contains(where: { $0 === keyboardWindow }) {
            windows.append(keyboardWindow)
        }
        windows.sort { $0.windowLevel < $1.windowLevel }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            for each in windows {
                each.drawHierarchy(in: each.frame, afterScreenUpdates: true)
            }
        }
    }

    private func save(_ image: UIImage, name: String, width: CGFloat) throws {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }
}

// MARK: - Fakes

/// 内存里的相册：「最近」24 项（第 2、8 项是视频，第 3 项是实况照片），「Screenshots」3 项；缩略图是纯色块。
private final class FakePhotoLibrary: TellomiPhotoPickerLibrary {
    var isAccessLimited = false
    var isAccessDenied = false
    var onChange: (() -> Void)?

    let recents: [TellomiPhotoPickerItem]
    let screenshots: [TellomiPhotoPickerItem]

    /// 各种比例轮着来：横 4:3、竖 3:4、方、宽 16:9、窄 9:16、3:2。
    static let pixelSizes = [
        CGSize(width: 4032, height: 3024),
        CGSize(width: 3024, height: 4032),
        CGSize(width: 2000, height: 2000),
        CGSize(width: 1920, height: 1080),
        CGSize(width: 1080, height: 1920),
        CGSize(width: 3000, height: 2000),
    ]

    /// 交出去的附件，按网格里的 id（用来核对发送顺序）。
    private(set) var attachmentsById = [String: PreviewableAttachment]()

    init() {
        recents = (0..<24).map { index in
            TellomiPhotoPickerItem(
                id: "r\(index)",
                isVideo: index == 1 || index == 7,
                duration: index == 1 ? 75 : 3_725,
                isLivePhoto: index == 2,
                isAnimatedImage: index == 5,
                pixelSize: Self.pixelSizes[index % Self.pixelSizes.count],
                asset: nil,
            )
        }
        screenshots = (0..<3).map { index in
            TellomiPhotoPickerItem(id: "s\(index)", isVideo: false, duration: 0, isLivePhoto: false, isAnimatedImage: false, pixelSize: CGSize(width: 1170, height: 2532), asset: nil)
        }
    }

    func albums() -> [TellomiPhotoPickerAlbum] {
        // 拒绝了照片权限：同系统相册，「最近」是空的，别的相簿一个都没有。
        guard !isAccessDenied else {
            return [TellomiPhotoPickerAlbum(id: "recents", title: TellomiSystemPhotoLibrary.recentsTitle, count: 0, isRecents: true)]
        }
        return [
            TellomiPhotoPickerAlbum(id: "recents", title: TellomiSystemPhotoLibrary.recentsTitle, count: recents.count, isRecents: true),
            TellomiPhotoPickerAlbum(id: "screenshots", title: "Screenshots", count: screenshots.count, isRecents: false),
        ]
    }

    private func items(in album: TellomiPhotoPickerAlbum) -> [TellomiPhotoPickerItem] {
        guard !isAccessDenied else { return [] }
        return album.id == "screenshots" ? screenshots : recents
    }

    func itemCount(in album: TellomiPhotoPickerAlbum) -> Int {
        items(in: album).count
    }

    func item(at index: Int, in album: TellomiPhotoPickerAlbum) -> TellomiPhotoPickerItem {
        items(in: album)[index]
    }

    private struct NoopRequest: TellomiPhotoPickerRequest {
        func cancel() {}
    }

    func requestThumbnail(for item: TellomiPhotoPickerItem, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) -> TellomiPhotoPickerRequest {
        completion(image(for: item, size: CGSize(width: 90, height: 90)))
        return NoopRequest()
    }

    /// 查看器取图时交出来的进度回调，按 id（G-3：测试里自己报 iCloud 下载进度）。
    private(set) var viewerProgress = [String: (Double) -> Void]()

    func requestViewerImage(
        for item: TellomiPhotoPickerItem,
        targetSize: CGSize,
        progress: @escaping (Double) -> Void,
        completion: @escaping (UIImage?) -> Void,
    ) -> TellomiPhotoPickerRequest {
        viewerProgress[item.id] = progress
        return requestThumbnail(for: item, targetSize: targetSize, completion: completion)
    }

    private func color(for item: TellomiPhotoPickerItem) -> UIColor {
        let index = Int(item.id.dropFirst()) ?? 0
        if item.id.hasPrefix("s") {
            return UIColor(white: 0.25 + 0.2 * CGFloat(index), alpha: 1)
        }
        return UIColor(hue: CGFloat(index % 12) / 12, saturation: 0.5, brightness: 0.85, alpha: 1)
    }

    private func image(for item: TellomiPhotoPickerItem, size: CGSize) -> UIImage {
        let color = color(for: item)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.3).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: size.width * 0.3, y: size.height * 0.3, width: size.width * 0.4, height: size.height * 0.4))
        }
    }

    func attachment(for item: TellomiPhotoPickerItem, attachmentLimits: OutgoingAttachmentLimits) async throws -> PreviewableAttachment {
        let data = try XCTUnwrap(image(for: item, size: CGSize(width: 64, height: 48)).jpegData(compressionQuality: 0.8))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: url)
        let attachment = try PreviewableAttachment.imageAttachment(
            dataSource: DataSourcePath(fileUrl: url, ownership: .owned),
            dataUTI: UTType.jpeg.identifier,
        )
        attachmentsById[item.id] = attachment
        return attachment
    }

    /// #1263：哪几项是 HEIC；按文件发时交出去的（含 HEIC 选择），文件名 IMG_<id>.JPG / .HEIC。
    var heicIds = Set<String>()
    private(set) var fileRequests = [(id: String, convertHeicToJpeg: Bool)]()
    var tooLargeIds = Set<String>()

    func isHeic(_ item: TellomiPhotoPickerItem) -> Bool { heicIds.contains(item.id) }

    func originalFileName(for item: TellomiPhotoPickerItem) -> String? {
        "IMG_\(item.id).\(heicIds.contains(item.id) ? "HEIC" : "JPG")"
    }

    func fileAttachment(for item: TellomiPhotoPickerItem, convertHeicToJpeg: Bool, attachmentLimits: OutgoingAttachmentLimits) async throws -> TellomiPhotoPickerFile {
        fileRequests.append((item.id, convertHeicToJpeg))
        let converted = heicIds.contains(item.id) && convertHeicToJpeg
        let fileName = converted ? "IMG_\(item.id).JPG" : (originalFileName(for: item) ?? "")
        if tooLargeIds.contains(item.id) {
            return .tooLarge(fileName: fileName)
        }
        let data = try XCTUnwrap(image(for: item, size: CGSize(width: 64, height: 48)).jpegData(compressionQuality: 0.8))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: url)
        let dataSource = DataSourcePath(fileUrl: url, ownership: .owned)
        dataSource.sourceFilename = fileName
        let attachment = try PreviewableAttachment.tellomiAsFileAttachment(dataSource: dataSource, dataUTI: UTType.jpeg.identifier, attachmentLimits: attachmentLimits)
        attachmentsById[item.id] = attachment
        return .attachment(attachment)
    }

    func ids(of approved: ApprovedAttachments) -> [String] {
        approved.attachments.map { attachment in
            attachmentsById.first { $0.value.rawValue === attachment.rawValue }?.key ?? "?"
        }
    }
}

private final class RecordingPickerDelegate: TellomiPhotoPickerDelegate {
    struct Sent {
        let approved: ApprovedAttachments
        let body: MessageBody?
        let separately: Bool
        var captionAboveMedia = false
        var scheduledAt: Date?
    }

    var cancels = 0
    var cameraRequests = 0
    var systemPickerRequests = 0
    var sent = [Sent]()
    var bodies = [MessageBody?]()
    var dockSelections = [TellomiAttachmentDockItem]()

    func photoPicker(_ picker: TellomiPhotoPickerViewController, didSelectDockItem item: TellomiAttachmentDockItem) {
        dockSelections.append(item)
    }

    func photoPickerDidRequestSystemPicker(_ picker: TellomiPhotoPickerViewController) {
        systemPickerRequests += 1
    }

    func photoPickerDidCancel(_ picker: TellomiPhotoPickerViewController) {
        cancels += 1
    }

    func photoPickerDidRequestCamera(_ picker: TellomiPhotoPickerViewController) {
        cameraRequests += 1
    }

    func photoPicker(_ picker: TellomiPhotoPickerViewController, send approvedAttachments: ApprovedAttachments, messageBody: MessageBody?, separately: Bool, captionAboveMedia: Bool, scheduledAt: Date?) {
        sent.append(Sent(approved: approvedAttachments, body: messageBody, separately: separately, captionAboveMedia: captionAboveMedia, scheduledAt: scheduledAt))
    }

    func photoPicker(_ picker: TellomiPhotoPickerViewController, didChangeMessageBody messageBody: MessageBody?) {
        bodies.append(messageBody)
    }

    var scheduledMessageCapacity = 100

    func photoPickerScheduledMessageCapacity(_ picker: TellomiPhotoPickerViewController) -> Int {
        scheduledMessageCapacity
    }
}

/// 假相机：记下起停次数；「取景」是一块深色渐变（截图用）。
/// 算自定义档位的高度用：只给最大高度。
@available(iOS 16, *)
@MainActor
private final class FakeDetentContext: NSObject, UISheetPresentationControllerDetentResolutionContext {
    let containerTraitCollection = UITraitCollection()
    let maximumDetentValue: CGFloat

    init(maximumDetentValue: CGFloat) {
        self.maximumDetentValue = maximumDetentValue
    }
}

private final class FakeCamera: TellomiPhotoPickerCamera {
    let access: TellomiPhotoPickerCameraAccess
    var starts = 0
    var stops = 0

    init(access: TellomiPhotoPickerCameraAccess) {
        self.access = access
    }

    func makePreviewView() -> UIView {
        let view = UIView()
        let gradient = CAGradientLayer()
        gradient.colors = [UIColor(rgbHex: 0x3A4F63).cgColor, UIColor(rgbHex: 0x14202B).cgColor]
        gradient.frame = CGRect(x: 0, y: 0, width: 600, height: 1200)
        view.layer.addSublayer(gradient)
        view.clipsToBounds = true
        return view
    }

    func startPreview() {
        starts += 1
    }

    func stopPreview() {
        stops += 1
    }
}

private final class FakeApprovalDataSource: AttachmentApprovalViewControllerDataSource {
    var attachmentApprovalTextInputContextIdentifier: String? { nil }
    var attachmentApprovalRecipientNames: [String] { ["Alice"] }

    func attachmentApprovalMentionableAcis(tx: DBReadTransaction) -> [Aci] { [] }

    func attachmentApprovalMentionCacheInvalidationKey() -> String { "tellomi-photo-picker-tests" }
}
