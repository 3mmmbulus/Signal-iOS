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
///
/// E-3b：选中后的拉柄（`TellomiShapeHandles`）改宽高、气泡尾巴、箭头两端和弯曲，所以宽高比、尾巴、弯曲是每个形状自己的。
final class ImageEditorShapeItem: ImageEditorItem, ImageEditorTransformable {

    enum Kind: CaseIterable {
        case rectangle
        case circle
        case star
        case bubble
        case arrow

        /// 新形状的高 / 宽。矩形、气泡照 Telegram iOS 的新形状（0.75、0.7），圆、星形是方的；箭头是一条横线，这个高只是让它好点中。
        var aspectRatio: CGFloat {
            switch self {
            case .rectangle: 0.75
            case .circle, .star: 1
            case .bubble: 0.7
            case .arrow: TellomiShapePath.arrowAspect(bend: 0)
            }
        }

        /// 箭头没有填充（照 Telegram 安卓：箭头的图标没有填充的那一版）。
        var canFill: Bool { self != .arrow }

        /// 圆、星形只能等比缩放（Telegram 安卓的圆只有一个半径柄，iOS 的星形锁宽高比）。
        var keepsSquare: Bool { self == .circle || self == .star }
    }

    /// 新形状的宽：图的短边的一半（Telegram iOS 是画布宽的一半，安卓是短边的 0.4）。
    static let defaultUnitWidth: CGFloat = 0.5

    let kind: Kind
    let color: UIColor
    let isFilled: Bool
    /// 宽，以图的短边为 1（scaling = 1 时）。
    let unitWidth: CGFloat
    /// 高 / 宽。
    let aspectRatio: CGFloat
    /// 线宽，和笔画一样以图的短边为 1（scaling = 1 时）。
    let unitLineWidth: CGFloat
    /// 气泡：尾巴尖在宽上的位置（0 = 左边）。
    let tailX: CGFloat
    /// 气泡：身子占整个框高的比例（剩下的是尾巴）。
    let bodyFraction: CGFloat
    /// 箭头：中间那一点离开直线多远（按箭头长度算，往下为正）。
    let bend: CGFloat
    let unitCenter: ImageEditorSample
    let rotationRadians: CGFloat
    let scaling: CGFloat

    init(
        itemId: String = UUID().uuidString,
        kind: Kind,
        color: UIColor,
        isFilled: Bool,
        unitWidth: CGFloat = ImageEditorShapeItem.defaultUnitWidth,
        aspectRatio: CGFloat? = nil,
        unitLineWidth: CGFloat,
        tailX: CGFloat = TellomiShapePath.bubbleTailTip,
        bodyFraction: CGFloat = TellomiShapePath.bubbleBodyHeight,
        bend: CGFloat = 0,
        unitCenter: ImageEditorSample = .unitMidpoint,
        rotationRadians: CGFloat,
        scaling: CGFloat,
    ) {
        self.kind = kind
        self.color = color
        self.isFilled = isFilled && kind.canFill
        self.unitWidth = unitWidth
        self.aspectRatio = aspectRatio ?? kind.aspectRatio
        self.unitLineWidth = unitLineWidth
        self.tailX = tailX
        self.bodyFraction = bodyFraction
        self.bend = bend
        self.unitCenter = unitCenter
        self.rotationRadians = rotationRadians
        self.scaling = scaling
        super.init(itemId: itemId, itemType: .shape)
    }

