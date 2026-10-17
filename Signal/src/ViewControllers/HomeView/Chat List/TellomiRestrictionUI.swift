//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// Tellomi（tellomi/tellomi ADR-0078 §3.4）：人工处置说明的文字。文案定稿见 ADR-0078 §3.4（简繁英；其它语言显示英文）。
/// 一条说明 = 正文 + 申诉句；截止时间按本机语言和时区显示到分钟。
enum TellomiRestrictionUI {

    /// 会话列表顶上的提示（stranger / all）。
    static func notice(_ restriction: TellomiRestriction) -> String {
        let body: String
        switch restriction.level {
        case .stranger:
            body = String(
                format: OWSLocalizedString(
                    "TELLOMI_RESTRICTION_STRANGER",
                    value: "Your account can't message people who aren't your contacts until %@ because it broke the Tellomi Community Guidelines. Contacts you've already connected with aren't affected.",
                    comment: "Tellomi (ADR-0078): chat list notice while the account may not message non-contacts. Embeds the date and time the restriction ends.",
                ),
                untilText(restriction.until),
            )
        case .all, .suspended:
            body = String(
                format: OWSLocalizedString(
                    "TELLOMI_RESTRICTION_ALL",
                    value: "Your account can't send messages until %@ because it broke the Tellomi Community Guidelines. You can still receive messages and read your chats.",
                    comment: "Tellomi (ADR-0078): chat list notice while the account may not send any messages. Embeds the date and time the restriction ends.",
                ),
                untilText(restriction.until),
            )
        }
        return body + " " + appeal(restriction)
    }

    /// 重新注册被拒（这个号码被暂停）时的说明。
    static func suspendedAtRegistration(_ restriction: TellomiRestriction) -> String {
        let body = String(
            format: OWSLocalizedString(
                "TELLOMI_RESTRICTION_SUSPENDED_REGISTRATION",
                value: "The Tellomi account for this number is suspended until %@ for breaking the Tellomi Community Guidelines, so it can't be registered again before then.",
                comment: "Tellomi (ADR-0078): shown when registering a suspended number. Embeds the date and time the suspension ends.",
            ),
            untilText(restriction.until),
        )
        return body + " " + appeal(restriction)
    }

    private static func appeal(_ restriction: TellomiRestriction) -> String {
        if let caseId = restriction.caseId {
            return String(
                format: OWSLocalizedString(
                    "TELLOMI_RESTRICTION_APPEAL_CASE",
                    value: "If you think this is a mistake, email %1$@ and include case number %2$@.",
                    comment: "Tellomi (ADR-0078): second sentence of a restriction notice. Embeds the appeal email address, then the case number to quote.",
                ),
                restriction.appeal,
                caseId,
            )
        }
        return String(
            format: OWSLocalizedString(
                "TELLOMI_RESTRICTION_APPEAL",
                value: "If you think this is a mistake, email %@.",
                comment: "Tellomi (ADR-0078): second sentence of a restriction notice when there is no case number. Embeds the appeal email address.",
            ),
            restriction.appeal,
        )
    }

    static func untilText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
