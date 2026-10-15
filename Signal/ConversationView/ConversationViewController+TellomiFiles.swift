//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Tellomi（tellomi/tellomi#1121）：附件 Sheet「文件」页交给会话页的事——发文件、换页、dock 的别的格子。
extension ConversationViewController {

    func makeTellomiFilesPage() -> TellomiAttachmentFilesViewController {
        let limits = OutgoingAttachmentLimits.currentLimits()
        let page = TellomiAttachmentFilesViewController(
            source: TellomiRecentFilesDatabaseSource(),
            // F-9：上限读服务端下发的配置（remoteConfig），不写死
            maxFileSizeText: ByteCountFormatter.string(fromByteCount: Int64(clamping: limits.maxPlaintextBytes), countStyle: .file),
            canScan: VNDocumentCameraViewController.isSupported,
            // 同选图页那份：GIF 只在能用时列（#1078 isGifAvailable）
            dockItems: TellomiAttachmentDockItem.attachmentSheetItems,
        )
        page.delegate = self
        return page
    }
}

extension ConversationViewController: TellomiAttachmentFilesDelegate {

    func filesPageDidCancel(_ page: TellomiAttachmentFilesViewController) {
        dismiss(animated: true)
    }

    func filesPage(_ page: TellomiAttachmentFilesViewController, didSelectDockItem item: TellomiAttachmentDockItem) {
        switch item {
        case .file:
            break
        case .gallery, .poll, .contact, .location:
            if let container = page.parent as? TellomiAttachmentSheetController, tellomiOpenInSheet(item, container: container) {
                return
            }
            fallthrough
        case .gif:
            dismiss(animated: true) { [weak self] in
                guard let self else { return }
                switch item {
                case .location: self.locationButtonPressed()
                case .poll: self.pollButtonPressed()
                case .contact: self.contactButtonPressed()
                // owner 2026-09-26 临时加回的 GIF：同选图页 dock，走上游 GIF 键的处理
                case .gif: self.gifButtonPressed()
                case .gallery, .file: break
                }
            }
        }
    }

    /// F-4、F-5：系统文件选择器挑的（可多选）或扫描合成的 PDF：每个一条、立即发送，发完收起 Sheet。
    /// 超过上限的不发，发完剩下的再提示「文件太大」并写明上限。图片、视频按 ADR-0068 的 asFile 发原文件
    /// （不压缩、不转码，对方画成文件行、用系统应用打开），tellomi/tellomi#1263 之前是压成照片 / 转成 mp4 发的。
    func filesPage(_ page: TellomiAttachmentFilesViewController, sendFilesAt urls: [URL]) {
        let limits = OutgoingAttachmentLimits.currentLimits()
        tellomiSendPreparedFiles(from: page, limits: limits) {
            var prepared = TellomiPreparedFiles()
            for url in urls {
                do {
                    if let attachment = try await Self.tellomiBuildFileAttachment(url: url, limits: limits) {
                        prepared.attachments.append(attachment)
                    } else {
                        prepared.tooLarge.append(url.lastPathComponent)
                    }
                } catch {
                    Logger.warn("Couldn't prepare picked file: \(error)")
                    prepared.failed = true
                }
            }
            return prepared
        }
    }

