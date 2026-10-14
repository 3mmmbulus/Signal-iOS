//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import simd
import UIKit

/// Tellomi（tellomi/tellomi#1598 E5-8，Epic #1523）：调色页的「模糊」（移轴）页签。
///
/// 照两端 Telegram 的模糊（iOS `TGPhotoEditorBlurToolView` / `TGPhotoEditorBlurAreaView`，安卓 `PhotoFilterBlurControl` + `blurItem`；
/// 只读机制，代码自己写）：
/// - 面板里「关 / 径向 / 线性」三个切换；
/// - 照片上：中心一个圆点；径向画内外两个虚线圆，线性画内外两对虚线；
/// - 按在中心附近拖 = 挪中心；按在内（外）圈 / 线附近拖 = 改内（外）半径；线性时按在别处拖 = 绕中心转；两指捏 = 内外半径一起缩放。
/// O8：强度、人像模糊两端 Telegram 都没有（iOS 的人像按钮注释掉了），不做。
enum TellomiBlurKindChoice: CaseIterable {
    case off
    case radial
    case linear

    var kind: TellomiImageAdjustments.Blur.Kind {
        switch self {
        case .off: return .off
        case .radial: return .radial
        case .linear: return .linear
        }
    }

    var title: String {
        switch self {
        case .off:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_BLUR_OFF", comment: "Image editor, adjustments, blur: no blur.")
        case .radial:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_BLUR_RADIAL", comment: "Image editor, adjustments, blur: blur everything outside a circle.")
        case .linear:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_BLUR_LINEAR", comment: "Image editor, adjustments, blur: blur everything outside a band.")
        }
    }
}

/// 图上的单位坐标（左上为原点，0…1）和画布上（`gestureReferenceView`）的点之间换算，照画布摆底图的算法（`imageFrame`、
/// `ImageEditorTransform.affineTransform`、只作用在底图上的左右翻转）。
@MainActor
struct TellomiImageUnitMapping {
    let viewSize: CGSize
    let imageSize: CGSize
    let transform: ImageEditorTransform
    private let imageFrame: CGRect
    private let affine: CGAffineTransform
    private let center: CGPoint

    init(viewSize: CGSize, imageSize: CGSize, transform: ImageEditorTransform) {
        self.viewSize = viewSize
        self.imageSize = imageSize
        self.transform = transform
        imageFrame = ImageEditorCanvasView.imageFrame(forViewSize: viewSize, imageSize: imageSize, transform: transform)
        affine = transform.affineTransform(viewSize: viewSize)
        center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    }

    var isValid: Bool {
        imageFrame.width > 0 && imageFrame.height > 0 && imageSize.width > 0 && imageSize.height > 0
    }

    func view(fromUnit unit: SIMD2<Float>) -> CGPoint {
        let x = transform.isFlipped ? 1 - CGFloat(unit.x) : CGFloat(unit.x)
        let inLayer = CGPoint(x: imageFrame.minX + x * imageFrame.width, y: imageFrame.minY + CGFloat(unit.y) * imageFrame.height)
        return inLayer.minus(center).applying(affine).plus(center)
    }

    func unit(fromView point: CGPoint) -> SIMD2<Float> {
        let inLayer = point.minus(center).applying(affine.inverted()).plus(center)
        let x = (inLayer.x - imageFrame.minX) / imageFrame.width
        let y = (inLayer.y - imageFrame.minY) / imageFrame.height
        return SIMD2(Float(transform.isFlipped ? 1 - x : x), Float(y))
    }

    /// 图的短边（模糊半径的单位）在画布上有多长。
    var shortSideInView: CGFloat {
        min(imageSize.width, imageSize.height) * imageFrame.width / imageSize.width * transform.scaling
    }

    /// 单位坐标的差换成「短边 = 1」的向量（模糊的距离在这里量）。
    func shortSideVector(_ delta: SIMD2<Float>) -> SIMD2<Float> {
        delta * SIMD2(Float(imageSize.width), Float(imageSize.height)) / Float(min(imageSize.width, imageSize.height))
    }

    func unitDelta(fromShortSideVector vector: SIMD2<Float>) -> SIMD2<Float> {
        vector * Float(min(imageSize.width, imageSize.height)) / SIMD2(Float(imageSize.width), Float(imageSize.height))
    }
}

/// 盖在照片上的模糊控件：画中心点、内外圈（线）；拖、捏改模糊。
final class TellomiBlurOverlayView: UIView, UIGestureRecognizerDelegate {

