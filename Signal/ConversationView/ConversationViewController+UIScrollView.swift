//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import Foundation
import SignalServiceKit
import SignalUI
public import UIKit

extension ConversationViewController {

    private var scrollDownButton: ConversationScrollButton { viewState.scrollDownButton }
    private var scrollToNextMentionButton: ConversationScrollButton { viewState.scrollToNextMentionButton }
    private var isHidingScrollDownButton: Bool {
        get { viewState.isHidingScrollDownButton }
        set { viewState.isHidingScrollDownButton = newValue }
    }

    private var isHidingScrollToNextMentionButton: Bool {
        get { viewState.isHidingScrollToNextMentionButton }
        set { viewState.isHidingScrollToNextMentionButton = newValue }
    }

    private var scrollToNextReactionButton: ConversationScrollButton { viewState.scrollToNextReactionButton }
    private var isHidingScrollToNextReactionButton: Bool {
        get { viewState.isHidingScrollToNextReactionButton }
        set { viewState.isHidingScrollToNextReactionButton = newValue }
    }

    public var scrollUpdateTimer: Timer? {
        get { viewState.scrollUpdateTimer }
        set { viewState.scrollUpdateTimer = newValue }
    }

    public var isWaitingForDeceleration: Bool {
        get { viewState.isWaitingForDeceleration }
        set { viewState.isWaitingForDeceleration = newValue }
    }

    public var userHasScrolled: Bool {
        get { viewState.userHasScrolled }
        set {
            guard viewState.userHasScrolled != newValue else {
                return
            }
            viewState.userHasScrolled = newValue
            ensureBannerState()
        }
    }

    // MARK: -

