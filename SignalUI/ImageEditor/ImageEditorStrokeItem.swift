//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

class ImageEditorStrokeItem: ImageEditorItem {

    enum StrokeType: Equatable {
        case pen
        case highlighter
        case blur
        // Tellomi（tellomi/tellomi#1522 E-2，照 Telegram 两端的画笔）：箭头、霓虹、橡皮。
        case arrow
        case neon
        case eraser

        /// 画在涂鸦层上的笔（橡皮擦的就是这些）；模糊不算，它属于底图那一层。
        var isPaint: Bool {
            switch self {
            case .pen, .highlighter, .arrow, .neon: return true
            case .blur, .eraser: return false
            }
        }
    }

    // Until we need to serialize these items,
    // just use UIColor.
    let color: UIColor?

    let strokeType: StrokeType

    typealias StrokeSample = ImageEditorSample

    let unitSamples: [StrokeSample]

    // Expressed as a "Unit" value as a fraction of
    // min(width, height) of the destination viewport.
    let unitStrokeWidth: CGFloat

    /// Tellomi（tellomi/tellomi#1522 E-2）：手指已经抬起。箭头这时才长出箭头。
    let isFinished: Bool

    /// Tellomi（tellomi/tellomi#1522 E-2）：长按画布填满（照两端 TG：iOS `FillTool`、安卓 `Input.fill`）：不是一条线，是整块画布。
    /// 笔、荧光笔是涂满颜色，橡皮是擦掉它之前画的所有笔画，模糊是整张打码。`unitSamples` 只记按下去的那一点。
    let isFill: Bool

    func strokeWidth(forDstSize dstSize: CGSize) -> CGFloat {
        ImageEditorStrokeItem.strokeWidth(forUnitStrokeWidth: unitStrokeWidth, dstSize: dstSize)
    }

    init(
        color: UIColor? = nil,
        strokeType: StrokeType,
        unitSamples: [StrokeSample],
        unitStrokeWidth: CGFloat,
        isFinished: Bool = true,
        isFill: Bool = false,
    ) {
        self.color = color
        self.strokeType = strokeType
        self.unitSamples = unitSamples
        self.unitStrokeWidth = unitStrokeWidth
        self.isFinished = isFinished
        self.isFill = isFill

        super.init(itemType: .stroke)
    }

    init(
        itemId: String,
        color: UIColor? = nil,
        strokeType: StrokeType,
        unitSamples: [StrokeSample],
        unitStrokeWidth: CGFloat,
        isFinished: Bool = true,
        isFill: Bool = false,
    ) {
        self.color = color
        self.strokeType = strokeType
        self.unitSamples = unitSamples
        self.unitStrokeWidth = unitStrokeWidth
        self.isFinished = isFinished
        self.isFill = isFill

        super.init(itemId: itemId, itemType: .stroke)
    }

    // First value is default unitStrokeWidth for a given stroke type.
    // Second value is the power to raise adjustment factor (slider value) if the factor is greater than 1.
    private class func metrics(forStrokeType strokeType: StrokeType) -> (CGFloat, CGFloat) {
        switch strokeType {
        case .pen:
            return (0.02, 3)
        case .highlighter:
            return (0.04, 3)
        case .blur:
            return (0.05, 2)
        case .arrow:
            return (0.02, 3)
        case .neon:
            return (0.03, 2)
        case .eraser:
            return (0.05, 2)
        }
    }

    class func unitStrokeWidth(
        forStrokeType strokeType: StrokeType,
        widthAdjustmentFactor adjustmentFactor: CGFloat,
    ) -> CGFloat {
        let (defaultWidth, power) = metrics(forStrokeType: strokeType)
        let multiplier: CGFloat
        if adjustmentFactor > 1 {
            multiplier = pow(adjustmentFactor, power)
        } else {
            multiplier = adjustmentFactor
        }
        return defaultWidth * multiplier
    }

    class func strokeWidth(forUnitStrokeWidth unitStrokeWidth: CGFloat, dstSize: CGSize) -> CGFloat {
        return CGFloat.clamp01(unitStrokeWidth) * min(dstSize.width, dstSize.height)
    }

    // MARK: - Arrow

    /// 箭头两臂离开尖端、相对“往回”方向的角度（照 Telegram iOS 的笔：±0.45 rad）。
    static let arrowArmAngle: CGFloat = 0.45

    /// 箭头：尖端和两臂的端点。方向从尖端往回找第一个离尖端超过半个箭头长的点，抬手时的一点抖动不会把箭头带歪；
    /// 箭头长取线宽 3 倍和图片长边 2% 里大的那个（照 Telegram iOS）。线没有方向时返回 nil。
    static func arrowHead(
        points: [CGPoint],
        strokeWidth: CGFloat,
        imageLongSide: CGFloat,
        progress: CGFloat = 1,
    ) -> (tip: CGPoint, arm1: CGPoint, arm2: CGPoint)? {
        guard points.count >= 2, let tip = points.last else { return nil }
        let headLength = max(3 * strokeWidth, 0.02 * imageLongSide)
        let half = headLength / 2
        var index = points.count - 2
        while index > 0, hypot(points[index].x - tip.x, points[index].y - tip.y) < half {
            index -= 1
        }
        let dx = tip.x - points[index].x
        let dy = tip.y - points[index].y
        guard dx != 0 || dy != 0 else { return nil }
        let back = atan2(-dy, -dx)
        let length = headLength * progress.clamp01()
        func arm(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: tip.x + length * cos(angle), y: tip.y + length * sin(angle))
        }
        return (tip, arm(back + arrowArmAngle), arm(back - arrowArmAngle))
    }
}