    private func copy(
        color: UIColor? = nil,
        unitWidth: CGFloat? = nil,
        aspectRatio: CGFloat? = nil,
        unitLineWidth: CGFloat? = nil,
        tailX: CGFloat? = nil,
        bodyFraction: CGFloat? = nil,
        bend: CGFloat? = nil,
        unitCenter: ImageEditorSample? = nil,
        rotationRadians: CGFloat? = nil,
        scaling: CGFloat? = nil,
    ) -> ImageEditorShapeItem {
        ImageEditorShapeItem(
            itemId: itemId,
            kind: kind,
            color: color ?? self.color,
            isFilled: isFilled,
            unitWidth: unitWidth ?? self.unitWidth,
            aspectRatio: aspectRatio ?? self.aspectRatio,
            unitLineWidth: unitLineWidth ?? self.unitLineWidth,
            tailX: tailX ?? self.tailX,
            bodyFraction: bodyFraction ?? self.bodyFraction,
            bend: bend ?? self.bend,
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
        return CGSize(width: width, height: width * aspectRatio)
    }

    func lineWidth(shortSide: CGFloat) -> CGFloat {
        max(1, unitLineWidth * shortSide)
    }

    var shape: TellomiShapeHandles.Shape {
        TellomiShapeHandles.Shape(kind: kind, width: unitWidth, aspectRatio: aspectRatio, tailX: tailX, bodyFraction: bodyFraction, bend: bend)
    }

    /// 拉柄拉完：形状参数换成 `result` 的，中心挪 `result.centerOffset`（形状自己的坐标，scaling = 1、以图短边为 1），
    /// 转 `result.rotation`。
    func applying(_ result: TellomiShapeHandles.Result, imageAspect: CGSize) -> ImageEditorShapeItem {
        let rotated = result.centerOffset.applying(CGAffineTransform(rotationAngle: rotationRadians))
        // 中心是按图的宽 / 高算的 0…1，偏移是按短边算的。
        let shortSide = min(imageAspect.width, imageAspect.height)
        let delta = CGPoint(
            x: rotated.x * scaling * shortSide / max(imageAspect.width, 0.0001),
            y: rotated.y * scaling * shortSide / max(imageAspect.height, 0.0001),
        )
        return copy(
            unitWidth: result.shape.width,
            aspectRatio: result.shape.aspectRatio,
            tailX: result.shape.tailX,
            bodyFraction: result.shape.bodyFraction,
            bend: result.shape.bend,
            unitCenter: CGPoint.clamp01(unitCenter.plus(delta)),
            rotationRadians: rotationRadians + result.rotation,
        )
    }
}

// MARK: - Handles

/// Tellomi（tellomi/tellomi#1522 E-3b）：选中形状后的拉柄（两端 Telegram 都有：iOS `DrawingSimpleShapeEntityView` 的角柄、
/// `DrawingBubbleEntityView` 的尾巴柄、`DrawingVectorEntityView` 的两端 + 中间；安卓 `ShapeInput` 的角柄、尾巴柄、箭头两端 + 中间）。
///
/// - 矩形、气泡：四个角，拉一个角、对角不动，宽高各自变（气泡拉的是身子的角，尾巴长度不变）；
/// - 圆、星形：四个角，对角不动、等比；
/// - 气泡：尾巴尖，左右挪、往下拉长（照 Telegram iOS，尾巴只在底边；安卓能朝任何方向，只有一端有，不做）；
/// - 箭头：两端（另一端不动，长度和方向跟着变）、中间（拉弯，曲线穿过这一点，照 Telegram iOS）。
///
/// 坐标：形状自己的、中心在原点、y 往下、宽以图短边为 1（scaling = 1）。两端用同一套算法（安卓 `ShapeHandles`）。
enum TellomiShapeHandles {

    enum Handle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        case tail
        case arrowStart, arrowEnd, arrowBend
    }

    struct Shape: Equatable {
        var kind: ImageEditorShapeItem.Kind
        var width: CGFloat
        var aspectRatio: CGFloat
        var tailX: CGFloat
        var bodyFraction: CGFloat
        var bend: CGFloat

        var height: CGFloat { width * aspectRatio }
    }

    struct Result: Equatable {
        var shape: Shape
        /// 新中心相对旧中心（形状自己的坐标）。
        var centerOffset: CGPoint
        /// 多转的角度（只有拉箭头两端时有）。
        var rotation: CGFloat
    }

    /// 最小宽高（以图短边为 1）。
    static let minimumSize: CGFloat = 0.04