    public func configureScrollDownButtons() {
        AssertIsOnMainThread()

        guard hasAppearedAndHasAppliedFirstLoad else {
            scrollDownButton.isHidden = true
            scrollToNextMentionButton.isHidden = true
            scrollToNextReactionButton.isHidden = true
            return
        }

        let scrollSpaceToBottom = (
            safeContentHeight + collectionView.contentInset.bottom
                - (collectionView.contentOffset.y + collectionView.frame.height),
        )
        let pageHeight = (
            collectionView.frame.height
                - (collectionView.contentInset.top + collectionView.contentInset.bottom),
        )
        let isScrolledUpOnePage = scrollSpaceToBottom > pageHeight * 1.0

        let hasLaterMessageOffscreen = (lastSortIdInLoadedWindow > lastVisibleSortId) || canLoadNewerItems

        let scrollDownWasHidden = isHidingScrollDownButton || scrollDownButton.isHidden
        let scrollToNextMentionWasHidden = isHidingScrollToNextMentionButton || scrollToNextMentionButton.isHidden
        let scrollToNextReactionWasHidden = isHidingScrollToNextReactionButton || scrollToNextReactionButton.isHidden

        let unseenReactionMessageIds = tellomiUnseenReactionMessageIds

        let layout = Self.tellomiScrollButtonsLayout(
            shouldScrollDownAppear: isScrolledUpOnePage || hasLaterMessageOffscreen,
            isSuppressed: viewState.inProgressVoiceMessage?.isRecording == true || isInPreviewPlatter,
            unreadMentionCount: conversationViewModel.unreadMentionMessageIds.count,
            unseenReactionCount: unseenReactionMessageIds.count,
        )
        let scrollDownIsHidden = layout.scrollDownHidden
        let scrollToNextMentionIsHidden = layout.mentionHidden
        let scrollToNextReactionIsHidden = layout.reactionHidden

        self.scrollDownButton.unreadCount = threadViewModel.unreadCount
        self.scrollToNextMentionButton.unreadCount = UInt(conversationViewModel.unreadMentionMessageIds.count)
        self.scrollToNextReactionButton.unreadCount = UInt(unseenReactionMessageIds.count)

        var changes: [(button: ConversationScrollButton, isHidden: Bool, setHiding: (Bool) -> Void)] = []
        if scrollDownIsHidden != scrollDownWasHidden {
            changes.append((scrollDownButton, scrollDownIsHidden, { self.isHidingScrollDownButton = $0 }))
        }
        if scrollToNextMentionIsHidden != scrollToNextMentionWasHidden {
            changes.append((scrollToNextMentionButton, scrollToNextMentionIsHidden, { self.isHidingScrollToNextMentionButton = $0 }))
        }
        if scrollToNextReactionIsHidden != scrollToNextReactionWasHidden {
            changes.append((scrollToNextReactionButton, scrollToNextReactionIsHidden, { self.isHidingScrollToNextReactionButton = $0 }))
        }
        let shouldAnimateChanges = self.hasAppearedAndHasAppliedFirstLoad

        guard !changes.isEmpty else {
            return
        }

        // Tellomi（交互审计 A-14，照 Telegram iOS `ChatHistoryNavigationButtons`：出现 alpha 0 → 1、缩放 0.2 → 1，消失反过来，
        // 0.3 s 弹簧，从当前状态起步，中途反向不跳）。原来是 0.2 s 只变透明度，并且先 `removeAllAnimations`——中途反向时
        // 先跳到上一段的终点再往回。减弱动态效果时只变透明度。
        let reduceMotion = TellomiMotion.isReduceMotionEnabled
        let hiddenTransform: CGAffineTransform = (shouldAnimateChanges && !reduceMotion) ? .scale(0.2) : .identity
        for change in changes {
            if !change.isHidden, change.button.isHidden {
                change.button.transform = hiddenTransform
            }
            change.button.isHidden = false
            change.setHiding(change.isHidden)
        }

        // Tellomi（chat-telegram-parity F01 / F02）：按钮一列叠着，下面那颗不在时上面的落下来，和出场 / 退场同一段动画
        // （Telegram iOS `updateLayout` 按 down / mentions 在不在排 mentions / reactions 的位置）。先把别的布局落定，只动按钮。
        view.layoutIfNeeded()
        viewState.tellomiMentionButtonStackConstraint?.constant = layout.mentionStack
        viewState.tellomiReactionButtonStackConstraint?.constant = layout.reactionStack

        let alphaBlock = {
            for change in changes {
                change.button.alpha = change.isHidden ? 0 : 1
                change.button.transform = change.isHidden ? hiddenTransform : .identity
            }
            self.view.layoutIfNeeded()
        }
        // 只收尾最近这一次：上一段动画在反向之后才结束时，不能按它的目标把按钮藏掉。
        viewState.tellomiScrollButtonsAnimationGeneration += 1
        let generation = viewState.tellomiScrollButtonsAnimationGeneration
        let completionBlock = {
            guard generation == self.viewState.tellomiScrollButtonsAnimationGeneration else { return }
            for change in changes {
                change.button.isHidden = change.isHidden
                change.button.transform = .identity
                change.setHiding(false)
            }
        }

        if shouldAnimateChanges {
            let animator = TellomiMotion.animator(TellomiMotion.snap, animations: alphaBlock)
            animator.addCompletion { _ in completionBlock() }
            animator.startAnimation()
        } else {
            alphaBlock()
            completionBlock()
        }
    }

    /// Tellomi：上面一颗按钮的底边离下面一颗的底边（按钮 40 pt + Signal 原来的 30 pt 间距）。
    static let tellomiScrollButtonStackStep: CGFloat = -70

    struct TellomiScrollButtonsLayout: Equatable {
        var scrollDownHidden: Bool
        var mentionHidden: Bool
        var reactionHidden: Bool
        /// 提及按钮底边相对滚到底按钮底边、回应按钮底边相对提及按钮底边（pt，往上为负）。
        var mentionStack: CGFloat
        var reactionStack: CGFloat
    }

