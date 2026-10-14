//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Tellomi（tellomi/tellomi#1597 E5-7，Epic #1523）：调色页的「曲线」页签。
///
/// 照两端 Telegram 的曲线（iOS `TGPhotoEditorCurvesToolView` + `TGPhotoEditorCurvesHistogramView`，安卓 `PhotoFilterCurvesControl`；
/// 只读机制，代码自己写）：
/// - 照片上盖一层：竖线把宽度分成 5 段，一条虚线对角线（不调时的样子），当前那条曲线（全部白、红绿蓝各自的颜色），每段底下写那个点的值（0.25）；
/// - 在哪一段里上下拖就改哪个点（第 1 段 = 黑、…、第 5 段 = 白），这里点跟着手指走：拖过整个照片的高度 = 0…1；
/// - 面板里「全部 / 红 / 绿 / 蓝」四个切换（照 TG iOS 的文字按钮，选中白、其他灰）。
/// O8：直方图、双击复位只有 Telegram iOS 有，不做。
enum TellomiCurveChannel: CaseIterable {
    case all
    case red
    case green
    case blue

    var title: String {
        switch self {
        case .all:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_CURVES_ALL", comment: "Image editor, adjustments, curves: the curve that changes all three colour channels.")
        case .red:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_CURVES_RED", comment: "Image editor, adjustments, curves: the red channel's curve.")
        case .green:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_CURVES_GREEN", comment: "Image editor, adjustments, curves: the green channel's curve.")
        case .blue:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_CURVES_BLUE", comment: "Image editor, adjustments, curves: the blue channel's curve.")
        }
    }

    /// 曲线的颜色（自己挑的）。
    var color: UIColor {
        switch self {
        case .all:
            return .white
        case .red:
            return UIColor(rgbHex: 0xFF5A5F)
        case .green:
            return UIColor(rgbHex: 0x3DDC84)
        case .blue:
            return UIColor(rgbHex: 0x4D8CFF)
        }
    }

    var keyPath: WritableKeyPath<TellomiImageAdjustments.Curves, TellomiImageAdjustments.CurvePoints> {
        switch self {
        case .all:
            return \.all
        case .red:
            return \.red
        case .green:
            return \.green
        case .blue:
            return \.blue
        }
    }
}

extension TellomiImageAdjustments.CurvePoints {
    /// 第 `index` 个点（0 = 黑 … 4 = 白）的输出值，0…100。
    subscript(index: Int) -> Float {
        get { values[index] }
        set {
            let value = min(max(newValue, 0), 100)
            switch index {
            case 0: blacks = value
            case 1: shadows = value
            case 2: midtones = value
            case 3: highlights = value
            default: whites = value
            }
        }
    }
}

/// 盖在照片上的曲线层：画网格、对角线、曲线、数值；在哪一段上下拖就改哪个点。
final class TellomiCurvesOverlayView: UIView {

    static let segmentCount = 5

    /// 改了一个点：(通道, 第几个点, 新值 0…100)。
    var onChange: ((TellomiCurveChannel, Int, Float) -> Void)?

    private(set) var channel: TellomiCurveChannel = .all
    private(set) var curves = TellomiImageAdjustments.Curves()

    private let gridLayer = CAShapeLayer()
    private let diagonalLayer = CAShapeLayer()
    private let curveLayer = CAShapeLayer()
    private var labels: [UILabel] = []
    private var activeSegment: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear

        gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
        gridLayer.lineWidth = 1
        diagonalLayer.strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
        diagonalLayer.lineWidth = 1
        diagonalLayer.lineDashPattern = [4, 4]
        curveLayer.fillColor = UIColor.clear.cgColor
        curveLayer.lineWidth = 2
        curveLayer.lineCap = .round
        curveLayer.lineJoin = .round
        for shape in [gridLayer, diagonalLayer, curveLayer] {
            shape.fillColor = UIColor.clear.cgColor
            layer.addSublayer(shape)
        }

