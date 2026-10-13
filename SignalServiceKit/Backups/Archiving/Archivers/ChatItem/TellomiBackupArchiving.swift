//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（tellomi/tellomi#1263，ADR-0068 §4.5 / §4.7）：附件的呈现方式和「说明在上方」进出备份
/// （`MessageAttachment.tellomi = 1001`、`StandardMessage.tellomi = 1000`，同 tellomi/libsignal 与另外两端）。
///
/// 导出：渲染标记里的按文件、`TellomiMediaSpoiler` 里的遮罩（这台设备揭示过没有不导出，spec D10）、`TellomiLivePhoto` 里的实况指针
/// （动态部分不落库，转成只有传输层位置的 `FilePointer`）、`TellomiCaptionAbove`。
/// 导入：把这几项拼回一个 `SSKProtoAttachmentPointer`，走收到消息时的同一套 `markReceived`，规则和本机落点都和收到时一样；
/// 引用缩略图不按文件、不带实况（同另外两端）。
enum TellomiBackupArchiving {

    // MARK: - Export

    static func attachment(
        _ reference: AttachmentReference,
        tx: DBReadTransaction,
    ) -> BackupProto_TellomiAttachment? {
        let asFile = reference.renderingFlag == .tellomiAsFile
        let spoiler = TellomiMediaSpoiler.isSpoiler(reference, tx: tx)
        let livePhotoVideo = TellomiLivePhoto.storedPointer(reference, tx: tx).flatMap(filePointer(from:))
        guard asFile || spoiler || livePhotoVideo != nil else {
            return nil
        }
        var proto = BackupProto_TellomiAttachment()
        proto.asFile = asFile
        proto.spoiler = spoiler
        if let livePhotoVideo {
            proto.livePhotoVideo = livePhotoVideo
        }
        return proto
    }

    static func standardMessage(_ message: TSMessage, tx: DBReadTransaction) -> BackupProto_TellomiStandardMessage? {
        guard TellomiCaptionAbove.isCaptionAboveMedia(messageUniqueId: message.uniqueId, tx: tx) else {
            return nil
        }
        var proto = BackupProto_TellomiStandardMessage()
        proto.captionAboveMedia = true
        return proto
    }

    /// The moving half as where it is on the transit tier (key, digest, CDN key and number), like when it was received.
    /// No incremental MAC: iOS doesn't keep one for received pointers either.
    private static func filePointer(from video: SSKProtoAttachmentPointer) -> BackupProto_FilePointer? {
        guard
            let cdnKey = video.cdnKey?.nilIfEmpty,
            let key = video.key?.nilIfEmpty,
            let digest = video.digest?.nilIfEmpty
        else {
            return nil
        }
        var locator = BackupProto_FilePointer.LocatorInfo()
        locator.key = key
        locator.encryptedDigest = digest
        locator.size = video.size
        locator.transitCdnKey = cdnKey
        locator.transitCdnNumber = video.cdnNumber
        if video.hasUploadTimestamp, video.uploadTimestamp > 0 {
            locator.transitTierUploadTimestamp = video.uploadTimestamp
        }

        var pointer = BackupProto_FilePointer()
        if let contentType = video.contentType {
            pointer.contentType = contentType
        }
        if let fileName = video.fileName {
            pointer.fileName = fileName
        }
        if video.hasWidth, video.width > 0 {
            pointer.width = video.width
        }
        if video.hasHeight, video.height > 0 {
            pointer.height = video.height
        }
        pointer.locatorInfo = locator
        return pointer
    }

    // MARK: - Import

    /// The rendering flag it was received with: sent as a file wins, but never on a quoted thumbnail.
    static func renderingFlag(
        _ attachment: BackupProto_MessageAttachment,
        isQuotedThumbnail: Bool,
    ) -> AttachmentReference.RenderingFlag {
        if !isQuotedThumbnail, attachment.hasTellomi, attachment.tellomi.asFile {
            return .tellomiAsFile
        }
        return attachment.flag.asAttachmentFlag
    }

    /// Covered and live photo, recorded as when it was received (`markReceived`). Call with the owner the attachment
    /// is restored with.
    static func restore(
        _ attachment: BackupProto_MessageAttachment,
        owner: AttachmentReference.OwnerBuilder,
        tx: DBWriteTransaction,
    ) {
        guard attachment.hasTellomi else {
            return
        }
        let backup = attachment.tellomi
        let tellomi = SSKProtoTellomiAttachment.builder()
        tellomi.setAsFile(backup.asFile)
        tellomi.setSpoiler(backup.spoiler)
        if backup.hasLivePhotoVideo, let video = videoPointer(from: backup.livePhotoVideo) {
            tellomi.setLivePhotoVideo(video)
        }
        let mimeType = attachment.pointer.contentType
        let pointer = SSKProtoAttachmentPointer.builder()
        pointer.setContentType(mimeType)
        pointer.setTellomi(tellomi.buildInfallibly())
        let proto = pointer.buildInfallibly()

        TellomiMediaSpoiler.markReceived(proto, mimeType: mimeType, owner: owner, tx: tx)
        TellomiLivePhoto.markReceived(proto, mimeType: mimeType, owner: owner, tx: tx)
    }

    /// Back to the pointer it was received as; `TellomiLivePhoto.videoPointer` then checks it like any received one.
    private static func videoPointer(from filePointer: BackupProto_FilePointer) -> SSKProtoAttachmentPointer? {
        guard filePointer.hasLocatorInfo else {
            return nil
        }
        let locator = filePointer.locatorInfo
        guard
            locator.hasTransitCdnKey,
            !locator.transitCdnKey.isEmpty,
            !locator.key.isEmpty,
            !locator.encryptedDigest.isEmpty
        else {
            return nil
        }
        let builder = SSKProtoAttachmentPointer.builder()
        builder.setCdnKey(locator.transitCdnKey)
        builder.setCdnNumber(locator.transitCdnNumber)
        builder.setKey(locator.key)
        builder.setDigest(locator.encryptedDigest)
        builder.setSize(locator.size)
        if locator.hasTransitTierUploadTimestamp {
            builder.setUploadTimestamp(locator.transitTierUploadTimestamp)
        }
        if filePointer.hasContentType {
            builder.setContentType(filePointer.contentType)
        }
        if filePointer.hasFileName {
            builder.setFileName(filePointer.fileName)
        }
        if filePointer.hasWidth {
            builder.setWidth(filePointer.width)
        }
        if filePointer.hasHeight {
            builder.setHeight(filePointer.height)
        }
        return builder.buildInfallibly()
    }
}
