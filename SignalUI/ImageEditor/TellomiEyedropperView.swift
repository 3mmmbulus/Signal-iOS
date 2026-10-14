//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Tellomi（tellomi/tellomi#1522 E-2，照 Telegram iOS `DrawingUI` 的 `EyedropperView`）：吸管。
///
/// 盖在画布上，`snapshot` 是盖住的这一块画布现在的样子（和这个视图一样大，1 点 1 像素）。放大镜 148 pt，一开始在正中，
/// 手指在哪儿拖都按位移挪它（不跳到手指下）；圈里是中心附近的像素放大 15 倍、带格线，中间一格框着取到的像素，外圈是取到的颜色；
/// 松手就取这个颜色（`onPicked`），放大镜缩小消失。出现是从小弹到原大（0.4 s 弹簧），消失 0.2 s 缩小淡出，和 Telegram 一样。
/// 颜色很浅（亮度 > 0.9）时白圈换灰、格线换深，免得看不出边界。自己写的，一行没搬（GPLv2）。
final class TellomiEyedropperView: UIView {

    static let diameter: CGFloat = 148
    static let zoom: CGFloat = 15

    var onPicked: ((UIColor) -> Void)?

    private let pixels: TellomiEyedropperPixels?

    private let containerView = UIView()
    private let clipView = UIView()
    private let zoomLayer = CALayer()
    private let gridLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let colorRingLayer = CAShapeLayer()
    private let centerLayer = CALayer()

    private(set) var currentColor: UIColor?
    private(set) var isDismissing = false

