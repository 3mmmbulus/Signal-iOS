//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 回应飞入（tellomi/tellomi 交互审计 A-07）在会话页这一侧：什么时候起飞、落到哪。飞行本身见 [ReactionFlyIn]。
///
/// 起飞要等两件事：菜单收完（收起期间聊天列表不落 load，消息也还是预览快照）、这条回应已经画在消息下方。
/// 一找到落点就起飞，不再等它停稳：[ReactionFlyIn] 每一帧重新量落点（模型层坐标），接连几次重新布局把格子挪来挪去
/// 也跟得上（Telegram 安卓 `ReactionsEffectOverlay` 也是每帧重新取落点）。
extension ConversationViewController {

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
        flyIn.land(on: target, targetFontSize: target.font.pointSize)
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
}
