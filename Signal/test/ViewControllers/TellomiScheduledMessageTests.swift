//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import UniformTypeIdentifiers
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1519 M-4，方案 §6.1 / §6.2）：定时消息的记录、到点发送、认领防重发、删会话 / 退群 / 拉黑时丢弃。
final class TellomiScheduledMessageTests: SignalBaseTest {

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

    // MARK: - Store

    func testRecordsComeOutInTimeOrderAndOnlyDueOnesAreDue() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let later = try record(thread: "a", at: base.addingTimeInterval(60), createdAt: base)
        let firstOfTwo = try record(thread: "a", at: base, createdAt: base.addingTimeInterval(1))
        let secondOfTwo = try record(thread: "b", at: base, createdAt: base.addingTimeInterval(2))
        try write { tx in
            for message in [later, secondOfTwo, firstOfTwo] {
                try TellomiScheduledMessageStore.insert(message, tx: tx)
            }
        }

        read { tx in
            XCTAssertEqual(TellomiScheduledMessageStore.fetchAll(tx: tx).map(\.id), [firstOfTwo.id, secondOfTwo.id, later.id])
            XCTAssertEqual(TellomiScheduledMessageStore.fetchDue(now: base.addingTimeInterval(59), tx: tx).map(\.id), [firstOfTwo.id, secondOfTwo.id])
            XCTAssertEqual(TellomiScheduledMessageStore.fetchDue(now: base.addingTimeInterval(-1), tx: tx), [])
            XCTAssertEqual(TellomiScheduledMessageStore.nextScheduledAt(tx: tx), base)
            XCTAssertEqual(TellomiScheduledMessageStore.fetchAll(threadUniqueId: "a", tx: tx).map(\.id), [firstOfTwo.id, later.id])
            XCTAssertEqual(TellomiScheduledMessageStore.fetch(id: later.id, tx: tx), later)
        }
    }

    /// 删记录 = 认领：只有第一次成功；文件在事务提交后删掉。
    func testRemovingIsAOneTimeClaimAndDeletesTheFiles() throws {
        let message = try record(thread: "a", at: Date())
        let directory = TellomiScheduledMessageStore.directory(for: message.id)
        XCTAssertTrue(OWSFileSystem.ensureDirectoryExists(directory.path))
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("0.bin"))
        try write { tx in try TellomiScheduledMessageStore.insert(message, tx: tx) }

        XCTAssertTrue(write { tx in TellomiScheduledMessageStore.remove(id: message.id, tx: tx) })
        XCTAssertFalse(write { tx in TellomiScheduledMessageStore.remove(id: message.id, tx: tx) })
        XCTAssertFalse(OWSFileSystem.fileOrFolderExists(url: directory))
    }

    func testOrphanedDirectoriesAreDeleted() throws {
        let kept = try record(thread: "a", at: Date())
        try write { tx in try TellomiScheduledMessageStore.insert(kept, tx: tx) }
        let keptDirectory = TellomiScheduledMessageStore.directory(for: kept.id)
        let orphan = TellomiScheduledMessageStore.directory(for: UUID().uuidString)
        XCTAssertTrue(OWSFileSystem.ensureDirectoryExists(keptDirectory.path))
        XCTAssertTrue(OWSFileSystem.ensureDirectoryExists(orphan.path))

        // 刚建的目录默认不动（可能正在排）；截止时间放到以后，两个都算旧的。
        read { tx in TellomiScheduledMessageStore.deleteOrphanedDirectories(olderThan: Date().addingTimeInterval(-60), tx: tx) }
        XCTAssertTrue(OWSFileSystem.fileOrFolderExists(url: orphan))
        read { tx in TellomiScheduledMessageStore.deleteOrphanedDirectories(olderThan: Date().addingTimeInterval(60), tx: tx) }

        XCTAssertTrue(OWSFileSystem.fileOrFolderExists(url: keptDirectory))
        XCTAssertFalse(OWSFileSystem.fileOrFolderExists(url: orphan))
    }

    /// 会话合并：定时消息跟着去合并后的会话。
    func testMergingChatsMovesTheirScheduledMessages() throws {
        let message = try record(thread: "old", at: Date())
        let other = try record(thread: "other", at: Date())
        try write { tx in
            try TellomiScheduledMessageStore.insert(message, tx: tx)
            try TellomiScheduledMessageStore.insert(other, tx: tx)
            TellomiScheduledMessageStore.moveAll(fromThreadUniqueId: "old", toThreadUniqueId: "new", tx: tx)
        }
        read { tx in
            XCTAssertEqual(TellomiScheduledMessageStore.fetchAll(threadUniqueId: "new", tx: tx).map(\.id), [message.id])
            XCTAssertEqual(TellomiScheduledMessageStore.fetchAll(threadUniqueId: "old", tx: tx), [])
            XCTAssertEqual(TellomiScheduledMessageStore.fetchAll(threadUniqueId: "other", tx: tx).map(\.id), [other.id])
        }
    }

    // MARK: - Sending

    /// 排一条带图带 @ 样式的，到点发出：会话里出现一条外发消息，时间戳是发出时刻（不是排定时），图在，记录和文件没了。
    @MainActor
    func testADueMessageIsSentWithAFreshTimestampAndItsRecordIsGone() async throws {
        let thread = makeContactThread()
        let sender = makeSender()
        let body = MessageBody(text: "到点了", ranges: MessageBodyRanges(mentions: [], styles: [NSRangedValue(.bold, range: NSRange(location: 0, length: 2))]))
        let scheduledAt = Date().addingTimeInterval(3600)
        let message = try await sender.schedule(
            body: body,
            attachments: [try await photo()],
            isViewOnce: false,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: true,
            at: scheduledAt,
        )
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertTrue(OWSFileSystem.fileOrFolderExists(url: TellomiScheduledMessageStore.fileUrl(for: message.attachments[0], messageId: message.id)))
        XCTAssertTrue(outgoingMessages(in: thread).isEmpty, "nothing in the chat until it's sent")

        // 还没到点：不发。
        await sender.flushDue()
        XCTAssertTrue(outgoingMessages(in: thread).isEmpty)

        // 到点。
        sender.now = { Date().addingTimeInterval(3601) }
        let beforeSending = Date.ows_millisecondTimestamp()
        await sender.flushDue()

        let sent = try XCTUnwrap(outgoingMessages(in: thread).first)
        XCTAssertEqual(outgoingMessages(in: thread).count, 1)
        XCTAssertEqual(sent.body, "到点了")
        XCTAssertEqual(sent.bodyRanges?.collapsedStyles.count, 1)
        XCTAssertGreaterThanOrEqual(sent.timestamp, beforeSending)
        XCTAssertLessThan(sent.timestamp, scheduledAt.ows_millisecondsSince1970, "not the scheduled time")
        read { tx in
            let references = DependenciesBridge.shared.attachmentStore.fetchReferences(
                owner: .messageBodyAttachment(messageRowId: sent.sqliteRowId!),
                tx: tx,
            )
            XCTAssertEqual(references.count, 1)
            XCTAssertTrue(TellomiCaptionAbove.isCaptionAboveMedia(messageUniqueId: sent.uniqueId, tx: tx))
            XCTAssertEqual(TellomiScheduledMessageStore.fetchAll(tx: tx), [])
        }
        XCTAssertFalse(OWSFileSystem.fileOrFolderExists(url: TellomiScheduledMessageStore.directory(for: message.id)))
    }

    /// 两处同时发同一条（例如定时器和回到前台）：只发出一条。
    @MainActor
    func testTwoSendersRacingForTheSameMessageSendItOnce() async throws {
        let thread = makeContactThread()
        let first = makeSender()
        let second = makeSender()
        try await first.schedule(
            body: MessageBody(text: "只发一次", ranges: .empty),
            attachments: [],
            isViewOnce: false,
            thread: thread,
            quotedReplyDraft: nil,
            linkPreviewDraft: nil,
            captionAboveMedia: false,
            at: Date().addingTimeInterval(-1),
        )

        async let a: Void = first.flushDue()
        async let b: Void = second.flushDue()
        _ = await (a, b)

        XCTAssertEqual(outgoingMessages(in: thread).map(\.body), ["只发一次"])
        XCTAssertEqual(read { tx in TellomiScheduledMessageStore.fetchAll(tx: tx) }, [])
    }

    /// 同一条认领两次：第一次发出、删记录；第二次（记录没了）不落库。改到以后的也不发。
    @MainActor
    func testTheClaimSendsOnceAndRespectsAReschedule() async throws {
        // 不建执行器（它听到记录变化会自己去发）：直接写记录，只测认领。
        let thread = makeContactThread()
        let message = try record(thread: thread.uniqueId, at: Date().addingTimeInterval(-1), text: "只发一次")
        let moved = try record(thread: thread.uniqueId, at: Date().addingTimeInterval(-1), text: "改到以后")
        try write { tx in
            try TellomiScheduledMessageStore.insert(message, tx: tx)
            try TellomiScheduledMessageStore.insert(moved, tx: tx)
            XCTAssertTrue(try TellomiScheduledMessageStore.reschedule(id: moved.id, to: Date().addingTimeInterval(3600), tx: tx))
        }

        func enqueue(_ message: TellomiScheduledMessage) async throws -> ThreadUtil.TellomiEnqueueOutcome {
            try await ThreadUtil.tellomiEnqueueScheduledMessage(
                body: try message.messageBody(),
                attachments: [],
                isViewOnce: false,
                thread: thread,
                quotedReplyDraft: nil,
                linkPreviewDraft: nil,
                captionAboveMedia: false,
                claim: ThreadUtil.TellomiEnqueueClaim(
                    isStillDue: { tx in TellomiScheduledMessageStore.isDue(id: message.id, now: Date(), tx: tx) },
                    claim: { tx in TellomiScheduledMessageStore.remove(id: message.id, tx: tx) },
                ),
            )
        }
        let first = try await enqueue(message)
        let second = try await enqueue(message)
        let rescheduled = try await enqueue(moved)
        XCTAssertEqual(first, .enqueued)
        XCTAssertEqual(second, .notDue)
        XCTAssertEqual(rescheduled, .notDue)

        XCTAssertEqual(outgoingMessages(in: thread).map(\.body), ["只发一次"])
        XCTAssertEqual(read { tx in TellomiScheduledMessageStore.fetchAll(tx: tx).map(\.id) }, [moved.id])
    }

    /// 删会话：定时消息跟着删。退群、拉黑：到点不发，记录删掉。
    @MainActor
    func testDeletedChatsLeftGroupsAndBlockedChatsDropTheirMessages() async throws {
        let sender = makeSender()
        let deleted = makeContactThread()
        let blocked = makeContactThread()
        let leftGroup = makeGroupThread(includingMe: false)
        let kept = makeContactThread()
        for thread in [deleted, blocked, leftGroup, kept] {
            try await sender.schedule(
                body: MessageBody(text: "定时", ranges: .empty),
                attachments: [],
                isViewOnce: false,
                thread: thread,
                quotedReplyDraft: nil,
                linkPreviewDraft: nil,
                captionAboveMedia: false,
                at: Date().addingTimeInterval(3600),
            )
        }

        write { tx in
            DependenciesBridge.shared.threadDeletionManager.deleteThreads(
                [deleted],
                sendDeleteForMeSyncMessage: false,
                updateStorageService: false,
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
            SSKEnvironment.shared.blockingManagerRef.addBlockedThread(blocked, blockMode: .local, transaction: tx)
        }
        XCTAssertEqual(read { tx in TellomiScheduledMessageStore.fetchAll(tx: tx).map(\.threadUniqueId) }.sorted(), [blocked, leftGroup, kept].map(\.uniqueId).sorted())

        sender.now = { Date().addingTimeInterval(3601) }
        await sender.flushDue()

        XCTAssertTrue(outgoingMessages(in: blocked).isEmpty)
        XCTAssertTrue(outgoingMessages(in: leftGroup).isEmpty)
        XCTAssertEqual(outgoingMessages(in: kept).map(\.body), ["定时"])
        XCTAssertEqual(read { tx in TellomiScheduledMessageStore.fetchAll(tx: tx) }, [])
    }

    /// 前台定时器：排了就挂在最早那一条上（记录变化的通知挂的，不用先「回到前台」）；发完挂下一条。
    @MainActor
    func testTheTimerWaitsForTheEarliestMessage() async throws {
        let thread = makeContactThread()
        let sender = makeSender()
        let soon = Date().addingTimeInterval(600)
        let later = Date().addingTimeInterval(1200)
        for date in [later, soon] {
            try await sender.schedule(
                body: MessageBody(text: "定时", ranges: .empty),
                attachments: [],
                isViewOnce: false,
                thread: thread,
                quotedReplyDraft: nil,
                linkPreviewDraft: nil,
                captionAboveMedia: false,
                at: date,
            )
        }
        // 通知是异步发到主线程的：让出主线程等它到（最多 5 秒）。
        var waited: TimeInterval = 0
        while sender.nextTimerFireDateForTesting.map({ abs($0.timeIntervalSince(soon)) >= 2 }) ?? true, waited < 5 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
        XCTAssertEqual(try XCTUnwrap(sender.nextTimerFireDateForTesting).timeIntervalSince(soon), 0, accuracy: 2)

        sender.now = { soon.addingTimeInterval(1) }
        await sender.flushDue()
        XCTAssertEqual(outgoingMessages(in: thread).count, 1)
        // 测试里的「现在」是 soon + 1 秒，离 later 还有 599 秒；定时器按真实时间挂。
        let expectedFireDate = Date().addingTimeInterval(later.timeIntervalSince(soon) - 1)
        XCTAssertEqual(try XCTUnwrap(sender.nextTimerFireDateForTesting).timeIntervalSince(expectedFireDate), 0, accuracy: 2)
    }

    // MARK: - Helpers

    private func record(thread: String, at date: Date, createdAt: Date = Date(), text: String = "x") throws -> TellomiScheduledMessage {
        try TellomiScheduledMessage(
            threadUniqueId: thread,
            scheduledAt: date,
            createdAt: createdAt,
            body: MessageBody(text: text, ranges: .empty),
            attachments: [],
            isViewOnce: false,
            captionAboveMedia: false,
            replyInfo: nil,
            linkPreview: nil,
        )
    }

    @MainActor
    private func makeSender() -> TellomiScheduledMessageSender {
        TellomiScheduledMessageSender()
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

    private func makeGroupThread(includingMe: Bool) -> TSGroupThread {
        write { tx in
            let other = SignalServiceAddress(Aci.randomForTesting())
            let members = includingMe ? [LocalIdentifiers.forUnitTests.aciAddress, other] : [other]
            return try! GroupManager.createGroupForTests(members: members, shouldInsertInfoMessage: false, name: "群", transaction: tx)
        }
    }

    private func outgoingMessages(in thread: TSThread) -> [TSOutgoingMessage] {
        read { tx in
            let interactions = (try? InteractionFinder(threadUniqueId: thread.uniqueId).fetchAllInteractions(rowIdFilter: .newest, limit: 100, tx: tx)) ?? []
            return interactions.compactMap { $0 as? TSOutgoingMessage }
        }
    }

    private func photo() async throws -> SendableAttachment {
        let image = UIImage.image(color: .orange, size: CGSize(square: 40))
        let url = OWSFileSystem.temporaryFileUrl(fileExtension: "png", isAvailableWhileDeviceLocked: true)
        try XCTUnwrap(image.pngData()).write(to: url)
        let previewable = try PreviewableAttachment.imageAttachment(dataSource: DataSourcePath(fileUrl: url, ownership: .owned), dataUTI: UTType.png.identifier)
        return try await SendableAttachment.forPreviewableAttachment(previewable, imageQualityLevel: .one)
    }
}
