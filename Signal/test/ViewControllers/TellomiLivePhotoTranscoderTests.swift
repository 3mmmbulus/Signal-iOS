//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import XCTest

@testable import Signal
@testable import SignalServiceKit

/// tellomi/tellomi#1263, ADR-0068 §4.4: the moving half of a live photo goes out as H.264, long edge ≤ 848, about 1.6 Mbps,
/// AAC 64 kbps with its sound, in its original orientation.
final class TellomiLivePhotoTranscoderTests: XCTestCase {

    func testOutputSizeKeepsTheAspectAndEvenSides() {
        XCTAssertEqual(TellomiLivePhotoTranscoder.outputSize(for: CGSize(width: 1920, height: 1440)), CGSize(width: 848, height: 636))
        XCTAssertEqual(TellomiLivePhotoTranscoder.outputSize(for: CGSize(width: 1080, height: 1920)), CGSize(width: 478, height: 848))
        XCTAssertEqual(TellomiLivePhotoTranscoder.outputSize(for: CGSize(width: 1920, height: 1080)), CGSize(width: 848, height: 478))
        // Smaller than the limit: not scaled up.
        XCTAssertEqual(TellomiLivePhotoTranscoder.outputSize(for: CGSize(width: 640, height: 480)), CGSize(width: 640, height: 480))
        XCTAssertEqual(TellomiLivePhotoTranscoder.outputSize(for: .zero), .zero)
    }

    func testAPairedVideoBecomesASmallH264Mp4() async throws {
        // Like an iPhone paired video: 1920 × 1080 stored sideways with a 90° transform, with sound, 2 s.
        let source = try await Self.makeSourceMovie(size: CGSize(width: 1920, height: 1080), seconds: 2, transform: CGAffineTransform(rotationAngle: .pi / 2))
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await TellomiLivePhotoTranscoder.transcode(source)
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertEqual(output.pathExtension, "mp4")

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let (size, transform, formats, rate) = try await video.load(.naturalSize, .preferredTransform, .formatDescriptions, .estimatedDataRate)
        XCTAssertEqual(size, CGSize(width: 848, height: 478))
        // Keeps the orientation (90°: a = 0, b = 1, c = -1, d = 0).
        XCTAssertEqual(transform.a, 0, accuracy: 0.001)
        XCTAssertEqual(transform.b, 1, accuracy: 0.001)
        XCTAssertEqual(transform.c, -1, accuracy: 0.001)
        XCTAssertEqual(transform.d, 0, accuracy: 0.001)
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_H264)
        XCTAssertLessThan(rate, 2_200_000, "about 1.6 Mbps")

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first, "keeps the sound")
        let audioFormats = try await audio.load(.formatDescriptions)
        XCTAssertEqual(audioFormats.first.map(CMFormatDescriptionGetMediaSubType), kAudioFormatMPEG4AAC)

        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.2, "not cut short")
    }

    // MARK: - Source movie

    private static func makeSourceMovie(size: CGSize, seconds: Int, transform: CGAffineTransform) async throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tellomi-live-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        video.transform = transform
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        for frame in 0..<(Int32(seconds) * fps) {
            while !video.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let buffer = try XCTUnwrap(makeFrame(size: size, pool: adaptor.pixelBufferPool, hue: CGFloat(frame) / CGFloat(Int32(seconds) * fps)))
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        video.markAsFinished()

        // Silence in 1024-frame packets.
        let sampleRate = 44_100
        var written = 0
        while written < sampleRate * seconds {
            while !audio.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let count = min(1024, sampleRate * seconds - written)
            audio.append(try makeSilence(frames: count, at: written, sampleRate: sampleRate))
            written += count
        }
        audio.markAsFinished()

        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    private static func makeFrame(size: CGSize, pool: CVPixelBufferPool?, hue: CGFloat) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return nil }
        context.setFillColor(UIColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: size.width * hue, y: size.height * 0.3, width: size.height * 0.4, height: size.height * 0.4))
        return buffer
    }

    private static func makeSilence(frames: Int, at start: Int, sampleRate: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0,
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let length = frames * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let blockBuffer = try XCTUnwrap(block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: length)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: try XCTUnwrap(format),
            sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil,
            sampleBufferOut: &sample,
        )
        return try XCTUnwrap(sample)
    }
}
