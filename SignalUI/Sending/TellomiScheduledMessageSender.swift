//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import SignalServiceKit

/// Tellomi（tellomi/tellomi#1519 M-4，方案 `docs/product/specs/scheduled-send-ios-plan.md` §6.2）：定时消息的排定与到点发送（主 App）。
///
/// 和 Signal 安卓一样是「本机尽力而为」（安卓 `ScheduledMessageManager`）：App 在前台时定时器准点发；
/// 在后台或没开时等下次回到前台补发（`applicationDidBecomeActive`，同安卓启动时 `scheduleIfNecessary`）。
/// 后台刷新顺手发、到点通知是下一步（方案 §6.2 / §6.3）。
///
/// 到点发出：用当时的会话建消息（时间戳 = 发出时刻，阅后即焚取当时的设置）；消息建好后在落库的同一个写事务里删定时记录，
/// 谁先删到谁发——崩溃重来、几处同时触发都不会重发，也不会漏。会话删了、退了群、只许管理员发言、拉黑了就不发，
/// 记录删掉、记日志（安卓退群时 `deleteScheduledMessages`，删会话时消息跟着删）。
@MainActor
public final class TellomiScheduledMessageSender {

    public static let shared = TellomiScheduledMessageSender()

    /// 测试换掉。
    var now: () -> Date = { Date() }

    private var timer: Timer?
    private var hasCleanedUpFiles = false
    private var isFlushing = false
    private var needsAnotherFlush = false
    /// 建消息出错的（例如文件坏了、磁盘满）：不反复重试，下次回到前台再试一次；用户可以在定时消息列表里删掉。
    private var failedSinceActivation = Set<String>()