    static func handles(for kind: ImageEditorShapeItem.Kind) -> [Handle] {
        switch kind {
        case .rectangle, .circle, .star: [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case .bubble: [.topLeft, .topRight, .bottomLeft, .bottomRight, .tail]
        case .arrow: [.arrowStart, .arrowEnd, .arrowBend]
        }
    }

    /// 拉柄的位置。气泡的下面两个角是身子的角，不是框的角。
    static func position(of handle: Handle, in shape: Shape) -> CGPoint {
        let halfWidth = shape.width / 2
        let top = -shape.height / 2
        let bottom = shape.kind == .bubble ? top + shape.height * shape.bodyFraction : shape.height / 2
        switch handle {
        case .topLeft: return CGPoint(x: -halfWidth, y: top)
        case .topRight: return CGPoint(x: halfWidth, y: top)
        case .bottomLeft: return CGPoint(x: -halfWidth, y: bottom)
        case .bottomRight: return CGPoint(x: halfWidth, y: bottom)
        case .tail: return CGPoint(x: -halfWidth + shape.width * shape.tailX, y: shape.height / 2)
        case .arrowStart: return CGPoint(x: -halfWidth, y: 0)
        case .arrowEnd: return CGPoint(x: halfWidth, y: 0)
        case .arrowBend: return CGPoint(x: 0, y: shape.bend * shape.width)
        }
    }

    /// 把 `handle` 拉到 `point`（形状自己的坐标，按拉之前的形状算）之后的形状。
    static func drag(_ handle: Handle, to point: CGPoint, in shape: Shape) -> Result {
        var result = Result(shape: shape, centerOffset: .zero, rotation: 0)
        switch handle {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let corner = position(of: handle, in: shape)
            let opposite = position(of: opposite(handle), in: shape)
            let signX: CGFloat = corner.x >= opposite.x ? 1 : -1
            let signY: CGFloat = corner.y >= opposite.y ? 1 : -1
            var width = max(minimumSize, (point.x - opposite.x) * signX)
            var height = max(minimumSize, (point.y - opposite.y) * signY)
            if shape.kind.keepsSquare {
                width = max(width, height)
                height = width
            }
            let moved = CGPoint(x: opposite.x + signX * width, y: opposite.y + signY * height)
            let bodyCenter = CGPoint(x: (moved.x + opposite.x) / 2, y: (moved.y + opposite.y) / 2)
            if shape.kind == .bubble {
                // 身子变了，尾巴长度不变；框的中心在身子中心下面半个尾巴。
                let tail = shape.height * (1 - shape.bodyFraction)
                let total = height + tail
                result.shape.width = width
                result.shape.aspectRatio = total / width
                result.shape.bodyFraction = height / total
                result.centerOffset = CGPoint(x: bodyCenter.x, y: bodyCenter.y + tail / 2)
            } else {
                result.shape.width = width
                result.shape.aspectRatio = height / width
                result.centerOffset = bodyCenter
            }

        case .tail:
            let body = shape.height * shape.bodyFraction
            let top = -shape.height / 2
            let tail = min(max(point.y - (top + body), body * 0.1), body * 1.5)
            let total = body + tail
            result.shape.tailX = min(max((point.x + shape.width / 2) / shape.width, 0.05), 0.95)
            result.shape.aspectRatio = total / shape.width
            result.shape.bodyFraction = body / total
            // 上边不动。
            result.centerOffset = CGPoint(x: 0, y: (total - shape.height) / 2)

        case .arrowStart, .arrowEnd:
            let fixed = position(of: handle == .arrowEnd ? .arrowStart : .arrowEnd, in: shape)
            let vector = handle == .arrowEnd
                ? CGPoint(x: point.x - fixed.x, y: point.y - fixed.y)
                : CGPoint(x: fixed.x - point.x, y: fixed.y - point.y)
            let length = max(minimumSize, hypot(vector.x, vector.y))
            let angle = atan2(vector.y, vector.x)
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let start = handle == .arrowEnd ? fixed : CGPoint(x: fixed.x - direction.x * length, y: fixed.y - direction.y * length)
            result.shape.width = length
            result.shape.aspectRatio = TellomiShapePath.arrowAspect(bend: shape.bend)
            result.centerOffset = CGPoint(x: start.x + direction.x * length / 2, y: start.y + direction.y * length / 2)
            result.rotation = angle

        case .arrowBend:
            let bend = min(max(point.y / max(shape.width, 0.0001), -0.5), 0.5)
            result.shape.bend = bend
            result.shape.aspectRatio = TellomiShapePath.arrowAspect(bend: bend)
        }
        return result
    }

    private static func opposite(_ handle: Handle) -> Handle {
        switch handle {
        case .topLeft: .bottomRight
        case .topRight: .bottomLeft
        case .bottomLeft: .topRight
        case .bottomRight: .topLeft
        default: handle
        }
    }
}

// MARK: - Geometry

/// 五种形状的轮廓，画在 (0, 0)…size 里。描边的形状往里收半个线宽，线不出框；箭头是一根杆（描边）加一个实心头。
enum TellomiShapePath {

    /// 星形内外半径之比（Telegram iOS 0.4、安卓约 0.43）。
    static let starInnerRatio: CGFloat = 0.4
    /// 气泡：身子占的高、尾巴尖的位置（按宽 / 高的比例，尾巴在左下，照 Telegram iOS 新气泡）；尾巴根宽 0.2、中点在尖右边 0.14。
    static let bubbleBodyHeight: CGFloat = 0.78
    static let bubbleTailTip: CGFloat = 0.12
    static let bubbleTailHalfBase: CGFloat = 0.1
    static let bubbleTailBaseOffset: CGFloat = 0.14

    struct Parameters {
        var lineWidth: CGFloat
        var isFilled: Bool
        var tailX: CGFloat = bubbleTailTip
        var bodyFraction: CGFloat = bubbleBodyHeight
        var bend: CGFloat = 0
    }

    static func path(kind: ImageEditorShapeItem.Kind, size: CGSize, lineWidth: CGFloat, isFilled: Bool) -> CGPath {
        path(kind: kind, size: size, parameters: Parameters(lineWidth: lineWidth, isFilled: isFilled))
    }

