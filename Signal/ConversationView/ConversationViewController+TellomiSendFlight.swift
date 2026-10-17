//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（M9 发送动画）在会话页这一侧：什么时候飞、认哪一条、落到哪。飞行本身见 `TellomiSendFlight`。
extension ConversationViewController {

    /// 这一次发送能不能飞；能就在清空输入框之前把它的样子记下来。只给纯文字（不带引用、链接预览，不是编辑）、会话停在最底下、
    /// 没在多选、没开「减弱动态效果」时飞（同 Android `canPlaySendTransition`）；输入框里字多到自己在滚动也不飞。
    func tellomiSendFlightSourceIfEligible(_ inputToolbar: ConversationInputToolbar) -> TellomiSendFlight.Source? {
        guard
            !TellomiMotion.isReduceMotionEnabled,
            inputToolbar.editTarget == nil,
            inputToolbar.quotedReplyDraft == nil,
            inputToolbar.linkPreviewDraft == nil,
            !isShowingSelectionUI,
            isScrolledToBottom,
            view.window != nil
        else {
            return nil
        }
        return inputToolbar.tellomiSendFlightSource()
    }

    /// 消息已经交出去（拿到了时间戳）：开始等它进列表。
    func beginTellomiSendFlight(messageTimestamp: UInt64, source: TellomiSendFlight.Source) {
        guard let window = view.window else {
            return
        }
        let flight = TellomiSendFlight(
            messageTimestamp: messageTimestamp,
            source: source,
            window: window,
            findTarget: { [weak self] interactionUniqueId in
                self?.tellomiSendFlightTarget(interactionUniqueId: interactionUniqueId)
            },
            makeContent: { [weak self] renderItem in
                guard let self else {
                    return nil
                }
                let cellView = CVCellView()
                cellView.configure(renderItem: renderItem, componentDelegate: self)
                return cellView
            },
            onChange: { [weak self] _ in
                self?.tellomiApplySendFlightFieldAlpha()
            },
            onReveal: { [weak self] _, interactionUniqueId in
                self?.tellomiRevealSendFlightRow(interactionUniqueId: interactionUniqueId)
            },
            onFinish: { [weak self] flight in
                guard let self else {
                    return
                }
                self.viewState.tellomiSendFlights.removeAll { $0 === flight }
                self.tellomiApplySendFlightFieldAlpha()
            },
        )
        viewState.tellomiSendFlights.append(flight)
        tellomiApplySendFlightFieldAlpha()
    }

    /// 这一批更新里插进来的、正等着飞的那几条：认领它们（格子从第一次配置起就藏着），返回它们插进去的位置
    /// （列表排版用：这几格出现时不再淡入，免得落定那一刻格子本身还没淡完）。在 `performBatchUpdates` 之前调用。
    func tellomiClaimSendFlights(items: [CVUpdate.Item]) -> Set<IndexPath> {
        let waiting = viewState.tellomiSendFlights.filter { $0.phase == .waiting && $0.interactionUniqueId == nil }
        guard !waiting.isEmpty else {
            return []
        }
        var claimed = Set<IndexPath>()
        for item in items {
            guard
                case .insert(let newIndex) = item.updateType,
                let message = item.value.interaction as? TSOutgoingMessage,
                !message.wasNotCreatedLocally,
                let flight = waiting.first(where: { $0.messageTimestamp == message.timestamp && $0.interactionUniqueId == nil })
            else {
                continue
            }
            flight.claim(interactionUniqueId: item.value.interactionUniqueId)
            claimed.insert(IndexPath(row: newIndex, section: Self.messageSection))
        }
        return claimed
    }

    /// 页面要走：飞的那一层在窗口上，不能留到下一页上面。
    func tellomiCancelSendFlights() {
        for flight in viewState.tellomiSendFlights {
            flight.cancelImmediately()
        }
        viewState.tellomiSendFlights.removeAll()
        tellomiApplySendFlightFieldAlpha()
    }

    private func tellomiSendFlightTarget(interactionUniqueId: String) -> TellomiSendFlight.Target? {
        guard
            let indexPath = indexPath(forInteractionUniqueId: interactionUniqueId),
            let cell = collectionView.cellForItem(at: indexPath) as? CVCell,
            let renderItem = cell.renderItem,
            let messageView = cell.componentView as? CVComponentMessage.CVComponentViewMessage,
            let bubbleView = messageView.tellomiSendFlightBubbleView,
            let bodyTextView = messageView.tellomiSendFlightBodyTextView
        else {
            return nil
        }
        return TellomiSendFlight.Target(bubbleView: bubbleView, bodyTextView: bodyTextView, renderItem: renderItem)
    }

    private func tellomiRevealSendFlightRow(interactionUniqueId: String) {
        guard
            let indexPath = indexPath(forInteractionUniqueId: interactionUniqueId),
            let cell = collectionView.cellForItem(at: indexPath) as? CVCell
        else {
            return
        }
        cell.tellomiIsHeldForSendFlight = viewState.tellomiSendFlights.contains {
            $0.isHoldingRow(interactionUniqueId: interactionUniqueId)
        }
    }

    /// 输入框的透明度：还在等、在飞的那几次里最透明的那个；都完了就是 1。
    private func tellomiApplySendFlightFieldAlpha() {
        inputToolbar?.tellomiInputTextAlpha = viewState.tellomiSendFlights.map(\.fieldAlpha).min() ?? 1
    }
}