    /// F-3（tellomi/tellomi#1263，owner 2026-10-13 照 Telegram）：先收起附件 Sheet，再整屏推出相册网格；取消就回到聊天
    /// （Telegram iOS `attachmentController?.dismiss` 后 `presentFileGallery`）。网格用自己的一份系统相册（`onChange` 只有一个）。
    func filesPageDidSelectGallery(_ page: TellomiAttachmentFilesViewController) {
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            let gallery = TellomiFilesGalleryViewController(library: TellomiSystemPhotoLibrary())
            gallery.delegate = self
            gallery.modalPresentationStyle = .fullScreen
            self.present(gallery, animated: true)
        }
    }
    /// 文件页几条「立即发送」的共同收尾：转圈里准备好附件，每个一条发出去；超过上限的发完再提示「文件太大」并写明上限，
    /// 一个都没准备成就提示失败；发出去了就收起 Sheet。
    fileprivate func tellomiSendPreparedFiles(
        from presenter: UIViewController,
        limits: OutgoingAttachmentLimits,
        messageBody: MessageBody? = nil,
        prepare: @escaping () async -> TellomiPreparedFiles,
    ) {
        ModalActivityIndicatorViewController.present(
            fromViewController: presenter,
            title: CommonStrings.preparingModal,
            asyncBlock: { modal in
                let prepared = await prepare()
                let attachments = prepared.attachments
                if !attachments.isEmpty {
                    await TellomiPhotoPickerSending.sendSeparately(
                        ApprovedAttachments(nonViewOnceAttachments: attachments, imageQuality: .standard),
                        messageBody: messageBody,
                    ) { part, body in
                        // 文件页发的东西不带聊天输入框里的草稿：发完不清（同 Android clearCompose = false）
                        await self.sendAttachments(part, messageBody: body, from: presenter, attachmentLimits: limits, clearsDraft: false)
                    }
                }
                modal.dismiss(completion: {
                    if let name = prepared.tooLarge.first {
                        let limitText = ByteCountFormatter.string(fromByteCount: Int64(clamping: limits.maxPlaintextBytes), countStyle: .file)
                        OWSActionSheets.showActionSheet(title: String.nonPluralLocalizedStringWithFormat(
                            OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_TOO_LARGE_FORMAT", comment: "Alert when a picked file is over the size limit. Embeds {{file name}} and {{maximum size of one file}}."),
                            name,
                            limitText,
                        ), fromViewController: attachments.isEmpty ? presenter : nil)
                    } else if prepared.failed, attachments.isEmpty {
                        OWSActionSheets.showActionSheet(title: OWSLocalizedString("ATTACHMENT_PICKER_DOCUMENTS_FAILED_ALERT_TITLE", comment: "Alert title when picking a document fails for an unknown reason"), fromViewController: presenter)
                    }
                    if !attachments.isEmpty {
                        self.dismiss(animated: true)
                    }
                })
            },
        )
    }

    /// 一个挑来的文件变成要发的附件；超过上限返回 nil（交给调用方统一提示）。
    static func tellomiBuildFileAttachment(url: URL, limits: OutgoingAttachmentLimits) async throws -> PreviewableAttachment? {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            throw OWSAssertionError("Picked a directory")
        }
        if let size = values?.fileSize, UInt64(size) > limits.maxPlaintextBytes {
            return nil
        }
        let dataSource = DataSourcePath(fileUrl: url, ownership: .owned)
        dataSource.sourceFilename = url.lastPathComponent.strippedOrNil
        let dataUTI = (values?.contentType ?? .data).identifier
        do {
            if SignalAttachment.inputImageUTISet.contains(dataUTI) || SignalAttachment.videoUTISet.contains(dataUTI) {
                return try PreviewableAttachment.tellomiAsFileAttachment(dataSource: dataSource, dataUTI: dataUTI, attachmentLimits: limits)
            }
            return try PreviewableAttachment.buildAttachment(dataSource: dataSource, dataUTI: dataUTI, attachmentLimits: limits)
        } catch SignalAttachmentError.fileSizeTooLarge {
            return nil
        }
    }

    /// F-7、F-8：再发本机已有的文件——同上游「转发」：从原消息的附件引用取出本机那份（解密出一份临时明文），
    /// 走正常的发送；落库时按内容哈希认出是同一份，不会多存一份（`AttachmentManagerImpl`）。
    /// 多个文件每个一条，说明挂在最后一个；发完收起 Sheet。
    func filesPage(_ page: TellomiAttachmentFilesViewController, send files: [TellomiRecentFile], messageBody: MessageBody?) {
        let limits = OutgoingAttachmentLimits.currentLimits()
        let streams: [ReferencedAttachmentStream] = SSKEnvironment.shared.databaseStorageRef.read { tx in
            files.compactMap { file in
                DependenciesBridge.shared.attachmentStore
                    .fetchReferencedAttachmentsOwnedByMessage(messageRowId: file.messageRowId, tx: tx)
                    .first { $0.attachment.id == file.attachmentRowId }?
                    .asReferencedStream
            }
        }
        guard streams.count == files.count else {
            OWSActionSheets.showActionSheet(title: OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_NOT_ON_DEVICE_CANT_SEND", comment: "Toast shown when tapping a recently sent file whose local copy was deleted."), fromViewController: page)
            return
        }
        ModalActivityIndicatorViewController.present(
            fromViewController: page,
            title: CommonStrings.preparingModal,
            asyncBlock: { modal in
                do {
                    let attachments = try streams.map { try SignalAttachmentCloner.cloneAsSignalAttachment(attachment: $0, attachmentLimits: limits) }
                    await TellomiPhotoPickerSending.sendSeparately(
                        ApprovedAttachments(nonViewOnceAttachments: attachments, imageQuality: .standard),
                        messageBody: messageBody,
                    ) { part, body in
                        // 文件页发的东西不带聊天输入框里的草稿：发完不清（同 Android clearCompose = false）
                        await self.sendAttachments(part, messageBody: body, from: page, attachmentLimits: limits, clearsDraft: false)
                    }
                    modal.dismiss(completion: {
                        self.dismiss(animated: true)
                    })
                } catch {
                    owsFailDebug("Couldn't resend file: \(error)")
                    modal.dismiss(completion: {
                        OWSActionSheets.showActionSheet(title: OWSLocalizedString("ATTACHMENT_PICKER_DOCUMENTS_FAILED_ALERT_TITLE", comment: "Alert title when picking a document fails for an unknown reason"), fromViewController: page)
                    })
                }
            },
        )
    }
}


