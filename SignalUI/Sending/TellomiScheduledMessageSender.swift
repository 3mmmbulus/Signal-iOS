//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import SignalServiceKit

/// Tellomi（tellomi/tellomi#1519 M-4，方案 `docs/product/specs/scheduled-send-ios-plan.md` §6.2）：定时消息的排定与到点发送（主 App）。
///
/// 和 Signal 安卓一样是「本机尽力而为」（安卓 `ScheduledMessageManager`）：App 在前台时定时器准点发；
/// 在后台时系统后台刷新碰上就发（`MessageFetchBGRefreshTask`，提前到最早那一条）；到点弹本地通知，点它或「立即发送」就发
/// （`TellomiScheduledMessageNotifications`）；都没碰上就等下次回到前台补发（`applicationDidBecomeActive`，同安卓启动时
/// `scheduleIfNecessary`）。
///
/// 到点发出：用当时的会话建消息（时间戳 = 发出时刻，阅后即焚取当时的设置）；消息建好后在落库的同一个写事务里删定时记录，
/// 谁先删到谁发——崩溃重来、几处同时触发都不会重发，也不会漏。会话删了、退了群、只许管理员发言、拉黑了就不发，
/// 记录删掉、记日志（安卓退群时 `deleteScheduledMessages`，删会话时消息跟着删）。
@MainActor
public final class TellomiScheduledMessageSender {

    public static let shared = TellomiScheduledMessageSender(managesNotifications: true)

    /// 测试换掉。
    var now: () -> Date = { Date() }

    private var timer: Timer?
    private var hasCleanedUpFiles = false
    /// 正在发的这一轮；这时又被叫就等它（它发完再看一遍）。
    private var currentFlush: Task<Void, Never>?
    private var needsAnotherFlush = false
    /// 建消息出错的（例如文件坏了、磁盘满）：不反复重试，下次回到前台再试一次；用户可以在定时消息列表里删掉。
    private var failedSinceActivation = Set<String>()

    /// 到点通知是 App 全局的一份，只让 `shared` 管（测试里建的执行器不碰系统通知）。
    private let managesNotifications: Bool

    init(managesNotifications: Bool = false) {
        self.managesNotifications = managesNotifications
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
        syncNotifications()
    }

