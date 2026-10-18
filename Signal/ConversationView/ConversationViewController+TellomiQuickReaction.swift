//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi：双击别人的消息 = 快速回应（owner 2026-09-24 C-01，`docs/product/UX_DIRECTION.md`「体验研究第一轮」③；
/// 10-18 真机「双击对方消息也无法回复表情」）。双击自己的消息照旧是上游的编辑（C-01「保留 Signal」）。
///
/// 怎么回应照 Telegram 两端（只读源码，没搬代码）：
/// - iOS `ChatMessageBubbleItemNode.tapLongTapOrDoubleTapGesture`：双击 → `updateMessageReaction(message, .default)`；
///   `ChatController` 里已经是这个回应就撤回，否则加上，等回应真的加到消息上（`awaitingAppliedReaction`），再在消息的回应按钮上
///   播这个回应的动画和周围的效果（`StandaloneReactionAnimation`，`playHaptic: false`）。
/// - Android `ChatActivity.onDoubleTap` → `getDoubleTapReaction()`（默认是第一个回应）→ `selectReaction(…, fromDoubleTap)`：
///   `MessageObject.selectReaction` 已选就撤回；发出去以后在回应按钮上播 `ReactionsEffectOverlay.SHORT_ANIMATION`（不飞）。
///
/// 用的表情是回应条上第一个（用户的第一个回应，默认 ❤️）；已经是它就撤回。没有起飞，回应画出来时在胶囊上爆开一下
/// （和从条上选时落地那一下一样，`TellomiReactionBurst`）。
///
/// 触感：Telegram 两端加回应时都轻触一下，撤回不震——iOS 双击时 `selectPollOptionFeedback?.tap()`（`HapticFeedback.tap()`
/// 就是 `selectionChanged()`）；安卓在回应按钮上的效果开始时 `KEYBOARD_TAP`（`ReactionsEffectOverlay.startShortAnimation`）。
/// Tellomi 两端都在双击时给一下 selection（和从条上选、落地那一下同一种）。
extension ConversationViewController {

    /// 等回应画出来最多这么久；过了就不爆了（写失败、消息被滚走）。
    static let tellomiQuickReactionBurstWait: TimeInterval = 1.5

    /// 双击要回应什么：[quickEmoji]，我已经用它回应过就撤回。
    static func tellomiQuickReaction(quickEmoji: String, myEmoji: String?) -> (emoji: String, isRemoving: Bool) {
        let mine = myEmoji.flatMap { EmojiWithSkinTones(rawValue: $0)?.rawValue } ?? myEmoji
        return (quickEmoji, mine == quickEmoji)
    }

    /// 双击这条是不是快速回应：只有别人的消息（C-01）。自己的消息、系统消息不是。
    static func tellomiDoubleTapReacts(to interaction: TSInteraction) -> Bool {
        interaction is TSIncomingMessage
    }

    public func tellomiCanQuickReact(_ viewModel: CVItemViewModelImpl) -> Bool {
        guard thread.canSendReactionToThread, Self.tellomiDoubleTapReacts(to: viewModel.interaction) else {
            return false
        }
        return shouldShowReactionPickerForInteraction(viewModel.interaction)
    }

    public func tellomiDidDoubleTapToReact(_ viewModel: CVItemViewModelImpl) {
        guard
            tellomiCanQuickReact(viewModel),
            let message = viewModel.interaction as? TSMessage,
            let quickEmoji = ContextMenuReactionBarAccessory.quickReactionEmoji()
        else {
            return
        }
        let (emoji, isRemoving) = Self.tellomiQuickReaction(
            quickEmoji: quickEmoji,
            myEmoji: viewModel.reactionState?.localUserEmoji,
        )

        if !isRemoving {
            SelectionHapticFeedback().selectionChanged()
            if TellomiReactionBurst.shouldPlay {
                viewState.tellomiPendingQuickReactionBurst = (message.uniqueId, emoji, Date())
            }
        }

        SSKEnvironment.shared.databaseStorageRef.asyncWrite { transaction in
            ReactionManager.localUserReacted(
                to: message.uniqueId,
                emoji: emoji,
                isRemoving: isRemoving,
                tx: transaction,
            )
        }

        if UIAccessibility.isVoiceOverRunning {
            let announcement = Self.tellomiReactionAnnouncement(emoji: emoji, isRemoving: isRemoving)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tellomiReactionAnnouncementDelay) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
    }

    /// 每次 load 落地时调（`landPendingReactionFlyInIfPossible`）：双击的回应画出来了，就在胶囊里那个表情上爆开。
    func tellomiPlayPendingQuickReactionBurstIfPossible() {
        guard let pending = viewState.tellomiPendingQuickReactionBurst else {
            return
        }
        guard Date().timeIntervalSince(pending.time) <= Self.tellomiQuickReactionBurstWait else {
            viewState.tellomiPendingQuickReactionBurst = nil
            return
        }
        guard
            let window = view.window,
            let target = reactionFlyInTarget(messageUniqueId: pending.messageUniqueId, emoji: pending.emoji),
            target.window != nil
        else {
            return
        }
        viewState.tellomiPendingQuickReactionBurst = nil
        let center = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: window)
        TellomiReactionBurst.play(emoji: pending.emoji, at: center, in: window, emojiSize: target.font.pointSize)
    }
}
