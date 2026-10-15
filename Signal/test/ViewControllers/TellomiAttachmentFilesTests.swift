//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import GRDB
import LibSignalClient
import PDFKit
import XCTest
@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1121，需求 `attachment-files-location.md` §二 F-1…F-10）：附件 Sheet 的「文件」页。
///
/// 截图只在 `TELLOMI_SHOTS=1` 时拍：每台模拟器截自己的屏宽，写到 `TELLOMI_SHOTS_DIR/<屏宽>/files-*.png`。
final class TellomiAttachmentFilesTests: SignalBaseTest {

    // MARK: - Data (F-6)

    /// 只列我发出的文件类附件、新的在前；同一个文件发两次只留最新那次；收到的、图片、一次性查看都不算；本机没有的标出来。
    func testRecentFilesAreMySentFilesNewestFirstDedupedByContent() throws {
        let db = InMemoryDB()
        let thread = insertThread(db)
        let outgoing1 = insertMessage(db, thread: thread, recordType: .outgoingMessage)
        let outgoing2 = insertMessage(db, thread: thread, recordType: .outgoingMessage)
        let incoming = insertMessage(db, thread: thread, recordType: .incomingMessage)

        let contract = insertAttachment(db, record: .mockStream(mimeType: "application/pdf"))
        addReference(db, attachment: contract, message: outgoing1, thread: thread, at: 100, name: "合同.pdf")
        addReference(db, attachment: contract, message: outgoing2, thread: thread, at: 300, name: "合同.pdf")
        let archive = insertAttachment(db, record: .mockStream(mimeType: "application/zip"))
        addReference(db, attachment: archive, message: outgoing1, thread: thread, at: 200, name: "照片.zip", order: 1)
        let photo = insertAttachment(db, record: .mockStream(mimeType: "image/jpeg"))
        addReference(db, attachment: photo, message: outgoing1, thread: thread, at: 250, name: "p.jpg", order: 2)
        let theirs = insertAttachment(db, record: .mockStream(mimeType: "application/pdf"))
        addReference(db, attachment: theirs, message: incoming, thread: thread, at: 400, name: "别人的.pdf")
        let secret = insertAttachment(db, record: .mockStream(mimeType: "application/pdf"))
        addReference(db, attachment: secret, message: outgoing2, thread: thread, at: 350, name: "一次性.pdf", order: 1, isViewOnce: true)
        let gone = insertAttachment(db, record: .mockPointer(mimeType: "text/plain"))
        addReference(db, attachment: gone, message: outgoing2, thread: thread, at: 150, name: "旧.txt", order: 2)

        let files = db.read { tx in TellomiRecentFilesDatabaseSource.fetch(limit: 100, tx: tx) }

        XCTAssertEqual(files.map(\.fileName), ["合同.pdf", "照片.zip", "旧.txt"])
        XCTAssertEqual(files.map(\.isOnDevice), [true, true, false])
        XCTAssertEqual(files.first?.sentAt, Date(millisecondsSince1970: 300), "同一个文件发两次，留最新那次")
        XCTAssertEqual(files.first?.messageRowId, outgoing2)
        XCTAssertEqual(Set(files.map(\.id)).count, files.count)
    }

    func testRecentFilesRespectTheLimit() throws {
        let db = InMemoryDB()
        let thread = insertThread(db)
        let message = insertMessage(db, thread: thread, recordType: .outgoingMessage)
        for index in 0..<5 {
            let file = insertAttachment(db, record: .mockStream(mimeType: "application/pdf"))
            addReference(db, attachment: file, message: message, thread: thread, at: UInt64(100 + index), name: "\(index).pdf", order: UInt32(index))
        }

        let files = db.read { tx in TellomiRecentFilesDatabaseSource.fetch(limit: 3, tx: tx) }

        XCTAssertEqual(files.map(\.fileName), ["4.pdf", "3.pdf", "2.pdf"])
    }

    func testNamelessFileGetsTheDefaultNameWithAnExtension() {
        XCTAssertEqual(TellomiRecentFilesDatabaseSource.displayName(sourceFilename: " 报价.xlsx ", mimeType: nil), "报价.xlsx")
        let fallback = TellomiRecentFilesDatabaseSource.displayName(sourceFilename: nil, mimeType: "application/pdf")
        XCTAssertTrue(fallback.hasSuffix(".pdf"), fallback)
    }

    // MARK: - Page (F-2, F-6…F-10)

    @MainActor
    func testEntryRowsFollowScanAvailability() {
        XCTAssertEqual(host(files: [], canScan: true).page.entriesForTesting, [.gallery, .files, .scan])
        XCTAssertEqual(host(files: [], canScan: false).page.entriesForTesting, [.gallery, .files], "不能扫描的设备（模拟器、没相机的 iPad）不显示「扫描文件」")
    }

    /// F-9：一条都没发过时是一句说明，上限是服务端下发的那个值（这里传进去的字）。
    @MainActor
    func testEmptyStateShowsTheServerLimit() {
        let hosted = host(files: [])
        let footer = hosted.page.footerTextForTesting() ?? ""
        XCTAssertTrue(footer.contains("97.5 MB"), footer)
        XCTAssertFalse(hosted.page.isSearchButtonShownForTesting)
        XCTAssertEqual(hosted.page.tableViewForTesting.numberOfRows(inSection: 1), 0)
    }

    /// owner 2026-09-28：一条都没有时连「最近发送的文件」标题都不显示，看起来像没这个功能 → 标题常驻，
    /// 空的时候标题下面是插画 + 说明（照 Telegram `AttachmentFileEmptyItem` 的空状态：图 + 一句话，独立实现）。
    @MainActor
    func testRecentHeaderStaysAndEmptyStateHasAnIllustration() throws {
        let recentHeader = OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_RECENT_HEADER", comment: "")
        let empty = host(files: [])
        XCTAssertEqual(empty.page.recentHeaderTextForTesting(), recentHeader)
        let emptyView = try XCTUnwrap(empty.page.recentEmptyViewForTesting())
        XCTAssertNotNil(emptyView.illustrationForTesting.image)
        XCTAssertTrue(emptyView.messageTextForTesting?.contains("97.5 MB") == true, emptyView.messageTextForTesting ?? "")

        let loading = host(files: nil)
        XCTAssertEqual(loading.page.recentHeaderTextForTesting(), recentHeader)
        XCTAssertNil(loading.page.recentEmptyViewForTesting())

        let some = host(files: makeFiles(3))
        XCTAssertEqual(some.page.recentHeaderTextForTesting(), recentHeader)
        XCTAssertNil(some.page.recentEmptyViewForTesting())
    }

    /// F-10：🔍 只在最近文件 > 10 条或加载中时出现。
    @MainActor
    func testSearchButtonOnlyWithMoreThanTenFilesOrWhileLoading() {
        XCTAssertFalse(host(files: makeFiles(10)).page.isSearchButtonShownForTesting)
        XCTAssertTrue(host(files: makeFiles(11)).page.isSearchButtonShownForTesting)
        let loading = host(files: nil)
        XCTAssertTrue(loading.page.isSearchButtonShownForTesting)
        XCTAssertTrue(cell(in: loading, row: 0, section: 1) is TellomiRecentFileSkeletonCell, "加载中是骨架")
    }