extension ConversationViewController: TellomiFilesGalleryDelegate {

    func filesGalleryDidCancel(_ gallery: TellomiFilesGalleryViewController) {
        gallery.dismiss(animated: true)
    }

    /// F-3：「从相册中选择」勾的：相册里的原文件、原文件名（ADR-0068 asFile，不压缩、不转码；选了「转成 JPEG」的 HEIC 除外），
    /// 按勾选的顺序每个一条、立即发送，说明挂最后一个；超过上限的同「从文件中选择」；发完收起网格。
    func filesGallery(_ gallery: TellomiFilesGalleryViewController, send items: [TellomiPhotoPickerItem], convertHeicToJpeg: Bool, caption: String?) {
        let limits = OutgoingAttachmentLimits.currentLimits()
        let library = gallery.library
        let messageBody = caption.map { MessageBody(text: $0, ranges: .empty) }
        tellomiSendPreparedFiles(from: gallery, limits: limits, messageBody: messageBody) {
            var prepared = TellomiPreparedFiles()
            for item in items {
                do {
                    switch try await library.fileAttachment(for: item, convertHeicToJpeg: convertHeicToJpeg, attachmentLimits: limits) {
                    case .attachment(let attachment): prepared.attachments.append(attachment)
                    case .tooLarge(let fileName): prepared.tooLarge.append(fileName)
                    }
                } catch {
                    Logger.warn("Couldn't prepare a gallery item as a file: \(error)")
                    prepared.failed = true
                }
            }
            return prepared
        }
    }
}

/// Tellomi（#1121、#1263）：文件页一次「立即发送」准备好的东西。
private struct TellomiPreparedFiles {
    var attachments = [PreviewableAttachment]()
    /// 超过上限、没发的文件名。
    var tooLarge = [String]()
    /// 有读不出来的。
    var failed = false
}