    /// 模糊变了（拖动中每一下都调）。
    var onChange: ((TellomiImageAdjustments.Blur) -> Void)?
    /// 给图上的单位坐标和画布上的点换算（画布大小、裁剪变了由外面重新给）。
    var mappingProvider: ((CGSize) -> TellomiImageUnitMapping?)?

    private(set) var blur = TellomiImageAdjustments.Blur()

    private let centerLayer = CAShapeLayer()
    private let innerLayer = CAShapeLayer()
    private let outerLayer = CAShapeLayer()

    /// 离中心、圈 / 线多近算按在上面（点）。
    static let touchInset: CGFloat = 30
    /// 内半径最小、内外最少差多少（短边 = 1）。
    static let minimumInner: Float = 0.02
    static let minimumGap: Float = 0.02

    enum Control: Equatable {
        case center
        case inner
        case outer
        case rotation
    }

    private var activeControl: Control?
    private var startBlur = TellomiImageAdjustments.Blur()
    private var startPoint = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        for shape in [innerLayer, outerLayer, centerLayer] {
            shape.strokeColor = UIColor.white.cgColor
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 1.5
            shape.shadowColor = UIColor.black.cgColor
            shape.shadowOpacity = 0.35
            shape.shadowRadius = 1.5
            shape.shadowOffset = .zero
            layer.addSublayer(shape)
        }
        innerLayer.lineDashPattern = [12, 6]
        outerLayer.lineDashPattern = [5, 5]
        centerLayer.fillColor = UIColor.white.cgColor

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(blur: TellomiImageAdjustments.Blur) {
        self.blur = blur
        setNeedsLayout()
    }

