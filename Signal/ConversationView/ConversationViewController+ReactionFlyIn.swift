//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 回应飞入（tellomi/tellomi 交互审计 A-07）在会话页这一侧：什么时候起飞、落到哪。飞行本身见 [ReactionFlyIn]。
///
/// 起飞要等三件事：菜单收完（收起期间聊天列表不落 load，消息也还是预览快照）、这条回应已经画在消息下方、
/// 落点不再跳动。取的是模型层坐标：键盘弹回之类的动画一开始模型值就到了终点，飞行和它同时收尾；
/// 要防的是接连几次重新布局把格子挪来挪去，所以隔一帧取一次样就够了。
extension ConversationViewController {

    /// 连续两次取到的落点相差不到这么多，就算停稳了。
    private static var reactionFlyInStillTolerance: CGFloat { 0.5 }
    private static var reactionFlyInStillCheckInterval: TimeInterval { 1.0 / 60 }
    private static var reactionFlyInStillCheckLimit: Int { 8 }

    func beginReactionFlyIn(messageUniqueId: String, emoji: String, source: ReactionFlyIn.Source) {
        viewState.pendingReactionFlyIn?.cancel()
        viewState.pendingReactionFlyIn = nil
        guard let window = view.window else {
            return
        }
        viewState.pendingReactionFlyIn = ReactionFlyIn(
            messageUniqueId: messageUniqueId,
            emoji: emoji,
            source: source,
            window: window,
        )
    }

    /// 菜单收完、每次 load 落地时各调一次。回应还没画出来就什么都不做，等下一次或者超时。
    func landPendingReactionFlyInIfPossible() {
        // Tellomi（owner 2026-10-18）：双击回应没有起飞，回应画出来时在胶囊上爆开一下。
        tellomiPlayPendingQuickReactionBurstIfPossible()

        guard
            let flyIn = viewState.pendingReactionFlyIn,
            collectionViewActiveContextMenuInteraction == nil,
            let target = reactionFlyInTarget(messageUniqueId: flyIn.messageUniqueId, emoji: flyIn.emoji)
        else {
            return
        }
        viewState.pendingReactionFlyIn = nil
        flyIn.claim(target)
        landWhenStill(flyIn: flyIn, target: target, previousCenter: nil, checksLeft: Self.reactionFlyInStillCheckLimit)
    }

    func reactionFlyInTarget(messageUniqueId: String, emoji: String) -> UILabel? {
        guard
            let indexPath = indexPath(forInteractionUniqueId: messageUniqueId),
            let cell = collectionView.cellForItem(at: indexPath) as? CVCell,
            let messageView = cell.componentView as? CVComponentMessage.CVComponentViewMessage
        else {
            return nil
        }
        return messageView.reactionEmojiLabel(for: emoji)
    }

    private func landWhenStill(flyIn: ReactionFlyIn, target: UILabel, previousCenter: CGPoint?, checksLeft: Int) {
        guard target.window != nil else {
            flyIn.cancel()
            return
        }
        let center = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        if let previousCenter {
            let moved = hypot(center.x - previousCenter.x, center.y - previousCenter.y)
            if moved < Self.reactionFlyInStillTolerance || checksLeft <= 0 {
                flyIn.land(on: target, targetFontSize: target.font.pointSize)
                return
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reactionFlyInStillCheckInterval) { [weak self, weak target] in
            guard let self, let target else {
                flyIn.cancel()
                return
            }
            self.landWhenStill(flyIn: flyIn, target: target, previousCenter: center, checksLeft: checksLeft - 1)
        }
    }
}
