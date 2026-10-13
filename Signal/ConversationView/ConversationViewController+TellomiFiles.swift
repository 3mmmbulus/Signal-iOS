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
        case .gallery:
            (page.parent as? TellomiAttachmentSheetController)?.show(.gallery)
        case .file:
            break
        case .location, .poll, .contact, .gif:
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
        ModalActivityIndicatorViewController.present(
            fromViewController: page,
            title: CommonStrings.preparingModal,
            asyncBlock: { modal in
                var attachments = [PreviewableAttachment]()
                var tooLarge = [String]()
                var failed = false
                for url in urls {
                    do {
                        if let attachment = try await Self.tellomiBuildFileAttachment(url: url, limits: limits) {
                            attachments.append(attachment)
                        } else {
                            tooLarge.append(url.lastPathComponent)
                        }
                    } catch {
                        Logger.warn("Couldn't prepare picked file: \(error)")
                        failed = true
                    }
                }
                if !attachments.isEmpty {
                    await TellomiPhotoPickerSending.sendSeparately(
                        ApprovedAttachments(nonViewOnceAttachments: attachments, imageQuality: .standard),
                        messageBody: nil,
                    ) { part, body in
                        // 文件页发的东西不带聊天输入框里的草稿：发完不清（同 Android clearCompose = false）
                        await self.sendAttachments(part, messageBody: body, from: page, attachmentLimits: limits, clearsDraft: false)
                    }
                }
                modal.dismiss(completion: {
                    if let name = tooLarge.first {
                        let limitText = ByteCountFormatter.string(fromByteCount: Int64(clamping: limits.maxPlaintextBytes), countStyle: .file)
                        OWSActionSheets.showActionSheet(title: String.nonPluralLocalizedStringWithFormat(
                            OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_TOO_LARGE_FORMAT", comment: "Alert when a picked file is over the size limit. Embeds {{file name}} and {{maximum size of one file}}."),
                            name,
                            limitText,
                        ), fromViewController: attachments.isEmpty ? page : nil)
                    } else if failed, attachments.isEmpty {
                        OWSActionSheets.showActionSheet(title: OWSLocalizedString("ATTACHMENT_PICKER_DOCUMENTS_FAILED_ALERT_TITLE", comment: "Alert title when picking a document fails for an unknown reason"), fromViewController: page)
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
