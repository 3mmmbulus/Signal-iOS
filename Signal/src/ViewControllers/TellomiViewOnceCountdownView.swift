//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1714，ADR-0079 §4.3 第 2 条）：计时一次性查看的查看器右上角的倒计时环——满圈开始、顺时针走空、没有数字
/// （照 Telegram 两端 `SecretMediaPreviewController` / `SecretMediaViewer` 右上角的环，只取样子，画法是自己的）。
final class TellomiViewOnceCountdownView: UIView {

    static let size: CGFloat = 24
    private static let lineWidth: CGFloat = 2.5

    private let trackLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private(set) var duration: TimeInterval = 0
    private var startedAt: Date?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for layer in [trackLayer, ringLayer] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = Self.lineWidth
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        trackLayer.strokeColor = UIColor.Signal.label.withAlphaComponent(0.25).cgColor
        ringLayer.strokeColor = UIColor.Signal.label.cgColor
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.size, height: Self.size) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // 从 12 点钟方向顺时针一圈；走的时候起点往前追（strokeStart 0 → 1），就是顺时针走空。
        let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)
        trackLayer.frame = bounds
        ringLayer.frame = bounds
        trackLayer.path = path.cgPath
        ringLayer.path = path.cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        trackLayer.strokeColor = UIColor.Signal.label.withAlphaComponent(0.25).cgColor
        ringLayer.strokeColor = UIColor.Signal.label.cgColor
    }

    /// 开始走 [duration] 秒。
    func start(duration: TimeInterval) {
        self.duration = duration
        startedAt = Date()
        ringLayer.removeAllAnimations()
        let animation = CABasicAnimation(keyPath: "strokeStart")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        ringLayer.add(animation, forKey: "countdown")
        accessibilityLabel = String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString("TELLOMI_VIEW_ONCE_COUNTDOWN_FORMAT", comment: "Accessibility label of the countdown ring on a timed view-once photo or video. Embeds {{ number of seconds it stays open }}."),
            OWSFormat.formatInt(Int(duration.rounded())),
        )
    }

    /// 还剩的比例（1 = 满圈，0 = 走完）。
    var remainingFractionForTesting: Double {
        guard let startedAt, duration > 0 else { return 1 }
        return max(0, 1 - Date().timeIntervalSince(startedAt) / duration)
    }
}
