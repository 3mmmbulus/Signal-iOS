//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1518 V-6，owner 2026-10-14 照 Telegram 两端）：静音的视频当 GIF 发——去音轨、压到 540p 框、单独成一条。
final class TellomiMutedVideoTests: SignalBaseTest {

    /// 静音：要重新导出、选过的档作废、不能再选档。
    @MainActor
    func testMutingDropsTheLevelAndNeedsARender() async throws {
        let url = try await Self.makeVideo(size: CGSize(width: 1920, height: 1080), frames: 15, withAudio: true)
        let model = try Self.model(url: url, sourceSize: CGSize(width: 1920, height: 1080))
        model.tellomiLevel = .p1080
        XCTAssertTrue(model.needsRender)

        model.tellomiIsMuted = true
        XCTAssertNil(model.tellomiLevel)
        XCTAssertTrue(model.needsRender)

        model.tellomiIsMuted = false
        XCTAssertFalse(model.needsRender)
    }

    /// 导出来没有音轨，画面压进 960×540 的框。
    @MainActor
    func testMutedExportHasNoSoundAndFitsTheBox() async throws {
        let url = try await Self.makeVideo(size: CGSize(width: 1920, height: 1080), frames: 15, withAudio: true)
        XCTAssertEqual(AVURLAsset(url: url).tracks(withMediaType: .audio).count, 1, "the source has sound")
        let model = try Self.model(url: url, sourceSize: CGSize(width: 1920, height: 1080))
        model.tellomiIsMuted = true

        let output = AVURLAsset(url: try await model.render())

        XCTAssertEqual(output.tracks(withMediaType: .audio).count, 0)
        let track = try XCTUnwrap(output.tracks(withMediaType: .video).first)
        XCTAssertLessThanOrEqual(max(track.naturalSize.width, track.naturalSize.height), 960)
        XCTAssertLessThanOrEqual(min(track.naturalSize.width, track.naturalSize.height), 540)
    }

    /// 静音视频单独一条、在后面；其余的一条在前、带说明；全是静音视频时说明跟最后一条；不用拆时是 nil。
    @MainActor
    func testMutedVideosGoOnePerMessageAfterTheRest() async throws {
        let photoA = try Self.photo()
        let photoB = try Self.photo()
        let muted = try await Self.mutedVideo()
        let mutedToo = try await Self.mutedVideo()

        let split = try XCTUnwrap(TellomiMutedVideoSending.messageGroups(
            ApprovedAttachments(nonViewOnceAttachments: [photoA, muted, photoB], imageQuality: .standard),
        ))
        XCTAssertEqual(split.groups.map { $0.attachments.count }, [2, 1])
        XCTAssertTrue(split.groups[1].attachments[0].rawValue.isLoopingVideo)
        XCTAssertEqual(split.bodyIndex, 0)

        let allMuted = try XCTUnwrap(TellomiMutedVideoSending.messageGroups(
            ApprovedAttachments(nonViewOnceAttachments: [muted, mutedToo], imageQuality: .standard),
        ))
        XCTAssertEqual(allMuted.groups.count, 2)
        XCTAssertEqual(allMuted.bodyIndex, 1)

        XCTAssertNil(TellomiMutedVideoSending.messageGroups(ApprovedAttachments(nonViewOnceAttachments: [photoA, photoB], imageQuality: .standard)))
        XCTAssertNil(TellomiMutedVideoSending.messageGroups(ApprovedAttachments(nonViewOnceAttachments: [muted], imageQuality: .standard)))
    }

    // MARK: - Helpers

    @MainActor
    private static func model(url: URL, sourceSize: CGSize) throws -> VideoEditorModel {
        var attachment = try PreviewableAttachment.videoAttachment(
            dataSource: DataSourcePath(fileUrl: url, ownership: .borrowed),
            dataUTI: UTType.mpeg4Movie.identifier,
            attachmentLimits: .currentLimits(remoteConfig: .current, callingCode: nil),
        )
        attachment.tellomiVideoSource = TellomiVideoSource(assetIdentifier: "test", pixelSize: sourceSize)
        let model = try XCTUnwrap(try VideoEditorModel(attachment))
        model.tellomiLoadSourceAsset = { _ in AVURLAsset(url: url) }
        return model
    }

    private static func photo() throws -> PreviewableAttachment {
        let image = UIImage.image(color: .orange, size: CGSize(square: 40))
        let url = OWSFileSystem.temporaryFileUrl(fileExtension: "png", isAvailableWhileDeviceLocked: true)
        try XCTUnwrap(image.pngData()).write(to: url)
        return try PreviewableAttachment.imageAttachment(dataSource: DataSourcePath(fileUrl: url, ownership: .owned), dataUTI: UTType.png.identifier)
    }

    private static func mutedVideo() async throws -> PreviewableAttachment {
        let url = try await makeVideo(size: CGSize(width: 320, height: 240), frames: 5, withAudio: false)
        let attachment = try PreviewableAttachment.videoAttachment(
            dataSource: DataSourcePath(fileUrl: url, ownership: .owned),
            dataUTI: UTType.mpeg4Movie.identifier,
            attachmentLimits: .currentLimits(remoteConfig: .current, callingCode: nil),
        )
        attachment.rawValue.isLoopingVideo = true
        return attachment
    }

    /// 写一段纯色 H.264 视频（30 fps），要的话带一条无声的 AAC 音轨。
    private static func makeVideo(size: CGSize, frames: Int, withAudio: Bool) async throws -> URL {
        let url = OWSFileSystem.temporaryFileUrl(fileExtension: "mp4", isAvailableWhileDeviceLocked: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(video)

        var audio: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
            var description = AudioStreamBasicDescription(
                mSampleRate: 44_100,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 2,
                mFramesPerPacket: 1,
                mBytesPerFrame: 2,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 16,
                mReserved: 0,
            )
            CMAudioFormatDescriptionCreate(
                allocator: nil,
                asbd: &description,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &audioFormat,
            )
        }

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let samplesPerFrame = 44_100 / 30
        for frame in 0..<frames {
            while !video.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, Int32(60 + frame * 7), CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))

            if let audio, let audioFormat {
                while !audio.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let byteCount = samplesPerFrame * 2
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil,
                    memoryBlock: nil,
                    blockLength: byteCount,
                    blockAllocator: nil,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: byteCount,
                    flags: kCMBlockBufferAssureMemoryNowFlag,
                    blockBufferOut: &block,
                )
                let blockBuffer = try XCTUnwrap(block)
                CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil,
                    dataBuffer: blockBuffer,
                    formatDescription: audioFormat,
                    sampleCount: samplesPerFrame,
                    presentationTimeStamp: CMTime(value: CMTimeValue(frame * samplesPerFrame), timescale: 44_100),
                    packetDescriptions: nil,
                    sampleBufferOut: &sample,
                )
                audio.append(try XCTUnwrap(sample))
            }
        }
        video.markAsFinished()
        audio?.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }
}
