//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Lottie
import SignalServiceKit
import SignalUI

extension ConversationInputToolbar {

    class VoiceMemoLockView: UIView {

        override init(frame: CGRect) {
            super.init(frame: frame)

            directionalLayoutMargins = .init(top: 12, leading: 8, bottom: 8, trailing: 8)

            if #available(iOS 26, *) {
                visualEffectView.clipsToBounds = true
                visualEffectView.cornerConfiguration = .capsule()
            }
            addSubview(visualEffectView)
            visualEffectView.contentView.addSubview(lockIconView)
            visualEffectView.contentView.addSubview(chevronView)
            addConstraints([
                lockIconView.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
                lockIconView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
                lockIconView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),

                chevronView.centerXAnchor.constraint(equalTo: centerXAnchor),
                chevronView.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
                iconSpacingConstraint,
            ])
        }

        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            visualEffectView.frame = bounds

            if #unavailable(iOS 26) {
                let maskLayer = CAShapeLayer()
                maskLayer.path = UIBezierPath(
                    roundedRect: bounds,
                    cornerRadius: bounds.size.smallerAxis / 2,
                ).cgPath
                visualEffectView.layer.mask = maskLayer
            }
        }

        func update(ratioComplete: CGFloat) {
            iconSpacingConstraint.constant = CGFloat.lerp(left: initialIconSpacing, right: 0, alpha: ratioComplete)
        }

        // MARK: - Subviews

        private let initialIconSpacing: CGFloat = 16

        private lazy var iconSpacingConstraint = chevronView.topAnchor.constraint(equalTo: lockIconView.bottomAnchor, constant: initialIconSpacing)

        private lazy var lockIconView: UIImageView = {
            let imageView = UIImageView(image: UIImage(imageLiteralResourceName: "lock"))
            imageView.tintColor = Style.primaryTextColor
            imageView.translatesAutoresizingMaskIntoConstraints = false
            return imageView
        }()

        private lazy var chevronView: UIImageView = {
            let imageView = UIImageView(image: UIImage(imageLiteralResourceName: "chevron-up"))
            imageView.tintColor = Style.primaryTextColor
            imageView.translatesAutoresizingMaskIntoConstraints = false
            return imageView
        }()

        private lazy var visualEffectView: UIVisualEffectView = {
            let visualEffect: UIVisualEffect = {
                if #available(iOS 26, *) {
                    UIGlassEffect(style: .regular)
                } else {
                    UIBlurEffect(style: .systemThinMaterial)
                }
            }()
            return UIVisualEffectView(effect: visualEffect)
        }()
    }

    class VoiceMessageDraftView: UIView, AudioPlayerDelegate {
        private let playbackTimeLabel: UILabel = {
            let label = UILabel()
            label.font = .monospacedDigitSystemFont(ofSize: UIFont.dynamicTypeSubheadlineClamped.pointSize, weight: .regular)
            label.textColor = Style.secondaryTextColor
            label.setContentHuggingHorizontalHigh()
            label.setCompressionResistanceHorizontalHigh()
            return label
        }()

        private lazy var playPauseButton: LottieToggleButton = {
            let button = LottieToggleButton()
            button.animationName = "playPauseButton"
            button.animationSize = CGSize(square: 24)
            button.animationSpeed = 3
            button.setValueProvider(
                ColorValueProvider(Theme.primaryIconColor.lottieColorValue),
                keypath: AnimationKeypath(keypath: "**.Fill 1.Color"),
            )
            button.addAction(
                UIAction { [weak self] _ in
                    self?.didTogglePlayPause()
                },
                for: .primaryActionTriggered,
            )
            return button
        }()

        private let waveformView: AudioWaveformProgressView
        private let voiceMessageInterruptedDraft: VoiceMessageInterruptedDraft

        var audioPlaybackState: AudioPlaybackState = .stopped

        init(
            voiceMessageInterruptedDraft: VoiceMessageInterruptedDraft,
            mediaCache: CVMediaCache,
        ) {
            self.voiceMessageInterruptedDraft = voiceMessageInterruptedDraft
            self.waveformView = AudioWaveformProgressView(mediaCache: mediaCache)

            super.init(frame: .zero)

            directionalLayoutMargins = .init(hMargin: 12, vMargin: 0)

            voiceMessageInterruptedDraft.audioPlayer.delegate = self

            waveformView.thumbColor = .Signal.label
            waveformView.playedColor = .Signal.label
            waveformView.unplayedColor = .Signal.tertiaryLabel
            waveformView.audioWaveformTask = voiceMessageInterruptedDraft.audioWaveformTask

            let stackView = UIStackView(arrangedSubviews: [
                playPauseButton,
                waveformView,
                playbackTimeLabel,
            ])
            stackView.axis = .horizontal
            stackView.spacing = 12
            stackView.alignment = .center
            addSubview(stackView)
            stackView.translatesAutoresizingMaskIntoConstraints = false
            addConstraints([
                waveformView.heightAnchor.constraint(equalToConstant: 28),

                stackView.topAnchor.constraint(greaterThanOrEqualTo: layoutMarginsGuide.topAnchor),
                stackView.centerYAnchor.constraint(equalTo: layoutMarginsGuide.centerYAnchor),
                stackView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
                stackView.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            ])

            addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan)))

            updateAudioProgress(currentTime: 0)
        }

        deinit {
            voiceMessageInterruptedDraft.audioPlayer.stop()
        }

        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private var isScrubbing = false

        @objc
        private func handlePan(_ sender: UIPanGestureRecognizer) {
            let location = sender.location(in: waveformView)
            var progress = CGFloat.clamp01(location.x / waveformView.width)

            // When in RTL mode, the slider moves in the opposite direction so inverse the ratio.
            if CurrentAppContext().isRTL {
                progress = 1 - progress
            }

            guard let duration = voiceMessageInterruptedDraft.duration else {
                return owsFailDebug("Missing duration")
            }

            let currentTime = duration * Double(progress)

            switch sender.state {
            case .began:
                isScrubbing = true
                updateAudioProgress(currentTime: currentTime)
            case .changed:
                updateAudioProgress(currentTime: currentTime)
            case .ended:
                isScrubbing = false
                voiceMessageInterruptedDraft.audioPlayer.setCurrentTime(currentTime)
            case .cancelled, .failed, .possible:
                isScrubbing = false
            @unknown default:
                isScrubbing = false
            }
        }

        func updateAudioProgress(currentTime: TimeInterval) {
            guard let duration = voiceMessageInterruptedDraft.duration else { return }
            waveformView.value = CGFloat.clamp01(CGFloat(currentTime / duration))
            playbackTimeLabel.text = OWSFormat.localizedDurationString(from: duration - currentTime)
        }

        private func didTogglePlayPause() {
            AppEnvironment.shared.cvAudioPlayerRef.stopAll()
            playPauseButton.setSelected(!playPauseButton.isSelected, animated: true)
            voiceMessageInterruptedDraft.audioPlayer.togglePlayState()
        }

        func setAudioProgress(_ progress: TimeInterval, duration: TimeInterval, playbackRate: Float) {
            guard !isScrubbing else { return }
            updateAudioProgress(currentTime: progress)
        }

        func audioPlayerDidFinish() {
            playPauseButton.setSelected(false, animated: true)
            updateAudioProgress(currentTime: 0)
        }
    }
}

