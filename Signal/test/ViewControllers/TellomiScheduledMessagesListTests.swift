//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UniformTypeIdentifiers
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1519 M-4，照 Telegram 两端）：一个会话的「定时消息」页——按天分组、组头、空的时候、长按菜单、
/// 改时间带着原来的时间、删除；一个会话最多 100 条。
final class TellomiScheduledMessagesListTests: SignalBaseTest {

    override func setUp() {
        super.setUp()
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
            SSKPreferences.setAreIntentDonationsEnabled(false, transaction: tx)
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: - Rules

    func testMessagesAreGroupedByDayInOrder() throws {
        let messages = try [
            record(at: date(10, 14, 18)),
            record(at: date(10, 14, 21)),
            record(at: date(10, 15, 9)),
            record(at: date(11, 2, 9)),
        ]
        let sections = TellomiScheduledMessagesViewController.sections(for: messages, calendar: calendar)
        XCTAssertEqual(sections.map(\.messages.count), [2, 1, 1])
        XCTAssertEqual(sections.map(\.day), [date(10, 14, 0), date(10, 15, 0), date(11, 2, 0)])
    }

    func testDayHeaders() {
        let now = date(10, 14, 10)
        let locale = Locale(identifier: "en_US")
        func title(_ day: Date) -> String {
            TellomiScheduledMessagesViewController.dayTitle(for: day, now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(title(date(10, 14, 0)), "Scheduled for today")
        XCTAssertEqual(title(date(10, 15, 0)), "Scheduled for October 15")
        XCTAssertEqual(title(date(1, 3, 0, year: 2027)), "Scheduled for January 3, 2027")
    }

    // MARK: - Screen

    @MainActor
    func testTheScreenListsThisChatsMessagesAndUpdates() async throws {
        let thread = makeContactThread()
        let other = makeContactThread()
        let sender = TellomiScheduledMessageSender()
        let soon = try await schedule(sender, "第一条", in: thread, at: Date().addingTimeInterval(3600))
        _ = try await schedule(sender, "第二条", in: thread, at: Date().addingTimeInterval(2 * 86_400))
        _ = try await schedule(sender, "别的会话", in: other, at: Date().addingTimeInterval(3600))

        let screen = TellomiScheduledMessagesViewController(threadUniqueId: thread.uniqueId, isNoteToSelf: false, bubbleColor: nil, sender: sender)
        screen.loadViewIfNeeded()
        XCTAssertEqual(screen.title, "Scheduled Messages")
        XCTAssertEqual(screen.sectionsForTesting.flatMap(\.messages).map { try? $0.messageBody()?.text }, ["第一条", "第二条"])
        XCTAssertEqual(screen.sectionsForTesting.count, 2, "two different days")
        XCTAssertFalse(screen.isEmptyShownForTesting)

        // 长按菜单：立即发送、改时间、复制、删除（删除要再确认一次）。
        let menu = screen.menuElements(for: soon, text: "第一条")
        XCTAssertEqual(menu.map(\.title), ["Send Now", "Reschedule", "Copy", "Delete"])
        let delete = try XCTUnwrap(menu.last as? UIMenu)
        XCTAssertEqual(delete.children.map(\.title), ["Delete Scheduled Message"])

        // 只有图、没有字的：没有「复制」。
        let photosOnly = try await sender.schedule(
            body: nil,
            attachments: [try await photo(.systemOrange)],
            isViewOnce: false,
            thread: other,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: false,
            at: Date().addingTimeInterval(3600),
        )
        XCTAssertNil(screen.plainTextForTesting(photosOnly))
        XCTAssertEqual(screen.menuElements(for: photosOnly, text: screen.plainTextForTesting(photosOnly)).map(\.title), ["Send Now", "Reschedule", "Delete"])

        // 改时间：写进记录，列表跟着换到新的那天。
        let moved = TellomiScheduleTimeSheet.defaultDate(now: Date()).addingTimeInterval(4 * 86_400)
        await screen.rescheduleForTesting(soon, to: moved)
        XCTAssertEqual(read { tx in TellomiScheduledMessageStore.fetch(id: soon.id, tx: tx)?.scheduledAt }, moved)
        let rescheduled = await waitUntil { screen.sectionsForTesting.last?.messages.last?.id == soon.id }
        XCTAssertTrue(rescheduled)
        // 执行器的定时器重新挂到所有会话里现在最早的那条。
        let earliest = try XCTUnwrap(read { tx in TellomiScheduledMessageStore.nextScheduledAt(tx: tx) })
        let timerMoved = await waitUntil { sender.nextTimerFireDateForTesting.map { abs($0.timeIntervalSince(earliest)) < 2 } ?? false }
        XCTAssertTrue(timerMoved)

        // 删一条：列表跟着变（记录变化的通知异步到主线程）。
        let movedSoon = try XCTUnwrap(read { tx in TellomiScheduledMessageStore.fetch(id: soon.id, tx: tx) })
        screen.deleteForTesting(movedSoon)
        let updated = await waitUntil { screen.sectionsForTesting.flatMap(\.messages).count == 1 }
        XCTAssertTrue(updated)

        // 立即发送：发出去以后列表空了，页面不关，显示空的提示（同 TG 两端）。
        let last = try XCTUnwrap(screen.sectionsForTesting.first?.messages.first)
        screen.sendNowForTesting(last)
        let empty = await waitUntil { screen.isEmptyShownForTesting }
        XCTAssertTrue(empty)
        let sent = read { tx in
            ((try? InteractionFinder(threadUniqueId: thread.uniqueId).fetchAllInteractions(rowIdFilter: .newest, limit: 10, tx: tx)) ?? [])
                .compactMap { ($0 as? TSOutgoingMessage)?.body }
        }
        XCTAssertEqual(sent, ["第二条"])
    }

    @MainActor
    func testSavedMessagesCallsThemReminders() {
        let screen = TellomiScheduledMessagesViewController(threadUniqueId: "t", isNoteToSelf: true, bubbleColor: nil, sender: TellomiScheduledMessageSender())
        screen.loadViewIfNeeded()
        XCTAssertEqual(screen.title, "Reminders")
        XCTAssertTrue(screen.isEmptyShownForTesting)
    }

    /// 改时间：选时间页带着原来的时间打开（同 TG 两端）。（写进记录见上面列表的用例。）
    @MainActor
    func testTheRescheduleSheetStartsAtTheCurrentTime() {
        let current = TellomiScheduleTimeSheet.defaultDate(now: Date()).addingTimeInterval(3 * 86_400)
        let sheet = TellomiScheduleTimeSheet(isReminder: false, initialDate: current) { _ in }
        sheet.loadViewIfNeeded()
        XCTAssertEqual(sheet.datePickerForTesting.date, current)
    }

    /// 一个会话最多 100 条（同 TG 的上限）；别的会话不受影响。
    @MainActor
    func testAChatHoldsAtMostAHundred() async throws {
        let thread = makeContactThread()
        let sender = TellomiScheduledMessageSender()
        let later = Date().addingTimeInterval(3600)
        try write { tx in
            for index in 0..<(TellomiScheduledMessageSender.maxScheduledPerChat - 1) {
                try TellomiScheduledMessageStore.insert(try record(at: later, thread: thread.uniqueId, text: "\(index)"), tx: tx)
            }
        }
        XCTAssertEqual(read { tx in TellomiScheduledMessageSender.remainingCapacity(threadUniqueId: thread.uniqueId, tx: tx) }, 1)
        _ = try await schedule(sender, "第 100 条", in: thread, at: later)
        XCTAssertEqual(read { tx in TellomiScheduledMessageSender.remainingCapacity(threadUniqueId: thread.uniqueId, tx: tx) }, 0)
        do {
            _ = try await schedule(sender, "第 101 条", in: thread, at: later)
            XCTFail("the 101st should be refused")
        } catch TellomiScheduledMessageSender.ScheduleError.tooManyScheduled {
            XCTAssertEqual(
                TellomiScheduledMessageSender.ScheduleError.tooManyScheduled.localizedDescription,
                "Sorry, you can't schedule more than 100 messages.",
            )
        }
        _ = try await schedule(sender, "别的会话", in: makeContactThread(), at: later)
    }

    /// 会话输入框里长按发送（M-4，同 TG 两端）：只有文字时气泡贴着文字宽；字多了到最宽、换行。菜单里是「定时发送」。
    @MainActor
    func testTheTextOnlyPreviewFitsTheText() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let button = UIButton(frame: CGRect(x: 350, y: 800, width: 40, height: 40))
        root.view.addSubview(button)

        func layout(_ text: String) -> TellomiSendPreviewViewController.Layout {
            let preview = TellomiSendPreviewViewController(
                tiles: [],
                caption: text,
                captionAboveMedia: false,
                bubbleColor: nil,
                actions: [.init(title: TellomiScheduleTimeSheet.title(isReminder: false), image: nil, keepsPresented: false, handler: {})],
                sourceButton: button,
                onSend: {},
            )
            root.present(preview, animated: false)
            preview.view.layoutIfNeeded()
            defer { preview.dismiss(animated: false) }
            return preview.layoutForTesting
        }
        let short = layout("Hi")
        XCTAssertTrue(short.tiles.isEmpty)
        XCTAssertLessThan(short.message.size.width, 120, "a short text gets a narrow bubble")
        XCTAssertLessThanOrEqual(short.message.maxX, button.frame.origin.x, "left of the send button")

        let long = layout(String(repeating: "A long message that wraps. ", count: 6))
        // 折行后最宽的一行比最大宽度略窄（按词折），所以是「接近最宽」。
        XCTAssertGreaterThan(long.message.size.width, 230, "a long text uses (about) the full width")
        XCTAssertLessThanOrEqual(long.message.size.width, 260)
        XCTAssertGreaterThan(long.message.size.height, short.message.size.height)
    }

    /// 从右往左的语言：发送键在左边，气泡和菜单在它右边，不出屏幕。
    @MainActor
    func testThePreviewMirrorsForRightToLeft() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let button = UIButton(frame: CGRect(x: 12, y: 800, width: 40, height: 40))
        root.view.addSubview(button)
        let preview = TellomiSendPreviewViewController(
            tiles: [],
            caption: "مرحبا",
            captionAboveMedia: false,
            bubbleColor: nil,
            actions: [.init(title: "Schedule", image: nil, keepsPresented: false, handler: {})],
            sourceButton: button,
            onSend: {},
        )
        preview.loadViewIfNeeded()
        preview.view.semanticContentAttribute = .forceRightToLeft
        root.present(preview, animated: false)
        defer { preview.dismiss(animated: false) }
        preview.view.layoutIfNeeded()
        let layout = preview.layoutForTesting
        XCTAssertGreaterThanOrEqual(layout.message.minX, button.frame.maxX, "right of the send button")
        XCTAssertGreaterThanOrEqual(layout.menu.minX, button.frame.maxX)
        XCTAssertLessThanOrEqual(layout.menu.maxX, 402)
    }

    /// 记录变化的通知带上会话：别的会话的变化，会话页、定时消息页不用管。
    @MainActor
    func testChangeNotificationsNameTheChat() throws {
        let posted = expectation(forNotification: TellomiScheduledMessageStore.didChange, object: nil) { notification in
            TellomiScheduledMessageStore.didChange(notification, affect: "a") && !TellomiScheduledMessageStore.didChange(notification, affect: "b")
        }
        try write { tx in try TellomiScheduledMessageStore.insert(try record(at: Date(), thread: "a"), tx: tx) }
        wait(for: [posted], timeout: 5)
        XCTAssertTrue(TellomiScheduledMessageStore.didChange(Notification(name: TellomiScheduledMessageStore.didChange), affect: "anything"), "no chat named: everyone refreshes")
    }

    /// 选图页一次会排成几条：单独发送一张一条，否则一条（静音视频另算，见 `TellomiMutedVideoTests`）。
    func testHowManyMessagesAPickerSendSchedules() async throws {
        let approved = ApprovedAttachments(nonViewOnceAttachments: [try previewablePhoto(.red), try previewablePhoto(.blue), try previewablePhoto(.green)], imageQuality: .standard)
        XCTAssertEqual(ConversationViewController.tellomiScheduledMessageCount(for: approved, separately: true), 3)
        XCTAssertEqual(ConversationViewController.tellomiScheduledMessageCount(for: approved, separately: false), 1)
    }

    /// 链接预览的图存成记录目录里的文件，不放进记录；到点建消息时读回来。
    @MainActor
    func testTheLinkPreviewImageIsAFile() async throws {
        let thread = makeContactThread()
        let imageData = try XCTUnwrap(UIImage.image(color: .systemBlue, size: CGSize(square: 20)).pngData())
        let draft = OWSLinkPreviewDraft(url: URL(string: "https://example.com")!, title: "Example", imageData: imageData, imageMimeType: "image/png", isForwarded: false)
        let message = try await TellomiScheduledMessageSender().schedule(
            body: MessageBody(text: "https://example.com", ranges: .empty),
            attachments: [],
            isViewOnce: false,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: draft,
            captionAboveMedia: false,
            at: Date().addingTimeInterval(3600),
        )
        let preview = try XCTUnwrap(message.linkPreview)
        XCTAssertNil(preview.imageData, "not inside the record")
        let fileName = try XCTUnwrap(preview.imageFileName)
        let directory = TellomiScheduledMessageStore.directory(for: message.id)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(fileName)), imageData)
        XCTAssertEqual(preview.draft(in: directory).imageData, imageData)
        XCTAssertEqual(preview.draft(in: directory).title, "Example")
    }

    /// 截图（TELLOMI_SHOTS=1）：一个会话的定时消息页（两天、带图、带说明）。
    @MainActor
    func testScheduledMessagesScreenshot() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let thread = makeContactThread()
        let sender = TellomiScheduledMessageSender()
        let today = Date().addingTimeInterval(1800)
        _ = try await schedule(sender, "Don't forget the tickets!", in: thread, at: today)
        _ = try await sender.schedule(
            body: MessageBody(text: "Photos from the trip", ranges: .empty),
            attachments: [try await photo(.systemOrange), try await photo(.systemTeal), try await photo(.systemPink)],
            isViewOnce: false,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: false,
            at: today.addingTimeInterval(86_400 + 3600),
        )
        _ = try await schedule(sender, "Happy birthday 🎉", in: thread, at: today.addingTimeInterval(5 * 86_400))

        let screen = TellomiScheduledMessagesViewController(
            threadUniqueId: thread.uniqueId,
            thread: thread,
            isNoteToSelf: false,
            bubbleColor: .solidColor(color: UIColor(red: 0.23, green: 0.47, blue: 0.27, alpha: 1)),
            sender: sender,
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = OWSNavigationController(rootViewController: screen)
        window.isHidden = false
        defer { window.isHidden = true }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("402")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func shoot(_ name: String) async throws {
            _ = await waitUntil(timeout: 3) { false }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        }
        // 底下的输入框（M-4 第五步）：空的、写了字、在改一条（带图的那条，「编辑消息」后面一张小图）
        try await shoot("scheduled-messages-list")
        let composeBar = try XCTUnwrap(screen.composeBarForTesting)
        composeBar.setTextForTesting("See you at 8")
        try await shoot("scheduled-messages-compose")
        let photos = try XCTUnwrap(screen.sectionsForTesting.flatMap(\.messages).first { !$0.attachments.isEmpty })
        screen.beginEditingForTesting(photos)
        try await shoot("scheduled-messages-edit")
    }

    // MARK: - Writing and editing（M-4 第五步，照 TG 两端：定时消息页底下能写新的、长按能改）

    /// 记录里改文字：换正文，到点时刻、排定先后不变；说明删光了就谈不上在上面；记录没了返回 nil。
    func testTheStoreEditsTheText() throws {
        var original = try record(at: date(10, 20, 9), text: "原文")
        original.captionAboveMedia = true
        try write { tx in try TellomiScheduledMessageStore.insert(original, tx: tx) }

        let old = try write { tx in
            try TellomiScheduledMessageStore.edit(id: original.id, body: MessageBody(text: "改过", ranges: .empty), linkPreview: nil, tx: tx)
        }
        XCTAssertEqual(old, original)
        let edited = try XCTUnwrap(read { tx in TellomiScheduledMessageStore.fetch(id: original.id, tx: tx) })
        XCTAssertEqual(try edited.messageBody()?.text, "改过")
        XCTAssertEqual(edited.scheduledAt, original.scheduledAt)
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertTrue(edited.captionAboveMedia)

        _ = try write { tx in
            try TellomiScheduledMessageStore.edit(id: original.id, body: MessageBody(text: "", ranges: .empty), linkPreview: nil, tx: tx)
        }
        let cleared = try XCTUnwrap(read { tx in TellomiScheduledMessageStore.fetch(id: original.id, tx: tx) })
        XCTAssertNil(cleared.body)
        XCTAssertFalse(cleared.captionAboveMedia)

        let gone = try write { tx in
            try TellomiScheduledMessageStore.edit(id: "gone", body: MessageBody(text: "x", ranges: .empty), linkPreview: nil, tx: tx)
        }
        XCTAssertNil(gone)
    }

    /// 到点建消息的这段时间里改了文字：认领时发现内容换了，不发旧的（改过的那版接着到点再发）。
    func testAnEditDuringSendingStopsTheOldText() throws {
        let original = try record(at: Date().addingTimeInterval(-1), text: "旧的")
        try write { tx in try TellomiScheduledMessageStore.insert(original, tx: tx) }
        XCTAssertTrue(read { tx in TellomiScheduledMessageStore.isStillDue(original, now: Date(), tx: tx) })
        _ = try write { tx in
            try TellomiScheduledMessageStore.edit(id: original.id, body: MessageBody(text: "新的", ranges: .empty), linkPreview: nil, tx: tx)
        }
        XCTAssertFalse(read { tx in TellomiScheduledMessageStore.isStillDue(original, now: Date(), tx: tx) }, "the old snapshot")
        let current = try XCTUnwrap(read { tx in TellomiScheduledMessageStore.fetch(id: original.id, tx: tx) })
        XCTAssertTrue(read { tx in TellomiScheduledMessageStore.isStillDue(current, now: Date(), tx: tx) })
    }

    /// 执行器改文字：预览没变就沿用原来的图文件；去掉预览就删图；换了网址另存新图、删旧图。
    /// 纯文字的不能改成空的；改的这会儿已经发出去了返回 false。
    @MainActor
    func testTheSenderEditsTextAndLinkPreview() async throws {
        let thread = makeContactThread()
        let sender = TellomiScheduledMessageSender()
        let imageData = try XCTUnwrap(UIImage.image(color: .systemBlue, size: CGSize(square: 20)).pngData())
        let draft = OWSLinkPreviewDraft(url: URL(string: "https://example.com")!, title: "Example", imageData: imageData, imageMimeType: "image/png", isForwarded: false)
        let message = try await sender.schedule(
            body: MessageBody(text: "看 https://example.com", ranges: .empty),
            attachments: [],
            isViewOnce: false,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: draft,
            captionAboveMedia: false,
            at: Date().addingTimeInterval(3600),
        )
        let directory = TellomiScheduledMessageStore.directory(for: message.id)
        let firstImage = try XCTUnwrap(message.linkPreview?.imageFileName)

        // 同一个预览（编辑时从记录里取出来的那份）：图文件不动
        let sameDraft = try XCTUnwrap(message.linkPreview?.draft(in: directory))
        let edited = try await sender.edit(id: message.id, body: MessageBody(text: "快看 https://example.com", ranges: .empty), linkPreviewDraft: sameDraft)
        XCTAssertTrue(edited)
        var current = try XCTUnwrap(read { tx in TellomiScheduledMessageStore.fetch(id: message.id, tx: tx) })
        XCTAssertEqual(try current.messageBody()?.text, "快看 https://example.com")
        XCTAssertEqual(current.scheduledAt, message.scheduledAt)
        XCTAssertEqual(current.linkPreview?.imageFileName, firstImage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(firstImage).path))

        // 换了网址：新图另存，旧图删掉
        let otherImage = try XCTUnwrap(UIImage.image(color: .systemRed, size: CGSize(square: 20)).pngData())
        let otherDraft = OWSLinkPreviewDraft(url: URL(string: "https://example.org")!, title: "Other", imageData: otherImage, imageMimeType: "image/png", isForwarded: false)
        _ = try await sender.edit(id: message.id, body: MessageBody(text: "https://example.org", ranges: .empty), linkPreviewDraft: otherDraft)
        current = try XCTUnwrap(read { tx in TellomiScheduledMessageStore.fetch(id: message.id, tx: tx) })
        let secondImage = try XCTUnwrap(current.linkPreview?.imageFileName)
        XCTAssertNotEqual(secondImage, firstImage)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(secondImage)), otherImage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(firstImage).path))
        XCTAssertEqual(current.linkPreview?.draft(in: directory).title, "Other")

        // 去掉预览：图也删掉
        _ = try await sender.edit(id: message.id, body: MessageBody(text: "不要预览了", ranges: .empty), linkPreviewDraft: nil)
        current = try XCTUnwrap(read { tx in TellomiScheduledMessageStore.fetch(id: message.id, tx: tx) })
        XCTAssertNil(current.linkPreview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(secondImage).path))

        // 纯文字改成空的：不让
        do {
            _ = try await sender.edit(id: message.id, body: MessageBody(text: "", ranges: .empty), linkPreviewDraft: nil)
            XCTFail("a text-only message can't become empty")
        } catch TellomiScheduledMessageSender.EditError.nothingLeft {
        }

        // 已经发出去（记录没了）
        write { tx in _ = TellomiScheduledMessageStore.remove(id: message.id, tx: tx) }
        let lost = try await sender.edit(id: message.id, body: MessageBody(text: "晚了", ranges: .empty), linkPreviewDraft: nil)
        XCTAssertFalse(lost)
    }

    /// 定时消息页：能发的会话底下有输入框，长按多一项「编辑」（排在复制后面、删除前面，同 TG iOS）；
    /// 编辑时原文进输入框、出「编辑消息」那条，保存后写进记录、收起；纯文字改空了不能存，有图的可以。
    @MainActor
    func testTheScreenEditsAMessage() async throws {
        let thread = makeContactThread()
        let sender = TellomiScheduledMessageSender()
        let message = try await schedule(sender, "原来的字", in: thread, at: Date().addingTimeInterval(3600))
        let screen = TellomiScheduledMessagesViewController(threadUniqueId: thread.uniqueId, thread: thread, isNoteToSelf: false, bubbleColor: nil, sender: sender)
        screen.loadViewIfNeeded()
        let composeBar = try XCTUnwrap(screen.composeBarForTesting)
        XCTAssertEqual(screen.menuElements(for: message, text: "原来的字").map(\.title), ["Send Now", "Reschedule", "Copy", "Edit", "Delete"])

        // 空的时候不能点
        XCTAssertFalse(composeBar.submitButtonForTesting.isEnabled)
        XCTAssertEqual(composeBar.submitButtonForTesting.accessibilityLabel, "Schedule Message")

        // 先写了一半新的，再去改一条：改完放回来
        composeBar.setTextForTesting("写了一半")
        screen.beginEditingForTesting(message)
        XCTAssertEqual(composeBar.editingMessageId, message.id)
        XCTAssertTrue(composeBar.isEditHeaderShownForTesting)
        XCTAssertEqual(composeBar.messageBody.text, "原来的字")
        XCTAssertEqual(composeBar.submitButtonForTesting.accessibilityLabel, CommonStrings.saveButton)
        composeBar.setTextForTesting("")
        XCTAssertFalse(composeBar.canSubmit, "text-only: can't be emptied")
        composeBar.setTextForTesting("改好的字")
        XCTAssertTrue(composeBar.canSubmit)
        composeBar.submitForTesting()
        let saved = await waitUntil {
            (try? self.read { tx in TellomiScheduledMessageStore.fetch(id: message.id, tx: tx) }?.messageBody()?.text) == "改好的字"
        }
        XCTAssertTrue(saved)
        let closed = await waitUntil { composeBar.editingMessageId == nil }
        XCTAssertTrue(closed)
        XCTAssertFalse(composeBar.isEditHeaderShownForTesting)
        XCTAssertEqual(composeBar.messageBody.text, "写了一半", "the half-written new message comes back")
        let stillThere = try XCTUnwrap(read { tx in TellomiScheduledMessageStore.fetch(id: message.id, tx: tx) })
        XCTAssertEqual(stillThere.scheduledAt, message.scheduledAt)

        // 有图的：说明可以删光
        let withPhoto = try await sender.schedule(
            body: MessageBody(text: "说明", ranges: .empty),
            attachments: [try await photo(.systemOrange)],
            isViewOnce: false,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: true,
            at: Date().addingTimeInterval(7200),
        )
        _ = await waitUntil { screen.sectionsForTesting.flatMap(\.messages).count == 2 }
        screen.beginEditingForTesting(withPhoto)
        composeBar.setTextForTesting("")
        XCTAssertTrue(composeBar.canSubmit, "a photo's caption can be removed")
        composeBar.submitForTesting()
        let captionGone = await waitUntil {
            self.read { tx in TellomiScheduledMessageStore.fetch(id: withPhoto.id, tx: tx) }?.body == nil
        }
        XCTAssertTrue(captionGone)
        let photoKept = try XCTUnwrap(read { tx in TellomiScheduledMessageStore.fetch(id: withPhoto.id, tx: tx) })
        XCTAssertEqual(photoKept.attachments.count, 1)
        XCTAssertFalse(photoKept.captionAboveMedia)

        // 改的那条被删了：收起编辑
        screen.beginEditingForTesting(stillThere)
        screen.deleteForTesting(stillThere)
        XCTAssertNil(composeBar.editingMessageId)
    }

    /// 阅后即焚的没有「编辑」（不许带说明）；正在存 / 排时按钮不让点；排新的那会儿开始改另一条，正在改的字不被清掉，
    /// 放在一边的那份（就是刚排的那条）丢掉。
    @MainActor
    func testEditGuards() async throws {
        let thread = makeContactThread()
        let sender = TellomiScheduledMessageSender()
        let viewOnce = try await sender.schedule(
            body: nil,
            attachments: [try await photo(.systemOrange)],
            isViewOnce: true,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: false,
            at: Date().addingTimeInterval(3600),
        )
        let text = try await schedule(sender, "要改的", in: thread, at: Date().addingTimeInterval(7200))
        let screen = TellomiScheduledMessagesViewController(threadUniqueId: thread.uniqueId, thread: thread, isNoteToSelf: false, bubbleColor: nil, sender: sender)
        screen.loadViewIfNeeded()
        XCTAssertEqual(screen.menuElements(for: viewOnce, text: nil).map(\.title), ["Send Now", "Reschedule", "Delete"])
        XCTAssertTrue(screen.menuElements(for: text, text: "要改的").map(\.title).contains("Edit"))

        let composeBar = try XCTUnwrap(screen.composeBarForTesting)
        composeBar.setTextForTesting("新写的")
        composeBar.isBusy = true
        XCTAssertFalse(composeBar.canSubmit)
        XCTAssertFalse(composeBar.submitButtonForTesting.isEnabled)
        composeBar.isBusy = false
        XCTAssertTrue(composeBar.canSubmit)

        screen.beginEditingForTesting(text)
        composeBar.clearAfterSubmit()
        XCTAssertEqual(composeBar.messageBody.text, "要改的", "the text being edited stays")
        composeBar.endEditing()
        XCTAssertEqual(composeBar.messageBody.text, "", "the set-aside draft was the one just scheduled")
    }

    /// 定时消息页底下写新的：选好时间后排进去（同会话页长按发送那条路），输入框清空。
    /// 会话现在不能发（退了群之类）就没有输入框，也没有「编辑」。
    @MainActor
    func testTheScreenSchedulesANewMessage() async throws {
        let thread = makeContactThread()
        let sender = TellomiScheduledMessageSender()
        let screen = TellomiScheduledMessagesViewController(threadUniqueId: thread.uniqueId, thread: thread, isNoteToSelf: false, bubbleColor: nil, sender: sender)
        screen.loadViewIfNeeded()
        let composeBar = try XCTUnwrap(screen.composeBarForTesting)
        composeBar.setTextForTesting("页里写的")
        XCTAssertTrue(composeBar.canSubmit)
        let at = Date().addingTimeInterval(5400)
        await screen.scheduleNewForTesting(body: composeBar.messageBody, at: at)
        let scheduled = read { tx in TellomiScheduledMessageStore.fetchAll(threadUniqueId: thread.uniqueId, tx: tx) }
        XCTAssertEqual(scheduled.map { try? $0.messageBody()?.text }, ["页里写的"])
        XCTAssertEqual(scheduled.first?.scheduledAt, at)
        XCTAssertEqual(composeBar.messageBody.text, "")
        XCTAssertEqual(screen.sectionsForTesting.flatMap(\.messages).map(\.id), scheduled.map(\.id))

        // 没有会话（只读的列表）：没有输入框、没有「编辑」
        let readOnly = TellomiScheduledMessagesViewController(threadUniqueId: thread.uniqueId, isNoteToSelf: false, bubbleColor: nil, sender: sender)
        readOnly.loadViewIfNeeded()
        XCTAssertNil(readOnly.composeBarForTesting)
        let first = try XCTUnwrap(scheduled.first)
        XCTAssertFalse(readOnly.menuElements(for: first, text: "页里写的").map(\.title).contains("Edit"))
    }

    // MARK: - Helpers

    private func record(at date: Date, thread: String = "t", text: String = "x") throws -> TellomiScheduledMessage {
        try TellomiScheduledMessage(
            threadUniqueId: thread,
            scheduledAt: date,
            body: MessageBody(text: text, ranges: .empty),
            attachments: [],
            isViewOnce: false,
            captionAboveMedia: false,
            replyInfo: nil,
            linkPreview: nil,
        )
    }

    @MainActor
    @discardableResult
    private func schedule(_ sender: TellomiScheduledMessageSender, _ text: String, in thread: TSThread, at date: Date) async throws -> TellomiScheduledMessage {
        try await sender.schedule(
            body: MessageBody(text: text, ranges: .empty),
            attachments: [],
            isViewOnce: false,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: false,
            at: date,
        )
    }

    private func makeContactThread() -> TSContactThread {
        write { tx in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
    }

    private func previewablePhoto(_ color: UIColor) throws -> PreviewableAttachment {
        let image = UIImage.image(color: color, size: CGSize(square: 40))
        let url = OWSFileSystem.temporaryFileUrl(fileExtension: "png", isAvailableWhileDeviceLocked: true)
        try XCTUnwrap(image.pngData()).write(to: url)
        return try PreviewableAttachment.imageAttachment(dataSource: DataSourcePath(fileUrl: url, ownership: .owned), dataUTI: UTType.png.identifier)
    }

    private func photo(_ color: UIColor) async throws -> SendableAttachment {
        let image = UIImage.image(color: color, size: CGSize(square: 200))
        let url = OWSFileSystem.temporaryFileUrl(fileExtension: "png", isAvailableWhileDeviceLocked: true)
        try XCTUnwrap(image.pngData()).write(to: url)
        let previewable = try PreviewableAttachment.imageAttachment(dataSource: DataSourcePath(fileUrl: url, ownership: .owned), dataUTI: UTType.png.identifier)
        return try await SendableAttachment.forPreviewableAttachment(previewable, imageQualityLevel: .one)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}