    /// 改时间（定时消息页）。上次建不成的这次再试（到新时间）。
    public func reschedule(id: String, to date: Date) async {
        do {
            _ = try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
                try TellomiScheduledMessageStore.reschedule(id: id, to: date, tx: tx)
            }
        } catch {
            Logger.warn("Couldn't reschedule a scheduled message: \(error)")
        }
        failedSinceActivation.remove(id)
        scheduleTimer()
    }

    /// 改文字（定时消息页）：换正文和链接预览，到点时刻不变。记录已经没了（刚发出 / 删掉）返回 false。
    /// 预览没变（还是那个网址、那份内容）就沿用原来的图；换了就另存一张新图，改好后删掉旧图。
    public func edit(id: String, body: MessageBody?, linkPreviewDraft: OWSLinkPreviewDraft?) async throws -> Bool {
        let db = SSKEnvironment.shared.databaseStorageRef
        let current = db.read { tx in TellomiScheduledMessageStore.fetch(id: id, tx: tx) }
        guard let current else {
            return false
        }
        guard body?.isEmpty == false || !current.attachments.isEmpty else {
            throw EditError.nothingLeft
        }
        let directory = TellomiScheduledMessageStore.directory(for: id)
        var newImageFileName: String?
        let linkPreview: TellomiScheduledMessage.LinkPreview?
        if let linkPreviewDraft {
            if let existing = current.linkPreview, Self.isSamePreview(existing, linkPreviewDraft) {
                linkPreview = existing
            } else {
                if let imageData = linkPreviewDraft.imageData {
                    guard OWSFileSystem.ensureDirectoryExists(directory.path) else {
                        throw OWSAssertionError("Couldn't create the scheduled message directory.")
                    }
                    let fileName = "link-preview-\(UUID().uuidString)"
                    let url = directory.appendingPathComponent(fileName)
                    try imageData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    OWSFileSystem.protectFileOrFolder(atPath: url.path)
                    newImageFileName = fileName
                }
                linkPreview = TellomiScheduledMessage.LinkPreview(linkPreviewDraft, imageFileName: newImageFileName)
            }
        } else {
            linkPreview = nil
        }
        let old: TellomiScheduledMessage?
        do {
            old = try await db.awaitableWrite { tx in
                try TellomiScheduledMessageStore.edit(id: id, body: body, linkPreview: linkPreview, tx: tx)
            }
        } catch {
            if let newImageFileName {
                try? OWSFileSystem.deleteFileIfExists(url: directory.appendingPathComponent(newImageFileName))
            }
            throw error
        }
        guard let old else {
            // 改的这会儿已经发出去了：新存的图没人用了（目录随记录删掉时已经删了，这里只是保险）
            if let newImageFileName {
                try? OWSFileSystem.deleteFileIfExists(url: directory.appendingPathComponent(newImageFileName))
            }
            return false
        }
        if let oldImageFileName = old.linkPreview?.imageFileName, oldImageFileName != linkPreview?.imageFileName {
            try? OWSFileSystem.deleteFileIfExists(url: directory.appendingPathComponent(oldImageFileName))
        }
        Logger.info("Edited a scheduled message.")
        // 内容换了：上次建不成的这次再试
        failedSinceActivation.remove(id)
        scheduleTimer()
        return true
    }

    public enum EditError: Error {
        /// 纯文字的改成了空的（界面上存不了，这里再挡一次）。
        case nothingLeft
    }

    private static func isSamePreview(_ stored: TellomiScheduledMessage.LinkPreview, _ draft: OWSLinkPreviewDraft) -> Bool {
        stored.url == draft.url
            && stored.title == draft.title
            && stored.previewDescription == draft.previewDescription
            && stored.date == draft.date
            && stored.rich == draft.rich
            && (stored.imageFileName != nil || stored.imageData != nil) == (draft.imageData != nil)
    }

    /// 这个会话还能排几条（到上限 `maxScheduledPerChat` 为止）。
    public static func remainingCapacity(threadUniqueId: String, tx: DBReadTransaction) -> Int {
        max(0, maxScheduledPerChat - TellomiScheduledMessageStore.fetchAll(threadUniqueId: threadUniqueId, tx: tx).count)
    }

    /// 到点通知上点了它或「立即发送」：这一条马上发（还没到点的提前到现在），等它进了发送队列再返回。
    public func sendNow(id: String) async {
        let now = self.now()
        do {
            try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
                if let message = TellomiScheduledMessageStore.fetch(id: id, tx: tx), message.scheduledAt > now {
                    try TellomiScheduledMessageStore.reschedule(id: id, to: now, tx: tx)
                }
            }
        } catch {
            Logger.warn("Couldn't move a scheduled message to now: \(error)")
        }
        failedSinceActivation.remove(id)
        await flushDue()
    }

    @objc
    private func storeDidChange() {
        // 通知是异步投到主线程的，可能晚于环境拆掉（只在测试里会这样）。
        guard SSKEnvironment.hasShared else { return }
        scheduleTimer()
        syncNotifications()
    }

    /// 到点通知对齐记录。几处同时要对齐时排成一个接一个（各自都读最新的记录，最后一次说了算）。
    private var notificationSync: Task<Void, Never>?

    private func syncNotifications() {
        guard managesNotifications else { return }
        let previous = notificationSync
        notificationSync = Task {
            await previous?.value
            await TellomiScheduledMessageNotifications.sync()
        }
    }

    // MARK: - Scheduling

    /// 一个会话最多排这么多条（同 Telegram：服务器上限 100，两端都提示 `MessageScheduledLimitReached`）。
    public nonisolated static let maxScheduledPerChat = 100

    public enum ScheduleError: Error, LocalizedError {
        case tooManyScheduled

        public var errorDescription: String? {
            String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "TELLOMI_SCHEDULED_MESSAGES_LIMIT_REACHED_FORMAT",
                    comment: "Alert when a chat already has the maximum number of scheduled messages. Embeds {{the maximum, e.g. 100}}.",
                ),
                OWSFormat.formatInt(TellomiScheduledMessageSender.maxScheduledPerChat),
            )
        }
    }

    /// 排一条：附件（已渲染 / 压缩好的）复制到记录自己的目录，记下来。`at` 已过也行：马上发。
    /// 这个会话已经排满 `maxScheduledPerChat` 条时抛 `ScheduleError.tooManyScheduled`。
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
        let threadUniqueId = thread.uniqueId
        let capacity = SSKEnvironment.shared.databaseStorageRef.read { tx in
            Self.remainingCapacity(threadUniqueId: threadUniqueId, tx: tx)
        }
        guard capacity > 0 else {
            throw ScheduleError.tooManyScheduled
        }
        let id = UUID().uuidString
        let directory = TellomiScheduledMessageStore.directory(for: id)
        do {
            let storedAttachments = try await Self.storeFiles(attachments, in: directory)
            var linkPreviewImageFileName: String?
            if let imageData = linkPreviewDraft?.imageData {
                guard OWSFileSystem.ensureDirectoryExists(directory.path) else {
                    throw OWSAssertionError("Couldn't create the scheduled message directory.")
                }
                let fileName = "link-preview"
                let url = directory.appendingPathComponent(fileName)
                try imageData.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
                OWSFileSystem.protectFileOrFolder(atPath: url.path)
                linkPreviewImageFileName = fileName
            }
            let message = try TellomiScheduledMessage(
                id: id,
                threadUniqueId: thread.uniqueId,
                scheduledAt: date,
                body: body?.isEmpty == true ? nil : body,
                attachments: storedAttachments,
                isViewOnce: isViewOnce,
                captionAboveMedia: captionAboveMedia && body?.isEmpty == false,
                replyInfo: quotedReplyDraft.flatMap(Self.replyInfo(for:)),
                linkPreview: linkPreviewDraft.map { TellomiScheduledMessage.LinkPreview($0, imageFileName: linkPreviewImageFileName) },
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
            // Tellomi（ADR-0068 §4.4）：实况的动态部分也存一份，到点照样两段发。
            var liveFileName: String?
            if let live = attachment.tellomiLivePhotoVideo {
                let name = "\(index).live.mp4"
                let liveDestination = directory.appendingPathComponent(name)
                try OWSFileSystem.copyFile(from: live, to: liveDestination)
                OWSFileSystem.protectFileOrFolder(atPath: liveDestination.path)
                liveFileName = name
            }
            return TellomiScheduledMessage.Attachment(
                fileName: fileName,
                dataUTI: attachment.dataUTI,
                mimeType: attachment.mimeType,
                sourceFilename: attachment.sourceFilename?.rawValue ?? attachment.defaultFilename,
                renderingFlag: attachment.renderingFlag,
                tellomiSpoiler: attachment.isTellomiSpoiler,
                tellomiLiveFileName: liveFileName,
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

    /// 发出到点的（按先后，一条一条）。已经在发的时候又被叫：等这一轮，它发完再看一遍。
    /// 返回时到点的都已进了发送队列（或丢掉 / 记为失败）：后台刷新、「立即发送」接着等发送队列发完。
    /// 调用方被取消（后台刷新、通知动作的 27 秒限时到了）就停在两条之间：没发的还到点，下次再发（认领保证不重不漏）。
    public func flushDue() async {
        if let currentFlush {
            needsAnotherFlush = true
            await Self.wait(for: currentFlush)
            return
        }
        let flush = Task { @MainActor in
            defer {
                currentFlush = nil
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
                    guard !Task.isCancelled else { return }
                    await send(message)
                }
            } while needsAnotherFlush && !Task.isCancelled
        }
        currentFlush = flush
        await Self.wait(for: flush)
    }

    private static func wait(for flush: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await flush.value
        } onCancel: {
            flush.cancel()
        }
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
                return SendableAttachment.ForSending(
                    dataSource: .pendingAttachment(pendingAttachment),
                    renderingFlag: attachment.renderingFlag,
                    isTellomiSpoiler: attachment.isTellomiSpoiler,
                    tellomiLivePhotoVideo: TellomiScheduledMessageStore.liveVideoUrl(for: attachment, messageId: message.id),
                )
            }

            ThreadUtil.addThreadToProfileWhitelistIfEmptyOrPendingRequestAndSetDefaultTimerWithSneakyTransaction(thread)

            let outcome = try await ThreadUtil.tellomiEnqueueScheduledMessage(
                body: try message.messageBody(),
                attachments: attachments,
                isViewOnce: message.isViewOnce,
                thread: thread,
                quotedReplyDraft: message.replyInfo.flatMap(Self.quotedReplyDraft(for:)),
                linkPreviewDraft: message.linkPreview?.draft(in: TellomiScheduledMessageStore.directory(for: message.id)),
                captionAboveMedia: message.captionAboveMedia,
                claim: ThreadUtil.TellomiEnqueueClaim(
                    isStillDue: { tx in TellomiScheduledMessageStore.isStillDue(message, now: now, tx: tx) },
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
