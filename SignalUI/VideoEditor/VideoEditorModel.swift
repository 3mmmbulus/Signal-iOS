//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Photos
import SignalServiceKit

protocol VideoEditorModelObserver: AnyObject {
    func videoEditorModelDidChange(_ model: VideoEditorModel)
}

// MARK: -

// Should be @MainActor.
class VideoEditorModel: NSObject {

    let srcVideoPath: String

    let untrimmedDuration: CMTime

    var untrimmedDurationSeconds: TimeInterval {
        return untrimmedDuration.seconds
    }

    var trimmedDurationSeconds: TimeInterval {
        return max(0, trimmedEndSeconds - trimmedStartSeconds)
    }

    private(set) var trimmedStartSeconds: TimeInterval = 0

    private(set) var trimmedEndSeconds: TimeInterval = 0

    let naturalSize: CGSize

    let displaySize: CGSize

    // MARK: Tellomi video level (tellomi/tellomi#1518 V-7 ②)

    /// 相册里的原件；没有（不是从相册选的）就不能选档。
    let tellomiSource: TellomiVideoSource?

    /// 这个视频选的画质档；nil = 上游的样子（选图时压好的 360p）。
    var tellomiLevel: TellomiVideoLevel? {
        didSet {
            guard tellomiLevel != oldValue else { return }
            fireModelDidChange()
        }
    }

    /// Tellomi（tellomi/tellomi#1518 V-6，owner 2026-10-14 照 TG 两端）：静音 = 当 GIF 发——去音轨、压到 540p 框（TG iOS 848、安卓 854，
    /// 系统预设里最近的是 960×540）、自动播放循环；静音时不能选档，选过的档作废。
    var tellomiIsMuted = false {
        didSet {
            guard tellomiIsMuted != oldValue else { return }
            if tellomiIsMuted {
                tellomiLevel = nil
            }
            fireModelDidChange()
        }
    }

    static let tellomiMutedExportPreset = AVAssetExportPreset960x540

    /// 原件能选的档；不到两档就不给选。
    var tellomiAvailableLevels: [TellomiVideoLevel] {
        guard let tellomiSource else { return [] }
        return TellomiVideoLevel.available(forDisplaySize: tellomiSource.pixelSize)
    }

    /// 取原件的 AVAsset（测试里换成本地文件）。
    var tellomiLoadSourceAsset: (TellomiVideoSource) async throws -> AVAsset = VideoEditorModel.loadPhotoLibraryAsset

    /// 取过一次就留着：菜单估几档的大小、发送时导出都用同一个。
    private var tellomiSourceAsset: AVAsset?

    private func tellomiResolvedSourceAsset(_ source: TellomiVideoSource) async throws -> AVAsset {
        if let tellomiSourceAsset {
            return tellomiSourceAsset
        }
        let asset = try await tellomiLoadSourceAsset(source)
        tellomiSourceAsset = asset
        return asset
    }

