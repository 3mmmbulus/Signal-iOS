//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import SignalServiceKit

/// Tellomi（tellomi/tellomi#1263，ADR-0068 §4.4，spec P-4）：实况照片的动态部分转成要发的 MP4——
/// H.264、长边不超过 848、视频约 1.6 Mbps、AAC 64 kbps 双声道、留声音、不截短（Telegram iOS `TGMediaVideoConverter` 的这组参数：
/// 848 / 1600 kbps / AAC 64 kbps，只取机制，代码是自己写的）。方向照原片的 `preferredTransform`。
enum TellomiLivePhotoTranscoder {

    static let maxLongEdge: CGFloat = 848
    static let videoBitRate = 1_600_000
    static let audioBitRate = 64_000

    enum TranscodeError: Error {
        case noVideoTrack
        case cannotRead
        case cannotWrite(Error?)
    }

    /// 输出的像素尺寸（变换前的方向）：等比缩到长边 ≤ 848，宽高都取偶数（H.264 要求）；本来就小的不放大。
    static func outputSize(for naturalSize: CGSize) -> CGSize {
        let width = abs(naturalSize.width), height = abs(naturalSize.height)
        guard width > 0, height > 0 else { return .zero }
        let scale = min(1, maxLongEdge / max(width, height))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(width), height: even(height))
    }

    @concurrent
    static func transcode(_ input: URL) async throws -> URL {
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TranscodeError.noVideoTrack
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (naturalSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let size = outputSize(for: naturalSize)

        let output = OWSFileSystem.temporaryFileUrl(fileExtension: "mp4", isAvailableWhileDeviceLocked: false)
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch {
            throw TranscodeError.cannotWrite(error)
        }
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ])
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false

        var pairs = [(AVAssetReaderTrackOutput, AVAssetWriterInput)]()
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw TranscodeError.cannotRead }
        reader.add(videoOutput)
        writer.add(videoInput)
        pairs.append((videoOutput, videoInput))

        if let audioTrack {
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: audioBitRate,
            ])
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                pairs.append((audioOutput, audioInput))
            }
        }

        guard reader.startReading(), writer.startWriting() else {
            try? OWSFileSystem.deleteFileIfExists(url: output)
            throw TranscodeError.cannotWrite(writer.error ?? reader.error)
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (index, (readerOutput, writerInput)) in pairs.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "org.tellomi.livephoto.transcode.\(index)")
                        writerInput.requestMediaDataWhenReady(on: queue) {
                            while writerInput.isReadyForMoreMediaData {
                                guard reader.status == .reading, let buffer = readerOutput.copyNextSampleBuffer() else {
                                    writerInput.markAsFinished()
                                    continuation.resume()
                                    return
                                }
                                if !writerInput.append(buffer) {
                                    writerInput.markAsFinished()
                                    continuation.resume()
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }

        if reader.status == .failed || writer.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            try? OWSFileSystem.deleteFileIfExists(url: output)
            throw TranscodeError.cannotWrite(writer.error ?? reader.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? OWSFileSystem.deleteFileIfExists(url: output)
            throw TranscodeError.cannotWrite(writer.error)
        }
        return output
    }
}
