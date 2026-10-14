//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Tellomi（tellomi/tellomi#1593 E5-3）：调色的滑杆。照 Telegram iOS 调整页滑杆的样子和手感（`TGPhotoEditorSliderView`，
/// 只读机制，代码自己写）：细轨道，从 0 填到当前值（双极的从中间往两边填），白色圆钮；按住任意位置左右拖，按拖动的距离改值
/// （不会一按就跳到手指下）；整数一格。没有双击复位（只有 Telegram iOS 有、安卓没有，O8 不做）。
final class TellomiAdjustmentSlider: UIControl {

    let range: ClosedRange<Float>

    private(set) var value: Float

    /// 开始拖 / 拖完（调色页用来藏起这一行的字、淡掉面板底）。
    var interactionBegan: (() -> Void)?
    var interactionEnded: (() -> Void)?

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let knobView = UIView()

    private static let knobSize: CGFloat = 18
    private static let trackHeight: CGFloat = 2

    private var trackingStartValue: Float = 0
    private var trackingStartX: CGFloat = 0

    init(range: ClosedRange<Float>, value: Float) {
        self.range = range
        self.value = min(max(value, range.lowerBound), range.upperBound)
        super.init(frame: .zero)

        trackLayer.backgroundColor = UIColor.white.withAlphaComponent(0.3).cgColor
        trackLayer.cornerRadius = Self.trackHeight / 2
        layer.addSublayer(trackLayer)

        fillLayer.backgroundColor = UIColor.Signal.accent.cgColor
        fillLayer.cornerRadius = Self.trackHeight / 2
        layer.addSublayer(fillLayer)

        knobView.backgroundColor = .white
        knobView.layer.cornerRadius = Self.knobSize / 2
        knobView.layer.shadowColor = UIColor.black.cgColor
        knobView.layer.shadowOpacity = 0.25
        knobView.layer.shadowRadius = 2
        knobView.layer.shadowOffset = CGSize(width: 0, height: 1)
        knobView.isUserInteractionEnabled = false
        addSubview(knobView)

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 32)
    }

    /// 从外面设值（撤回、换照片）；不发 `.valueChanged`。
    func setValue(_ newValue: Float) {
        value = min(max(newValue.rounded(), range.lowerBound), range.upperBound)
        setNeedsLayout()
    }

    /// 0 在轨道上的位置：双极的在中间，单极的在最左。
    private var originValue: Float {
        min(max(0, range.lowerBound), range.upperBound)
    }

    private var usableWidth: CGFloat {
        max(1, bounds.width - Self.knobSize)
    }

    private func x(for value: Float) -> CGFloat {
        let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        return Self.knobSize / 2 + fraction * usableWidth
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let midY = bounds.midY
        trackLayer.frame = CGRect(x: Self.knobSize / 2, y: midY - Self.trackHeight / 2, width: usableWidth, height: Self.trackHeight)
        let originX = x(for: originValue)
        let valueX = x(for: value)
        fillLayer.frame = CGRect(x: min(originX, valueX), y: midY - Self.trackHeight / 2, width: abs(valueX - originX), height: Self.trackHeight)
        CATransaction.commit()
        knobView.frame = CGRect(x: valueX - Self.knobSize / 2, y: midY - Self.knobSize / 2, width: Self.knobSize, height: Self.knobSize)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        fillLayer.backgroundColor = UIColor.Signal.accent.cgColor
    }

    // MARK: - Tracking

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        trackingStartValue = value
        trackingStartX = touch.location(in: self).x
        interactionBegan?()
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let delta = touch.location(in: self).x - trackingStartX
        let newValue = trackingStartValue + Float(delta / usableWidth) * (range.upperBound - range.lowerBound)
        updateValue(newValue)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        interactionEnded?()
    }

    override func cancelTracking(with event: UIEvent?) {
        interactionEnded?()
    }

    /// 改值并发 `.valueChanged`（值没变就不发）。
    func updateValue(_ newValue: Float) {
        let clamped = min(max(newValue.rounded(), range.lowerBound), range.upperBound)
        guard clamped != value else { return }
        value = clamped
        setNeedsLayout()
        layoutIfNeeded()
        sendActions(for: .valueChanged)
    }

    // MARK: - Accessibility

    override var accessibilityValue: String? {
        get { TellomiImageAdjustViewController.valueText(value, range: range) ?? "0" }
        set { super.accessibilityValue = newValue }
    }

    override func accessibilityIncrement() {
        updateValue(value + 10)
    }

    override func accessibilityDecrement() {
        updateValue(value - 10)
    }
}