    init() {
        // 一建出来就听：刚注册完还没「回到前台」过时排的也要挂定时器。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange),
            name: TellomiScheduledMessageStore.didChange,
            object: nil,
        )
    }

    // MARK: - Lifecycle

    /// 主 App 每次回到前台（已注册）：补发到点的，重排定时器。第一次还会在后台清掉没有记录的文件。
    public func applicationDidBecomeActive() {
        failedSinceActivation.removeAll()
        if !hasCleanedUpFiles {
            hasCleanedUpFiles = true
            Task.detached(priority: .utility) {
                let cutoff = Date().addingTimeInterval(-10 * .minute)
                SSKEnvironment.shared.databaseStorageRef.read { tx in
                    TellomiScheduledMessageStore.deleteOrphanedDirectories(olderThan: cutoff, tx: tx)
                }
            }
        }
        Task { await flushDue() }
    }

    @objc
    private func storeDidChange() {
        // 通知是异步投到主线程的，可能晚于环境拆掉（只在测试里会这样）。
        guard SSKEnvironment.hasShared else { return }
        scheduleTimer()
    }

    // MARK: - Scheduling

    /// 排一条：附件（已渲染 / 压缩好的）复制到记录自己的目录，记下来。`at` 已过也行：马上发。
    @discardableResult
    public func schedule(
        body: MessageBody?,
        attachments: [SendableAttachment],
        isViewOnce: Bool,
        thread: TSThread,
        quotedReplyDraft: DraftQuotedReplyModel?,
        linkPreviewDraft: OWSLinkPreviewDraft?,
        captionAboveMedia: Bool,
        at date: Date,
    ) async throws -> TellomiScheduledMessage {
        let id = UUID().uuidString
        let directory = TellomiScheduledMessageStore.directory(for: id)
        do {
            let storedAttachments = try await Self.storeFiles(attachments, in: directory)
            let message = try TellomiScheduledMessage(
                id: id,
                threadUniqueId: thread.uniqueId,
                scheduledAt: date,
                body: body?.isEmpty == true ? nil : body,
                attachments: storedAttachments,
                isViewOnce: isViewOnce,
                captionAboveMedia: captionAboveMedia && body?.isEmpty == false,
                replyInfo: quotedReplyDraft.flatMap(Self.replyInfo(for:)),
                linkPreview: linkPreviewDraft.map(TellomiScheduledMessage.LinkPreview.init),
            )
            try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
                try TellomiScheduledMessageStore.insert(message, tx: tx)
            }
            Logger.info("Scheduled a message with \(storedAttachments.count) attachment(s).")
            return message
        } catch {
            try? OWSFileSystem.deleteFileIfExists(url: directory)
            throw error
        }
    }

    @concurrent
    private nonisolated static func storeFiles(_ attachments: [SendableAttachment], in directory: URL) async throws -> [TellomiScheduledMessage.Attachment] {
        guard !attachments.isEmpty else {
            return []
        }
        guard OWSFileSystem.ensureDirectoryExists(directory.path) else {
            throw OWSAssertionError("Couldn't create the scheduled message directory.")
        }
        return try attachments.enumerated().map { index, attachment in
            let fileExtension = attachment.dataSource.fileUrl.pathExtension
            let fileName = fileExtension.isEmpty ? "\(index)" : "\(index).\(fileExtension)"
            let destination = directory.appendingPathComponent(fileName)
            try OWSFileSystem.copyFile(from: attachment.dataSource.fileUrl, to: destination)
            OWSFileSystem.protectFileOrFolder(atPath: destination.path)
            return TellomiScheduledMessage.Attachment(
                fileName: fileName,
                dataUTI: attachment.dataUTI,
                mimeType: attachment.mimeType,
                sourceFilename: attachment.sourceFilename?.rawValue ?? attachment.defaultFilename,
                renderingFlag: attachment.renderingFlag,
            )
        }
    }

    private static func replyInfo(for draft: DraftQuotedReplyModel) -> ThreadReplyInfo? {
        guard let timestamp = draft.originalMessageTimestamp, let aci = draft.originalMessageAuthorAddress.aci else {
            return nil
        }
        return ThreadReplyInfo(timestamp: timestamp, author: aci)
    }

    // MARK: - Sending

    /// 发出到点的（按先后，一条一条）。已经在发的时候又被叫：发完这一轮再看一遍。
    public func flushDue() async {
        guard !isFlushing else {
            needsAnotherFlush = true
            return
        }
        isFlushing = true
        defer {
            isFlushing = false
            scheduleTimer()
        }
        repeat {
            needsAnotherFlush = false
            guard DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
                return
            }
            let due = SSKEnvironment.shared.databaseStorageRef.read { tx in
                TellomiScheduledMessageStore.fetchDue(now: now(), tx: tx)
            }
            for message in due where !failedSinceActivation.contains(message.id) {
                await send(message)
            }
        } while needsAnotherFlush
    }

    private enum Disposition {
        case send(TSThread)
        case discard(String)
    }

    private func send(_ message: TellomiScheduledMessage) async {
        let db = SSKEnvironment.shared.databaseStorageRef
        let now = self.now()
        let disposition = db.read { tx -> Disposition in
            guard let thread = TSThread.anyFetch(uniqueId: message.threadUniqueId, transaction: tx) else {
                return .discard("the chat is gone")
            }
            if let reason = TellomiScheduledMessageStore.reasonNotToSend(to: thread, tx: tx) {
                return .discard(reason)
            }
            let missingFile = message.attachments.contains {
                !OWSFileSystem.fileOrFolderExists(url: TellomiScheduledMessageStore.fileUrl(for: $0, messageId: message.id))
            }
            if missingFile {
                return .discard("its files are missing")
            }
            return .send(thread)
        }

        let thread: TSThread
        switch disposition {
        case .discard(let reason):
            Logger.warn("Dropping a scheduled message: \(reason).")
            _ = await db.awaitableWrite { tx in
                TellomiScheduledMessageStore.remove(id: message.id, tx: tx)
            }
            return
        case .send(let validThread):
            thread = validThread
        }

        do {
            let validator = DependenciesBridge.shared.attachmentContentValidator
            let attachments = try await message.attachments.mapAsync { attachment in
                let dataSource = DataSourcePath(
                    fileUrl: TellomiScheduledMessageStore.fileUrl(for: attachment, messageId: message.id),
                    ownership: .borrowed,
                )
                let pendingAttachment = try await validator.validateDataSourceContents(
                    dataSource,
                    mimeType: attachment.mimeType,
                    renderingFlag: attachment.renderingFlag,
                    sourceFilename: attachment.sourceFilename,
                )
                return SendableAttachment.ForSending(dataSource: .pendingAttachment(pendingAttachment), renderingFlag: attachment.renderingFlag)
            }

            ThreadUtil.addThreadToProfileWhitelistIfEmptyOrPendingRequestAndSetDefaultTimerWithSneakyTransaction(thread)

            let outcome = try await ThreadUtil.tellomiEnqueueScheduledMessage(
                body: try message.messageBody(),
                attachments: attachments,
                isViewOnce: message.isViewOnce,
                thread: thread,
                quotedReplyDraft: message.replyInfo.flatMap(Self.quotedReplyDraft(for:)),
                linkPreviewDraft: message.linkPreview?.draft,
                captionAboveMedia: message.captionAboveMedia,
                claim: ThreadUtil.TellomiEnqueueClaim(
                    isStillDue: { tx in TellomiScheduledMessageStore.isDue(id: message.id, now: now, tx: tx) },
                    claim: { tx in TellomiScheduledMessageStore.remove(id: message.id, tx: tx) },
                ),
            )
            switch outcome {
            case .enqueued:
                Logger.info("Sent a scheduled message.")
            case .notDue:
                Logger.info("A scheduled message was already sent, deleted or moved to later.")
            case .failedToPrepare:
                Logger.warn("Couldn't build a scheduled message; will retry on the next activation.")
                failedSinceActivation.insert(message.id)
            }
        } catch {
            Logger.warn("Couldn't send a scheduled message; will retry on the next activation: \(error)")
            failedSinceActivation.insert(message.id)
        }
    }

    /// 同会话页恢复草稿里的引用（`ConversationViewController.buildDraftQuotedReply`）：按时间戳和作者找原消息。
    private static func quotedReplyDraft(for replyInfo: ThreadReplyInfo) -> DraftQuotedReplyModel? {
        SSKEnvironment.shared.databaseStorageRef.read { tx in
            let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
            let original = try? InteractionFinder.fetchInteractions(timestamp: replyInfo.timestamp, transaction: tx)
                .first { candidate in
                    if let incoming = candidate as? TSIncomingMessage {
                        return incoming.authorAddress.aci == replyInfo.author
                    }
                    return candidate is TSOutgoingMessage && localAci == replyInfo.author
                } as? TSMessage
            guard let original else {
                Logger.info("The message a scheduled message replies to is gone; sending without the quote.")
                return nil
            }
            if original is OWSPaymentMessage {
                return DraftQuotedReplyModel.fromOriginalPaymentMessage(original, tx: tx)
            }
            return DependenciesBridge.shared.quotedReplyManager.buildDraftQuotedReply(
                originalMessage: original,
                loadNormalizedImage: NormalizedImage.loadImage(imageSource:maxPixelSize:),
                tx: tx,
            )
        }
    }

    // MARK: - Timer

    /// 前台定时器挂在最早那一条上（后台时 App 被挂起，回到前台由 `applicationDidBecomeActive` 补）。
    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        // 没注册时 `flushDue` 什么都不发：不挂，免得到点的那条让定时器一直立刻再触发。
        guard DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
            return
        }
        let next = SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiScheduledMessageStore.fetchAll(tx: tx).first { !failedSinceActivation.contains($0.id) }?.scheduledAt
        }
        guard let next else {
            return
        }
        let interval = max(0, next.timeIntervalSince(now()))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.flushDue()
            }
        }
    }

#if TESTABLE_BUILD
    var nextTimerFireDateForTesting: Date? { timer?.fireDate }
#endif
}
