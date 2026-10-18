//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（chat-telegram-parity F03）：按日期跳转。安卓同一刀：Signal-Android#384。
///
/// 照 Telegram 两端（只读源码，没搬代码）：
/// - 点吸在顶上的日期 → 跳到那天的第一条（iOS `ChatMessageDateHeader` 吸顶时 `navigateToFirstDateMessage`；安卓点 `floatingDateView` → `jumpToDate`）；
/// - 点原位的日期 → 打开日历，停在那天（iOS `alreadyThere` → `openCalendarSearch`；安卓点日期格 → `CalendarActivity`）；
/// - 会话内搜索栏也有日历按钮（iOS 搜索栏 `openCalendarSearch`；安卓 `searchCalendarButton`）。
extension ConversationViewController {

    public func tellomiDidTapDateHeader(timestamp: UInt64, isStuck: Bool) {
        guard uiMode != .selection else {
            return
        }
        let day = Calendar.current.startOfDay(for: Date(millisecondsSince1970: timestamp))
        if isStuck {
            tellomiJumpToDay(day)
        } else {
            tellomiShowJumpToDatePicker(initialDay: day)
        }
    }

    /// 打开日历（有消息的日子才能选），选了就跳到那天的第一条；[beforeJump] 在跳之前调（搜索栏用来收起搜索）。
    func tellomiShowJumpToDatePicker(initialDay: Date, beforeJump: (() -> Void)? = nil) {
        let threadUniqueId = thread.uniqueId
        let days = SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiConversationDays.daysWithMessages(threadUniqueId: threadUniqueId, tx: tx)
        }
        TellomiJumpToDateViewController.present(from: self, days: days, initialDay: initialDay) { [weak self] day in
            beforeJump?()
            self?.tellomiJumpToDay(day)
        }
    }

    /// 跳到 [day] 那天（本地 0 点起）的第一条，放到顶上；那天之后没消息就到底。
    func tellomiJumpToDay(_ day: Date) {
        let threadUniqueId = thread.uniqueId
        let messageId = SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiConversationDays.firstMessageUniqueId(onOrAfter: day, threadUniqueId: threadUniqueId, tx: tx)
        }
        guard let messageId else {
            scrollToBottomOfConversation(animated: true)
            return
        }
        ensureInteractionLoadedThenScrollToInteraction(messageId, alignment: .top, isAnimated: true)
    }
}
