//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit

/// Tellomi（交互审计 A-12「录音看不到音量」iOS 半边，同安卓 `TellomiVoiceLevel`）：麦克风电平 → 录音按钮后面那圈光晕有多大。
///
/// `AVAudioRecorder.peakPower`（dBFS，-160…0）在 [floorDecibels] 以下算没声音（0），0 dB 算满（1）；光晕从按钮原大（1 倍）
/// 长到 [maxHaloScale] 倍。Telegram 两端也是录音时按钮外一圈随音量变大（iOS `ManagedAudioRecorder.micLevel`，
/// 安卓 `ChatActivityEnterView.RecordCircle.setAmplitude`）。一行没搬（GPLv2）。
enum TellomiVoiceLevel {
    static let floorDecibels: Float = -45
    static let maxHaloScale: CGFloat = 1.6

    static func level(decibels: Float) -> CGFloat {
        guard decibels.isFinite else { return 0 }
        return CGFloat(min(max((decibels - floorDecibels) / -floorDecibels, 0), 1))
    }

    static func haloScale(level: CGFloat) -> CGFloat {
        1 + (maxHaloScale - 1) * min(max(level, 0), 1)
    }
}

/// 光晕本身：每帧读一次电平，用临界阻尼弹簧（同安卓 `TellomiMotion.Fade`：刚度 1600、阻尼比 1）平滑后缩放；
/// 位置、透明度跟着它垫在下面的那个按钮（按钮有平移、收起时变淡变小）。减弱动态效果时不显示。
final class TellomiVoiceLevelHalo: UIView {

    static let haloAlpha: CGFloat = 0.3
    private static let stiffness: CGFloat = 1600
    private static let dampingRatio: CGFloat = 1

    /// 当前峰值电平（dBFS）；没在录时给 nil。
    var levelSource: (() -> Float?)?
    private weak var button: UIView?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private(set) var levelScale: CGFloat = 1
    private var velocity: CGFloat = 0

    func start(following button: UIView) {
        stop()
        guard levelSource != nil, !UIAccessibility.isReduceMotionEnabled else {
            isHidden = true
            return
        }
        self.button = button
        levelScale = 1
        velocity = 0
        lastTimestamp = nil
        isHidden = false
        sync()
        let displayLink = CADisplayLink(target: self, selector: #selector(step(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isHidden = true
        transform = .identity
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stop()
        }
    }

    @objc
    private func step(_ link: CADisplayLink) {
        let dt = lastTimestamp.map { link.timestamp - $0 } ?? link.duration
        lastTimestamp = link.timestamp
        advance(towards: Self.targetScale(decibels: levelSource?()), by: dt)
        sync()
    }

    static func targetScale(decibels: Float?) -> CGFloat {
        TellomiVoiceLevel.haloScale(level: TellomiVoiceLevel.level(decibels: decibels ?? -160))
    }

    /// 弹簧走 [dt] 秒（拆成不超过 1/240 s 的小步，帧率掉了也稳）。
    func advance(towards target: CGFloat, by dt: CFTimeInterval) {
        let damping = 2 * Self.dampingRatio * Self.stiffness.squareRoot()
        let steps = max(1, Int((dt * 240).rounded(.up)))
        let h = CGFloat(dt) / CGFloat(steps)
        for _ in 0..<steps {
            let acceleration = -Self.stiffness * (levelScale - target) - damping * velocity
            velocity += acceleration * h
            levelScale += velocity * h
        }
    }

    private func sync() {
        guard let button else { return }
        transform = button.transform.scaledBy(x: levelScale, y: levelScale)
        alpha = Self.haloAlpha * button.alpha
    }
}