// MARK: - Tellomi（Telegram 对照 3.3 / F12）：锁定录音时的暂停 / 继续按钮

/// 输入栏只通过这个接口碰正在录的那条（[VoiceMessageInProgressDraft] 实现）。
protocol TellomiVoicePauseControlling: AnyObject {
    var isPaused: Bool { get }
    var tellomiElapsed: TimeInterval { get }
    @discardableResult
    func pauseRecording() -> Bool
    @discardableResult
    func resumeRecording() -> Bool
}

extension VoiceMessageInProgressDraft: TellomiVoicePauseControlling {}

/// 暂停按钮的纯逻辑（图标、无障碍文字、计时文字、点按后的动作），方便单测。
enum TellomiVoicePauseUI {
    enum Action: Equatable {
        case pause
        case resume
    }

    /// 录音中显示“暂停”，暂停中显示“继续”。
    static func imageName(isPaused: Bool) -> String {
        isPaused ? "play-fill" : "pause-fill"
    }

    static func accessibilityLabel(isPaused: Bool) -> String {
        isPaused
            ? OWSLocalizedString("VOICE_MESSAGE_RESUME_RECORDING", comment: "Accessibility label for the button that resumes a paused voice message recording.")
            : OWSLocalizedString("VOICE_MESSAGE_PAUSE_RECORDING", comment: "Accessibility label for the button that pauses a voice message recording.")
    }

    static func action(isPaused: Bool) -> Action {
        isPaused ? .resume : .pause
    }

    /// 计时标签：只算真正在录的时间（暂停不涨），四舍五入到秒。
    static func durationText(elapsed: TimeInterval) -> String {
        OWSFormat.formatDurationSeconds(Int(round(max(0, elapsed))))
    }

    /// 点一下：录音中 → 暂停，暂停中 → 继续。返回点完以后是否处于暂停（没生效时保持原样）。
    @discardableResult
    static func toggle(_ control: TellomiVoicePauseControlling) -> Bool {
        switch action(isPaused: control.isPaused) {
        case .pause: control.pauseRecording()
        case .resume: control.resumeRecording()
        }
        return control.isPaused
    }
}

extension ConversationInputToolbar {

    /// 锁定录音后，「取消」左边的暂停 / 继续按钮。
    final class TellomiVoicePauseButton: UIButton {

        var onToggle: (() -> Void)?

        init() {
            super.init(frame: .zero)
            var configuration = UIButton.Configuration.borderless()
            configuration.baseForegroundColor = .Signal.red
            configuration.contentInsets = .init(margin: 8)
            self.configuration = configuration
            addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .primaryActionTriggered)
            update(isPaused: false)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(isPaused: Bool) {
            configuration?.image = UIImage(imageLiteralResourceName: TellomiVoicePauseUI.imageName(isPaused: isPaused))
            accessibilityLabel = TellomiVoicePauseUI.accessibilityLabel(isPaused: isPaused)
        }
    }
}