    /// Tellomi（chat-telegram-parity F01 / F02）：三颗按钮各自藏不藏、怎么叠。提及、回应按钮有东西可跳就出现，不管滚到哪——
    /// Telegram 两端都这样（iOS `ChatHistoryNavigationButtons` 看 `mentionCount != 0` / `reactionsCount != 0`，安卓
    /// `showMentionDownButton` / `updateReactionsMentionButton`）；Signal 原来提及按钮只跟着滚到底按钮出现。录音、预览时都藏。
    static func tellomiScrollButtonsLayout(
        shouldScrollDownAppear: Bool,
        isSuppressed: Bool,
        unreadMentionCount: Int,
        unseenReactionCount: Int,
    ) -> TellomiScrollButtonsLayout {
        let scrollDownHidden = isSuppressed || !shouldScrollDownAppear
        let mentionHidden = isSuppressed || unreadMentionCount == 0
        let reactionHidden = isSuppressed || unseenReactionCount == 0
        return TellomiScrollButtonsLayout(
            scrollDownHidden: scrollDownHidden,
            mentionHidden: mentionHidden,
            reactionHidden: reactionHidden,
            mentionStack: scrollDownHidden ? 0 : tellomiScrollButtonStackStep,
            reactionStack: mentionHidden ? 0 : tellomiScrollButtonStackStep,
        )
    }
}

// MARK: -

extension ConversationViewController: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        AssertIsOnMainThread()

        // Constantly try to update the lastKnownDistanceFromBottom.
        updateLastKnownDistanceFromBottom()

        configureScrollDownButtons()

        scheduleScrollUpdateTimer()

        updateScrollingContent()

        updateContextMenuInteractionIfNeeded()
    }

    private func scheduleScrollUpdateTimer() {
        AssertIsOnMainThread()

        guard self.scrollUpdateTimer == nil else {
            return
        }

        // We need to manually schedule this timer using NSRunLoopCommonModes
        // or it won't fire during scrolling.
        let scrollUpdateTimer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.scrollUpdateTimerDidFire()
        }
        self.scrollUpdateTimer = scrollUpdateTimer
        RunLoop.main.add(scrollUpdateTimer, forMode: .common)
    }

    private func updateContextMenuInteractionIfNeeded() {
        if let contextMenuInteraction = collectionViewActiveContextMenuInteraction {
            contextMenuInteraction.cancelPresentationGesture()
        }
    }

    private func scrollUpdateTimerDidFire() {
        AssertIsOnMainThread()

        scrollUpdateTimer?.invalidate()
        scrollUpdateTimer = nil

        guard viewHasEverAppeared else {
            return
        }

        autoLoadMoreIfNecessary()

        if !isUserScrolling, !isWaitingForDeceleration {
            saveLastVisibleSortIdAndOnScreenPercentage()
        }

        // Tellomi（交互审计 A-08）：滚到（或滚过）滚到底按钮记着的来处，就不记了。
        tellomiFilterJumpBackStack()

        // Tellomi（chat-telegram-parity F01）：露出来的回应算看到；列表停下时爆开。
        tellomiMarkVisibleUnseenReactions()
        tellomiPlayUnseenReactionBurstsIfIdle()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        AssertIsOnMainThread()

        self.userHasScrolled = true
        self.isUserScrolling = true
        scrollingAnimationDidStart()
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        AssertIsOnMainThread()

        if !willDecelerate {
            scrollingAnimationDidComplete()
        }

        if !isUserScrolling {
            return
        }

        self.isUserScrolling = false

        if willDecelerate {
            self.isWaitingForDeceleration = willDecelerate
        } else {
            scheduleScrollUpdateTimer()
        }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        AssertIsOnMainThread()

        scrollingAnimationDidComplete()

        if !isWaitingForDeceleration {
            return
        }

        self.isWaitingForDeceleration = false

        scheduleScrollUpdateTimer()
    }

    public func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        AssertIsOnMainThread()

        // If the user taps on the status bar, the UIScrollView tries to perform
        // a "scroll to top" animation that swings _past_ the top of the scroll
        // view content, then bounces back to settle at zero.  This is likely
        // to trigger a "load older" load which can land before the animation
        // settles.  If so, the animation will overwrite the contentOffset,
        // breaking scroll continuity and probably triggering another "load older"
        // load.  So there's also a risk of a load loop.
        //
        // To avoid this, we use a simple animation to "scroll to top" unless
        // we know its safe to use the default animation, e.g. when there's no
        // older content to load.
        if canLoadOlderItems {
            let newContentOffset = CGPoint(x: 0, y: 0)
            collectionView.setContentOffset(newContentOffset, animated: true)
            return false
        } else {
            scrollingAnimationDidStart()

            return true
        }
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        AssertIsOnMainThread()

        scrollingAnimationDidComplete()
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        AssertIsOnMainThread()

        scrollingAnimationDidComplete()
    }
}