    private var mapping: TellomiImageUnitMapping? {
        guard let mapping = mappingProvider?(bounds.size), mapping.isValid else { return nil }
        return mapping
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard blur.kind != .off, let mapping else {
            for shape in [centerLayer, innerLayer, outerLayer] {
                shape.path = nil
            }
            return
        }
        let center = mapping.view(fromUnit: SIMD2(blur.centerX, blur.centerY))
        centerLayer.path = UIBezierPath(arcCenter: center, radius: 8, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        let radii = TellomiImageAdjustmentsRenderer.blurRadii(blur)
        let short = mapping.shortSideInView
        switch blur.kind {
        case .radial:
            innerLayer.path = UIBezierPath(arcCenter: center, radius: CGFloat(radii.inner) * short, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
            outerLayer.path = UIBezierPath(arcCenter: center, radius: CGFloat(radii.outer) * short, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        case .linear:
            innerLayer.path = bandPath(distance: radii.inner, mapping: mapping)
            outerLayer.path = bandPath(distance: radii.outer, mapping: mapping)
        case .off:
            break
        }
    }

    /// 平行于那条线、离它 `distance`（短边 = 1）的两条线，在图上取得足够长，画到画布外面也没关系（会裁掉）。
    private func bandPath(distance: Float, mapping: TellomiImageUnitMapping) -> CGPath {
        let normal = TellomiImageAdjustmentsRenderer.blurNormal(blur)
        let along = SIMD2(-normal.y, normal.x)
        let center = SIMD2(blur.centerX, blur.centerY)
        let path = UIBezierPath()
        for side: Float in [-1, 1] {
            let offset = center + mapping.unitDelta(fromShortSideVector: normal * distance * side)
            let start = offset + mapping.unitDelta(fromShortSideVector: along * -4)
            let end = offset + mapping.unitDelta(fromShortSideVector: along * 4)
            path.move(to: mapping.view(fromUnit: start))
            path.addLine(to: mapping.view(fromUnit: end))
        }
        return path.cgPath
    }

    /// 按在 `point` 上算按住的是哪一部分（照两端 TG：中心 → 内圈 → 外圈，线性时别处是转）。
    func control(at point: CGPoint) -> Control? {
        guard blur.kind != .off, let mapping else { return nil }
        let center = mapping.view(fromUnit: SIMD2(blur.centerX, blur.centerY))
        if hypot(point.x - center.x, point.y - center.y) < Self.touchInset {
            return .center
        }
        let distance = CGFloat(distanceFromCenter(of: point, mapping: mapping)) * mapping.shortSideInView
        let radii = TellomiImageAdjustmentsRenderer.blurRadii(blur)
        let inner = CGFloat(radii.inner) * mapping.shortSideInView
        let outer = CGFloat(radii.outer) * mapping.shortSideInView
        let toInner = abs(distance - inner)
        let toOuter = abs(distance - outer)
        if min(toInner, toOuter) < Self.touchInset {
            return toInner <= toOuter ? .inner : .outer
        }
        return blur.kind == .linear ? .rotation : nil
    }

    /// 点到中心（径向）或到那条线（线性）的距离，短边 = 1。
    private func distanceFromCenter(of point: CGPoint, mapping: TellomiImageUnitMapping) -> Float {
        let q = mapping.shortSideVector(mapping.unit(fromView: point) - SIMD2(blur.centerX, blur.centerY))
        return blur.kind == .radial ? simd_length(q) : abs(simd_dot(q, TellomiImageAdjustmentsRenderer.blurNormal(blur)))
    }

    @objc
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            activeControl = control(at: point)
            startBlur = blur
            startPoint = point
        case .changed:
            guard let activeControl, let mapping else { return }
            drag(activeControl, from: startPoint, to: point, startBlur: startBlur, mapping: mapping)
        default:
            activeControl = nil
        }
    }

    /// 从 `start` 拖到 `point`：按 `control` 改 `startBlur`。
    func drag(_ control: Control, from start: CGPoint, to point: CGPoint, startBlur: TellomiImageAdjustments.Blur, mapping: TellomiImageUnitMapping) {
        var updated = startBlur
        let center = SIMD2(startBlur.centerX, startBlur.centerY)
        switch control {
        case .center:
            let moved = center + mapping.unit(fromView: point) - mapping.unit(fromView: start)
            updated.centerX = min(max(moved.x, 0), 1)
            updated.centerY = min(max(moved.y, 0), 1)
        case .inner, .outer:
            let measure = { (p: CGPoint) -> Float in
                let q = mapping.shortSideVector(mapping.unit(fromView: p) - center)
                return startBlur.kind == .radial ? simd_length(q) : abs(simd_dot(q, TellomiImageAdjustmentsRenderer.blurNormal(startBlur)))
            }
            let delta = measure(point) - measure(start)
            if control == .inner {
                updated.falloff = min(max(startBlur.falloff + delta, Self.minimumInner), startBlur.size - Self.minimumGap)
            } else {
                updated.size = max(startBlur.size + delta, startBlur.falloff + Self.minimumGap)
            }
        case .rotation:
            let from = mapping.shortSideVector(mapping.unit(fromView: start) - center)
            let to = mapping.shortSideVector(mapping.unit(fromView: point) - center)
            guard simd_length(from) > 0, simd_length(to) > 0 else { return }
            updated.angle = startBlur.angle + atan2(to.y, to.x) - atan2(from.y, from.x)
        }
        guard updated != blur else { return }
        blur = updated
        setNeedsLayout()
        onChange?(updated)
    }

    @objc
    private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            startBlur = blur
        case .changed:
            guard blur.kind != .off else { return }
            pinch(scale: Float(gesture.scale), startBlur: startBlur)
        default:
            break
        }
    }

    /// 两指捏：内外半径一起按比例缩放。
    func pinch(scale: Float, startBlur: TellomiImageAdjustments.Blur) {
        var updated = startBlur
        updated.falloff = max(startBlur.falloff * scale, Self.minimumInner)
        updated.size = max(startBlur.size * scale, updated.falloff + Self.minimumGap)
        guard updated != blur else { return }
        blur = updated
        setNeedsLayout()
        onChange?(updated)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}

/// 模糊页签的面板：「关 / 径向 / 线性」三个切换（照两端 TG 的三个按钮）。
final class TellomiBlurPanelView: UIView {

    var onSelect: ((TellomiImageAdjustments.Blur.Kind) -> Void)?

    private(set) var buttons: [TellomiImageAdjustments.Blur.Kind: UIButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView()
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        for choice in TellomiBlurKindChoice.allCases {
            let button = UIButton(type: .custom)
            button.setTitle(choice.title, for: .normal)
            button.titleLabel?.font = .dynamicTypeSubheadlineClamped
            button.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .normal)
            button.setTitleColor(.white, for: .selected)
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(choice.kind) }, for: .touchUpInside)
            buttons[choice.kind] = button
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
        select(.off)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func select(_ kind: TellomiImageAdjustments.Blur.Kind) {
        for (each, button) in buttons {
            button.isSelected = each == kind
            button.accessibilityTraits = each == kind ? [.button, .selected] : .button
        }
    }
}
