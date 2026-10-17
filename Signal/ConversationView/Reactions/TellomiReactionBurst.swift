//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit

/// 回应落到胶囊上的那一下「爆开」（tellomi/tellomi 交互审计 A-07，owner 2026-10-17）。
///
/// Telegram 两端在表情快落进胶囊时都在胶囊周围播一段效果（iOS `ReactionContextNode.animateOutToReaction` 的
/// around 动画，飞行开始后 0.15 s / 共 0.2 s；Android `ReactionsEffectOverlay`，飞到 70% 时）。那是 Telegram 自己的 Lottie 文件，不能用；这里是 Tellomi 自己画的：
/// 一圈淡出的环 + 十颗小号的同一个表情从落点向外散开、往上飘、淡掉，0.7 s 内播完。
///
/// - 粒子 / 「烟花」原本不做（PRODUCT_REQUIREMENTS TR-PLAT-16），回应爆开是 ADR-0058 写明的唯一例外。
/// - 减弱动态效果、低电量模式不播（交互与动效标准第六、七节：点缀类动效在省电时关）。
/// - 只是窗口上叠的一层，不挡触摸、不进读屏，播完自己摘掉。
@MainActor
enum TellomiReactionBurst {

    struct Particle: Equatable {
        /// 朝哪个方向飞（弧度，0 = 向右，逆时针为负 y）。
        let angle: CGFloat
        /// 飞多远（点）。
        let distance: CGFloat
        /// 粒子字号相对落点表情字号的比例。
        let scale: CGFloat
        /// 晚多久出发。
        let delay: TimeInterval
    }

    static let particleCount = 10
    static let duration: TimeInterval = 0.7
    static let ringDuration: TimeInterval = 0.35
    /// 粒子飞出的距离 = 落点表情字号 × 这个数（再按粒子错开 ±20%）。
    static let reachFactor: CGFloat = 2.2
    /// 散开的同时整体往上飘这么多（点）。
    static let floatUp: CGFloat = 14

    /// 粒子的方向和远近：黄金角错开，看起来随机但每次一样（单测覆盖，录屏可复现）。
    static func particles(count: Int = particleCount, emojiSize: CGFloat) -> [Particle] {
        let goldenAngle = CGFloat.pi * (3 - 5.squareRoot())
        return (0..<count).map { index in
            let wobble = CGFloat((index * 7) % 5) / 4 // 0, 0.75, 0.5, 0.25, 1 …
            return Particle(
                angle: CGFloat(index) * goldenAngle,
                distance: emojiSize * reachFactor * (0.8 + 0.4 * wobble),
                scale: 0.35 + 0.15 * wobble,
                delay: TimeInterval(index % 3) * 0.02,
            )
        }
    }

    static var shouldPlay: Bool {
        !TellomiMotion.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// 在窗口坐标 [center] 处播一次。[emojiSize] 是胶囊里表情的字号。
    static func play(emoji: String, at center: CGPoint, in window: UIWindow, emojiSize: CGFloat, ringColor: UIColor = .Signal.secondaryLabel) {
        guard shouldPlay else { return }

        let overlay = UIView(frame: window.bounds)
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        window.addSubview(overlay)

        // 环：从表情大小的 0.6 倍放到 1.8 倍，同时淡掉。
        let ring = CAShapeLayer()
        let ringRadius = emojiSize
        ring.path = UIBezierPath(ovalIn: CGRect(x: -ringRadius, y: -ringRadius, width: ringRadius * 2, height: ringRadius * 2)).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = ringColor.cgColor
        ring.lineWidth = 2
        ring.position = center
        ring.opacity = 0
        overlay.layer.addSublayer(ring)

        let ringScale = CABasicAnimation(keyPath: "transform.scale")
        ringScale.fromValue = 0.6
        ringScale.toValue = 1.8
        let ringFade = CABasicAnimation(keyPath: "opacity")
        ringFade.fromValue = 0.9
        ringFade.toValue = 0
        let ringGroup = CAAnimationGroup()
        ringGroup.animations = [ringScale, ringFade]
        ringGroup.duration = ringDuration
        ringGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(ringGroup, forKey: "burst")

        // 粒子：同一个表情的小号，从落点散开、往上飘、缩小、淡掉。
        let image = renderedEmoji(emoji, fontSize: emojiSize)
        for particle in particles(emojiSize: emojiSize) {
            let layer = CALayer()
            layer.contents = image.cgImage
            layer.contentsScale = image.scale
            layer.bounds = CGRect(origin: .zero, size: image.size)
            layer.position = center
            layer.opacity = 0
            overlay.layer.addSublayer(layer)

            let end = CGPoint(
                x: center.x + cos(particle.angle) * particle.distance,
                y: center.y + sin(particle.angle) * particle.distance - floatUp,
            )
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(cgPoint: center)
            move.toValue = NSValue(cgPoint: end)
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [particle.scale * 0.4, particle.scale, particle.scale * 0.6]
            scale.keyTimes = [0, 0.3, 1]

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.1, 0.55, 1]

            let group = CAAnimationGroup()
            group.animations = [move, scale, fade]
            group.duration = duration - particle.delay
            group.beginTime = CACurrentMediaTime() + particle.delay
            group.fillMode = .backwards
            layer.add(group, forKey: "burst")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            overlay.removeFromSuperview()
        }
    }

    private static func renderedEmoji(_ emoji: String, fontSize: CGFloat) -> UIImage {
        let attributed = NSAttributedString(string: emoji, attributes: [.font: UIFont.systemFont(ofSize: fontSize)])
        let size = attributed.size()
        return UIGraphicsImageRenderer(size: size).image { _ in
            attributed.draw(at: .zero)
        }
    }
}
