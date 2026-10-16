//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

// Tellomi（交互审计 A-30，iOS 半边）：提示条（`ToastView`）。
// - 滑走跟手：原来是离散的轻扫识别器，扫一下才收、手指拖着不动。改成拖着走：横向、朝它贴着的那条边 1:1 跟手，反方向带阻尼；
//   松手按投射落点（位移 + 速度 × 0.1 s，同 A-10 / A-20）判断滑走还是弹回，滑走从手指的速度接着飞出去。
// - 减弱动态效果：进出不缩放、滑走不飞，只淡入淡出。
// - 「可撤销」形态：带「撤销」键的提示条左边一个倒计时环，中间是剩下的秒数（照 Telegram iOS `UndoOverlayControllerNode`：
//   可撤销的停 5 s，`RadialStatusNode` 的 `.secretTimeout` 环走空，秒数换的时候旧的往下淡出、新的从上面淡入，0.12 s）。

/// 拖提示条：跟手怎么动、松手是滑走还是弹回。
enum TellomiToastDrag {

    /// 投射落点 = 位移 + 速度 × 这么久（秒）。
    static let projectionTime: CGFloat = 0.1
    /// 横向投射超过自身宽度的这个比例就滑走。
    static let horizontalDismissFraction: CGFloat = 0.35
    /// 朝贴着的那条边投射超过自身高度的这个比例就滑走。
    static let edgeDismissFraction: CGFloat = 0.5
    /// 往反方向（离开边）拖时的阻尼上限。
    static let rubberBandLimit: CGFloat = 24

    enum Outcome: Equatable {
        case stay
        /// 往左（-1）或往右（1）滑走。
        case dismissHorizontally(sign: CGFloat)
        /// 往贴着的那条边滑走。
        case dismissTowardEdge
    }

    /// 手指拖了 `translation` 时提示条该在哪：横向 1:1；纵向朝边（`towardEdgeSign`：贴底边 1，贴顶边 -1）1:1，反方向阻尼。
    static func displayedOffset(translation: CGPoint, towardEdgeSign: CGFloat) -> CGPoint {
        let towardEdge = translation.y * towardEdgeSign >= 0
        return CGPoint(x: translation.x, y: towardEdge ? translation.y : rubberBanded(translation.y))
    }

    /// 越拖越拖不动，最多 [rubberBandLimit]。
    static func rubberBanded(_ value: CGFloat) -> CGFloat {
        let limit = rubberBandLimit
        let sign: CGFloat = value < 0 ? -1 : 1
        return sign * limit * (1 - 1 / (abs(value) / limit + 1))
    }

    static func outcome(translation: CGPoint, velocity: CGPoint, size: CGSize, towardEdgeSign: CGFloat) -> Outcome {
        let projectedX = translation.x + velocity.x * projectionTime
        let projectedY = translation.y + velocity.y * projectionTime
        if abs(projectedX) > size.width * horizontalDismissFraction, abs(projectedX) >= abs(projectedY) {
            return .dismissHorizontally(sign: projectedX > 0 ? 1 : -1)
        }
        if projectedY * towardEdgeSign > size.height * edgeDismissFraction {
            return .dismissTowardEdge
        }
        return .stay
    }
}

/// 可撤销提示条左边的倒计时：环从满走到空，中间是剩下的整秒数。
final class TellomiToastCountdownView: UIView {

    static let diameter: CGFloat = 24
    static let lineWidth: CGFloat = 2
    /// 换数字的时长和挪的距离（同 Telegram）。
    static let digitTransitionDuration: TimeInterval = 0.12
    static let digitTravel: CGFloat = 10

    private let ringLayer = CAShapeLayer()
    private let trackLayer = CAShapeLayer()
    private let label = UILabel()
    private var timer: Timer?
    private var endDate: Date?
    private(set) var displayedSeconds: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        isUserInteractionEnabled = false

        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
        trackLayer.lineWidth = Self.lineWidth
        layer.addSublayer(trackLayer)

        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.strokeColor = UIColor.white.cgColor
        ringLayer.lineWidth = Self.lineWidth
        ringLayer.lineCap = .round
        layer.addSublayer(ringLayer)

        label.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(square: Self.diameter)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.lineWidth / 2
        // 从 12 点钟方向开始、顺时针；走空是 strokeEnd 1 → 0
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: min(bounds.width, bounds.height) / 2 - inset,
            startAngle: -.pi / 2,
            endAngle: 3 * .pi / 2,
            clockwise: true,
        )
        trackLayer.frame = bounds
        trackLayer.path = path.cgPath
        ringLayer.frame = bounds
        ringLayer.path = path.cgPath
        label.frame = bounds
    }

    /// 剩下的整秒数（向上取整：刚开始是 5，最后一秒是 1）。
    static func displayedSeconds(remaining: TimeInterval) -> Int {
        max(0, Int(ceil(remaining - 0.001)))
    }

    func start(duration: TimeInterval) {
        stop()
        endDate = Date().addingTimeInterval(duration)
        displayedSeconds = Self.displayedSeconds(remaining: duration)
        label.text = OWSFormat.formatInt(displayedSeconds)

        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        ringLayer.strokeEnd = 0
        ringLayer.add(animation, forKey: "tellomiCountdown")

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func removeFromSuperview() {
        stop()
        super.removeFromSuperview()
    }

    private func tick() {
        guard let endDate else {
            return
        }
        let seconds = Self.displayedSeconds(remaining: endDate.timeIntervalSinceNow)
        guard seconds != displayedSeconds else {
            return
        }
        displayedSeconds = seconds
        if seconds == 0 {
            stop()
        }
        showDigits(OWSFormat.formatInt(seconds))
    }

    /// 换数字：旧的往下淡出、新的从上面淡入；减弱动态效果时只淡。
    private func showDigits(_ text: String) {
        let travel = UIAccessibility.isReduceMotionEnabled ? 0 : Self.digitTravel
        if let snapshot = label.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = label.frame
            addSubview(snapshot)
            UIView.animate(withDuration: Self.digitTransitionDuration, animations: {
                snapshot.alpha = 0
                snapshot.transform = CGAffineTransform(translationX: 0, y: travel)
            }, completion: { _ in
                snapshot.removeFromSuperview()
            })
        }
        label.text = text
        label.alpha = 0
        label.transform = CGAffineTransform(translationX: 0, y: -travel)
        UIView.animate(withDuration: Self.digitTransitionDuration) {
            self.label.alpha = 1
            self.label.transform = .identity
        }
    }

    var labelTextForTesting: String? { label.text }
    var ringAnimationForTesting: CABasicAnimation? { ringLayer.animation(forKey: "tellomiCountdown") as? CABasicAnimation }
}

extension DispatchTimeInterval {
    /// 换成秒（`.never` 等算 0）。
    var tellomiSeconds: TimeInterval {
        switch self {
        case .seconds(let value): return TimeInterval(value)
        case .milliseconds(let value): return TimeInterval(value) / 1_000
        case .microseconds(let value): return TimeInterval(value) / 1_000_000
        case .nanoseconds(let value): return TimeInterval(value) / 1_000_000_000
        case .never: return 0
        @unknown default: return 0
        }
    }
}
