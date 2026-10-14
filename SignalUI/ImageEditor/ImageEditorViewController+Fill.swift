//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Tellomi（tellomi/tellomi#1522 E-2，照两端 Telegram）：画笔 / 打码时长按画布填满。
///
/// 照 TG iOS `DrawingView.handleLongPress` → `FillTool`、TG 安卓 `Input` 长按 → `fill`（只读机制，代码自己写）：
/// - 按住不动（这里 0.5 s、挪动不超过 6 pt）就填：笔、箭头、霓虹涂满当前颜色（TG 安卓把霓虹换成普通圆笔），荧光笔是半透明的那种颜色，
///   橡皮擦掉它之前画的所有笔画（不擦照片、文字、贴纸），打码是整张打码；
/// - 从手指那一点长出一个圆盖满画布（TG 安卓 450 ms 的扩散；这里 0.3 s），然后变成一步可撤销的填满，轻震一下。
extension ImageEditorViewController {

    static let fillPressDuration: TimeInterval = 0.5
    static let fillAllowableMovement: CGFloat = 6

    func makeFillGestureRecognizer() -> UILongPressGestureRecognizer {
        let gestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleFillGesture(_:)))
        gestureRecognizer.minimumPressDuration = Self.fillPressDuration
        gestureRecognizer.allowableMovement = Self.fillAllowableMovement
        gestureRecognizer.delegate = self
        return gestureRecognizer
    }

    @objc
    func handleFillGesture(_ gestureRecognizer: UILongPressGestureRecognizer) {
        guard gestureRecognizer.state == .began, mode == .draw || mode == .blur, currentStroke == nil else { return }
        let referenceView = imageEditorView.gestureReferenceView
        let location = gestureRecognizer.location(in: referenceView)
        guard referenceView.bounds.contains(location) else { return }
        animateFill(from: location, in: referenceView) { [weak self] in
            self?.fill(atLocationInView: location)
        }
    }

    /// 填满：加一个 `isFill` 的笔画（一步撤销）。
    @discardableResult
    func fill(atLocationInView location: CGPoint) -> ImageEditorStrokeItem {
        let referenceView = imageEditorView.gestureReferenceView
        // 只记按下去的那一点（填满不看它，留着给以后）；画布还没排版时记中心。
        let sample = referenceView.bounds.isEmpty ? CGPoint(x: 0.5, y: 0.5) : ImageEditorCanvasView.locationImageUnit(
            forLocationInView: location,
            viewBounds: referenceView.bounds,
            model: model,
            transform: model.currentTransform(),
        )
        let (strokeType, color) = fillStyle()
        let item = ImageEditorStrokeItem(
            color: color,
            strokeType: strokeType,
            unitSamples: [sample],
            unitStrokeWidth: currentStrokeUnitWidth(),
            isFill: true,
        )
        model.append(item: item)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        return item
    }

    /// 填什么：打码时是整张打码；画笔时笔 / 箭头 / 霓虹都按普通笔涂满当前颜色，荧光笔半透明，橡皮擦掉。
    private func fillStyle() -> (ImageEditorStrokeItem.StrokeType, UIColor?) {
        if mode == .blur {
            return (.blur, nil)
        }
        let color = drawToolbar.colorPickerBar.uiColor
        switch currentStrokeType {
        case .highlighter:
            return (.highlighter, color.withAlphaComponent(Self.highligherStrokeOpacity))
        case .eraser:
            return (.eraser, nil)
        case .blur:
            return (.blur, nil)
        case .pen, .arrow, .neon:
            return (.pen, color)
        }
    }

    /// 从按下去的那一点长出一个圆盖满画布，然后交给 `completion`。
    private func animateFill(from point: CGPoint, in view: UIView, completion: @escaping () -> Void) {
        let bounds = view.bounds
        let radius = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
            .map { hypot($0.x - point.x, $0.y - point.y) }
            .max() ?? 0
        let (strokeType, color) = fillStyle()
        let circle = CAShapeLayer()
        circle.path = UIBezierPath(arcCenter: .zero, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        circle.position = point
        switch strokeType {
        case .eraser, .blur:
            circle.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
        case .pen, .highlighter, .arrow, .neon:
            circle.fillColor = (color ?? .white).cgColor
        }
        circle.zPosition = 1000
        view.layer.addSublayer(circle)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            completion()
            circle.removeFromSuperlayer()
        }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.02
        grow.toValue = 1
        grow.duration = 0.3
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        circle.add(grow, forKey: "grow")
        CATransaction.commit()
    }
}
