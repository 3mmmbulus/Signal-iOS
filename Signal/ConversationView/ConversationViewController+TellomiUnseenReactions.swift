//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（chat-telegram-parity F01）：别人回应了我的消息、我还没在聊天里看到时，右下角出心形按钮，上面是这样的消息有几条。
/// 记在哪、怎么算看到见 `TellomiUnseenReactions`（SignalServiceKit）。安卓同一刀：Signal-Android#383。
///
/// 照 Telegram 两端（只读源码，没搬代码）：
/// - 按钮：iOS `ChatHistoryNavigationButtons.reactionsButton`（叠在提及按钮上），安卓 `ChatActivitySideControlsButtonsLayout.BUTTON_REACTIONS`。
/// - 看到才算读：iOS `ChatHistoryListNode` 把可视范围里有未读回应的消息交给 `unseenReactionsProcessingManager`（0.2 s），
///   同时 `displayUnseenReactionAnimations` 在消息的回应上播那个回应；安卓 `ChatMessageCell.checkUnreadReactions`（回应那一行在可视区里，
///   底下允许 16dp 被挡）+ `ReactionsEffectOverlay.show`。
/// - 点按钮：iOS `ChatControllerLoadDisplayNode` 的 `reactionsPressed` → `earliestUnseenPersonalReactionMessage`，导航期间
///   `suspendReadingReactions`、到了再播；安卓 `getNextReactionMention` 先划掉再跳。
/// - 长按：iOS `reactionsButton.activated` →「Read All Reactions」；安卓 `ReadAllMentionsMenu`（`TYPE_REACTIONS`）。
///
/// Tellomi 的做法：看到的规则两端统一用安卓那条（回应那一行在导航栏和输入栏之间，底下允许 16 pt 被挡），滚动停下 0.1 s 后检查
/// （`scrollUpdateTimerDidFire`）；爆开用 Tellomi 自己的 `TellomiReactionBurst`，等列表停下、回应还在屏幕上时才播（它画在固定位置）。
extension ConversationViewController {

    /// 跳去的那条最多等这么久滚到屏幕上；过了就不爆了。
    static let tellomiReactionJumpBurstWait: TimeInterval = 3

    /// 回应那一行底下允许被挡住这么多，仍算看到（Telegram 安卓 `checkUnreadReactions` 的 `dp(16)`）。
    static let tellomiUnseenReactionBottomAllowance: CGFloat = 16

    /// 还没看到回应的我的消息（最早的在前），去掉这里已经看到、还在等 load 更新的。
    var tellomiUnseenReactionMessageIds: [String] {
        let seenHere = viewState.tellomiReactionsSeenHere
        return conversationViewModel.unseenReactionMessageIds.filter { !seenHere.contains($0) }
    }

    /// 每次 load 落地时调（`updateViewToReflectLoad`）：load 已经不再列出的就不用再挡着；顺便看一眼屏幕上有没有刚来的回应。
    func tellomiUnseenReactionsDidLoad() {
        viewState.tellomiReactionsSeenHere.formIntersection(conversationViewModel.unseenReactionMessageIds)
        tellomiMarkVisibleUnseenReactions()
    }

    /// 点回应按钮：跳到最早那条，先记成看到了（不然太高、回应那一行露不出来的消息会让按钮一直指着它自己），到了再爆开。
    func tellomiScrollToNextReactionButtonTapped() {
        guard let messageId = tellomiUnseenReactionMessageIds.first else {
            return
        }
        viewState.tellomiReactionJumpTarget = (messageId, Date())
        tellomiMarkReactionsSeen([messageId])
        ensureInteractionLoadedThenScrollToInteraction(
            messageId,
            alignment: .centerIfNotEntirelyOnScreen,
            isAnimated: true,
        )
        // 已经整条在屏幕上时不会滚，也就等不到滚动结束。
        DispatchQueue.main.async { self.tellomiMarkVisibleUnseenReactions() }
    }

    /// 长按回应按钮「所有回应标为已读」。
    func tellomiMarkAllReactionsSeen() {
        let threadUniqueId = thread.uniqueId
        viewState.tellomiReactionsSeenHere.formUnion(conversationViewModel.unseenReactionMessageIds)
        configureScrollDownButtons()
        SSKEnvironment.shared.databaseStorageRef.asyncWrite(block: { tx in
            TellomiUnseenReactions.markAllSeen(threadUniqueId: threadUniqueId, tx: tx)
        }, completion: { [weak self] in
            self?.loadCoordinator.enqueueReload()
        })
    }

