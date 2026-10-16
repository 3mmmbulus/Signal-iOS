//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit

/// Tellomi（交互审计 A-19「聊天顶栏头像 → 资料页：小头像和大头像之间没有连续性」，iOS 半边）：点会话顶栏进会话设置时，
/// 顶栏的小头像沿着推入动画飞到设置页的大头像那里，而不是跟着顶栏滑走、再在新页里冒出来。
///
/// 机制照 Telegram iOS（只读）：`PeerInfoHeaderNode` 的 `PeerInfoHeaderNavigationTransition` 按推入动画的进度
/// （`fraction`）把资料页头像从聊天顶栏头像的位置、大小插到自己的位置、大小，顶栏原来的小头像同时缩放、移动、淡掉。
/// Signal 的设置页是另一个表格页，这里用窗口上的一张图：
/// - 推入前把小头像画成一张图放在窗口上、停在原处，原头像先藏起来；
/// - 跟着推入动画（`animate(alongsideTransition:)`，同一条时间曲线）飞到设置页大头像的位置、放大；大头像先藏起来，
///   有它自己的图就换成它的（大图放大不发虚）；
/// - 推完真头像显出来，飞的那张在它上面淡掉（[revealDuration]）。找不到大头像时，飞的那张跟着推入淡掉。
///
/// 减弱动态效果时不飞，照原来的推入。返回不飞（侧滑返回照旧可拖）。
enum TellomiAvatarHero {

    /// 推完后飞的那张在真头像上面淡掉的时长（同安卓 Signal-Android#330）。
    static let revealDuration: TimeInterval = 0.12

    /// 推入 [coordinator] 的同时，把 [source]（顶栏的小头像）飞到 [destination]() 返回的视图（设置页的大头像）上。
    /// 返回窗口上飞的那张图；没飞（减弱动态效果、没有推入动画、小头像不在屏幕上、不是圆头像）时返回 nil，什么都不改。
    @MainActor
    @discardableResult
    static func flyAlongPush(
        from source: ConversationAvatarView,
        coordinator: UIViewControllerTransitionCoordinator?,
        reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled,
        destination: @escaping () -> ConversationAvatarView?,
    ) -> UIView? {
        guard
            !reduceMotion,
            let coordinator,
            coordinator.isAnimated,
            let window = source.window,
            !source.isHidden,
            source.alpha > 0,
            source.bounds.width > 0,
            source.configuration.shape == .circular
        else {
            return nil
        }

        let flyer: UIView
        if let image = source.primaryImage {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            flyer = imageView
        } else if let snapshot = source.snapshotView(afterScreenUpdates: false) {
            flyer = snapshot
        } else {
            return nil
        }
        let start = source.convert(source.bounds, to: window)
        flyer.frame = start
        flyer.layer.cornerRadius = start.width / 2
        flyer.clipsToBounds = true
        flyer.isUserInteractionEnabled = false
        window.addSubview(flyer)

        let sourceAlpha = source.alpha
        source.alpha = 0
        weak var target: ConversationAvatarView?

        coordinator.animate(alongsideTransition: { context in
            let toView = context.view(forKey: .to) ?? context.viewController(forKey: .to)?.view
            var found: ConversationAvatarView?
            if let toView {
                UIView.performWithoutAnimation {
                    // 设置页已经在转场容器里了：先排好（不跟着动画），大头像这才在表头里
                    toView.layoutIfNeeded()
                    found = destination()
                }
            }
            guard let toView, let avatar = found, avatar.isDescendant(of: toView), avatar.bounds.width > 0 else {
                flyer.alpha = 0
                return
            }
            UIView.performWithoutAnimation {
                avatar.alpha = 0
                if let image = avatar.primaryImage, let imageView = flyer as? UIImageView {
                    imageView.image = image
                }
            }
            target = avatar
            // 推入时设置页整页从右边滑进来，推完它和容器重合：终点按它落定后的位置算
            let end = context.containerView.convert(avatar.convert(avatar.bounds, to: toView), to: window)
            flyer.frame = end
            flyer.layer.cornerRadius = end.width / 2
        }, completion: { context in
            source.alpha = sourceAlpha
            target?.alpha = 1
            if context.isCancelled {
                flyer.removeFromSuperview()
                return
            }
            UIView.animate(withDuration: revealDuration, animations: {
                flyer.alpha = 0
            }, completion: { _ in
                flyer.removeFromSuperview()
            })
        })
        return flyer
    }
}
