//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

///
/// An object that describes shape of a bubble in chat.
///
/// This structure is designed to work in conjunction with `CVColorOrGradientView` and `CVWallpaperBlurView`.
///
public struct BubbleConfiguration {

    /// Bubble's corner rounding configuration.
    public let corners: Corners

    /// Bubble's stroke configuration.
    ///
    /// This property can be `nil` for no stroke.
    public let stroke: Stroke?

    /// Tellomi（#1205）：一组最后一条、单独一条的小尾巴。`nil` = 不画。
    public let tail: Tail?

    /// - Parameter corners: Bubble's corner rouding configuration.
    /// - Parameter stroke: Bubble's stroke configuration. Pass `nil` for no stroke.
    /// - Parameter tail: Tellomi：小尾巴。有尾巴时传给 `bubblePath(for:)` 的矩形在尾巴那一侧多出 `Tail.extent`。
    public init(corners: Corners, stroke: Stroke? = nil, tail: Tail? = nil) {
        self.stroke = stroke
        self.corners = corners
        self.tail = tail
    }

    // MARK: - Corners

    ///
    /// An object that contains configuration of chat bubble corner rounding..
    ///
    public struct Corners {

        fileprivate enum Style {
            /// Same radius for all corners.
            case uniform(radius: CGFloat)
            /// One radius for corners in `sharpCorners`, other radius for the rest.
            case segmented(sharpCorners: UIRectCorner, sharpCornerRadius: CGFloat, wideCornerRadius: CGFloat)
            /// Dynamic corner radius dependent on view's size.
            case capsule(maxRadius: CGFloat)
        }

        fileprivate let style: Style

        /// Creates a configuration where all corners have the same radius.
        public static func uniform(_ radius: CGFloat) -> Corners {
            Corners(style: .uniform(radius: radius))
        }

        /// Creates a configuration where some corners have one (sharp) corner radius
        /// and the rest have another (wide) corner radius.
        ///
        /// - Parameter sharpCorners: Set of corners that should have `sharpCornerRadius`.
        /// - Parameter sharpCornerRadius: Radius for corners specified in `sharpCorners`.
        /// - Parameter wideCornerRadius: Radius to use in corners that are not in `sharpCorners`.
        ///
        /// This method will check parameter value and will fall back to `uniform()` if needed.
        public static func segmented(
            sharpCorners: OWSDirectionalRectCorner,
            sharpCornerRadius: CGFloat,
            wideCornerRadius: CGFloat,
        ) -> Corners {
            if sharpCornerRadius == wideCornerRadius {
                return .uniform(sharpCornerRadius)
            }
            if sharpCorners.isEmpty {
                return .uniform(wideCornerRadius)
            }
            if sharpCorners == [.allCorners] {
                return .uniform(sharpCornerRadius)
            }
            return Corners(style: .segmented(
                sharpCorners: UIView.uiRectCorner(forOWSDirectionalRectCorner: sharpCorners),
                sharpCornerRadius: sharpCornerRadius,
                wideCornerRadius: wideCornerRadius,
            ))
        }

        /// Creates a configuration where corner radius is calculated dynamically based on view's dimensions.
        ///
        /// - Parameter maxRadius: Upper limit for corner radius. Pass `0` for no limit.
        public static func capsule(maxRadius: CGFloat = 18) -> Corners {
            Corners(style: .capsule(maxRadius: maxRadius))
        }

        /// Does a quick check if corner configuration has uniform corners and returns corner radius if it does.
        ///
        /// - Returns Corner radius if corners are uniform, otherwise returns `nil`.
        ///
        /// It more performant to set `CALayer.cornerRadius` instead of doing a mask layer.
        /// This method is design to help with that.
        public func uniformCornerRadius(for rect: CGRect) -> CGFloat? {
            if case .segmented = style {
                return nil
            }
            return radius(for: .topLeft, in: rect)
        }

        /// - Returns Radius for a specific corner for a given view rectangle.
        public func radius(for corner: UIRectCorner, in rect: CGRect) -> CGFloat {
            switch style {
            case .uniform(let radius):
                return min(radius, rect.size.smallerAxis / 2)

            case .segmented(let sharpCorners, let sharpCornerRadius, let wideCornerRadius):
                return sharpCorners.contains(corner) ? sharpCornerRadius : wideCornerRadius

            case .capsule(let maxRadius):
                let radius = rect.size.smallerAxis / 2
                return maxRadius > 0 ? min(maxRadius, radius) : radius
            }
        }
    }

    // MARK: - Stroke

    ///
    /// An object that contains description of chat bubble's outline (stroke).
    ///
    public struct Stroke {

        /// Stroke's color.
        public let color: UIColor

        /// Stroke width.
        ///
        /// Note that center of the stroke line lies on the edge of the bubble view.
        /// Therefore half of the width provided will be drawn inside of the view and another half - outside.
        public let width: CGFloat

        public init(color: UIColor, width: CGFloat) {
            self.color = color
            self.width = width
        }
    }

    // MARK: UIBezierPath conversions

    /// - Returns `UIBezierPath` describing bubble shape.
    ///
    /// Designed to allow callers to configure masking layers that match bubble shape..
    public func bubblePath(for rect: CGRect) -> UIBezierPath {
        if let tail {
            return tail.outline(body: tail.bodyRect(in: rect), corners: corners)
        }

        switch corners.style {
        case .uniform:
            let cornerRadius = corners.radius(for: .topLeft, in: rect)
            return UIBezierPath(cgPath: CGPath(
                roundedRect: rect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil,
            ))

        case .segmented(let sharpCorners, let sharpCornerRadius, let wideCornerRadius):
            return UIBezierPath.roundedRect(
                rect,
                sharpCorners: sharpCorners,
                sharpCornerRadius: sharpCornerRadius,
                wideCornerRadius: wideCornerRadius,
            )

        case .capsule:
            let cornerRadius = corners.radius(for: .topLeft, in: rect)
            return UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
        }
    }