        labels = (0..<Self.segmentCount).map { _ in
            let label = UILabel()
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            label.textColor = UIColor.white.withAlphaComponent(0.75)
            label.textAlignment = .center
            label.shadowColor = UIColor.black.withAlphaComponent(0.4)
            label.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(label)
            return label
        }

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))

        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(curves: TellomiImageAdjustments.Curves, channel: TellomiCurveChannel) {
        self.curves = curves
        self.channel = channel
        curveLayer.strokeColor = channel.color.cgColor
        setNeedsLayout()
    }

    private var points: TellomiImageAdjustments.CurvePoints {
        curves[keyPath: channel.keyPath]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        let segmentWidth = size.width / CGFloat(Self.segmentCount)

        let grid = UIBezierPath()
        for index in 1..<Self.segmentCount {
            let x = (segmentWidth * CGFloat(index)).rounded() + 0.5
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        gridLayer.path = grid.cgPath

        let diagonal = UIBezierPath()
        diagonal.move(to: CGPoint(x: 0, y: size.height))
        diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        diagonalLayer.path = diagonal.cgPath

        let spline = TellomiImageAdjustmentsRenderer.CurveSpline(points)
        let curve = UIBezierPath()
        let steps = 100
        for step in 0...steps {
            let x = Float(step) / Float(steps)
            let point = CGPoint(x: CGFloat(x) * size.width, y: (1 - CGFloat(spline.value(at: x))) * size.height)
            if step == 0 {
                curve.move(to: point)
            } else {
                curve.addLine(to: point)
            }
        }
        curveLayer.path = curve.cgPath

        for (index, label) in labels.enumerated() {
            label.text = Self.valueText(points[index])
            label.sizeToFit()
            label.frame = CGRect(
                x: segmentWidth * CGFloat(index),
                y: size.height - label.bounds.height - 6,
                width: segmentWidth,
                height: label.bounds.height,
            )
        }
    }

    /// 一个点的值：照两端 TG，值 / 100，两位小数（0.25）。
    static func valueText(_ value: Float) -> String {
        String(format: "%.2f", value / 100)
    }

    /// 横坐标落在哪一段（0…4）。
    static func segment(at x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return min(max(Int(x / (width / CGFloat(segmentCount))), 0), segmentCount - 1)
    }

    @objc
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            activeSegment = Self.segment(at: gesture.location(in: self).x, width: bounds.width)
        case .changed:
            guard let activeSegment, bounds.height > 0 else { return }
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            drag(segment: activeSegment, by: -translation.y / bounds.height * 100)
        default:
            activeSegment = nil
        }
    }

    /// 把第 `segment` 个点往上（正）挪 `delta`（0…100 的单位）。
    func drag(segment: Int, by delta: CGFloat) {
        let current = points[segment]
        var updated = points
        updated[segment] = current + Float(delta)
        guard updated[segment] != current else { return }
        onChange?(channel, segment, updated[segment])
    }

    // MARK: - Accessibility

    override var accessibilityElements: [Any]? {
        get {
            (0..<Self.segmentCount).map { index in
                let element = PointElement(overlay: self, index: index)
                let segmentWidth = bounds.width / CGFloat(Self.segmentCount)
                element.accessibilityFrameInContainerSpace = CGRect(x: segmentWidth * CGFloat(index), y: 0, width: segmentWidth, height: bounds.height)
                return element
            }
        }
        set {}
    }

    /// 读屏时每个点是一个可调的元素：上下滑一次改 5。
    private final class PointElement: UIAccessibilityElement {
        private weak var overlay: TellomiCurvesOverlayView?
        private let index: Int

        init(overlay: TellomiCurvesOverlayView, index: Int) {
            self.overlay = overlay
            self.index = index
            super.init(accessibilityContainer: overlay)
            accessibilityTraits = .adjustable
            accessibilityLabel = "\(overlay.channel.title) \(index + 1)"
        }

        override var accessibilityValue: String? {
            get { overlay.map { TellomiCurvesOverlayView.valueText($0.points[index]) } }
            set {}
        }

        override func accessibilityIncrement() {
            overlay?.drag(segment: index, by: 5)
        }

        override func accessibilityDecrement() {
            overlay?.drag(segment: index, by: -5)
        }
    }

    // MARK: - Icon

    /// 页签的图标：一条 S 形曲线（Signal 的图标里没有，SF Symbols 里的曲线图标要 iOS 16，自己画）。
    static var tabIcon: UIImage {
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let frame = UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 20, height: 20), cornerRadius: 4)
            frame.lineWidth = 1.5
            UIColor.black.setStroke()
            frame.stroke()
            let curve = UIBezierPath()
            curve.move(to: CGPoint(x: 4, y: 18))
            curve.addCurve(to: CGPoint(x: 18, y: 4), controlPoint1: CGPoint(x: 13, y: 18), controlPoint2: CGPoint(x: 9, y: 4))
            curve.lineWidth = 2
            curve.lineCapStyle = .round
            curve.stroke()
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// 曲线页签的面板：「全部 / 红 / 绿 / 蓝」四个切换（照 Telegram iOS 的文字按钮）。
final class TellomiCurvesPanelView: UIView {

    var onSelect: ((TellomiCurveChannel) -> Void)?

    private(set) var buttons: [TellomiCurveChannel: UIButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView()
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        for channel in TellomiCurveChannel.allCases {
            let button = UIButton(type: .custom)
            button.setTitle(channel.title, for: .normal)
            button.titleLabel?.font = .dynamicTypeSubheadlineClamped
            button.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .normal)
            button.setTitleColor(.white, for: .selected)
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(channel) }, for: .touchUpInside)
            buttons[channel] = button
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: 44),
        ])
        select(.all)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func select(_ channel: TellomiCurveChannel) {
        for (each, button) in buttons {
            button.isSelected = each == channel
            button.accessibilityTraits = each == channel ? [.button, .selected] : .button
        }
    }
}
