//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Tellomi（tellomi/tellomi#1522 E-3）：画笔菜单里「形状」加到图上的一个形状——矩形、圆、星形、气泡、箭头。
///
/// 照两端 Telegram 都有的那部分（只读机制，代码自己写）：iOS `DrawingScreen.presentShapePicker` →
/// `DrawingSimpleShapeEntity` / `DrawingBubbleEntity` / `DrawingVectorEntity`；安卓 `PaintToolsView` 的「+」→
/// `Brush.Shape` → `ShapeInput`。五种形状、默认描边可选填充、放在图中间、颜色和粗细取当前的笔、能挪能缩放能转。
/// 放下之后和贴纸一样是一个能再选中的东西（Signal 自己的贴纸、文字就是这样，D5），不是 Telegram 安卓那样画死在涂鸦层。
final class ImageEditorShapeItem: ImageEditorItem, ImageEditorTransformable {

    enum Kind: CaseIterable {
        case rectangle
        case circle
        case star
        case bubble
        case arrow

        /// 高 / 宽。矩形、气泡照 Telegram iOS 的新形状（0.75、0.7），圆、星形是方的；箭头是一条横线，这个高只是让它好点中。
        var aspectRatio: CGFloat {
            switch self {
            case .rectangle: 0.75
            case .circle, .star: 1
            case .bubble: 0.7
            case .arrow: 0.3
            }
        }

        /// 箭头没有填充（照 Telegram 安卓：箭头的图标没有填充的那一版）。
        var canFill: Bool { self != .arrow }
    }

    /// 新形状的宽：图的短边的一半（Telegram iOS 是画布宽的一半，安卓是短边的 0.4）。
    static let defaultUnitWidth: CGFloat = 0.5

    let kind: Kind
    let color: UIColor
    let isFilled: Bool
    /// 宽，以图的短边为 1（scaling = 1 时）。
    let unitWidth: CGFloat
    /// 线宽，和笔画一样以图的短边为 1（scaling = 1 时）。
    let unitLineWidth: CGFloat
    let unitCenter: ImageEditorSample
    let rotationRadians: CGFloat
    let scaling: CGFloat

    init(
        itemId: String = UUID().uuidString,
        kind: Kind,
        color: UIColor,
        isFilled: Bool,
        unitWidth: CGFloat = ImageEditorShapeItem.defaultUnitWidth,
        unitLineWidth: CGFloat,
        unitCenter: ImageEditorSample = .unitMidpoint,
        rotationRadians: CGFloat,
        scaling: CGFloat,
    ) {
        self.kind = kind
        self.color = color
        self.isFilled = isFilled && kind.canFill
        self.unitWidth = unitWidth
        self.unitLineWidth = unitLineWidth
        self.unitCenter = unitCenter
        self.rotationRadians = rotationRadians
        self.scaling = scaling
        super.init(itemId: itemId, itemType: .shape)
    }

    private func copy(
        color: UIColor? = nil,
        unitLineWidth: CGFloat? = nil,
        unitCenter: ImageEditorSample? = nil,
        rotationRadians: CGFloat? = nil,
        scaling: CGFloat? = nil,
    ) -> ImageEditorShapeItem {
        ImageEditorShapeItem(
            itemId: itemId,
            kind: kind,
            color: color ?? self.color,
            isFilled: isFilled,
            unitWidth: unitWidth,
            unitLineWidth: unitLineWidth ?? self.unitLineWidth,
            unitCenter: unitCenter ?? self.unitCenter,
            rotationRadians: rotationRadians ?? self.rotationRadians,
            scaling: scaling ?? self.scaling,
        )
    }

    func with(unitCenter: ImageEditorSample) -> ImageEditorShapeItem {
        copy(unitCenter: unitCenter)
    }

    func with(scaling: CGFloat, rotationRadians: CGFloat) -> ImageEditorShapeItem {
        copy(rotationRadians: rotationRadians, scaling: scaling)
    }

    func with(color: UIColor) -> ImageEditorShapeItem {
        copy(color: color)
    }

    func with(unitLineWidth: CGFloat) -> ImageEditorShapeItem {
        copy(unitLineWidth: unitLineWidth)
    }

    override var outputScale: CGFloat {
        scaling
    }