// MARK: - Scroll Down Button

extension ConversationViewController {
    public func createConversationScrollButtons() {
        AssertIsOnMainThread()

        scrollDownButton.addAction(
            UIAction { [weak self] _ in self?.scrollDownButtonTapped() },
            for: .primaryActionTriggered,
        )
        scrollDownButton.isHidden = true
        scrollDownButton.alpha = 0
        view.addSubview(scrollDownButton)
        scrollDownButton.accessibilityIdentifier = "scrollDownButton"

        scrollDownButton.autoPinEdge(.bottom, to: .top, of: bottomBarContainer, withOffset: -24)
        scrollDownButton.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 15)

        scrollToNextMentionButton.addAction(
            UIAction { [weak self] _ in self?.scrollToNextMentionButtonTapped() },
            for: .primaryActionTriggered,
        )
        scrollToNextMentionButton.isHidden = true
        scrollToNextMentionButton.alpha = 0
        view.addSubview(scrollToNextMentionButton)
        scrollToNextMentionButton.accessibilityIdentifier = "scrollToNextMentionButton"

        // Tellomi（chat-telegram-parity F01 / F02）：叠在滚到底按钮上，滚到底不在时落到它的位置（见 configureScrollDownButtons）。
        let mentionStack = scrollToNextMentionButton.bottomAnchor.constraint(equalTo: scrollDownButton.bottomAnchor, constant: 0)
        mentionStack.isActive = true
        viewState.tellomiMentionButtonStackConstraint = mentionStack
        scrollToNextMentionButton.autoPinEdge(.trailing, to: .trailing, of: scrollDownButton)

        scrollToNextReactionButton.addAction(
            UIAction { [weak self] _ in self?.tellomiScrollToNextReactionButtonTapped() },
            for: .primaryActionTriggered,
        )
        // Telegram 两端长按回应按钮都是「Read All Reactions」（iOS `reactionsButton.activated`、安卓 `ReadAllMentionsMenu`）。
        scrollToNextReactionButton.menu = UIMenu(children: [
            UIAction(
                title: OWSLocalizedString(
                    "TELLOMI_READ_ALL_REACTIONS",
                    comment: "Tellomi (chat-telegram-parity F01): long press on the button that jumps to my messages with reactions I haven't seen, as in Telegram.",
                ),
                image: UIImage(named: "check-circle"),
            ) { [weak self] _ in
                self?.tellomiMarkAllReactionsSeen()
            },
        ])
        scrollToNextReactionButton.showsMenuAsPrimaryAction = false
        scrollToNextReactionButton.accessibilityLabel = OWSLocalizedString(
            "TELLOMI_NEXT_UNSEEN_REACTION",
            comment: "Tellomi (chat-telegram-parity F01): read out by VoiceOver on the button that jumps to my messages with reactions I haven't seen yet.",
        )
        scrollToNextReactionButton.isHidden = true
        scrollToNextReactionButton.alpha = 0
        view.addSubview(scrollToNextReactionButton)
        scrollToNextReactionButton.accessibilityIdentifier = "scrollToNextReactionButton"

        let reactionStack = scrollToNextReactionButton.bottomAnchor.constraint(equalTo: scrollToNextMentionButton.bottomAnchor, constant: 0)
        reactionStack.isActive = true
        viewState.tellomiReactionButtonStackConstraint = reactionStack
        scrollToNextReactionButton.autoPinEdge(.trailing, to: .trailing, of: scrollDownButton)
    }
}