    // MARK: - Tail (Tellomi)

    ///
    /// Tellomi（#1205）：气泡下角伸出的小尾巴，形状是设计规范 `docs/product/specs/bubbles-and-motion-design.md`
    /// 第 2 节 owner 选的 A「圆润」：伸出约 6、高 14，尖端是一个小圆头；和 Android 同一条路径。
    ///
    /// 尾巴和气泡是**同一条轮廓**，不是另贴一块：遮罩、描边、渐变、壁纸模糊都自动覆盖尾巴，交接处不叠深、不出内线。
    /// 尾巴那一侧的下角不画圆角：侧边一直下到尾巴起点，接尾巴曲线到尖端，再沿底边回来。
    ///
    public struct Tail: Equatable {

        /// 尾巴在右下角（`true`）还是左下角。按屏幕方向：调用方已把「我发的 / 对方发的」和从右往左排版换算好。
        public let isOnRight: Bool

        public init(isOnRight: Bool) {
            self.isOnRight = isOnRight
        }

        /// 尾巴伸出气泡的宽度（按控制点量；曲线本身最远约 6.1）。
        public static let extent: CGFloat = 6.3

        /// 尾巴沿气泡侧边的高度。
        public static let height: CGFloat = 14

        /// 气泡在尾巴那一侧多留的外边距（规范 #1204 第 2 节的 e，A「圆润」是 6）：尾巴不贴屏幕边、不压头像。
        public static let sideMargin: CGFloat = 6

        /// 气泡本体：整块去掉尾巴那一侧的 `extent`。
        public func bodyRect(in rect: CGRect) -> CGRect {
            var body = rect
            body.size.width = max(0, rect.width - Self.extent)
            if !isOnRight {
                body.origin.x += Self.extent
            }
            return body
        }

        /// 气泡里的内容在尾巴那一侧要让出的宽度。
        public var contentInsets: UIEdgeInsets {
            isOnRight
                ? UIEdgeInsets(top: 0, left: 0, bottom: 0, right: Self.extent)
                : UIEdgeInsets(top: 0, left: Self.extent, bottom: 0, right: 0)
        }

        /// 「气泡 + 尾巴」一条顺时针轮廓。先按尾巴在右边画，尾巴在左边时整体镜像（半径先按镜像取）。
        func outline(body: CGRect, corners: Corners) -> UIBezierPath {
            let maxRadius = min(body.width, body.height) / 2
            func radius(_ corner: UIRectCorner) -> CGFloat {
                min(corners.radius(for: corner, in: body), maxRadius)
            }
            let topNear = radius(isOnRight ? .topRight : .topLeft)
            let topFar = radius(isOnRight ? .topLeft : .topRight)
            let bottomFar = radius(isOnRight ? .bottomLeft : .bottomRight)

            let x0 = body.minX
            let x1 = body.maxX
            let y0 = body.minY
            let y1 = body.maxY
            // 气泡矮到放不下 14 高的尾巴时，尾巴从上角圆弧结束处开始。
            let tailTop = max(y0 + topNear, y1 - Self.height)

            let path = UIBezierPath()
            path.move(to: CGPoint(x: x0 + topFar, y: y0))
            path.addLine(to: CGPoint(x: x1 - topNear, y: y0))
            path.addArc(withCenter: CGPoint(x: x1 - topNear, y: y0 + topNear), radius: topNear, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
            path.addLine(to: CGPoint(x: x1, y: tailTop))
            path.addCurve(to: CGPoint(x: x1 + 5.4, y: y1 - 1.0), controlPoint1: CGPoint(x: x1, y: y1 - 6.5), controlPoint2: CGPoint(x: x1 + 2.2, y: y1 - 1.8))
            path.addCurve(to: CGPoint(x: x1 + 5.4, y: y1), controlPoint1: CGPoint(x: x1 + 6.3, y: y1 - 0.8), controlPoint2: CGPoint(x: x1 + 6.3, y: y1))
            path.addLine(to: CGPoint(x: x0 + bottomFar, y: y1))
            path.addArc(withCenter: CGPoint(x: x0 + bottomFar, y: y1 - bottomFar), radius: bottomFar, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
            path.addLine(to: CGPoint(x: x0, y: y0 + topFar))
            path.addArc(withCenter: CGPoint(x: x0 + topFar, y: y0 + topFar), radius: topFar, startAngle: .pi, endAngle: .pi * 3 / 2, clockwise: true)
            path.close()

            if !isOnRight {
                path.apply(CGAffineTransform(translationX: body.minX + body.maxX, y: 0).scaledBy(x: -1, y: 1))
                // 镜像会把顺时针翻成逆时针：翻回来。媒体的内阴影（`OWSBubbleShapeView` `.innerShadow`）把这条轮廓和一个反向的外框
                // 拼起来按非零环绕填黑，只有两者方向相反时气泡里面才是空的；方向一样，左边带尾巴的气泡（对方发的）整张图都会被涂黑。
                return path.reversing()
            }
            return path
        }
    }

    /// - Returns `UIBezierPath` containing stroke path for the provided `UIRect`.
    /// Will return `nil` if `BubbleConfiguration` doesn't have stroke specified.
    ///
    /// Designed to work with `CAShapeLayer` to add stroke to chat bubbles.
    public func strokePath(for rect: CGRect) -> UIBezierPath? {
        guard stroke != nil else { return nil }

        return bubblePath(for: rect)
    }
}
