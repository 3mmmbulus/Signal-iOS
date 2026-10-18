//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 回应飞入（tellomi/tellomi 交互审计 A-07）在会话页这一侧：什么时候起飞、落到哪。飞行本身见 [ReactionFlyIn]。
///
/// 这条回应一画在消息下方，菜单收起和表情起飞就一起开始（Telegram 两端都这样：iOS 等回应写进消息
/// `awaitingAppliedReaction`，再 `dismissWithReaction` 同时收菜单、起飞）。选了回应以后聊天列表照常落 load
/// （`CVLoadCoordinator`），真消息藏到菜单收完（`CVViewState.tellomiHideWhileMenuCloses`），预览快照飞回它此刻的位置
/// （[tellomiRetargetMenuDismissal]）；表情落地时回应区先露出来（[tellomiShowReactionsWhileMenuCloses]）。
/// 一找到落点就起飞，不等它停稳：[ReactionFlyIn] 每一帧重新量落点（模型层坐标），接连几次重新布局把格子挪来挪去也跟得上
/// （Telegram 安卓 `ReactionsEffectOverlay` 也是每帧重新取落点）。
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

        tellomiRetargetMenuDismissal()

        guard
            let flyIn = viewState.pendingReactionFlyIn,
            collectionViewActiveContextMenuInteraction.map({ !$0.contextMenuVisible || $0.tellomiReactionChosen }) ?? true,
            let target = reactionFlyInTarget(messageUniqueId: flyIn.messageUniqueId, emoji: flyIn.emoji)
        else {
            return
        }
        viewState.pendingReactionFlyIn = nil
        flyIn.claim(target)
        // 菜单不再等回应条从选中起的 0.2 s 淡出播完，和起飞一起收；已经在收的，`dismissMenu` 只是等那一次收完。
        if let interaction = collectionViewActiveContextMenuInteraction, interaction.contextMenuVisible {
            interaction.dismissMenu(animated: true) {}
        }
        flyIn.land(on: target, targetFontSize: target.font.pointSize) { [weak self] in
            self?.tellomiShowReactionsWhileMenuCloses()
        }
    }

    /// Tellomi（交互审计 A-07 起飞时机）：选了回应、菜单还没收完，load 却已经落了：这条消息可能换了格子（`reloadItems` 会给它
    /// 新的 cell），也可能被新胶囊挤了位置。它此刻的格子照样藏着（新格子多半在配置时就藏了，这里补一次），菜单的预览改飞向它的气泡。
    func tellomiRetargetMenuDismissal() {
        guard
            let interaction = collectionViewActiveContextMenuInteraction,
            interaction.contextMenuVisible,
            interaction.tellomiReactionChosen,
            let cell = tellomiCell(forInteractionUniqueId: interaction.itemViewModel.interaction.uniqueId),
            let messageView = cell.componentView as? CVComponentMessage.CVComponentViewMessage
        else {
            return
        }
        viewState.tellomiHideWhileMenuCloses(cell, interactionUniqueId: interaction.itemViewModel.interaction.uniqueId)
        interaction.tellomiRetargetDismissal(previewTo: messageView.tellomiContextMenuCoveredViews.content)
    }

    /// Tellomi（交互审计 A-07 起飞时机）：表情落在胶囊上了，菜单还在收（和起飞一起收的话还剩约 0.05 s）：回应区先露出来，
    /// 胶囊里的表情接着露在落点上（Telegram 落地那一刻露出胶囊）。气泡照旧等菜单收完，免得和还差一点到位的预览叠成两个。
    func tellomiShowReactionsWhileMenuCloses() {
        guard
            let interaction = collectionViewActiveContextMenuInteraction,
            interaction.contextMenuVisible,
            interaction.tellomiReactionChosen
        else {
            return
        }
        interaction.tellomiReactionLanded = true
        guard
            let cell = tellomiCell(forInteractionUniqueId: interaction.itemViewModel.interaction.uniqueId),
            let messageView = cell.componentView as? CVComponentMessage.CVComponentViewMessage
        else {
            return
        }
        messageView.tellomiContextMenuCoveredViews.auxiliary.isHidden = false
    }

    private func tellomiCell(forInteractionUniqueId uniqueId: String) -> CVCell? {
        guard let indexPath = indexPath(forInteractionUniqueId: uniqueId) else {
            return nil
        }
        return collectionView.cellForItem(at: indexPath) as? CVCell
    }

    func reactionFlyInTarget(messageUniqueId: String, emoji: String) -> UILabel? {
        guard
            let indexPath = indexPath(forInteractionUniqueId: messageUniqueId),
            let cell = collectionView.cellForItem(at: indexPath) as? CVCell
        else {
            return nil
        }
        if let messageView = cell.componentView as? CVComponentMessage.CVComponentViewMessage {
            return messageView.reactionEmojiLabel(for: emoji)
        }
        // Tellomi（pinned-messages.md 3.7）：或者「××置顶了«…»」下面那一排。
        return (cell.componentView as? CVComponentSystemMessage.CVComponentViewSystemMessage)?.tellomiReactionEmojiLabel(for: emoji)
    }
}
