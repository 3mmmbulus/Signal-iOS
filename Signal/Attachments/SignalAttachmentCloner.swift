//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import SignalUI

enum SignalAttachmentCloner {
    static func cloneAsSignalAttachment(
        attachment: ReferencedAttachmentStream,
        attachmentLimits: OutgoingAttachmentLimits,
    ) throws -> PreviewableAttachment {
        guard let dataUTI = MimeTypeUtil.utiTypeForMimeType(attachment.attachmentStream.mimeType) else {
            throw OWSAssertionError("Missing dataUTI.")
        }

        let decryptedCopyUrl = try attachment.attachmentStream.makeDecryptedCopy(
            filename: attachment.reference.sourceFilename,
        )

        let decryptedDataSource = DataSourcePath(fileUrl: decryptedCopyUrl, ownership: .owned)
        decryptedDataSource.sourceFilename = attachment.reference.sourceFilename

        let result: PreviewableAttachment
        switch attachment.reference.renderingFlag {
        case .default:
            result = try PreviewableAttachment.buildAttachment(dataSource: decryptedDataSource, dataUTI: dataUTI, attachmentLimits: attachmentLimits)
        case .voiceMessage:
            result = try PreviewableAttachment.voiceMessageAttachment(dataSource: decryptedDataSource, dataUTI: dataUTI, attachmentLimits: attachmentLimits)
        case .borderless:
            result = try PreviewableAttachment.imageAttachment(dataSource: decryptedDataSource, dataUTI: dataUTI)
            result.rawValue.isBorderless = true
        case .shouldLoop:
            result = try PreviewableAttachment.buildAttachment(dataSource: decryptedDataSource, dataUTI: dataUTI, attachmentLimits: attachmentLimits)
            result.rawValue.isLoopingVideo = true
        case .tellomiAsFile:
            // Tellomi (ADR-0068): sent again as the same original file, not re-normalized into a photo.
            result = try PreviewableAttachment.tellomiAsFileAttachment(dataSource: decryptedDataSource, dataUTI: dataUTI, attachmentLimits: attachmentLimits)
        }
        // Tellomi (ADR-0068 §4.4 "转发"): a live photo is forwarded with its motion when this device has it (our own, or played
        // this run — a received one plays whenever it comes on screen); the spoiler is not carried over.
        if result.isImage {
            result.rawValue.tellomiLivePhotoVideo = SSKEnvironment.shared.databaseStorageRef.read { tx in
                TellomiLivePhoto.video(attachment.reference, tx: tx)
            }.flatMap(TellomiLivePhoto.localVideoFile(_:))
        }
        return result
    }
}
