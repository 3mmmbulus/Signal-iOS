//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit
public import UIKit

/// Tellomi（tellomi/tellomi#1263，spec R-1）：盖在被罩住的图片 / 视频上面的那一层：模糊的图 + 一层压暗 + 缓慢飘动、闪烁的白色小点。
///
/// 照 Telegram 的机制（iOS `ChatMessageInteractiveMediaNode` 的 `dustNode` = `InvisibleInkDustNode/MediaDustNode`：模糊图上一层
/// `CAEmitterLayer` 粒子；`tap(at:)` 后从点的位置把一个圆形遮罩在 0.45 秒里放大，圆里露出原图；只读）。实现是自己写的：
/// 只用 `CAEmitterLayer` 的公开属性（Telegram 用私有的 `emitterBehaviors` 做吸引子），揭示用一个奇偶填充的遮罩路径动画，
/// 粒子层往手指那边缩、淡掉；时长同 spec 的「约 0.45 秒」。
/// 图本身是模糊过的位图（不用 `UIVisualEffectView`：长按预览之类的截图里模糊效果可能不画，原图会露出来）。
/// 打开「减弱动态效果」时粒子不飘，揭示直接完成。
public final class TellomiSpoilerCoverView: UIView {

    public static let revealDuration: TimeInterval = 0.45

    private static let blurredCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    private let imageView = UIImageView()
    private let scrimView = UIView()
    private let emitterLayer = CAEmitterLayer()
    private let maskLayer = CAShapeLayer()

    private var loadingKey: String?
    private var revealCompletion: (() -> Void)?

    /// 还罩着（没开始揭示，或者正在揭示）。
    public private(set) var isCovering = true

    /// 正在揭示：这期间再点不算（不开查看器、不重新开始）。
    public private(set) var isRevealing = false

    public override init(frame: CGRect) {
        super.init(frame: frame)

        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = UIColor(white: 0.18, alpha: 1)
        accessibilityIdentifier = "TellomiSpoilerCoverView"

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)

        scrimView.backgroundColor = UIColor(white: 0, alpha: 0.2)
        addSubview(scrimView)

        emitterLayer.emitterShape = .rectangle
        emitterLayer.emitterMode = .surface
        emitterLayer.renderMode = .unordered
        emitterLayer.emitterCells = [Self.makeDustCell()]
        layer.addSublayer(emitterLayer)