    static func path(kind: ImageEditorShapeItem.Kind, size: CGSize, parameters: Parameters) -> CGPath {
        if kind == .arrow {
            let parts = arrow(size: size, lineWidth: parameters.lineWidth, bend: parameters.bend)
            let path = CGMutablePath()
            path.addPath(parts.shaft.copy(strokingWithWidth: parameters.lineWidth, lineCap: .butt, lineJoin: .round, miterLimit: 4))
            path.addPath(parts.head)
            return path
        }
        let inset = parameters.isFilled ? 0 : parameters.lineWidth / 2
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
            // 尾巴尖贴着框底；身子按 bodyFraction 算（描边时身子底边也往上收了 inset，尖往上收 inset）。
            return bubble(in: rect, frameHeight: size.height, tailX: parameters.tailX, bodyFraction: parameters.bodyFraction)
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

    static func bubble(
        in rect: CGRect,
        frameHeight: CGFloat? = nil,
        tailX: CGFloat = bubbleTailTip,
        bodyFraction: CGFloat = bubbleBodyHeight,
    ) -> CGPath {
        let inset = ((frameHeight ?? rect.height) - rect.height) / 2
        let bodyBottom = rect.minY - inset + (frameHeight ?? rect.height) * bodyFraction - inset
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, bodyBottom - rect.minY))
        let radius = min(body.width, body.height) * 0.3
        let tipX = rect.minX + rect.width * tailX
        let baseCenter = min(max(tailX + bubbleTailBaseOffset, bubbleTailHalfBase + 0.02), 1 - bubbleTailHalfBase - 0.02)
        let baseLeft = rect.minX + rect.width * (baseCenter - bubbleTailHalfBase)
        let baseRight = rect.minX + rect.width * (baseCenter + bubbleTailHalfBase)
        let tip = CGPoint(x: tipX, y: rect.maxY)
        let leftCorner = min(radius, baseLeft - body.minX)
        let rightCorner = min(radius, body.maxX - baseRight)

        // 一笔画完（身子底边在尾巴根处断开、接上尾巴），描边时尾巴和身子之间没有线。
        let path = CGMutablePath()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: max(0, rightCorner))
        path.addLine(to: CGPoint(x: baseRight, y: body.maxY))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: baseLeft, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: max(0, leftCorner))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }

    /// 箭头框的高 / 宽：要装下弯出去的那一段（`bend` 按长度算）和箭头。
    static func arrowAspect(bend: CGFloat) -> CGFloat {
        max(0.3, 2 * abs(bend) + 0.3)
    }

    /// 箭头：从左到右一根杆（二次曲线，穿过中间那一点）、右边一个实心三角头，头顺着曲线末端的方向。
    /// 头长取 3 倍线宽和长度的 0.18 里大的，两边各 30°（照 Telegram 安卓的箭头形状；iOS 的头是 3 × 1.5 线宽，这里取大一点，细线时头也看得清）。
    static func arrow(size: CGSize, lineWidth: CGFloat, bend: CGFloat = 0) -> (shaft: CGPath, head: CGPath) {
        let midY = size.height / 2
        let start = CGPoint(x: 0, y: midY)
        let end = CGPoint(x: size.width, y: midY)
        // 曲线在 t = 0.5 穿过 (宽 / 2, midY + bend·宽)，所以控制点离直线 2·bend·宽。
        let control = CGPoint(x: size.width / 2, y: midY + 2 * bend * size.width)
        let headLength = min(size.width * 0.6, max(lineWidth * 3, size.width * 0.18))
        let headHalfWidth = min(size.width * 0.15, max(headLength * tan(CGFloat.pi / 6), lineWidth))
        // 杆是整条曲线在头根处截下的前一段（de Casteljau），所以还穿过中间那一点；头从截点连到尖。
        // 曲线长按（控制折线 + 弦）/ 2 估。
        let curveLength = (hypot(control.x - start.x, control.y - start.y) + hypot(end.x - control.x, end.y - control.y) + (end.x - start.x)) / 2
        let t = min(max(1 - headLength / max(curveLength, 0.0001), 0.05), 1)
        let u = 1 - t
        let base = CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y,
        )
        var direction = CGPoint(x: end.x - base.x, y: end.y - base.y)
        let length = max(hypot(direction.x, direction.y), 0.0001)
        direction = CGPoint(x: direction.x / length, y: direction.y / length)
        let normal = CGPoint(x: -direction.y, y: direction.x)

        let shaft = CGMutablePath()
        shaft.move(to: start)
        shaft.addQuadCurve(to: base, control: CGPoint(x: start.x + (control.x - start.x) * t, y: start.y + (control.y - start.y) * t))

        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: CGPoint(x: base.x + normal.x * headHalfWidth, y: base.y + normal.y * headHalfWidth))
        head.addLine(to: CGPoint(x: base.x - normal.x * headHalfWidth, y: base.y - normal.y * headHalfWidth))
        head.closeSubpath()
        return (shaft, head)
    }
}
