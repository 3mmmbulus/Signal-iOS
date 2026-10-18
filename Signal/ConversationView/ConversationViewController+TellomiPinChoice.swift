//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（ADR-0081 §4.6，pinned-messages.md 3.1）：置顶前先问给谁看（`TellomiPinChoice`），最后一行是时长——默认永久，
/// 点开是 Signal 原来的 24 小时 / 7 天 / 30 天 / 永久，选完（或取消）回到这里。我的收藏不问，直接永久置顶。
/// 与安卓 `ConversationFragment.showPinChoiceDialog` 一致。
extension ConversationViewController {

    /// `duration` 为 nil 即永久。
    func tellomiShowPinChoiceSheet(duration: TimeInterval? = nil, completion: @escaping (TellomiPinChoice, TimeInterval?) -> Void) {
        let (canPinForEveryone, otherName) = SSKEnvironment.shared.databaseStorageRef.read { tx -> (Bool, String?) in
            let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
            let canPinForEveryone = localAci.map { thread.canUserEditPinnedMessages(aci: $0, tx: tx) } ?? false
            let otherName = (thread as? TSContactThread).map {
                SSKEnvironment.shared.contactManagerRef.displayName(for: $0.contactAddress, tx: tx).resolvedValue(useShortNameIfAvailable: true)
            }
            return (canPinForEveryone, otherName)
        }

        guard
            let choices = TellomiPinChoice.choices(
                isNoteToSelf: thread.isNoteToSelf,
                isGroup: thread.isGroupThread,
                canPinForEveryone: canPinForEveryone,
            )
        else {
            completion(.forBoth, duration)
            return
        }

        let actionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "TELLOMI_PIN_TITLE",
                comment: "Tellomi (ADR-0081, pinned-messages.md 3.1): title of the sheet asking who a pin is for.",
            ),
            message: nil,
        )
        for choice in choices {
            actionSheet.addAction(ActionSheetAction(
                title: Self.tellomiPinChoiceTitle(choice, otherName: otherName ?? ""),
                handler: { _ in
                    completion(choice, duration)
                },
            ))
        }
        actionSheet.addAction(ActionSheetAction(
            title: String(
                format: OWSLocalizedString(
                    "TELLOMI_PIN_DURATION",
                    comment: "Tellomi (ADR-0081, pinned-messages.md 3.1): the last row of the pin sheet; tapping it picks how long the pin lasts. Embeds {{ how long, e.g. Forever }}.",
                ),
                Self.tellomiPinDurationTitle(duration),
            ),
            handler: { [weak self] _ in
                self?.tellomiShowPinDurationSheet(current: duration) { newDuration in
                    self?.tellomiShowPinChoiceSheet(duration: newDuration, completion: completion)
                }
            },
        ))
        actionSheet.addAction(.cancel)
        presentActionSheet(actionSheet)
    }

    /// Signal 原来的「保持置顶…」几项；取消也回到选择那一层，时长不变。
    private func tellomiShowPinDurationSheet(current: TimeInterval?, completion: @escaping (TimeInterval?) -> Void) {
        let actionSheet = ActionSheetController(
            title: nil,
            message: OWSLocalizedString(
                "PINNED_MESSAGES_EXPIRY_SHEET_TITLE",
                comment: "Title for an action sheet to indicate how long to keep the pin active",
            ),
        )
        let durations: [TimeInterval?] = [TimeInterval.day, 7 * TimeInterval.day, 30 * TimeInterval.day, nil]
        for duration in durations {
            actionSheet.addAction(ActionSheetAction(
                title: Self.tellomiPinDurationTitle(duration),
                handler: { _ in
                    completion(duration)
                },
            ))
        }
        actionSheet.addAction(ActionSheetAction(
            title: CommonStrings.cancelButton,
            style: .cancel,
            handler: { _ in
                completion(current)
            },
        ))
        presentActionSheet(actionSheet)
    }

    private static func tellomiPinChoiceTitle(_ choice: TellomiPinChoice, otherName: String) -> String {
        switch choice {
        case .forBoth:
            return String(
                format: OWSLocalizedString(
                    "TELLOMI_PIN_FOR_ME_AND",
                    comment: "Tellomi (ADR-0081, pinned-messages.md 3.1): pin a message in a 1:1 chat for both people. Embeds {{ the other person's short name }}.",
                ),
                otherName,
            )
        case .forEveryone:
            return OWSLocalizedString(
                "TELLOMI_PIN_NOTIFY_ALL",
                comment: "Tellomi (ADR-0081, pinned-messages.md 3.1): pin a message in a group for everyone and notify them.",
            )
        case .forEveryoneSilent:
            return OWSLocalizedString(
                "TELLOMI_PIN_WITHOUT_NOTIFYING",
                comment: "Tellomi (ADR-0081, pinned-messages.md 3.1): pin a message in a group for everyone without notifying anyone.",
            )
        case .forMe:
            return OWSLocalizedString(
                "TELLOMI_PIN_FOR_ME",
                comment: "Tellomi (ADR-0081, pinned-messages.md 3.1): pin a message only on my own devices; the other side never sees it.",
            )
        }
    }

    private static func tellomiPinDurationTitle(_ duration: TimeInterval?) -> String {
        if duration == TimeInterval.day {
            return OWSLocalizedString("PINNED_MESSAGES_24_HOURS", comment: "Option in pinned message action sheet to pin for 24 hours.")
        } else if duration == 7 * TimeInterval.day {
            return OWSLocalizedString("PINNED_MESSAGES_7_DAYS", comment: "Option in pinned message action sheet to pin for 7 days.")
        } else if duration == 30 * TimeInterval.day {
            return OWSLocalizedString("PINNED_MESSAGES_30_DAYS", comment: "Option in pinned message action sheet to pin for 30 days.")
        }
        return OWSLocalizedString("PINNED_MESSAGES_FOREVER", comment: "Option in pinned message action sheet to pin with no expiry.")
    }

    /// 取消置顶时：「仅为我」的那条只告诉自己的设备（`TellomiPinsForMe.send`），别的照 Signal 发给会话。
    func tellomiOutgoingUnpinMessage(for message: TSMessage, tx: DBWriteTransaction) -> OutgoingUnpinMessage? {
        let unpinMessage = DependenciesBridge.shared.pinnedMessageManager.getOutgoingUnpinMessage(
            interaction: message,
            thread: thread,
            expiresAt: nil,
            tx: tx,
        )
        unpinMessage?.tellomiPinForSelfOnly = message.sqliteRowId.map { TellomiPinsForMe.isPinnedForMe(interactionId: $0, tx: tx) } ?? false
        return unpinMessage
    }
}
