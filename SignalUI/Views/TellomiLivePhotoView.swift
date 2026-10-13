//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit
public import UIKit

/// Tellomi（tellomi/tellomi#1263，spec R-2）：实况照片的动态部分，叠在静态图上面放。
///
/// 照 Telegram iOS 的机制（`ChatMessageInteractiveMediaNode` 会话里出现时静音放一遍、`playbackCompleted` 0.3 秒淡回静态图；
/// `UniversalVideoGalleryItem` 查看器里按 LIVE 或按住画面带声循环；只读）。实现是自己写的：用上游的 `VideoPlayer`
/// （静音放时和别的声音混着、不打断音乐；带声放时照常占用声音），停了就放掉。没出第一帧前播放层是透明的，静态图照常露着。
public final class TellomiLivePhotoView: UIView, VideoPlayerDelegate {

    /// 放完淡回静态图。
    public static let fadeOutDuration: TimeInterval = 0.3

    private let playerView = VideoPlayerView()
    private var videoPlayer: VideoPlayer?
    private var isLooping = false
    private var generation = 0

    /// 停下来（放完、被停）以后调一次。
    public var onStopped: (() -> Void)?

    /// 正在放。
    public var isPlaying: Bool { videoPlayer != nil }

    /// [fill]：会话里铺满裁切（同静态图）；查看器里完整显示。
    public init(fill: Bool) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        playerView.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        addSubview(playerView)
        alpha = 0
        isHidden = true
    }

    required init?(coder: NSCoder) {
        owsFail("Do not use this initializer.")
    }

    // 按 frame 铺满，不用约束：会话气泡是手动布局的（`ManualLayoutView`），约束会让这一层按视频原尺寸算大小
    override public func layoutSubviews() {
        super.layoutSubviews()
        playerView.frame = bounds
    }

    /// 放解密好的 [url]：静音放一遍；[loopWithSound] 时带声循环。
    public func play(_ url: URL, loopWithSound: Bool) {
        stopPlayer()
        generation += 1

        let player = VideoPlayer(decryptedFileUrl: url, shouldLoop: loopWithSound, shouldMixAudioWithOthers: !loopWithSound)
        player.isMuted = !loopWithSound
        player.delegate = self
        videoPlayer = player
        isLooping = loopWithSound
        playerView.videoPlayer = player

        layer.removeAllAnimations()
        isHidden = false
        alpha = 1
        player.play()
    }

    /// 停下，[animated] 时淡回静态图；没在放就什么都不做。
    public func stop(animated: Bool) {
        guard videoPlayer != nil else { return }
        let stoppingGeneration = generation
        if animated, !isHidden, window != nil {
            UIView.animate(withDuration: Self.fadeOutDuration, animations: {
                self.alpha = 0
            }, completion: { _ in
                // 淡出途中又开始放了：不动新的那一次
                guard self.generation == stoppingGeneration else { return }
                self.finishStop()
            })
        } else {
            finishStop()
        }
    }

    private func finishStop() {
        stopPlayer()
        alpha = 0
        isHidden = true
        onStopped?()
    }

    private func stopPlayer() {
        videoPlayer?.delegate = nil
        videoPlayer?.stop()
        playerView.videoPlayer = nil
        videoPlayer = nil
    }

    public func videoPlayerDidPlayToCompletion(_ videoPlayer: VideoPlayer) {
        if !isLooping {
            stop(animated: true)
        }
    }

    // MARK: - Icon

    /// 实况的图标：中间一个点、一个圆环、外面一圈小点（白色）。Tellomi 自己画的，不用 Telegram 的图。
    public static func iconImage(size: CGFloat, color: UIColor = .white) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(square: size), format: format).image { context in
            drawIcon(in: CGRect(origin: .zero, size: CGSize(square: size)), color: color, context: context.cgContext)
        }
    }

    /// 会话气泡左上角的角标：半透明深色圆底 + 白色图标（Telegram：离角 8）。
    public static func badgeImage(diameter: CGFloat = 22) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(square: diameter), format: format).image { context in
            let rect = CGRect(origin: .zero, size: CGSize(square: diameter))
            UIColor(white: 0, alpha: 0.35).setFill()
            context.cgContext.fillEllipse(in: rect)
            drawIcon(in: rect.insetBy(dx: diameter * 0.14, dy: diameter * 0.14), color: .white, context: context.cgContext)
        }
    }

    private static func drawIcon(in rect: CGRect, color: UIColor, context: CGContext) {
        // 24 × 24 的设计稿，同安卓 `symbol_tellomi_live_photo_24`
        let scale = rect.width / 24
        let center = CGPoint(x: rect.midX, y: rect.midY)
        color.setFill()
        func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
            CGRect(x: c.x - r * scale, y: c.y - r * scale, width: 2 * r * scale, height: 2 * r * scale)
        }
        context.fillEllipse(in: circle(center, 2.6))
        context.addEllipse(in: circle(center, 6.4))
        context.addEllipse(in: circle(center, 4.9))
        context.fillPath(using: .evenOdd)
        for index in 0..<18 {
            let angle = 2 * CGFloat.pi * CGFloat(index) / 18
            let dot = CGPoint(x: center.x + 9.6 * scale * cos(angle), y: center.y + 9.6 * scale * sin(angle))
            context.fillEllipse(in: circle(dot, 0.8))
        }
    }
}