    /// 没缩放、没转时在画布上的大小；`shortSide` 是图在画布上的短边。
    func size(shortSide: CGFloat) -> CGSize {
        let width = unitWidth * shortSide
        return CGSize(width: width, height: width * kind.aspectRatio)
    }

    func lineWidth(shortSide: CGFloat) -> CGFloat {
        max(1, unitLineWidth * shortSide)
    }
}

// MARK: - Geometry

/// 五种形状的轮廓，画在 (0, 0)…size 里。描边的形状往里收半个线宽，线不出框；箭头整个是一块填充（杆 + 头）。
enum TellomiShapePath {

    /// 星形内外半径之比（Telegram iOS 0.4、安卓约 0.43）。
    static let starInnerRatio: CGFloat = 0.4
    /// 气泡：身子占的高、尾巴根在底边上的位置、尖的位置（都按宽 / 高的比例，尾巴在左下，照 Telegram iOS 新气泡）。
    static let bubbleBodyHeight: CGFloat = 0.78
    static let bubbleTailBase: ClosedRange<CGFloat> = 0.16...0.36
    static let bubbleTailTip: CGFloat = 0.12

    static func path(kind: ImageEditorShapeItem.Kind, size: CGSize, lineWidth: CGFloat, isFilled: Bool) -> CGPath {
        if kind == .arrow {
            return arrow(size: size, lineWidth: lineWidth)
        }
        let inset = isFilled ? 0 : lineWidth / 2
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return CGMutablePath() }
        switch kind {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .circle:
            let side = min(rect.width, rect.height)
            return CGPath(ellipseIn: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side), transform: nil)
        case .star:
            return star(in: rect)
        case .bubble:
            return bubble(in: rect)
        case .arrow:
            return CGMutablePath()
        }
    }

    static func star(in rect: CGRect) -> CGPath {
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * starInnerRatio
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let path = CGMutablePath()
        for index in 0..<10 {
            let radius = index.isMultiple(of: 2) ? outer : inner
            // 第一个尖朝上。
            let angle = -CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 5
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    static func bubble(in rect: CGRect) -> CGPath {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * bubbleBodyHeight)
        let radius = min(body.width, body.height) * 0.3
        let tailStart = CGPoint(x: rect.minX + rect.width * bubbleTailBase.upperBound, y: body.maxY)
        let tailTip = CGPoint(x: rect.minX + rect.width * bubbleTailTip, y: rect.maxY)
        let tailEnd = CGPoint(x: rect.minX + rect.width * bubbleTailBase.lowerBound, y: body.maxY)

        // 一笔画完（身子的圆角矩形在左下角断开、接上尾巴），描边时尾巴和身子之间没有线。
        let path = CGMutablePath()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
        path.addLine(to: tailStart)
        path.addLine(to: tailTip)
        path.addLine(to: tailEnd)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: min(radius, tailEnd.x - body.minX))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }

    /// 箭头：从左到右一根杆、右边一个实心三角头。头长取 3 倍线宽和宽的 0.18 里大的，两边各 30°（照 Telegram 安卓的箭头形状；
    /// iOS 的头是 3 × 1.5 线宽，这里取大一点，细线时头也看得清）。
    static func arrow(size: CGSize, lineWidth: CGFloat) -> CGPath {
        let midY = size.height / 2
        let headLength = min(size.width * 0.6, max(lineWidth * 3, size.width * 0.18))
        let headHalfWidth = min(size.height / 2, max(headLength * tan(CGFloat.pi / 6), lineWidth))
        let shaftHalf = min(lineWidth / 2, headHalfWidth)
        let tipX = size.width
        let baseX = tipX - headLength
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: midY - shaftHalf))
        path.addLine(to: CGPoint(x: baseX, y: midY - shaftHalf))
        path.addLine(to: CGPoint(x: baseX, y: midY - headHalfWidth))
        path.addLine(to: CGPoint(x: tipX, y: midY))
        path.addLine(to: CGPoint(x: baseX, y: midY + headHalfWidth))
        path.addLine(to: CGPoint(x: baseX, y: midY + shaftHalf))
        path.addLine(to: CGPoint(x: 0, y: midY + shaftHalf))
        path.closeSubpath()
        return path
    }
}