    /// 滚动停下 0.1 s 后、load 落地后、跳转滚完后调：回应那一行露出来的就算看到了，等列表停下在回应上爆开。
    func tellomiMarkVisibleUnseenReactions() {
        guard hasAppearedAndHasAppliedFirstLoad, !isInPreviewPlatter, view.window != nil else {
            return
        }
        if let jump = viewState.tellomiReactionJumpTarget, Date().timeIntervalSince(jump.time) > Self.tellomiReactionJumpBurstWait {
            viewState.tellomiReactionJumpTarget = nil
        }
        let unseen = Set(tellomiUnseenReactionMessageIds)
        let jumpTarget = viewState.tellomiReactionJumpTarget?.messageUniqueId
        guard !unseen.isEmpty || jumpTarget != nil else {
            return
        }
        // 跳转还在滚：等滚完（Telegram iOS `suspendReadingReactions`），途经的不算、爆开也在停下的位置。
        if jumpTarget != nil, scrollingAnimationCompletionTimer != nil {
            return
        }

        let onScreen = tellomiMessagesWithReactionsOnScreen()
        let newlySeen = onScreen.filter { unseen.contains($0) }
        let toBurst = onScreen.filter { unseen.contains($0) || $0 == jumpTarget }
        guard !toBurst.isEmpty else {
            return
        }
        if let jumpTarget, toBurst.contains(jumpTarget) {
            viewState.tellomiReactionJumpTarget = nil
        }
        if !newlySeen.isEmpty {
            tellomiMarkReactionsSeen(newlySeen)
        }
        tellomiQueueUnseenReactionBursts(for: toBurst)
    }

    /// 等着爆开的，列表停下时在回应上播；滚走了的就算了。
    func tellomiPlayUnseenReactionBurstsIfIdle() {
        guard
            !viewState.tellomiReactionBurstsWhenIdle.isEmpty,
            !collectionView.isDragging,
            !collectionView.isDecelerating,
            scrollingAnimationCompletionTimer == nil,
            let window = view.window
        else {
            return
        }
        let bursts = viewState.tellomiReactionBurstsWhenIdle
        viewState.tellomiReactionBurstsWhenIdle.removeAll()
        guard TellomiReactionBurst.shouldPlay else {
            return
        }
        let onScreen = Set(tellomiMessagesWithReactionsOnScreen())
        for (messageId, emoji) in bursts where onScreen.contains(messageId) {
            guard let target = reactionFlyInTarget(messageUniqueId: messageId, emoji: emoji), target.window != nil else {
                continue
            }
            let center = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: window)
            TellomiReactionBurst.play(emoji: emoji, at: center, in: window, emojiSize: target.font.pointSize)
        }
    }

    private func tellomiMarkReactionsSeen(_ messageIds: [String]) {
        let threadUniqueId = thread.uniqueId
        viewState.tellomiReactionsSeenHere.formUnion(messageIds)
        configureScrollDownButtons()
        SSKEnvironment.shared.databaseStorageRef.asyncWrite(block: { tx in
            TellomiUnseenReactions.markSeen(messageUniqueIds: messageIds, threadUniqueId: threadUniqueId, tx: tx)
        }, completion: { [weak self] in
            self?.loadCoordinator.enqueueReload()
        })
    }

    /// 查出这几条里别人最新的那个回应表情，记下等列表停下再爆开。
    private func tellomiQueueUnseenReactionBursts(for messageIds: [String]) {
        let emojis: [String: String] = SSKEnvironment.shared.databaseStorageRef.read { tx in
            var emojis = [String: String]()
            for messageId in messageIds {
                emojis[messageId] = TellomiUnseenReactions.latestEmojiFromOthers(messageUniqueId: messageId, tx: tx)
            }
            return emojis
        }
        viewState.tellomiReactionBurstsWhenIdle.merge(emojis) { _, new in new }
        tellomiPlayUnseenReactionBurstsIfIdle()
    }

    /// 回应那一行在导航栏和输入栏之间：上边露出来，底下最多被挡 16 pt（Telegram 安卓 `checkUnreadReactions`）。
    static func tellomiReactionRowIsOnScreen(_ frame: CGRect, visible: CGRect) -> Bool {
        frame.minY > visible.minY && frame.maxY - tellomiUnseenReactionBottomAllowance < visible.maxY
    }

    /// 回应那一行（没有回应区时整个格子）在导航栏和输入栏之间、底下允许被挡 16 pt 的消息。
    private func tellomiMessagesWithReactionsOnScreen() -> [String] {
        let visible = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        var onScreen = [String]()
        for cell in collectionView.visibleCells {
            guard let cell = cell as? CVCell, let interaction = cell.renderItem?.interaction else {
                continue
            }
            let reactionsView = (cell.componentView as? CVComponentMessage.CVComponentViewMessage)?.reactionsView?.rootView
            let target: UIView = reactionsView.flatMap { $0.superview != nil ? $0 : nil } ?? cell
            if Self.tellomiReactionRowIsOnScreen(target.convert(target.bounds, to: collectionView), visible: visible) {
                onScreen.append(interaction.uniqueId)
            }
        }
        return onScreen
    }
}
