//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import UserNotifications

/// Tellomi（tellomi/tellomi#1519 M-4，方案 `docs/product/specs/scheduled-send-ios-plan.md` §6.3）：定时消息的到点本地通知。
///
/// iOS 不让 App 在指定时刻醒来，所以 App 不在前台时到点只能弹一条通知：点它打开会话并发出，或者点「立即发送」
/// 不打开 App 就发（要求设备已解锁）。不写正文；标题照通知设置决定写不写会话名。
/// 每条记录一个通知（标识 = 前缀 + 记录 id），记录一变就对齐：没了的撤掉（排着的、已弹的都撤），新的 / 改了时间的重排。
/// App 在前台时不弹（`AppDelegate.userNotificationCenter(_:willPresent:)`），定时器自己发。
public enum TellomiScheduledMessageNotifications {

    public static let categoryIdentifier = "Tellomi.AppNotificationCategory.scheduledMessageDue"
    public static let sendNowActionIdentifier = "Tellomi.AppNotifications.Action.sendScheduledMessageNow"

    static let identifierPrefix = "Tellomi.ScheduledMessage."
    private static let messageIdKey = "TellomiScheduledMessageId"
    private static let threadIdKey = "TellomiScheduledMessageThreadId"
    private static let scheduledAtKey = "TellomiScheduledMessageScheduledAt"
    private static let titleKey = "TellomiScheduledMessageTitle"

    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: sendNowActionIdentifier,
                    title: OWSLocalizedString(
                        "TELLOMI_SCHEDULED_MESSAGE_SEND_NOW_ACTION",
                        comment: "Action on the notification shown when a scheduled message is due: send it right away without opening the app.",
                    ),
                    options: [.authenticationRequired],
                    icon: UNNotificationActionIcon(systemImageName: "paperplane"),
                ),
            ],
            intentIdentifiers: [],
            options: [],
        )
    }

    // MARK: - Responses

    public struct Response {
        public let messageId: String
        public let threadUniqueId: String
        /// 点的是通知本身（打开 App）：发出后打开会话。点「立即发送」时不打开。
        public let opensChat: Bool
    }

    public static func isScheduledMessageNotification(_ notification: UNNotification) -> Bool {
        notification.request.content.categoryIdentifier == categoryIdentifier
    }

    /// 是定时消息的通知、而且是点了它或「立即发送」：要发哪条。别的（包括划掉）返回 nil。
    public static func response(for notification: UNNotification, actionIdentifier: String) -> Response? {
        response(for: notification.request.content, actionIdentifier: actionIdentifier)
    }

    static func response(for content: UNNotificationContent, actionIdentifier: String) -> Response? {
        guard content.categoryIdentifier == categoryIdentifier else {
            return nil
        }
        let userInfo = content.userInfo
        guard
            let messageId = userInfo[messageIdKey] as? String,
            let threadUniqueId = userInfo[threadIdKey] as? String
        else {
            return nil
        }
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            return Response(messageId: messageId, threadUniqueId: threadUniqueId, opensChat: true)
        case sendNowActionIdentifier:
            return Response(messageId: messageId, threadUniqueId: threadUniqueId, opensChat: false)
        default:
            return nil
        }
    }

    // MARK: - Sync

    struct Wanted: Equatable {
        let messageId: String
        let threadUniqueId: String
        let scheduledAt: Date
        /// 会话名；通知设置是「不显示名字也不显示内容」时 nil，这时也不和这个会话的通知归成一组（同上游 `threadIdentifier`）。
        let title: String?
    }

    struct Pending: Equatable {
        let identifier: String
        let scheduledAt: Date?
        var threadUniqueId: String?
        var title: String?
    }

    struct Plan: Equatable {
        var add: [Wanted] = []
        var removePending: [String] = []
        var removeDelivered: [String] = []
    }

    static func identifier(messageId: String) -> String {
        identifierPrefix + messageId
    }

    /// 对齐要做的事（纯函数，单测用）：
    /// - 排着的：记录没了、或时间对不上 → 撤；
    /// - 已弹的：记录没了（已发出 / 删掉）→ 撤；
    /// - 记录有、还没到点、没排着（或刚撤掉）→ 排。到点了的不排：执行器马上发，或者已经弹过了。
    static func plan(wanted: [Wanted], pending: [Pending], delivered: [String], now: Date) -> Plan {
        var plan = Plan()
        let wantedById = Dictionary(wanted.map { (identifier(messageId: $0.messageId), $0) }, uniquingKeysWith: { first, _ in first })
        var pendingOk = Set<String>()
        for request in pending where request.identifier.hasPrefix(identifierPrefix) {
            // 时间、会话（合并后会变）、标题（改名、改通知设置）都对得上才留着，否则重排。
            if
                let match = wantedById[request.identifier],
                let scheduledAt = request.scheduledAt,
                abs(match.scheduledAt.timeIntervalSince(scheduledAt)) < 0.001,
                match.threadUniqueId == request.threadUniqueId,
                match.title == request.title
            {
                pendingOk.insert(request.identifier)
            } else {
                plan.removePending.append(request.identifier)
            }
        }
        plan.removeDelivered = delivered.filter { $0.hasPrefix(identifierPrefix) && wantedById[$0] == nil }
        plan.add = wanted.filter { $0.scheduledAt > now && !pendingOk.contains(identifier(messageId: $0.messageId)) }
        return plan
    }

    /// 把系统里的通知对齐到现在的记录（主 App；记录一变、回到前台时调）。
    public static func sync(now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let wanted = SSKEnvironment.shared.databaseStorageRef.read(block: wanted(tx:))
        let pending = await center.pendingNotificationRequests().map(pending(for:))
        let delivered = await center.deliveredNotifications().map(\.request.identifier)

        let plan = plan(wanted: wanted, pending: pending, delivered: delivered, now: now)
        if !plan.removePending.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: plan.removePending)
        }
        if !plan.removeDelivered.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: plan.removeDelivered)
        }
        for item in plan.add {
            do {
                try await center.add(request(for: item))
            } catch {
                Logger.warn("Couldn't schedule the notification for a scheduled message: \(error)")
            }
        }
    }

    /// 每条记录要的通知；标题照通知设置：「不显示名字」时不写会话名。正文永远不写消息内容。
    /// 到点也发不出去的（会话没了、退了群、拉黑了，或没注册）不排：不许诺一条发不出去的消息。
    static func wanted(tx: DBReadTransaction) -> [Wanted] {
        guard DependenciesBridge.shared.tsAccountManager.registrationState(tx: tx).isRegistered else {
            return []
        }
        let previewType = DependenciesBridge.shared.notificationPreferencesManager.previewType(tx: tx)
        return TellomiScheduledMessageStore.fetchAll(tx: tx).compactMap { message in
            guard
                let thread = TSThread.anyFetch(uniqueId: message.threadUniqueId, transaction: tx),
                TellomiScheduledMessageStore.reasonNotToSend(to: thread, tx: tx) == nil
            else {
                return nil
            }
            let title = previewType == .noNameNoPreview ? nil : SSKEnvironment.shared.contactManagerRef.displayName(for: thread, transaction: tx)
            return Wanted(messageId: message.id, threadUniqueId: message.threadUniqueId, scheduledAt: message.scheduledAt, title: title)
        }
    }

    static func pending(for request: UNNotificationRequest) -> Pending {
        let userInfo = request.content.userInfo
        return Pending(
            identifier: request.identifier,
            scheduledAt: (userInfo[scheduledAtKey] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)),
            threadUniqueId: userInfo[threadIdKey] as? String,
            title: userInfo[titleKey] as? String,
        )
    }

    static func request(for item: Wanted) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = categoryIdentifier
        if let title = item.title {
            content.title = title
        }
        content.body = OWSLocalizedString(
            "TELLOMI_SCHEDULED_MESSAGE_DUE_NOTIFICATION_BODY",
            comment: "Body of the notification shown when a scheduled message is due and the app isn't open. It never includes the message text.",
        )
        content.sound = .default
        if item.title != nil {
            content.threadIdentifier = item.threadUniqueId
        }
        var userInfo: [AnyHashable: Any] = [
            messageIdKey: item.messageId,
            threadIdKey: item.threadUniqueId,
            scheduledAtKey: item.scheduledAt.timeIntervalSinceReferenceDate,
        ]
        if let title = item.title {
            userInfo[titleKey] = title
        }
        content.userInfo = userInfo
        // 带上时区：换时区、夏令时回拨时还是那一刻（不带时区的日期分量按「当地钟面」触发）。
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.scheduledAt)
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: identifier(messageId: item.messageId), content: content, trigger: trigger)
    }
}