    static func loadPhotoLibraryAsset(_ source: TellomiVideoSource) async throws -> AVAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [source.assetIdentifier], options: nil).firstObject else {
            throw OWSAssertionError("Missing photo library asset")
        }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    let error = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: error ?? OWSAssertionError("Couldn't load the video"))
                }
            }
        }
    }

    /// 估这一档、按现在剪的范围导出大概多大（系统导出会话自己估）；估不出来是 nil。
    func tellomiEstimatedBytes(for level: TellomiVideoLevel) async -> Int64? {
        guard let tellomiSource, let asset = try? await tellomiResolvedSourceAsset(tellomiSource) else { return nil }
        guard let session = AVAssetExportSession(asset: asset, presetName: level.exportPreset) else { return nil }
        session.outputFileType = .mp4
        session.timeRange = trimmedTimeRange
        if #available(iOS 16, *) {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Int64?, Never>) in
                session.estimateOutputFileLength { length, error in
                    continuation.resume(returning: error == nil && length > 0 ? length : nil)
                }
            }
        }
        let length: Int64 = session.estimatedOutputFileLength
        return length > 0 ? length : nil
    }

    private var trimmedTimeRange: CMTimeRange {
        let cmStart = CMTime(seconds: trimmedStartSeconds, preferredTimescale: untrimmedDuration.timescale)
        let cmDuration = CMTime(seconds: trimmedDurationSeconds, preferredTimescale: untrimmedDuration.timescale)
        return CMTimeRange(start: cmStart, duration: cmDuration)
    }

    static let minimumDurationSeconds: TimeInterval = 1

    /// Tellomi (tellomi/tellomi#1518 V-4, owner 2026-10-13): as in Telegram, a video shorter than 1.5 s can't be trimmed
    /// at all (`TGVideoEditMinimumTrimmableDuration`); a trimmed clip can still be as short as 1 s (`minimumDurationSeconds`).
    static let minimumTrimmableDurationSeconds: TimeInterval = 1.5

    private var minimumDurationSeconds: TimeInterval {
        return VideoEditorModel.minimumDurationSeconds
    }

    var canBeTrimmed: Bool {
        return Self.canTrim(untrimmedDurationSeconds: untrimmedDurationSeconds)
    }

    static func canTrim(untrimmedDurationSeconds: TimeInterval) -> Bool {
        return untrimmedDurationSeconds >= minimumTrimmableDurationSeconds
    }

    var isTrimmed: Bool {
        return trimmedStartSeconds > 0 || trimmedEndSeconds < untrimmedDurationSeconds
    }

    // We don't want to allow editing of videos if:
    //
    // * They are invalid.
    // * We can't determine their size / aspect-ratio.
    init?(_ attachment: PreviewableAttachment) throws {
        guard attachment.rawValue.isVideo, !attachment.rawValue.isLoopingVideo else {
            return nil
        }
        let mediaUrl = attachment.rawValue.dataSource.fileUrl
        self.srcVideoPath = mediaUrl.path

        let asset = AVURLAsset(url: mediaUrl)

        let duration: CMTime = asset.duration
        guard duration.seconds > 0 else {
            throw OWSAssertionError("Invalid duration: \(duration).")
        }

        let videoTracks = asset.tracks(withMediaType: .video)
        guard let firstVideoTrack: AVAssetTrack = videoTracks.first else {
            throw OWSAssertionError("Missing video track.")
        }

        let naturalSize: CGSize = firstVideoTrack.naturalSize
        guard naturalSize.width > 0, naturalSize.height > 0 else {
            throw OWSAssertionError("Invalid naturalSize: \(naturalSize).")
        }
        let preferredTransform: CGAffineTransform = firstVideoTrack.preferredTransform
        let displaySize = naturalSize.applying(preferredTransform).abs
        guard displaySize.width > 0, displaySize.height > 0 else {
            throw OWSAssertionError("Invalid displaySize: \(displaySize).")
        }

        guard
            asset.isPlayable,
            asset.isExportable,
            asset.isReadable,
            !asset.hasProtectedContent
        else {
            throw OWSAssertionError("Invalid content.")
        }

        self.untrimmedDuration = duration
        self.naturalSize = naturalSize
        self.displaySize = displaySize
        self.tellomiSource = attachment.tellomiVideoSource
        self.trimmedStartSeconds = 0
        self.trimmedEndSeconds = duration.seconds

        super.init()
    }

    func trimToStartSeconds(_ value: TimeInterval) {
        // Ensure:
        //
        // * Trimmed start > 0
        // * Trimmed start < video duration - minimum duration
        // * Trimmed start < trimmed end - minimum duration
        let minValue: TimeInterval = 0
        let maxValue: TimeInterval = min(untrimmedDurationSeconds, trimmedEndSeconds) - minimumDurationSeconds
        trimmedStartSeconds = max(minValue, min(maxValue, value))

        fireModelDidChange()
    }

    func trimToEndSeconds(_ value: TimeInterval) {
        // Ensure:
        //
        // * Trimmed end > 0 + minimum duration
        // * Trimmed end > trimmed start + minimum duration
        // * Trimmed end < video duration
        let minValue: TimeInterval = max(0, trimmedStartSeconds) + minimumDurationSeconds
        let maxValue: TimeInterval = untrimmedDurationSeconds
        trimmedEndSeconds = max(minValue, min(maxValue, value))

        fireModelDidChange()
    }

    // MARK: - Observers

    private var observers = [Weak<VideoEditorModelObserver>]()

    func add(observer: VideoEditorModelObserver) {
        observers.append(Weak(value: observer))
    }

    private func fireModelDidChange() {
        // We could diff here and yield a more narrow change event.
        for weakObserver in observers {
            guard let observer = weakObserver.value else {
                continue
            }
            observer.videoEditorModelDidChange(self)
        }
    }

    // MARK: - Rendering

    var needsRender: Bool { isTrimmed || tellomiExportLevel != nil || tellomiIsMuted }

    /// 发送时要按哪一档从原件重新导出：选了比上游默认高的档、并且有原件。选回 360p 就照上游（用选图时压好的那份）。
    private var tellomiExportLevel: TellomiVideoLevel? {
        guard tellomiSource != nil, let tellomiLevel, tellomiLevel != TellomiVideoLevel.upstreamDefault else { return nil }
        return tellomiLevel
    }

    @MainActor
    func render() async throws -> URL {
        owsPrecondition(self.needsRender)

        if tellomiIsMuted {
            return try await tellomiRenderMuted()
        }
        if let tellomiExportLevel, let tellomiSource {
            return try await tellomiRender(level: tellomiExportLevel, source: tellomiSource)
        }

        let startTime = MonotonicDate()

        let asset = AVURLAsset(url: URL(fileURLWithPath: self.srcVideoPath))
        let exportUrl = OWSFileSystem.temporaryFileUrl(
            fileExtension: "mp4",
            isAvailableWhileDeviceLocked: false,
        )

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw OWSAssertionError("couldn't create export session")
        }

        // This will ensure that the MP4 moov atom (movie atom)
        // is located at the beginning of the file. That may help
        // recipients validate incoming videos.
        session.shouldOptimizeForNetworkUse = true
        // Preserve the original timescale.
        let cmStart: CMTime = CMTime(seconds: self.trimmedStartSeconds, preferredTimescale: self.untrimmedDuration.timescale)
        let cmDuration: CMTime = CMTime(seconds: self.trimmedDurationSeconds, preferredTimescale: self.untrimmedDuration.timescale)
        let cmRange: CMTimeRange = CMTimeRange(start: cmStart, duration: cmDuration)
        session.timeRange = cmRange

        try await session.exportAsync(to: exportUrl, as: .mp4)

        let endTime = MonotonicDate()
        let formattedDuration = OWSOperation.formattedNs((endTime - startTime).nanoseconds)
        Logger.info("trimmed video in \(formattedDuration)s")

        switch session.status {
        case .completed:
            return exportUrl
        case .cancelled:
            throw CancellationError()
        default:
            throw session.error ?? OWSAssertionError("status \(session.status)")
        }
    }

    // MARK: - Tellomi video level (tellomi/tellomi#1518 V-7 ②)

    /// 从原件按这一档导出（剪了就只导出剪的那段），和上游选图时一样：网络播放优化、只留分享用的元数据。
    @MainActor
    private func tellomiRender(level: TellomiVideoLevel, source: TellomiVideoSource) async throws -> URL {
        let startTime = MonotonicDate()
        let asset = try await tellomiResolvedSourceAsset(source)
        guard let session = AVAssetExportSession(asset: asset, presetName: level.exportPreset) else {
            throw OWSAssertionError("couldn't create export session")
        }
        session.shouldOptimizeForNetworkUse = true
        session.metadataItemFilter = AVMetadataItemFilter.forSharing()
        if isTrimmed {
            session.timeRange = trimmedTimeRange
        }

        let exportUrl = OWSFileSystem.temporaryFileUrl(fileExtension: "mp4", isAvailableWhileDeviceLocked: false)
        try await session.exportAsync(to: exportUrl, as: .mp4)

        let formattedDuration = OWSOperation.formattedNs((MonotonicDate() - startTime).nanoseconds)
        Logger.info("exported video at \(level.label) in \(formattedDuration)s")

        switch session.status {
        case .completed:
            return exportUrl
        case .cancelled:
            throw CancellationError()
        default:
            throw session.error ?? OWSAssertionError("status \(session.status)")
        }
    }

    /// 静音当 GIF 发：只取画面轨（剪了就只取剪的那段），有原件就从原件取，压到 540p 框。
    @MainActor
    private func tellomiRenderMuted() async throws -> URL {
        let startTime = MonotonicDate()
        let asset: AVAsset
        if let tellomiSource {
            asset = try await tellomiResolvedSourceAsset(tellomiSource)
        } else {
            asset = AVURLAsset(url: URL(fileURLWithPath: srcVideoPath))
        }
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw OWSAssertionError("Missing video track.")
        }
        let duration = try await asset.load(.duration)
        let range = isTrimmed ? trimmedTimeRange : CMTimeRange(start: .zero, duration: duration)

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw OWSAssertionError("couldn't add a video track")
        }
        try track.insertTimeRange(range, of: sourceTrack, at: .zero)
        track.preferredTransform = try await sourceTrack.load(.preferredTransform)

        guard let session = AVAssetExportSession(asset: composition, presetName: Self.tellomiMutedExportPreset) else {
            throw OWSAssertionError("couldn't create export session")
        }
        session.shouldOptimizeForNetworkUse = true

        let exportUrl = OWSFileSystem.temporaryFileUrl(fileExtension: "mp4", isAvailableWhileDeviceLocked: false)
        try await session.exportAsync(to: exportUrl, as: .mp4)

        let formattedDuration = OWSOperation.formattedNs((MonotonicDate() - startTime).nanoseconds)
        Logger.info("exported muted video in \(formattedDuration)s")

        switch session.status {
        case .completed:
            return exportUrl
        case .cancelled:
            throw CancellationError()
        default:
            throw session.error ?? OWSAssertionError("status \(session.status)")
        }
    }
}