    init(snapshot: UIImage) {
        pixels = TellomiEyedropperPixels(image: snapshot)
        super.init(frame: .zero)

        zoomLayer.contents = snapshot.cgImage
        zoomLayer.magnificationFilter = .nearest
        zoomLayer.contentsGravity = .resize

        clipView.clipsToBounds = true
        clipView.isUserInteractionEnabled = false
        clipView.backgroundColor = .black
        clipView.layer.addSublayer(zoomLayer)
        clipView.layer.addSublayer(gridLayer)
        gridLayer.lineWidth = 1 / UIScreen.main.scale

        containerView.isUserInteractionEnabled = false
        containerView.addSubview(clipView)
        containerView.layer.addSublayer(ringLayer)
        containerView.layer.addSublayer(colorRingLayer)
        containerView.layer.addSublayer(centerLayer)
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.4
        containerView.layer.shadowRadius = 12
        containerView.layer.shadowOffset = .zero
        colorRingLayer.fillColor = nil
        colorRingLayer.lineWidth = 8
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 3
        centerLayer.borderWidth = 1.5
        centerLayer.cornerRadius = 2
        addSubview(containerView)
        applyContrast(light: false)

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var hasPlacedMagnifier = false

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = Self.diameter
        containerView.bounds = CGRect(origin: .zero, size: CGSize(square: diameter))
        if !hasPlacedMagnifier, bounds.width > 0, bounds.height > 0 {
            hasPlacedMagnifier = true
            containerView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let ringInset = colorRingLayer.lineWidth
        let inner = diameter - 2 * ringInset
        clipView.frame = CGRect(x: ringInset, y: ringInset, width: inner, height: inner)
        clipView.layer.cornerRadius = inner / 2
        let outerRect = containerView.bounds.insetBy(dx: colorRingLayer.lineWidth / 2, dy: colorRingLayer.lineWidth / 2)
        colorRingLayer.path = UIBezierPath(ovalIn: outerRect).cgPath
        let ringRect = containerView.bounds.insetBy(dx: ringInset + ringLayer.lineWidth / 2, dy: ringInset + ringLayer.lineWidth / 2)
        ringLayer.path = UIBezierPath(ovalIn: ringRect).cgPath
        let cell = Self.zoom
        centerLayer.frame = CGRect(x: (diameter - cell) / 2, y: (diameter - cell) / 2, width: cell, height: cell)
        containerView.layer.shadowPath = UIBezierPath(ovalIn: containerView.bounds).cgPath
        updateGrid()
        updateMagnifier()
    }

    private func updateGrid() {
        let size = clipView.bounds.size
        let cell = Self.zoom
        let path = UIBezierPath()
        // 格线对齐中间那一格。
        var x = (size.width - cell) / 2
        while x > 0 { x -= cell }
        while x < size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += cell
        }
        var y = (size.height - cell) / 2
        while y > 0 { y -= cell }
        while y < size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += cell
        }
        gridLayer.frame = clipView.bounds
        gridLayer.path = path.cgPath
    }

    private var isLightContrast = false

    private func applyContrast(light: Bool) {
        isLightContrast = light
        gridLayer.strokeColor = light ? UIColor.black.withAlphaComponent(0.2).cgColor : UIColor.white.withAlphaComponent(0.25).cgColor
        let ring = light ? UIColor(white: 0.6, alpha: 1) : UIColor.white
        ringLayer.strokeColor = ring.cgColor
        centerLayer.borderColor = ring.cgColor
    }

    /// 放大镜中心在这个视图里的位置。
    var magnifierCenter: CGPoint { containerView.center }

    /// 实际取色的点：放大镜中心所在像素的中心（1 点 1 像素），这样中间那一格正好框住它。
    var samplePoint: CGPoint {
        let center = magnifierCenter
        let x = min(max(center.x.rounded(.down), 0), max(bounds.width - 1, 0)) + 0.5
        let y = min(max(center.y.rounded(.down), 0), max(bounds.height - 1, 0)) + 0.5
        return CGPoint(x: x, y: y)
    }

    private func updateMagnifier() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = samplePoint
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 整块快照放大 15 倍，挪到让取色点落在圈的正中。
        let clipCenter = CGPoint(x: clipView.bounds.midX, y: clipView.bounds.midY)
        zoomLayer.frame = CGRect(
            x: clipCenter.x - point.x * Self.zoom,
            y: clipCenter.y - point.y * Self.zoom,
            width: bounds.width * Self.zoom,
            height: bounds.height * Self.zoom,
        )
        let color = pixels?.color(atUnit: CGPoint(x: point.x / bounds.width, y: point.y / bounds.height))
        currentColor = color
        colorRingLayer.strokeColor = color?.cgColor
        centerLayer.backgroundColor = color?.cgColor
        let light = color.map { Self.lightness(of: $0) > 0.9 } ?? false
        if light != isLightContrast {
            applyContrast(light: light)
        }
        CATransaction.commit()
    }

    static func lightness(of color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }

    // MARK: - Interaction

    @objc
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            moveMagnifier(by: translation)
        case .ended, .cancelled:
            finishPicking()
        default:
            break
        }
    }

    func moveMagnifier(by translation: CGPoint) {
        guard !isDismissing else { return }
        var center = containerView.center
        center.x = min(max(center.x + translation.x, 0), bounds.width)
        center.y = min(max(center.y + translation.y, 0), bounds.height)
        containerView.center = center
        updateMagnifier()
    }

    /// 松手：取当前颜色。
    func finishPicking() {
        guard !isDismissing, let currentColor else { return }
        onPicked?(currentColor)
    }

    // MARK: - Appear / dismiss

    func animateIn() {
        containerView.alpha = 0
        containerView.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        UIView.animate(
            withDuration: 0.4,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState],
        ) {
            self.containerView.transform = .identity
        }
        UIView.animate(withDuration: 0.2) {
            self.containerView.alpha = 1
        }
    }

    func dismiss(animated: Bool = true) {
        guard !isDismissing else { return }
        isDismissing = true
        isUserInteractionEnabled = false
        guard animated else {
            removeFromSuperview()
            return
        }
        UIView.animate(
            withDuration: 0.2,
            animations: {
                self.containerView.alpha = 0
                self.containerView.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
            },
            completion: { _ in
                self.removeFromSuperview()
            },
        )
    }
}

/// 位图的 RGBA 像素，按 (0…1, 0…1) 取色，越界取边上的。
struct TellomiEyedropperPixels {
    private let data: [UInt8]
    let width: Int
    let height: Int

    init?(image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let drew: Bool = buffer.withUnsafeMutableBytes { bytes in
            guard
                let context = CGContext(
                    data: bytes.baseAddress,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: pixelWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
                )
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return true
        }
        guard drew else { return nil }
        width = pixelWidth
        height = pixelHeight
        data = buffer
    }

    func color(atUnit point: CGPoint) -> UIColor {
        let x = min(max(Int((point.x * CGFloat(width)).rounded(.down)), 0), width - 1)
        let y = min(max(Int((point.y * CGFloat(height)).rounded(.down)), 0), height - 1)
        let index = (y * width + x) * 4
        return UIColor(
            red: CGFloat(data[index]) / 255,
            green: CGFloat(data[index + 1]) / 255,
            blue: CGFloat(data[index + 2]) / 255,
            alpha: 1,
        )
    }
}
