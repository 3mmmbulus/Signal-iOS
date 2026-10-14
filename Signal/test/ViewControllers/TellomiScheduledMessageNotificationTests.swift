//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import UserNotifications
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1519 M-4，方案 §6.2 / §6.3）：到点通知怎么对齐记录、写什么；后台刷新提前到最早那一条；「立即发送」。
final class TellomiScheduledMessageNotificationTests: SignalBaseTest {

    private typealias Notifications = TellomiScheduledMessageNotifications

    override func setUp() {
        super.setUp()
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
            // 发出去时上游会给 Siri 建议捐一条意图，要画头像（强转成 OWSContactsManager），测试环境的假通讯录过不去。
            SSKPreferences.setAreIntentDonationsEnabled(false, transaction: tx)
        }
    }

    // MARK: - Sync plan

    func testThePlanRemovesStaleOnesAndSchedulesNewOnes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let kept = wanted("kept", at: now.addingTimeInterval(60))
        let moved = wanted("moved", at: now.addingTimeInterval(120))
        let new = wanted("new", at: now.addingTimeInterval(180))
        let alreadyDue = wanted("due", at: now.addingTimeInterval(-1))
        let renamed = Notifications.Wanted(messageId: "renamed", threadUniqueId: "t", scheduledAt: now.addingTimeInterval(240), title: "New name")
        let merged = Notifications.Wanted(messageId: "merged", threadUniqueId: "aci-chat", scheduledAt: now.addingTimeInterval(300), title: nil)

        var oldName = pending("renamed", at: renamed.scheduledAt)
        oldName.title = "Old name"
        let plan = Notifications.plan(
            wanted: [kept, moved, new, alreadyDue, renamed, merged],
            pending: [
                pending("kept", at: kept.scheduledAt),
                pending("moved", at: now.addingTimeInterval(30)),
                pending("sent", at: now.addingTimeInterval(90)),
                oldName,
                pending("merged", at: merged.scheduledAt),
                Notifications.Pending(identifier: "Signal.someOtherNotification", scheduledAt: nil),
            ],
            delivered: [id("due"), id("sentEarlier"), "Signal.someMessage"],
            now: now,
        )

        XCTAssertEqual(plan.removePending.sorted(), [id("merged"), id("moved"), id("renamed"), id("sent")])
        XCTAssertEqual(plan.removeDelivered, [id("sentEarlier")], "a delivered one stays while its message is still waiting")
        XCTAssertEqual(
            plan.add.map(\.messageId).sorted(),
            ["merged", "moved", "new", "renamed"],
            "moved, renamed and merged ones are redone; already-due ones aren't scheduled (the executor sends them)",
        )
    }

    /// 排出去的请求再读回来（时间、会话、标题都从 userInfo 来），对齐时什么都不用做。
    func testAScheduledRequestReadsBackAsUpToDate() {
        let at = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456)
        for item in [
            Notifications.Wanted(messageId: "a", threadUniqueId: "t", scheduledAt: at, title: "小明"),
            Notifications.Wanted(messageId: "b", threadUniqueId: "t", scheduledAt: at, title: nil),
        ] {
            let readBack = Notifications.pending(for: Notifications.request(for: item))
            let plan = Notifications.plan(wanted: [item], pending: [readBack], delivered: [], now: at.addingTimeInterval(-60))
            XCTAssertEqual(plan, Notifications.Plan())
        }
    }

    /// 上游进出前台时清通知：定时消息的到点通知不清（还要等到点才弹）。
    func testActivationDoesNotClearTheReminders() {
        XCTAssertFalse(UserNotificationPresenter.shouldClearOnAppActivate(categoryIdentifier: Notifications.categoryIdentifier))
        XCTAssertTrue(UserNotificationPresenter.shouldClearOnAppActivate(categoryIdentifier: AppNotificationCategory.incomingMessageWithActions_CanReply.rawValue))
        XCTAssertTrue(UserNotificationPresenter.shouldClearOnAppActivate(categoryIdentifier: "something.else"))
    }

    // MARK: - Content

    func testTheNotificationFiresAtTheScheduledSecond() throws {
        let at = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 86_400).rounded(.down))
        let request = Notifications.request(for: Notifications.Wanted(messageId: "m", threadUniqueId: "t", scheduledAt: at, title: "小明"))

        XCTAssertEqual(request.identifier, id("m"))
        XCTAssertEqual(request.content.title, "小明")
        XCTAssertEqual(request.content.threadIdentifier, "t")
        XCTAssertEqual(request.content.body, OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGE_DUE_NOTIFICATION_BODY", comment: ""))
        XCTAssertEqual(request.content.categoryIdentifier, Notifications.categoryIdentifier)
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.nextTriggerDate(), at)
        XCTAssertEqual(trigger.dateComponents.timeZone, Calendar.current.timeZone, "an absolute moment, not a wall-clock time")

        // 不写会话名时也不和这个会话的通知归成一组。
        let anonymous = Notifications.request(for: Notifications.Wanted(messageId: "m", threadUniqueId: "t", scheduledAt: at, title: nil))
        XCTAssertEqual(anonymous.content.title, "")
        XCTAssertEqual(anonymous.content.threadIdentifier, "")

        // 点通知：发出并打开会话；点「立即发送」：只发出；划掉：什么都不做。
        let tap = try XCTUnwrap(Notifications.response(for: request.content, actionIdentifier: UNNotificationDefaultActionIdentifier))
        XCTAssertEqual(tap.messageId, "m")
        XCTAssertEqual(tap.threadUniqueId, "t")
        XCTAssertTrue(tap.opensChat)
        let sendNow = try XCTUnwrap(Notifications.response(for: request.content, actionIdentifier: Notifications.sendNowActionIdentifier))
        XCTAssertFalse(sendNow.opensChat)
        XCTAssertNil(Notifications.response(for: request.content, actionIdentifier: UNNotificationDismissActionIdentifier))

        let category = Notifications.category
        XCTAssertEqual(category.actions.map(\.identifier), [Notifications.sendNowActionIdentifier])
        XCTAssertEqual(category.actions.first?.options, UNNotificationActionOptions.authenticationRequired, "runs in the background, needs an unlocked device")
        XCTAssertTrue(UserNotificationConfig.allNotificationCategories.contains { $0.identifier == Notifications.categoryIdentifier })
    }

    /// 标题照通知设置：「不显示名字也不显示内容」时不写会话名。
    @MainActor
    func testTheTitleFollowsTheNotificationPrivacySetting() async throws {
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        try await TellomiScheduledMessageSender().schedule(
            body: MessageBody(text: "秘密", ranges: .empty),
            attachments: [],
            isViewOnce: false,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: false,
            at: Date().addingTimeInterval(3600),
        )
        let name = read { tx in SSKEnvironment.shared.contactManagerRef.displayName(for: thread, transaction: tx) }

        write { tx in DependenciesBridge.shared.notificationPreferencesManager.setPreviewType(.namePreview, tx: tx) }
        let withName = try XCTUnwrap(read(block: Notifications.wanted(tx:)).first)
        XCTAssertEqual(withName.title, name)
        // 就算设置是「显示名字和内容」，到点通知也不写消息内容。
        let request = Notifications.request(for: withName)
        let everything = [request.content.title, request.content.subtitle, request.content.body] + request.content.userInfo.values.map { "\($0)" }
        XCTAssertFalse(everything.contains { $0.contains("秘密") })

        write { tx in DependenciesBridge.shared.notificationPreferencesManager.setPreviewType(.noNameNoPreview, tx: tx) }
        XCTAssertEqual(read(block: Notifications.wanted(tx:)).map(\.title), [nil])
    }

    /// 到点也发不出去的不排通知（不许诺一条发不出去的消息）：退了群的。
    @MainActor
    func testNoReminderForAChatThatCantSend() async throws {
        let leftGroup = write { tx in
            try! GroupManager.createGroupForTests(members: [SignalServiceAddress(Aci.randomForTesting())], shouldInsertInfoMessage: false, name: "群", transaction: tx)
        }
        try await TellomiScheduledMessageSender().schedule(
            body: MessageBody(text: "x", ranges: .empty),
            attachments: [],
            isViewOnce: false,
            thread: leftGroup,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: false,
            at: Date().addingTimeInterval(3600),
        )
        XCTAssertEqual(read { tx in TellomiScheduledMessageStore.fetchAll(tx: tx) }.count, 1)
        XCTAssertEqual(read(block: Notifications.wanted(tx:)), [])
    }

    // MARK: - Background refresh

    func testBackgroundRefreshIsMovedUpToTheEarliestMessage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let interval: TimeInterval = 6 * 3600
        func earliest(_ next: Date?) -> Date {
            MessageFetchBGRefreshTask.tellomiEarliestBeginDate(now: now, refreshInterval: interval, nextScheduledMessage: next)
        }
        XCTAssertEqual(earliest(nil), now.addingTimeInterval(interval))
        XCTAssertEqual(earliest(now.addingTimeInterval(600)), now.addingTimeInterval(600))
        XCTAssertEqual(earliest(now.addingTimeInterval(-600)), now.addingTimeInterval(15 * 60), "overdue (it should have gone in the foreground): back off")
        XCTAssertEqual(earliest(now.addingTimeInterval(interval + 600)), now.addingTimeInterval(interval))
    }

    // MARK: - Send now

    /// 「立即发送」：还没到点的提前到现在发出，返回时已在发送队列里。
    @MainActor
    func testSendNowSendsAMessageBeforeItsTime() async throws {
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let sender = TellomiScheduledMessageSender()
        let message = try await sender.schedule(
            body: MessageBody(text: "提前发", ranges: .empty),
            attachments: [],
            isViewOnce: false,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: false,
            at: Date().addingTimeInterval(3600),
        )

        await sender.sendNow(id: message.id)

        let sent = read { tx in
            ((try? InteractionFinder(threadUniqueId: thread.uniqueId).fetchAllInteractions(rowIdFilter: .newest, limit: 10, tx: tx)) ?? [])
                .compactMap { ($0 as? TSOutgoingMessage)?.body }
        }
        XCTAssertEqual(sent, ["提前发"])
        XCTAssertEqual(read { tx in TellomiScheduledMessageStore.fetchAll(tx: tx) }, [])
    }

    // MARK: - Helpers

    private func id(_ messageId: String) -> String {
        Notifications.identifier(messageId: messageId)
    }

    private func wanted(_ messageId: String, at date: Date) -> Notifications.Wanted {
        Notifications.Wanted(messageId: messageId, threadUniqueId: "t", scheduledAt: date, title: nil)
    }

    private func pending(_ messageId: String, at date: Date) -> Notifications.Pending {
        Notifications.Pending(identifier: id(messageId), scheduledAt: date, threadUniqueId: "t", title: nil)
    }
}
