//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit

/// 接过传输中那张图的样子的一方（会话里的媒体视图）。
@MainActor
protocol TellomiTransferHandoffReceiver: AnyObject {
    /// 还在窗口里、自己已经没有进度环（传完了）。
    var tellomiCanReceiveTransferHandoff: Bool { get }
    func tellomiReceiveTransferHandoff(_ look: TellomiTransferHandoff.Look)
}

/// Tellomi（交互审计 A-13，iOS 半边）：一张图 / 一段视频传完（下载完、上传完）的那一下。
///
/// 传完时会话页整格重建：旧的媒体视图（模糊占位 + 进度环）换成新的（原图、没有环），所以环和占位一下就没了，
/// 下载的还会先露一下底色。Telegram 两端都是过渡过去的——
/// iOS `RadialStatusNode.transitionToState(.none)`：环 0.2 s 缩小淡出；`TransformImageNode` 的 `.subsequentUpdates`：
/// 旧图盖在上面 0.15 s 淡掉。Android `MediaActionDrawable.setIcon(ICON_NONE, true)`：160–220 ms 缩没；
/// `ImageReceiver` 从缩略图交叉淡入 150 ms（`DEFAULT_CROSSFADE_DURATION`）。Tellomi 安卓：进度环换状态是
/// 透明度 + 缩到 0.8 的交叉淡入（Signal-Android#300），原图本来就盖在模糊图上淡入。
///
/// 这里：传输中的旧视图离开窗口时把它的样子（环的快照、占位图）记下来，同一条消息、同一个附件的新视图进窗口时接过去，
/// 环在原处缩小淡出，占位图盖在原图上、原图到了再淡掉。两个视图进出窗口的先后不固定（`reloadItems` 换格子），
/// 所以两边谁先到都行：先到的只等同一次排版那么久。
@MainActor
final class TellomiTransferHandoff {

    /// 旧视图最后的样子。
    struct Look {
        /// 进度环（连同它的圆底）的快照。
        let ring: UIView
        let ringSize: CGSize
        /// 环底下那张图（模糊占位 / 备份缩略图）。上传完时新视图本来就是同一张原图，这里是 nil。
        let placeholder: UIImage?
    }

    /// 一次换格子在同一次排版里做完；超过这么久就不是同一件事了（滚出屏幕、关页面）。
    static let rendezvousWindow: TimeInterval = 0.1
    /// 新视图的原图迟迟不来时，最多盖这么久就把占位图淡掉。
    static let placeholderTimeout: TimeInterval = 1
    /// 环退场缩到这个比例（和 Android `TransferProgressIndicator` 的 `STATE_SWAP_SCALE` 一样）。
    static let ringExitScale: CGFloat = 0.8

    static let shared = TellomiTransferHandoff()

    /// 测试里换掉。
    var now: () -> CFTimeInterval = CACurrentMediaTime

    private struct Left {
        let look: Look
        let time: CFTimeInterval
    }

    private struct Waiting {
        weak var receiver: TellomiTransferHandoffReceiver?
        let time: CFTimeInterval
    }

    private var left = [String: Left]()
    private var waiting = [String: Waiting]()

    /// 同一条消息里的同一个附件（同一个附件可以被好几条消息引用）。
    static func key(interactionUniqueId: String, attachmentId: Int64) -> String {
        "\(interactionUniqueId)/\(attachmentId)"
    }

    /// 传输中的旧视图要离开窗口了：新视图已经在等就直接交给它，否则先放着。
    func transferringViewWillLeave(key: String, look: Look) {
        prune()
        if let waiting = waiting.removeValue(forKey: key), let receiver = waiting.receiver, receiver.tellomiCanReceiveTransferHandoff {
            receiver.tellomiReceiveTransferHandoff(look)
            return
        }
        left[key] = Left(look: look, time: now())
        schedulePrune()
    }

    /// 传完的新视图进了窗口：旧视图刚放下样子就接过去，否则等一下它。
    func finishedViewDidEnter(key: String, receiver: TellomiTransferHandoffReceiver) {
        prune()
        if let left = left.removeValue(forKey: key) {
            receiver.tellomiReceiveTransferHandoff(left.look)
            return
        }
        waiting[key] = Waiting(receiver: receiver, time: now())
        schedulePrune()
    }

    /// 过了时间的都扔掉（快照和图不留着）。
    func prune() {
        let time = now()
        left = left.filter { time - $0.value.time <= Self.rendezvousWindow }
        waiting = waiting.filter { $0.value.receiver != nil && time - $0.value.time <= Self.rendezvousWindow }
    }

    var isEmpty: Bool { left.isEmpty && waiting.isEmpty }

    private func schedulePrune() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rendezvousWindow * 2) { [weak self] in
            self?.prune()
        }
    }

    // MARK: - 过渡

    /// 环的快照放在 [container] 正中，缩小淡出后摘掉。减弱动态效果时只淡不缩（动效标准：缩放改成交叉淡入）。
    static func playRingExit(_ ring: UIView, size: CGSize, in container: ManualLayoutView, reduceMotion: Bool = TellomiMotion.isReduceMotionEnabled) {
        ring.isUserInteractionEnabled = false
        container.addSubview(ring)
        let place = { [weak ring] (view: UIView) in
            guard let ring, ring.superview === view else { return }
            // 用 bounds + center：动画里带着 transform，不能设 frame
            ring.bounds = CGRect(origin: .zero, size: size)
            ring.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
        container.addLayoutBlock(place)
        place(container)

        let fadeDuration = reduceMotion ? TellomiMotion.reducedMotionCrossfadeDuration : TellomiMotion.fadeOutDuration
        UIView.animate(withDuration: fadeDuration, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            ring.alpha = 0
        } completion: { _ in
            ring.removeFromSuperview()
        }
        if !reduceMotion {
            TellomiMotion.animator(TellomiMotion.snap, reduceMotion: false) {
                ring.transform = CGAffineTransform(scaleX: ringExitScale, y: ringExitScale)
            }.startAnimation()
        }
    }

    /// 占位图铺满 [container]、盖在 [mediaView] 上面（角标、遮罩、播放键还在它上面）。
    static func coverWithPlaceholder(_ image: UIImage, above mediaView: UIView, in container: ManualLayoutView) -> UIImageView {
        let placeholderView = UIImageView(image: image)
        // 和 `CVMediaView.configureImageView` 一样铺法
        placeholderView.contentMode = .scaleAspectFill
        placeholderView.layer.minificationFilter = .trilinear
        placeholderView.layer.magnificationFilter = .trilinear
        placeholderView.clipsToBounds = true
        placeholderView.isUserInteractionEnabled = false
        if mediaView.superview === container {
            container.insertSubview(placeholderView, aboveSubview: mediaView)
        } else {
            container.addSubview(placeholderView)
        }
        let place = { [weak placeholderView] (view: UIView) in
            guard let placeholderView, placeholderView.superview === view else { return }
            placeholderView.frame = view.bounds
        }
        container.addLayoutBlock(place)
        place(container)
        return placeholderView
    }

    /// 原图到了：占位图淡掉后摘掉（照 Telegram 两端 0.15 s）。叫两次也没事。
    static func fadeOutPlaceholder(_ placeholderView: UIView) {
        guard placeholderView.superview != nil else { return }
        UIView.animate(withDuration: TellomiMotion.fadeOutDuration, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            placeholderView.alpha = 0
        } completion: { _ in
            placeholderView.removeFromSuperview()
        }
    }
}
