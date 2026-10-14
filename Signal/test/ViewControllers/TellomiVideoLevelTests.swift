//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1518 V-7 ②）：每个视频各选画质（照 Telegram 两端）——档不超过原件，选了高的档发送前从原件按这一档导出，
/// 选回 360p 就是上游选图时压好的那份。
final class TellomiVideoLevelTests: SignalBaseTest {

    func testLevelsGoUpToTheSource() {
        XCTAssertEqual(TellomiVideoLevel.available(forDisplaySize: CGSize(width: 1920, height: 1080)), [.p360, .p540, .p720, .p1080])
        XCTAssertEqual(TellomiVideoLevel.available(forDisplaySize: CGSize(width: 1080, height: 1920)), [.p360, .p540, .p720, .p1080])
        XCTAssertEqual(TellomiVideoLevel.available(forDisplaySize: CGSize(width: 3840, height: 2160)), [.p360, .p540, .p720, .p1080])
        XCTAssertEqual(TellomiVideoLevel.available(forDisplaySize: CGSize(width: 1280, height: 720)), [.p360, .p540, .p720])
        XCTAssertEqual(TellomiVideoLevel.available(forDisplaySize: CGSize(width: 960, height: 540)), [.p360, .p540])
        XCTAssertEqual(TellomiVideoLevel.available(forDisplaySize: CGSize(width: 640, height: 360)), [.p360])
        XCTAssertEqual(TellomiVideoLevel.available(forDisplaySize: .zero), [])
        XCTAssertEqual(TellomiVideoLevel.upstreamDefault.exportPreset, AVAssetExportPreset640x480)
        XCTAssertTrue(TellomiVideoLevel.p720.isHighDefinition)
        XCTAssertFalse(TellomiVideoLevel.p540.isHighDefinition)
    }

    /// 选 720p：要重新导出，导出来长边 1280；选回 360p（没剪）就不用导出，用选图时那份。
    @MainActor
    func testPickedLevelExportsFromTheSource() async throws {
        let sourceUrl = try await Self.makeVideo(size: CGSize(width: 1920, height: 1080), frames: 20)
        let model = try Self.model(sourceUrl: sourceUrl, sourceSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(model.tellomiAvailableLevels, [.p360, .p540, .p720, .p1080])
        XCTAssertFalse(model.needsRender)

        model.tellomiLevel = .p720
        XCTAssertTrue(model.needsRender)
        let estimate = await model.tellomiEstimatedBytes(for: .p720)
        XCTAssertGreaterThan(estimate ?? 0, 0)

        let output = try await model.render()
        let track = try XCTUnwrap(AVURLAsset(url: output).tracks(withMediaType: .video).first)
        XCTAssertEqual(max(track.naturalSize.width, track.naturalSize.height), 1280, accuracy: 1)

        model.tellomiLevel = .p360
        XCTAssertFalse(model.needsRender, "360p is what the picker already compressed to")
    }

    /// 不是从相册选的视频（没有原件）不给选档，也不会因为档去导出。
    @MainActor
    func testVideoWithoutSourceHasNoLevels() async throws {
        let url = try await Self.makeVideo(size: CGSize(width: 1920, height: 1080), frames: 10)
        let attachment = try PreviewableAttachment.videoAttachment(
            dataSource: DataSourcePath(fileUrl: url, ownership: .borrowed),
            dataUTI: UTType.mpeg4Movie.identifier,
            attachmentLimits: .currentLimits(remoteConfig: .current, callingCode: nil),
        )
        let model = try XCTUnwrap(try VideoEditorModel(attachment))
        XCTAssertEqual(model.tellomiAvailableLevels, [])
        model.tellomiLevel = .p1080
        XCTAssertFalse(model.needsRender)
    }

    // MARK: - Helpers

    @MainActor
    private static func model(sourceUrl: URL, sourceSize: CGSize) throws -> VideoEditorModel {
        var attachment = try PreviewableAttachment.videoAttachment(
            dataSource: DataSourcePath(fileUrl: sourceUrl, ownership: .borrowed),
            dataUTI: UTType.mpeg4Movie.identifier,
            attachmentLimits: .currentLimits(remoteConfig: .current, callingCode: nil),
        )
        attachment.tellomiVideoSource = TellomiVideoSource(assetIdentifier: "test", pixelSize: sourceSize)
        let model = try XCTUnwrap(try VideoEditorModel(attachment))
        model.tellomiLoadSourceAsset = { _ in AVURLAsset(url: sourceUrl) }
        return model
    }

    /// 写一段纯色的 H.264 视频（30 fps）。
    private static func makeVideo(size: CGSize, frames: Int) async throws -> URL {
        let url = OWSFileSystem.temporaryFileUrl(fileExtension: "mp4", isAvailableWhileDeviceLocked: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, Int32(40 + frame * 5), CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }
}