    /// F-6：一行 = 扩展名图标 + 文件名 +「大小 · 日期」；F-7：点一行立即发送。
    @MainActor
    func testTappingARecentFileSendsItRightAway() throws {
        let files = makeFiles(3)
        let hosted = host(files: files)
        let row = try XCTUnwrap(cell(in: hosted, row: 0, section: 1) as? TellomiRecentFileCell)
        XCTAssertEqual(row.nameTextForTesting, files[0].fileName)
        XCTAssertEqual(row.iconForTesting.extensionTextForTesting, "pdf")
        XCTAssertEqual(row.iconForTesting.tint, .red)
        XCTAssertTrue(row.detailTextForTesting?.contains(" · ") == true, row.detailTextForTesting ?? "")

        hosted.page.tapFileForTesting(row: 1)

        XCTAssertEqual(hosted.delegate.sent.map(\.files), [[files[1]]])
        XCTAssertNil(hosted.delegate.sent.first?.body)
    }

    /// F-7：本机已经没有的：整行置灰、写「已不在本机」，点了不发。
    @MainActor
    func testFileNoLongerOnTheDeviceIsDimmedAndNotSent() throws {
        var files = makeFiles(2)
        files[0] = TellomiRecentFile(id: "gone", attachmentRowId: 99, messageRowId: 9, fileName: "旧.txt", byteCount: 10, sentAt: Date(), isOnDevice: false)
        let hosted = host(files: files)
        let row = try XCTUnwrap(cell(in: hosted, row: 0, section: 1) as? TellomiRecentFileCell)
        XCTAssertTrue(row.isDimmedForTesting)
        XCTAssertEqual(row.detailTextForTesting, OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_NOT_ON_DEVICE", comment: ""))
        XCTAssertFalse(try XCTUnwrap(cell(in: hosted, row: 1, section: 1) as? TellomiRecentFileCell).isDimmedForTesting)

        hosted.page.tapFileForTesting(row: 0)
        hosted.page.beginSelectionForTesting(row: 0)

        XCTAssertTrue(hosted.delegate.sent.isEmpty)
        XCTAssertNil(hosted.page.selectedIdsForTesting, "不在本机的也不能多选")
    }

    /// F-8：长按「选择」进多选；勾的顺序带序号；dock 换成「说明 + 发送」、🔍 藏起；说明挂在最后一个。
    @MainActor
    func testMultiSelectSendsInTheOrderPickedWithTheCaptionOnTheLast() throws {
        let files = makeFiles(12)
        let hosted = host(files: files)
        XCTAssertTrue(hosted.page.isSearchButtonShownForTesting)
        hosted.page.beginSelectionForTesting(row: 2)
        hosted.page.tapFileForTesting(row: 0)
        hosted.page.tapFileForTesting(row: 5)
        hosted.page.tapFileForTesting(row: 0)
        hosted.page.tapFileForTesting(row: 1)

        XCTAssertEqual(hosted.page.selectedIdsForTesting, [files[2].id, files[5].id, files[1].id])
        XCTAssertFalse(hosted.page.isDockShownForTesting)
        XCTAssertTrue(hosted.page.isSendBarShownForTesting)
        XCTAssertFalse(hosted.page.isSearchButtonShownForTesting, "多选时藏 🔍")
        XCTAssertEqual(hosted.page.tableViewForTesting.numberOfSections, 1, "多选时藏上面三行")
        XCTAssertEqual(try XCTUnwrap(cell(in: hosted, row: 5, section: 0) as? TellomiRecentFileCell).selectionNumberForTesting, 2)
        XCTAssertEqual(try XCTUnwrap(cell(in: hosted, row: 0, section: 0) as? TellomiRecentFileCell).selectionNumberForTesting, 0, "没勾的是空心圈")
        XCTAssertTrue(hosted.delegate.sent.isEmpty, "多选时点一行只是勾选")
        hosted.page.view.layoutIfNeeded()
        XCTAssertEqual(hosted.page.sendBarFrameForTesting.maxY, hosted.page.view.bounds.maxY, "底栏底色铺到底，列表不从下面露出来")

        hosted.page.sendSelectionForTesting(caption: " 三份材料 ")

        XCTAssertEqual(hosted.delegate.sent.map(\.files), [[files[2], files[5], files[1]]])
        XCTAssertEqual(hosted.delegate.sent.first?.body?.text, "三份材料")
    }

    /// 多选中点 ✕ 先退出多选，不关 Sheet；再点才关。
    @MainActor
    func testCloseLeavesSelectionFirst() {
        let hosted = host(files: makeFiles(3))
        hosted.page.beginSelectionForTesting(row: 0)
        hosted.page.tapCloseForTesting()
        XCTAssertNil(hosted.page.selectedIdsForTesting)
        XCTAssertTrue(hosted.page.isDockShownForTesting)
        XCTAssertFalse(hosted.page.isSendBarShownForTesting)
        XCTAssertEqual(hosted.page.tableViewForTesting.numberOfSections, 2, "三行入口回来")
        XCTAssertEqual(hosted.delegate.cancels, 0)

        hosted.page.tapCloseForTesting()

        XCTAssertEqual(hosted.delegate.cancels, 1)
    }

    /// F-10：本机文件名，大小写、全半角不敏感；超过 4 条先 3 条 +「显示更多」；搜不到写「没有找到」。
    @MainActor
    func testSearchIsLocalFoldedAndCollapsesLongResults() throws {
        let names = ["Report.PDF", "ｒｅｐｏｒｔ-2.pdf", "report 3.docx", "报告 report4.xlsx", "old-REPORT.zip", "notes.txt"]
        let files = names.enumerated().map { index, name in
            TellomiRecentFile(id: "n\(index)", attachmentRowId: Int64(100 + index), messageRowId: Int64(100 + index), fileName: name, byteCount: 1_000, sentAt: Date(), isOnDevice: true)
        } + makeFiles(6)
        XCTAssertEqual(TellomiAttachmentFilesViewController.search(files, for: "REPORT").map(\.fileName), Array(names.prefix(5)))
        XCTAssertEqual(TellomiAttachmentFilesViewController.search(files, for: "  "), [])

        let hosted = host(files: files)
        hosted.page.tapSearchForTesting()
        XCTAssertTrue(hosted.page.isSearchBarShownForTesting)
        XCTAssertFalse(hosted.page.isDockShownForTesting, "搜索时藏 dock")
        XCTAssertEqual(hosted.page.searchRowCountForTesting(), 0, "没输入时不列东西")

        hosted.page.searchForTesting("REPORT")
        XCTAssertEqual(hosted.page.searchRowCountForTesting(), 4, "5 条结果先显示 3 条 +「显示更多」")
        hosted.page.tapSearchRowForTesting(row: 3)
        XCTAssertEqual(hosted.page.searchRowCountForTesting(), 5)
        XCTAssertTrue(hosted.delegate.sent.isEmpty, "「显示更多」不发东西")

        hosted.page.tapSearchRowForTesting(row: 1)
        XCTAssertEqual(hosted.delegate.sent.map(\.files), [[files[1]]], "点结果立即发送")

        hosted.page.searchForTesting("没有这个")
        XCTAssertEqual(hosted.page.searchRowCountForTesting(), 1)
        let noResults = cell(in: hosted, row: 0, section: 0)
        let text = (noResults?.contentConfiguration as? UIListContentConfiguration)?.text ?? ""
        XCTAssertTrue(text.contains("没有这个"), text)
    }

    /// F-4：系统文件选择器可多选；挑回来的文件交给会话页去发。
    @MainActor
    func testFilePickerAllowsSeveralFilesAndHandsThemOver() async throws {
        let hosted = host(files: [], inWindow: true)
        defer { hosted.window?.isHidden = true }
        try await settle()
        hosted.page.tapEntryForTesting(.files)
        let picker = try await waitFor { hosted.page.presentedDocumentPickerForTesting }
        XCTAssertTrue(picker.allowsMultipleSelection)
        XCTAssertTrue(picker.delegate === hosted.page)

        let urls = [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.zip")]
        hosted.page.documentPicker(picker, didPickDocumentsAt: urls)
        hosted.page.documentPicker(picker, didPickDocumentsAt: [])
        picker.dismiss(animated: false)

        XCTAssertEqual(hosted.delegate.pickedURLs, [urls])
    }

    /// F-10：半屏里点 🔍 → 展开到全屏、搜索框出来、dock 藏起；✕ 退出搜索回到三行入口 + 最近文件。
    /// （改状态和 reloadData 之间夹着展开 Sheet 的同步排版时，表格按旧分组数取格子会越界崩溃。）
    @MainActor
    func testSearchInsideTheHalfSheetExpandsItAndComesBack() async throws {
        let hosted = host(files: makeFiles(12), asAttachmentSheet: true)
        defer { hosted.window?.isHidden = true }
        try await settle()
        let sheet = try XCTUnwrap(hosted.page.sheetPresentationController)
        XCTAssertNotEqual(sheet.selectedDetentIdentifier, .large)

        hosted.page.tapSearchForTesting()
        hosted.page.tableViewForTesting.layoutIfNeeded()

        XCTAssertEqual(sheet.selectedDetentIdentifier, .large)
        XCTAssertTrue(hosted.page.isSearchBarShownForTesting)
        XCTAssertFalse(hosted.page.isDockShownForTesting)
        XCTAssertEqual(hosted.page.tableViewForTesting.numberOfSections, 1)
        hosted.page.view.layoutIfNeeded()
        XCTAssertEqual(hosted.page.searchBarFrameForTesting.maxY, hosted.page.view.bounds.maxY, "搜索栏底色铺到底")
        XCTAssertEqual(hosted.page.tableViewForTesting.frame.minY, hosted.page.view.safeAreaInsets.top, accuracy: 0.5, "搜索时顶栏收起，结果从顶上开始")

        hosted.page.searchForTesting("报告")
        try await settle()
        hosted.page.tapSearchCloseForTesting()
        hosted.page.tableViewForTesting.layoutIfNeeded()

        XCTAssertFalse(hosted.page.isSearchBarShownForTesting)
        XCTAssertTrue(hosted.page.isDockShownForTesting)
        XCTAssertEqual(hosted.page.tableViewForTesting.numberOfSections, 2)
        XCTAssertEqual(hosted.page.tableViewForTesting.numberOfRows(inSection: 0), 3)
    }

    /// F-3（#1263）：「从相册中选择」不再置灰；点了交给会话页（会话页先收起 Sheet 再推出网格，owner 2026-10-13 照 Telegram）。
    @MainActor
    func testSelectFromGalleryHandsOverToTheConversation() throws {
        let hosted = host(files: [])
        let row = try XCTUnwrap(cell(in: hosted, row: 0, section: 0))
        XCTAssertFalse(row.accessibilityTraits.contains(.notEnabled))

        hosted.page.tapEntryForTesting(.gallery)

        XCTAssertEqual(hosted.delegate.galleryRequests, 1)
        XCTAssertTrue(hosted.delegate.sent.isEmpty)
        XCTAssertTrue(hosted.delegate.pickedURLs.isEmpty)
    }

    /// F-3：点格子右上的勾 = 勾选（带序号），再点取消；底栏「发送（N）」，0 个时是置灰的「发送」；发出去的按勾选的顺序。
    @MainActor
    func testGalleryTicksInOrderAndSends() throws {
        let (gallery, delegate) = hostGallery(GalleryPhotoLibrary())
        XCTAssertFalse(gallery.isSendEnabledForTesting)
        XCTAssertEqual(gallery.sendTitleForTesting, MessageStrings.sendButton)
        XCTAssertFalse(gallery.isEmptyStateShownForTesting)

        gallery.tapCheckForTesting(2)
        gallery.tapCheckForTesting(0)
        gallery.tapCheckForTesting(5)
        gallery.tapCheckForTesting(0)
        XCTAssertEqual(gallery.selectedIds, ["r2", "r5"])
        XCTAssertTrue(gallery.isSendEnabledForTesting)
        XCTAssertEqual(gallery.sendTitleForTesting, "Send (2)")

        gallery.tapSendForTesting()
        XCTAssertEqual(delegate.sent.map { $0.items.map(\.id) }, [["r2", "r5"]])
        XCTAssertEqual(delegate.sent.first?.convertHeicToJpeg, false)
        XCTAssertEqual(delegate.sent.first?.caption, nil)
        XCTAssertFalse(gallery.isAskingAboutHeicForTesting)

        gallery.tapCancelForTesting()
        XCTAssertEqual(delegate.cancels, 1)
    }

    /// F-3：最多 100 个；第 101 个点了不加。
    @MainActor
    func testGallerySelectsAtMostOneHundred() throws {
        let (gallery, _) = hostGallery(GalleryPhotoLibrary(recentCount: 101))
        for index in 0..<101 {
            gallery.tapCheckForTesting(index)
        }
        XCTAssertEqual(gallery.selectedIds.count, TellomiFilesGalleryViewController.maxSelection)
        XCTAssertEqual(gallery.selectedIds.last, "r99")
    }

    /// F-3：换相册（标题跟着变、网格换内容），已勾的留着；空相册显示「没有照片或视频」。
    @MainActor
    func testGallerySwitchesAlbumsAndKeepsTheSelection() throws {
        let library = GalleryPhotoLibrary()
        let (gallery, _) = hostGallery(library)
        gallery.tapCheckForTesting(1)

        let empty = try XCTUnwrap(library.albums().last)
        gallery.switchAlbumForTesting(empty)
        XCTAssertEqual(gallery.titleForTesting, "Empty")
        XCTAssertEqual(gallery.collectionViewForTesting.numberOfItems(inSection: 0), 0)
        XCTAssertTrue(gallery.isEmptyStateShownForTesting)
        XCTAssertEqual(gallery.selectedIds, ["r1"])
        XCTAssertEqual(gallery.sendTitleForTesting, "Send (1)")
    }

    /// F-3：勾的里有 HEIC 先问要不要转成 JPEG（同 Telegram iOS 文件模式、同「···」以文件发送），选了再交出去。
    @MainActor
    func testGalleryAsksAboutHeicBeforeSending() throws {
        let (gallery, delegate) = hostGallery(GalleryPhotoLibrary(heicIds: ["r3"]))
        gallery.tapCheckForTesting(3)
        gallery.tapCheckForTesting(4)

        gallery.tapSendForTesting()
        XCTAssertTrue(gallery.isAskingAboutHeicForTesting)
        XCTAssertTrue(delegate.sent.isEmpty)

        gallery.chooseHeicForTesting(convert: true)
        XCTAssertEqual(delegate.sent.map { $0.items.map(\.id) }, [["r3", "r4"]])
        XCTAssertEqual(delegate.sent.first?.convertHeicToJpeg, true)
    }

    /// F-3（owner 2026-10-13 照 Telegram）：点照片本身打开预览——文件模式：整本相册、不能编辑、底部文件信息 + 说明 + 发送。
    @MainActor
    func testTappingAPhotoOpensTheFilePreview() async throws {
        let (gallery, _, window) = hostGalleryInWindow(GalleryPhotoLibrary())
        defer { window.isHidden = true }
        gallery.tapCheckForTesting(4)

        gallery.tapItemForTesting(1)
        let preview = try await waitFor { gallery.presentedPreviewForTesting }
        XCTAssertEqual(preview.modalPresentationStyle, .overFullScreen)
        XCTAssertEqual(preview.positionTextForTesting, "2 / 12")
        XCTAssertTrue(preview.isFileBarShownForTesting)
        XCTAssertFalse(preview.isEditShownForTesting)
        XCTAssertFalse(preview.isCropShownForTesting)
        XCTAssertFalse(preview.isCountShownForTesting)
        XCTAssertEqual(preview.fileNameTextForTesting, "IMG_r1.JPG")
        XCTAssertEqual(preview.fileDetailsTextForTesting, "3024×4032 · 0:42")
        XCTAssertEqual(preview.sendBadgeTextForTesting, "1")
        XCTAssertNil(preview.checkNumberTextForTesting)

        preview.tapCheckForTesting()
        XCTAssertEqual(gallery.selectedIds, ["r4", "r1"])
        XCTAssertEqual(preview.checkNumberTextForTesting, "2")
        preview.typeCaptionForTesting("合同")
        XCTAssertEqual(gallery.caption, "合同")
    }

    /// F-3：预览里的发送——一个都没勾时发正在看的这一张；勾了就发勾的；说明去掉首尾空白、挂在最后一个。
    @MainActor
    func testPreviewSendsTheCurrentPhotoOnlyWhenNothingIsTicked() throws {
        let (gallery, delegate) = hostGallery(GalleryPhotoLibrary())
        gallery.sendFromPreviewForTesting(3, caption: "  合同  ")
        XCTAssertEqual(delegate.sent.map { $0.items.map(\.id) }, [["r3"]])
        XCTAssertEqual(delegate.sent.first?.caption, "合同")

        let (ticked, tickedDelegate) = hostGallery(GalleryPhotoLibrary())
        ticked.tapCheckForTesting(0)
        ticked.sendFromPreviewForTesting(4, caption: "")
        XCTAssertEqual(tickedDelegate.sent.map { $0.items.map(\.id) }, [["r0"]])
        XCTAssertEqual(tickedDelegate.sent.first?.caption, nil)
    }

    /// F-3：预览底部「尺寸 · 时长 · 大小」，知道的才写。
    func testFileDetailsShowOnlyWhatIsKnown() {
        let photo = TellomiPhotoPickerItem(id: "p", isVideo: false, duration: 0, isLivePhoto: false, isAnimatedImage: false, pixelSize: CGSize(width: 4032, height: 3024), asset: nil)
        let video = TellomiPhotoPickerItem(id: "v", isVideo: true, duration: 75, isLivePhoto: false, isAnimatedImage: false, pixelSize: .zero, asset: nil)
        let size = ByteCountFormatter.string(fromByteCount: 2_516_582, countStyle: .file)
        XCTAssertEqual(TellomiFilesGalleryViewController.fileDetails(for: photo, byteCount: 2_516_582), "4032×3024 · \(size)")
        XCTAssertEqual(TellomiFilesGalleryViewController.fileDetails(for: video, byteCount: nil), "1:15")
    }

    /// F-1：dock 的「文件」格选中；别的格子交给会话页（「相册」换回选图页）；重复点「文件」不交出去。
    @MainActor
    func testDockHandsOtherItemsToTheConversation() throws {
        let hosted = host(files: [])
        let dock = try XCTUnwrap(hosted.page.dockForTesting)
        XCTAssertEqual(dock.selectedItem, .file)
        dock.tapForTesting(.gallery)
        dock.tapForTesting(.poll)
        dock.tapForTesting(.file)
        XCTAssertEqual(hosted.delegate.dockSelections, [.gallery, .poll])
    }

    // MARK: - Container (F-1)

    /// 「相册」「文件」在同一个 Sheet 里换页；「文件」页只建一次；不许下拉关闭跟着当前页。
    @MainActor
    func testContainerSwitchesPagesInsideTheSameSheet() throws {
        let picker = TellomiPhotoPickerViewController(
            library: EmptyPhotoLibrary(),
            initialMessageBody: nil,
            defaultImageQuality: .standard,
            canSendSeparately: true,
            hasQuotedReplyDraft: false,
            attachmentLimits: .currentLimits(),
            approvalDataSource: FilesTestApprovalDataSource(),
            stickerSheetDelegate: nil,
            dockItems: TellomiAttachmentDockItem.allCases,
        )
        let filesPage = TellomiAttachmentFilesViewController(source: FakeRecentFiles(files: []), maxFileSizeText: "1 MB", canScan: false, dockItems: TellomiAttachmentDockItem.allCases)
        var made = 0
        let container = TellomiAttachmentSheetController(photoPicker: picker) {
            made += 1
            return filesPage
        }
        container.loadViewIfNeeded()
        XCTAssertTrue(container.visibleChildForTesting === picker)
        XCTAssertEqual(made, 0, "没点「文件」就不建")

        container.show(.files, animated: false)
        XCTAssertTrue(container.visibleChildForTesting === filesPage)
        XCTAssertNil(picker.parent)
        filesPage.isModalInPresentation = true
        XCTAssertTrue(container.isModalInPresentation)

        container.show(.gallery, animated: false)
        XCTAssertTrue(container.visibleChildForTesting === picker)
        XCTAssertFalse(container.isModalInPresentation)
        container.show(.files, animated: false)
        XCTAssertEqual(made, 1, "「文件」页只建一次，来回切换状态还在")
        XCTAssertTrue(container.visibleChildForTesting === filesPage)
        XCTAssertEqual(container.children.count, 1)
    }

    // MARK: - Poll page in the sheet (2026-10-16)

    func testContainerShowsThePollPageInsideTheSameSheetAndBuildsItFreshEachTime() throws {
        let picker = TellomiPhotoPickerViewController(
            library: EmptyPhotoLibrary(),
            initialMessageBody: nil,
            defaultImageQuality: .standard,
            canSendSeparately: true,
            hasQuotedReplyDraft: false,
            attachmentLimits: .currentLimits(),
            approvalDataSource: FilesTestApprovalDataSource(),
            stickerSheetDelegate: nil,
            dockItems: TellomiAttachmentDockItem.allCases,
        )
        var pollPagesMade = 0
        let container = TellomiAttachmentSheetController(photoPicker: picker) { page in
            guard page == .poll else { return nil }
            pollPagesMade += 1
            return TellomiAttachmentPollPage(poll: NewPollViewController2(maxOptionCount: 10), dockItems: TellomiAttachmentDockItem.allCases)
        }
        container.loadViewIfNeeded()

        container.show(.poll, animated: false)
        let first = try XCTUnwrap(container.visibleChildForTesting as? TellomiAttachmentPollPage, "投票页换进同一个 Sheet")
        XCTAssertEqual(container.children.count, 1)
        XCTAssertNil(picker.parent)
        XCTAssertNil(container.presentedViewController, "没有另外 present")

        container.show(.gallery, animated: false)
        XCTAssertTrue(container.visibleChildForTesting === picker)
        container.show(.poll, animated: false)
        XCTAssertEqual(pollPagesMade, 2, "投票页每次进都新建，上次没发的不留着")
        XCTAssertFalse(container.visibleChildForTesting === first)
    }

    func testEveryDockItemButGifIsAPageOfTheSheet() {
        XCTAssertEqual(TellomiAttachmentSheetController.page(for: .gallery), .gallery)
        XCTAssertEqual(TellomiAttachmentSheetController.page(for: .file), .files)
        XCTAssertEqual(TellomiAttachmentSheetController.page(for: .poll), .poll)
        XCTAssertEqual(TellomiAttachmentSheetController.page(for: .contact), .contact)
        XCTAssertEqual(TellomiAttachmentSheetController.page(for: .location), .location)
        XCTAssertNil(TellomiAttachmentSheetController.page(for: .gif), "GIF 等 #1012 挪到表情面板")
    }

    func testContactPageShowsInsideTheSameSheetWithItsOwnDock() throws {
        let picker = TellomiPhotoPickerViewController(
            library: EmptyPhotoLibrary(),
            initialMessageBody: nil,
            defaultImageQuality: .standard,
            canSendSeparately: true,
            hasQuotedReplyDraft: false,
            attachmentLimits: .currentLimits(),
            approvalDataSource: FilesTestApprovalDataSource(),
            stickerSheetDelegate: nil,
            dockItems: TellomiAttachmentDockItem.allCases,
        )
        let root = UIViewController()
        let container = TellomiAttachmentSheetController(photoPicker: picker) { page in
            page == .contact ? TellomiAttachmentNavigationPage(root: root, dockItem: .contact, dockItems: TellomiAttachmentDockItem.allCases) : nil
        }
        container.loadViewIfNeeded()

        container.show(.contact, animated: false)
        let page = try XCTUnwrap(container.visibleChildForTesting as? TellomiAttachmentNavigationPage)
        XCTAssertTrue(page.navigation.viewControllers.first === root)
        XCTAssertNil(container.presentedViewController)
        XCTAssertTrue(page.wantsExpandedSheet)

        let delegate = RecordingNavigationPageDelegate()
        page.delegate = delegate
        page.loadViewIfNeeded()
        XCTAssertTrue(page.isDockShownForTesting)
        page.selectDockItemForTesting(.contact)
        page.selectDockItemForTesting(.poll)
        XCTAssertEqual(delegate.items, [.poll], "重复点「联系人」由页面自己处理，别的交给会话页")
    }

    func testPollPageWaitsForTheSheetBeforeTheKeyboardAndHandsOtherDockItemsOn() {
        let poll = NewPollViewController2(maxOptionCount: 10)
        let page = TellomiAttachmentPollPage(poll: poll, dockItems: TellomiAttachmentDockItem.allCases)
        let delegate = RecordingNavigationPageDelegate()
        page.delegate = delegate
        page.loadViewIfNeeded()

        XCTAssertFalse(poll.autoFocusesQuestion, "Sheet 展开完再弹键盘")
        XCTAssertTrue(page.wantsExpandedSheet)
        XCTAssertTrue(page.isDockShownForTesting)

        page.selectDockItemForTesting(.poll)
        XCTAssertEqual(delegate.items, [], "重复点「投票」由页面自己处理")
        page.selectDockItemForTesting(.gallery)
        page.selectDockItemForTesting(.contact)
        XCTAssertEqual(delegate.items, [.gallery, .contact])
    }

    func testPollPageHidesTheDockWhileTheKeyboardIsUp() {
        let page = TellomiAttachmentPollPage(poll: NewPollViewController2(maxOptionCount: 10), dockItems: TellomiAttachmentDockItem.allCases)
        page.loadViewIfNeeded()

        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        XCTAssertFalse(page.isDockShownForTesting)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        XCTAssertTrue(page.isDockShownForTesting)
    }

    func testPollCloseGoesToTheSheetInsteadOfDismissingItself() throws {
        guard #available(iOS 16, *) else { throw XCTSkip("UIAction.performWithSender 要 iOS 16") }
        let poll = NewPollViewController2(maxOptionCount: 10)
        var closed = 0
        poll.onClose = { closed += 1 }
        poll.loadViewIfNeeded()

        let close = try XCTUnwrap(poll.navigationItem.leftBarButtonItem?.primaryAction)
        close.performWithSender(nil, target: nil)
        XCTAssertEqual(closed, 1)
    }

    /// 给人看的截图（TELLOMI_SHOTS=1 时才跑）：投票、联系人、位置三页嵌在附件 Sheet 里（全屏档）的样子——顶栏是上游页面自己的导航栏，
    /// 底部是和另外两页同一位置的 dock。写到 `TELLOMI_SHOTS_DIR/<屏宽>/attachment-sheet-<页>.png`。
    @MainActor
    func testShotsOfThePagesInsideTheAttachmentSheet() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(UIScreen.main.bounds.size.width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let pages: [(TellomiAttachmentSheetController.Page, String, () -> UIViewController)] = [
            (.poll, "poll", {
                TellomiAttachmentPollPage(poll: NewPollViewController2(maxOptionCount: 10), dockItems: TellomiAttachmentDockItem.allCases)
            }),
            // 上游 ContactPickerViewController 在测试环境里拿不到真的通讯录管理器（FakeContactsManager 转不成 OWSContactsManager 会崩），
            // 这里放一个同标题的空页看导航栏和 dock 的位置。
            (.contact, "contact", {
                let placeholder = UIViewController()
                placeholder.view.backgroundColor = .Signal.groupedBackground
                placeholder.title = OWSLocalizedString("CONTACT_PICKER_TITLE", comment: "navbar title for contact picker when sharing a contact")
                return TellomiAttachmentNavigationPage(root: placeholder, dockItem: .contact, dockItems: TellomiAttachmentDockItem.allCases)
            }),
            (.location, "location", {
                TellomiAttachmentNavigationPage(root: LocationPicker(), dockItem: .location, dockItems: TellomiAttachmentDockItem.allCases)
            }),
        ]

        for (page, name, make) in pages {
            let picker = TellomiPhotoPickerViewController(
                library: EmptyPhotoLibrary(),
                initialMessageBody: nil,
                defaultImageQuality: .standard,
                canSendSeparately: true,
                hasQuotedReplyDraft: false,
                attachmentLimits: .currentLimits(),
                approvalDataSource: FilesTestApprovalDataSource(),
                stickerSheetDelegate: nil,
                dockItems: TellomiAttachmentDockItem.allCases,
            )
            let container = TellomiAttachmentSheetController(photoPicker: picker) { $0 == page ? make() : nil }
            container.modalPresentationStyle = .pageSheet
            container.sheetPresentationController?.detents = [.large()]
            container.sheetPresentationController?.prefersGrabberVisible = true

            let window = UIWindow.tellomiTestWindow(frame: UIScreen.main.bounds)
            let base = UIViewController()
            base.view.backgroundColor = .Signal.background
            window.rootViewController = base
            window.isHidden = false
            base.present(container, animated: false)
            container.show(page, animated: false)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("attachment-sheet-\(name).png"))
            base.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    // MARK: - Icon (F-6)

    func testFileIconColourFollowsTheExtension() {
        XCTAssertEqual(TellomiFileTypeIcon.fileExtension(of: "Report.PDF"), "pdf")
        XCTAssertEqual(TellomiFileTypeIcon.fileExtension(of: "a.tar.gz"), "gz")
        XCTAssertEqual(TellomiFileTypeIcon.fileExtension(of: "README"), "")
        XCTAssertEqual(TellomiFileTypeIcon.fileExtension(of: "dots."), "")
        XCTAssertEqual(TellomiFileTypeIcon.tint(forExtension: "pdf"), .red)
        XCTAssertEqual(TellomiFileTypeIcon.tint(forExtension: "pptx"), .red)
        XCTAssertEqual(TellomiFileTypeIcon.tint(forExtension: "xlsx"), .green)
        XCTAssertEqual(TellomiFileTypeIcon.tint(forExtension: "csv"), .green)
        XCTAssertEqual(TellomiFileTypeIcon.tint(forExtension: "gz"), .orange)
        XCTAssertEqual(TellomiFileTypeIcon.tint(forExtension: "zip"), .orange)
        XCTAssertEqual(TellomiFileTypeIcon.tint(forExtension: "docx"), .blue)
        XCTAssertEqual(TellomiFileTypeIcon.tint(forExtension: ""), .blue)
    }

    // MARK: - Picked files (F-4)

    /// F-4：系统选择器挑回来的文件变成要发的附件（按文件发，文件名跟着走）；超过服务端上限的不建（nil，会话页统一提示「文件太大」并写明上限）。
    func testPickedFileOverTheServerLimitIsNotBuilt() async throws {
        let config = RemoteConfig(clockSkew: 0, valueFlags: ["global.attachments.maxBytes": "8192"])
        let limits = OutgoingAttachmentLimits(remoteConfig: config, callingCode: nil)
        let maxBytes = limits.maxPlaintextBytes
        XCTAssertLessThan(maxBytes, 8192, "上限读服务端下发的配置")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let small = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: small)
        let big = directory.appendingPathComponent("big.bin")
        try Data(count: Int(maxBytes) + 1).write(to: big)

        let attachment = try await ConversationViewController.tellomiBuildFileAttachment(url: small, limits: limits)
        XCTAssertEqual(attachment?.mimeType, "text/plain")
        XCTAssertEqual(attachment?.dataSource.sourceFilename, "notes.txt")
        let tooLarge = try await ConversationViewController.tellomiBuildFileAttachment(url: big, limits: limits)
        XCTAssertNil(tooLarge, "超过上限的不发")
    }

    // MARK: - Draft (F-4、F-5、F-7、F-8)

    /// 从「文件」页发东西，不清聊天输入框里还没发的草稿：文件页的说明从来不是那段草稿（点一行 / 系统选择器 / 扫描都没有说明，
    /// 多选的说明是文件页自己的输入框）。上游 `sendAttachments` 每发成一条就清输入框，于是「输入框里打了字 →「+」→ 文件 → 点一个文件」，
    /// 那段字既没发出去也没了。Android 同一功能（`ConversationFragment.sendSlidesInOrder`）传的是 `clearCompose = false`。
    /// 文件页的两处发送都传 `clearsDraft: false`；会话页别的发送照上游：发出去就清（草稿当说明一起发出去了），贴纸样子的单个无边框附件不清。
    @MainActor
    func testSendingFromTheFilesPageKeepsTheChatDraft() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let limits = OutgoingAttachmentLimits.currentLimits()
        func pickedFile(_ name: String) async throws -> PreviewableAttachment {
            let url = directory.appendingPathComponent(name)
            try Data("hello".utf8).write(to: url)
            let attachment = try await ConversationViewController.tellomiBuildFileAttachment(url: url, limits: limits)
            return try XCTUnwrap(attachment)
        }

        let notes = try await pickedFile("notes.txt")
        let files = ApprovedAttachments(nonViewOnceAttachments: [notes], imageQuality: .standard)
        XCTAssertFalse(ConversationViewController.tellomiClearsInputAfterSending(files, clearsDraft: false), "文件页发的：输入框里的草稿留着")
        XCTAssertTrue(ConversationViewController.tellomiClearsInputAfterSending(files, clearsDraft: true), "别的发送照上游：发出去就清")

        let stickerLike = try await pickedFile("sticker.txt")
        stickerLike.rawValue.isBorderless = true
        let sticker = ApprovedAttachments(nonViewOnceAttachments: [stickerLike], imageQuality: .standard)
        XCTAssertFalse(ConversationViewController.tellomiClearsInputAfterSending(sticker, clearsDraft: true), "照上游：贴纸样子的单个无边框附件不清")
    }

    // MARK: - Scan (F-5)

    /// 扫描的几页合成一个 PDF，页数不变；文件名是扫描标题（去掉不能进文件名的字符）或「扫描」。
    func testScannedPagesBecomeOnePdf() throws {
        let pages = [UIColor.red, .green, .blue].map { color in
            UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
            }
        }
        let url = try TellomiScannedDocument.makePDF(pages: pages, title: "合同/第1页")
        XCTAssertEqual(url.lastPathComponent, "合同-第1页.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(TellomiScannedDocument.fileName(title: "  "), OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_SCAN_FILENAME", comment: "") + ".pdf")
    }

    // MARK: - Screenshots

    /// 截图（TELLOMI_SHOTS=1）：同真机把「文件」页当附件 Sheet 弹出来——空、5 条、20 条（有 🔍）、多选、搜索结果收起、搜不到、
    /// 「从相册中选择」的网格（勾了两个）。
    @MainActor
    func testFilesPageScreenshots() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let width = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size.width }.first)

        let empty = host(files: [], asAttachmentSheet: true)
        try await settle()
        try save(render(empty.window!), name: "files-1-empty.png", width: width)
        empty.window?.isHidden = true

        let few = host(files: makeFiles(5), asAttachmentSheet: true)
        try await settle()
        try save(render(few.window!), name: "files-2-five.png", width: width)
        few.window?.isHidden = true

        let many = host(files: makeFiles(20), asAttachmentSheet: true)
        try await settle()
        try save(render(many.window!), name: "files-3-twenty.png", width: width)
        many.page.beginSelectionForTesting(row: 1)
        many.page.tapFileForTesting(row: 3)
        try await settle()
        try save(render(many.window!), name: "files-4-selecting.png", width: width)
        many.window?.isHidden = true

        let search = host(files: makeFiles(20), asAttachmentSheet: true)
        try await settle()
        search.page.tapSearchForTesting()
        search.page.searchForTesting("报告")
        try await settle()
        try save(render(search.window!), name: "files-5-search.png", width: width)
        search.page.searchForTesting("没有这个")
        try await settle()
        try save(render(search.window!), name: "files-6-no-results.png", width: width)
        search.window?.isHidden = true

        let (grid, _, window) = hostGalleryInWindow(GalleryPhotoLibrary(recentCount: 30))
        try await settle()
        grid.tapCheckForTesting(2)
        grid.tapCheckForTesting(0)
        try await settle()
        try save(render(window), name: "files-7-gallery.png", width: width)
        grid.tapItemForTesting(1)
        _ = try await waitFor { grid.presentedPreviewForTesting }
        try await settle()
        try save(render(window), name: "files-8-preview.png", width: width)
        window.isHidden = true
    }

    // MARK: - Hosting

    private struct Hosted {
        let page: TellomiAttachmentFilesViewController
        let delegate: RecordingFilesDelegate
        let window: UIWindow?
    }

    @MainActor
    private func host(
        files: [TellomiRecentFile]?,
        canScan: Bool = true,
        inWindow: Bool = false,
        asAttachmentSheet: Bool = false,
    ) -> Hosted {
        let delegate = RecordingFilesDelegate()
        let page = TellomiAttachmentFilesViewController(
            source: FakeRecentFiles(files: files),
            maxFileSizeText: "97.5 MB",
            canScan: canScan,
            dockItems: TellomiAttachmentDockItem.allCases,
        )
        page.delegate = delegate
        guard inWindow || asAttachmentSheet, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            page.loadViewIfNeeded()
            page.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            page.view.layoutIfNeeded()
            return Hosted(page: page, delegate: delegate, window: nil)
        }
        // 窗口接到真实屏幕上：安全区（底部横条）要算进 dock 的位置
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.backgroundColor = .Signal.background
        if asAttachmentSheet {
            // 同真机（#1115、#1121）：会话页把附件 Sheet 弹出来，聊天在后面
            let root = UIViewController()
            root.view.backgroundColor = .Signal.background
            window.rootViewController = root
            window.isHidden = false
            page.modalPresentationStyle = .pageSheet
            if let sheet = page.sheetPresentationController {
                ConversationViewController.configureAttachmentSheet(sheet)
            }
            root.present(page, animated: false)
        } else {
            window.rootViewController = page
            window.isHidden = false
        }
        window.layoutIfNeeded()
        return Hosted(page: page, delegate: delegate, window: window)
    }

    /// F-3 的相册网格，不进窗口。
    @MainActor
    private func hostGallery(_ library: TellomiPhotoPickerLibrary) -> (TellomiFilesGalleryViewController, RecordingGalleryDelegate) {
        let delegate = RecordingGalleryDelegate()
        let gallery = TellomiFilesGalleryViewController(library: library)
        gallery.delegate = delegate
        gallery.loadViewIfNeeded()
        gallery.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        gallery.view.layoutIfNeeded()
        return (gallery, delegate)
    }

    /// F-3 的相册网格，同真机整屏盖在会话页上（要弹预览就得在窗口里）。
    @MainActor
    private func hostGalleryInWindow(_ library: TellomiPhotoPickerLibrary) -> (TellomiFilesGalleryViewController, RecordingGalleryDelegate, UIWindow) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let root = UIViewController()
        root.view.backgroundColor = .Signal.background
        window.rootViewController = root
        window.isHidden = false
        let delegate = RecordingGalleryDelegate()
        let gallery = TellomiFilesGalleryViewController(library: library)
        gallery.delegate = delegate
        gallery.modalPresentationStyle = .fullScreen
        root.present(gallery, animated: false)
        window.layoutIfNeeded()
        return (gallery, delegate, window)
    }

    /// 取一行前先排一次版：`reloadData()` 之后要排过版才有可见的格子。
    @MainActor
    private func cell(in hosted: Hosted, row: Int, section: Int) -> UITableViewCell? {
        let tableView = hosted.page.tableViewForTesting
        tableView.layoutIfNeeded()
        return tableView.cellForRow(at: IndexPath(row: row, section: section))
    }

    private func makeFiles(_ count: Int) -> [TellomiRecentFile] {
        let extensions = ["pdf", "zip", "xlsx", "docx", "pptx", "txt", "csv"]
        // Xcode 26.6 的类型检查器对这一整个闭包里的字面量算式会超时：闭包写明类型，每个值先单独算好
        return (0..<count).map { (index: Int) -> TellomiRecentFile in
            let fileName: String = "第 \(index + 1) 季度报告（最终版）.\(extensions[index % extensions.count])"
            let byteCount: UInt64 = UInt64((index + 1) * 700 * 1_024)
            let sentSeconds: TimeInterval = 1_790_000_000 - Double(index) * 5_400
            return TellomiRecentFile(
                id: "f\(index)",
                attachmentRowId: Int64(index),
                messageRowId: Int64(index),
                fileName: fileName,
                byteCount: byteCount,
                sentAt: Date(timeIntervalSince1970: sentSeconds),
                isOnDevice: index != 4,
            )
        }
    }

    @MainActor
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    /// 等 [value] 变成非 nil（最多 3 秒）：弹出系统页面要等当前的出现过渡走完。
    @MainActor
    private func waitFor<T>(_ value: () -> T?) async throws -> T {
        for _ in 0..<30 {
            if let found = value() {
                return found
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return try XCTUnwrap(value())
    }

    @MainActor
    private func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func save(_ image: UIImage, name: String, width: CGFloat) throws {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }

    // MARK: - Database

    private func insertThread(_ db: InMemoryDB) -> TSThread {
        let thread = TSThread(uniqueId: UUID().uuidString)
        db.write { tx in try! thread.insert(tx.database) }
        return thread
    }

    /// 只关心「我发出的」判据（`recordType`），不建完整的消息。
    private func insertMessage(_ db: InMemoryDB, thread: TSThread, recordType: SDSRecordType) -> Int64 {
        let interaction = TSInteraction(timestamp: 0, receivedAtTimestamp: 0, thread: thread)
        db.write { tx in
            try! interaction.asRecord().insert(tx.database)
            try! tx.database.execute(
                sql: "UPDATE model_TSInteraction SET recordType = ? WHERE id = ?",
                arguments: [recordType.rawValue, interaction.sqliteRowId!],
            )
        }
        return interaction.sqliteRowId!
    }

    private func insertAttachment(_ db: InMemoryDB, record: Attachment.Record) -> Attachment {
        db.write { tx in
            var record = record
            try! record.insert(tx.database)
            return Attachment(record: record)
        }
    }

    private func addReference(
        _ db: InMemoryDB,
        attachment: Attachment,
        message: Int64,
        thread: TSThread,
        at timestamp: UInt64,
        name: String,
        order: UInt32 = 0,
        isViewOnce: Bool = false,
    ) {
        db.write { tx in
            let params = AttachmentReference.ConstructionParams.mock(
                owner: .message(.bodyAttachment(.init(
                    messageRowId: message,
                    receivedAtTimestamp: timestamp,
                    threadRowId: thread.sqliteRowId!,
                    contentType: attachment.contentType,
                    mimeType: attachment.mimeType,
                    isPastEditRevision: false,
                    caption: nil,
                    renderingFlag: .default,
                    orderInMessage: order,
                    idInOwner: nil,
                    isViewOnce: isViewOnce,
                ))),
                sourceFilename: name,
            )
            AttachmentStore().addReference(params, attachmentRowId: attachment.id, tx: tx)
        }
    }
}

// MARK: - Fakes

private final class FakeRecentFiles: TellomiRecentFilesSource {
    /// nil = 一直在读（看骨架）。
    let files: [TellomiRecentFile]?

    init(files: [TellomiRecentFile]?) {
        self.files = files
    }

    func loadRecentFiles(limit: Int, completion: @escaping ([TellomiRecentFile]) -> Void) {
        if let files {
            completion(Array(files.prefix(limit)))
        }
    }
}

private final class RecordingFilesDelegate: TellomiAttachmentFilesDelegate {
    struct Sent {
        let files: [TellomiRecentFile]
        let body: MessageBody?
    }

    var cancels = 0
    var dockSelections = [TellomiAttachmentDockItem]()
    var pickedURLs = [[URL]]()
    var sent = [Sent]()
    var galleryRequests = 0

    func filesPageDidCancel(_ page: TellomiAttachmentFilesViewController) {
        cancels += 1
    }

    func filesPage(_ page: TellomiAttachmentFilesViewController, didSelectDockItem item: TellomiAttachmentDockItem) {
        dockSelections.append(item)
    }

    func filesPage(_ page: TellomiAttachmentFilesViewController, sendFilesAt urls: [URL]) {
        pickedURLs.append(urls)
    }

    func filesPage(_ page: TellomiAttachmentFilesViewController, send files: [TellomiRecentFile], messageBody: MessageBody?) {
        sent.append(Sent(files: files, body: messageBody))
    }

    func filesPageDidSelectGallery(_ page: TellomiAttachmentFilesViewController) {
        galleryRequests += 1
    }
}

private final class RecordingGalleryDelegate: TellomiFilesGalleryDelegate {
    struct Sent {
        let items: [TellomiPhotoPickerItem]
        let convertHeicToJpeg: Bool
        let caption: String?
    }

    var cancels = 0
    var sent = [Sent]()

    func filesGalleryDidCancel(_ gallery: TellomiFilesGalleryViewController) {
        cancels += 1
    }

    func filesGallery(_ gallery: TellomiFilesGalleryViewController, send items: [TellomiPhotoPickerItem], convertHeicToJpeg: Bool, caption: String?) {
        sent.append(Sent(items: items, convertHeicToJpeg: convertHeicToJpeg, caption: caption))
    }
}

/// 容器测试用：没有任何照片的相册。
private final class EmptyPhotoLibrary: TellomiPhotoPickerLibrary {
    var isAccessLimited = false
    var isAccessDenied = false
    var onChange: (() -> Void)?

    func albums() -> [TellomiPhotoPickerAlbum] {
        [TellomiPhotoPickerAlbum(id: "recents", title: "Recents", count: 0, isRecents: true)]
    }

    func itemCount(in album: TellomiPhotoPickerAlbum) -> Int { 0 }

    func item(at index: Int, in album: TellomiPhotoPickerAlbum) -> TellomiPhotoPickerItem {
        fatalError("no items")
    }

    func requestThumbnail(for item: TellomiPhotoPickerItem, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) -> TellomiPhotoPickerRequest {
        fatalError("no items")
    }

    func attachment(for item: TellomiPhotoPickerItem, attachmentLimits: OutgoingAttachmentLimits) async throws -> PreviewableAttachment {
        fatalError("no items")
    }

    func isHeic(_ item: TellomiPhotoPickerItem) -> Bool { false }

    func originalFileName(for item: TellomiPhotoPickerItem) -> String? { nil }

    func fileAttachment(for item: TellomiPhotoPickerItem, convertHeicToJpeg: Bool, attachmentLimits: OutgoingAttachmentLimits) async throws -> TellomiPhotoPickerFile {
        fatalError("no items")
    }
}

/// F-3 的相册网格用：「Recents」[recentCount] 项（r0…）、「Empty」一项都没有；[heicIds] 里的算 HEIC；缩略图是纯色块。
private final class GalleryPhotoLibrary: TellomiPhotoPickerLibrary {
    var isAccessLimited = false
    var isAccessDenied = false
    var onChange: (() -> Void)?

    private let recentCount: Int
    private let heicIds: Set<String>

    init(recentCount: Int = 12, heicIds: Set<String> = []) {
        self.recentCount = recentCount
        self.heicIds = heicIds
    }

    func albums() -> [TellomiPhotoPickerAlbum] {
        [
            TellomiPhotoPickerAlbum(id: "recents", title: "Recents", count: recentCount, isRecents: true),
            TellomiPhotoPickerAlbum(id: "empty", title: "Empty", count: 0, isRecents: false),
        ]
    }

    func itemCount(in album: TellomiPhotoPickerAlbum) -> Int {
        album.isRecents ? recentCount : 0
    }

    func item(at index: Int, in album: TellomiPhotoPickerAlbum) -> TellomiPhotoPickerItem {
        TellomiPhotoPickerItem(id: "r\(index)", isVideo: index == 1, duration: index == 1 ? 42 : 0, isLivePhoto: false, isAnimatedImage: false, pixelSize: CGSize(width: 3024, height: 4032), asset: nil)
    }

    private struct NoopRequest: TellomiPhotoPickerRequest {
        func cancel() {}
    }

    func requestThumbnail(for item: TellomiPhotoPickerItem, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) -> TellomiPhotoPickerRequest {
        let hue = CGFloat(Int(item.id.dropFirst()) ?? 0).truncatingRemainder(dividingBy: 12) / 12
        completion(UIImage.image(color: UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1), size: CGSize(square: 8)))
        return NoopRequest()
    }

    func attachment(for item: TellomiPhotoPickerItem, attachmentLimits: OutgoingAttachmentLimits) async throws -> PreviewableAttachment {
        throw OWSAssertionError("not used")
    }

    func isHeic(_ item: TellomiPhotoPickerItem) -> Bool { heicIds.contains(item.id) }

    func originalFileName(for item: TellomiPhotoPickerItem) -> String? { "IMG_\(item.id).JPG" }

    func fileAttachment(for item: TellomiPhotoPickerItem, convertHeicToJpeg: Bool, attachmentLimits: OutgoingAttachmentLimits) async throws -> TellomiPhotoPickerFile {
        throw OWSAssertionError("not used")
    }
}

private final class FilesTestApprovalDataSource: AttachmentApprovalViewControllerDataSource {
    var attachmentApprovalTextInputContextIdentifier: String? { nil }
    var attachmentApprovalRecipientNames: [String] { ["Alice"] }

    func attachmentApprovalMentionableAcis(tx: DBReadTransaction) -> [Aci] { [] }

    func attachmentApprovalMentionCacheInvalidationKey() -> String { "tellomi-files-tests" }
}

private final class RecordingNavigationPageDelegate: TellomiAttachmentNavigationPageDelegate {
    var items: [TellomiAttachmentDockItem] = []

    func navigationPage(_ page: TellomiAttachmentNavigationPage, didSelectDockItem item: TellomiAttachmentDockItem) {
        items.append(item)
    }
}