        maskLayer.fillRule = .evenOdd
    }

    required init?(coder: NSCoder) {
        owsFail("Do not use this initializer.")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        scrimView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitterLayer.frame = bounds
        emitterLayer.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        emitterLayer.emitterSize = bounds.size
        // 粒子密度跟面积走（约每 14×14 点一个在场）
        let area = max(bounds.width * bounds.height, 1)
        emitterLayer.birthRate = Float(min(max(area / (14 * 14), 24), 420) / 1.8)
        CATransaction.commit()
    }

    // MARK: - Covering

    /// 罩上 [attachment]：先放模糊哈希（或深色底），缩略图模糊好了再换上。
    public func cover(_ attachment: ReferencedAttachment) {
        resetReveal()
        isHidden = false

        let key = "\(attachment.attachment.id)" as NSString
        loadingKey = key as String
        if let cached = Self.blurredCache.object(forKey: key) {
            imageView.image = cached
            return
        }
        imageView.image = attachment.attachment.blurHash?.nilIfEmpty.flatMap { BlurHash.image(for: $0) }
        Task { [weak self] in
            guard
                let thumbnail = await attachment.getThumbnailImage(quality: .small),
                let blurred = try? await thumbnail.withGaussianBlurAsync(radius: 6, resizeToMaxPixelDimension: 72)
            else {
                return
            }
            Self.blurredCache.setObject(blurred, forKey: key)
            await MainActor.run {
                guard let self, self.loadingKey == key as String, self.isCovering else { return }
                self.imageView.image = blurred
            }
        }
    }

    /// 发送前罩上一张本机的图（选图面板里罩住的格子，spec P-6）：同一套模糊 + 粒子，图在这里模糊。
    /// [key] 用来认出是不是同一张（缩略图先糊后清楚地来，换了才重新模糊）。
    public func cover(image: UIImage?, key: String) {
        if !isCovering || isHidden {
            resetReveal()
            isHidden = false
        }
        let cacheKey = "local:\(key):\(image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "-")" as NSString
        guard cacheKey as String != loadingKey else { return }
        loadingKey = cacheKey as String
        if let cached = Self.blurredCache.object(forKey: cacheKey) {
            imageView.image = cached
            return
        }
        guard let image else {
            imageView.image = nil
            return
        }
        Task { [weak self] in
            guard let blurred = try? await image.withGaussianBlurAsync(radius: 6, resizeToMaxPixelDimension: 72) else { return }
            Self.blurredCache.setObject(blurred, forKey: cacheKey)
            await MainActor.run {
                guard let self, self.loadingKey == cacheKey as String, self.isCovering else { return }
                self.imageView.image = blurred
            }
        }
    }

    /// 不罩（没有遮罩，或者已经揭示过）。
    public func uncover() {
        resetReveal()
        isCovering = false
        loadingKey = nil
        isHidden = true
    }

    // MARK: - Revealing

    /// 从 [point]（这一层的坐标）揭示；完了调 [completion]。没罩着、或者正在揭示时不做任何事。
    public func reveal(from point: CGPoint, completion: @escaping () -> Void) {
        guard isCovering, !isRevealing else { return }

        if UIAccessibility.isReduceMotionEnabled || bounds.isEmpty || window == nil {
            uncover()
            completion()
            return
        }

        isRevealing = true
        revealCompletion = completion
        let origin = CGPoint(x: point.x.clamp(0, bounds.width), y: point.y.clamp(0, bounds.height))
        let radius = [
            CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0),
            CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height),
        ].map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 0

        let timing = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.revealDuration)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.isRevealing else { return }
            let completion = self.revealCompletion
            self.uncover()
            completion?()
        }

        // 圆里露出原图，圆外照旧罩着
        maskLayer.frame = bounds
        let startPath = holePath(center: origin, radius: 0.5)
        let endPath = holePath(center: origin, radius: radius + 1)
        maskLayer.path = endPath
        layer.mask = maskLayer
        let holeAnimation = CABasicAnimation(keyPath: "path")
        holeAnimation.fromValue = startPath
        holeAnimation.toValue = endPath
        maskLayer.add(holeAnimation, forKey: "reveal")

        // 粒子往手指那边收、淡掉（spec R-1「粒子吸向手指」）
        emitterLayer.birthRate = 0
        let pull = CABasicAnimation(keyPath: "transform")
        pull.fromValue = CATransform3DIdentity
        let toTransform = CATransform3DConcat(
            CATransform3DConcat(
                CATransform3DMakeTranslation(-origin.x, -origin.y, 0),
                CATransform3DMakeScale(0.4, 0.4, 1),
            ),
            CATransform3DMakeTranslation(origin.x, origin.y, 0),
        )
        pull.toValue = toTransform
        emitterLayer.transform = toTransform
        emitterLayer.add(pull, forKey: "pull")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        emitterLayer.opacity = 0
        emitterLayer.add(fade, forKey: "fade")

        CATransaction.commit()
    }

    private func resetReveal() {
        isCovering = true
        isRevealing = false
        revealCompletion = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.removeAllAnimations()
        layer.mask = nil
        emitterLayer.removeAllAnimations()
        emitterLayer.transform = CATransform3DIdentity
        emitterLayer.opacity = 1
        emitterLayer.birthRate = 1
        CATransaction.commit()
        setNeedsLayout()
    }

    private func holePath(center: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        return path
    }

    // MARK: - Small thumbnails

    /// 引用缩略图这类小图上用的：糊到看不出内容（spec R-1：引用缩略图永远不露原图）。糊不出来就不给图。
    public static func coveredThumbnail(_ image: UIImage?) -> UIImage? {
        guard let resized = image?.resized(maxDimensionPixels: 24) else { return nil }
        return try? resized.withGaussianBlur(radius: 3, tintColor: UIColor(white: 0, alpha: 0.15))
    }

    // MARK: - Dust

    private static let dustImage: CGImage? = {
        let size = CGSize(square: 6)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }()

    private static func makeDustCell() -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = dustImage
        cell.birthRate = 1
        cell.lifetime = 1.8
        cell.lifetimeRange = 0.8
        cell.scale = 0.22
        cell.scaleRange = 0.1
        let isReduceMotion = UIAccessibility.isReduceMotionEnabled
        cell.velocity = isReduceMotion ? 0 : 7
        cell.velocityRange = isReduceMotion ? 0 : 6
        cell.emissionRange = .pi * 2
        // 闪烁：出生时亮度随机，慢慢淡掉
        cell.color = UIColor.white.cgColor
        cell.alphaRange = 0.5
        cell.alphaSpeed = -0.45
        return cell
    }
}
