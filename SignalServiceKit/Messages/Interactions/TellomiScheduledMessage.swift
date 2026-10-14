//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（tellomi/tellomi#1519 M-4，方案 `docs/product/specs/scheduled-send-ios-plan.md` §6.1）：一条还没发出去的定时消息。
///
/// 不是会话里的消息：到点才用当时的会话生成真正的外发消息（时间戳 = 实际发出时刻，阅后即焚取当时的设置，同安卓
/// `MessageTable.clearScheduledStatus`）。所以会话、未读、搜索、备份都看不到它，不用到处加过滤。
/// 附件在排定时已经渲染 / 压缩完，文件复制在 `TellomiScheduledMessageStore.directory(for:)` 里。
public struct TellomiScheduledMessage: Codable, Equatable {

    public struct Attachment: Codable, Equatable {
        /// 记录目录里的文件名。
        public let fileName: String
        public let dataUTI: String
        public let mimeType: String
        public let sourceFilename: String?
        public let renderingFlag: AttachmentReference.RenderingFlag

        public init(fileName: String, dataUTI: String, mimeType: String, sourceFilename: String?, renderingFlag: AttachmentReference.RenderingFlag) {
            self.fileName = fileName
            self.dataUTI = dataUTI
            self.mimeType = mimeType
            self.sourceFilename = sourceFilename
            self.renderingFlag = renderingFlag
        }
    }

    /// `OWSLinkPreviewDraft` 的字段（排定时已经取好，到点不再上网取）。预览图另存成记录目录里的文件（`imageFileName`），
    /// 不放进记录：每次读记录都要解码整条。
    public struct LinkPreview: Codable, Equatable {
        public let url: URL
        public let title: String?
        /// 旧格式才有（图放在记录里）；新排的是 nil、图在 `imageFileName`。
        public let imageData: Data?
        public let imageFileName: String?
        public let imageMimeType: String?
        public let previewDescription: String?
        public let date: Date?
        public let isForwarded: Bool
        public let rich: Data?

        public init(_ draft: OWSLinkPreviewDraft, imageFileName: String?) {
            url = draft.url
            title = draft.title
            imageData = nil
            self.imageFileName = draft.imageData == nil ? nil : imageFileName
            imageMimeType = draft.imageMimeType
            previewDescription = draft.previewDescription
            date = draft.date
            isForwarded = draft.isForwarded
            rich = draft.rich
        }

        /// - Parameter directory: 这条记录的目录（预览图文件在里面）。
        public func draft(in directory: URL) -> OWSLinkPreviewDraft {
            let fileData = imageFileName.flatMap { try? Data(contentsOf: directory.appendingPathComponent($0)) }
            return OWSLinkPreviewDraft(
                url: url,
                title: title,
                imageData: fileData ?? imageData,
                imageMimeType: imageMimeType,
                previewDescription: previewDescription,
                date: date,
                isForwarded: isForwarded,
                rich: rich,
            )
        }
    }

    public let id: String
    /// 会话合并时（`ThreadMerger`）改成合并后的会话。
    public var threadUniqueId: String
    public var scheduledAt: Date
    /// 同一时刻排了几条（例如「单独发送」拆开的）时按它排先后。
    public let createdAt: Date
    /// `MessageBody`（文字 + @ / 样式）按 NSSecureCoding 归档。
    public let body: Data?
    public let attachments: [Attachment]
    public let isViewOnce: Bool
    public let captionAboveMedia: Bool
    /// 引用回复：到点按它在会话里重新找原消息（同上游草稿的 `ThreadReplyInfo`）；原消息没了就不带引用。
    public let replyInfo: ThreadReplyInfo?
    public let linkPreview: LinkPreview?

    public init(
        id: String = UUID().uuidString,
        threadUniqueId: String,
        scheduledAt: Date,
        createdAt: Date = Date(),
        body: MessageBody?,
        attachments: [Attachment],
        isViewOnce: Bool,
        captionAboveMedia: Bool,
        replyInfo: ThreadReplyInfo?,
        linkPreview: LinkPreview?,
    ) throws {
        self.id = id
        self.threadUniqueId = threadUniqueId
        self.scheduledAt = scheduledAt
        self.createdAt = createdAt
        self.body = try body.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        self.attachments = attachments
        self.isViewOnce = isViewOnce
        self.captionAboveMedia = captionAboveMedia
        self.replyInfo = replyInfo
        self.linkPreview = linkPreview
    }

    public func messageBody() throws -> MessageBody? {
        guard let body else { return nil }
        guard let messageBody = try NSKeyedUnarchiver.unarchivedObject(ofClass: MessageBody.self, from: body) else {
            throw OWSAssertionError("Couldn't decode the scheduled message body.")
        }
        return messageBody
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.threadUniqueId == rhs.threadUniqueId
            && lhs.scheduledAt == rhs.scheduledAt
            && lhs.createdAt == rhs.createdAt
            && lhs.body == rhs.body
            && lhs.attachments == rhs.attachments
            && lhs.isViewOnce == rhs.isViewOnce
            && lhs.captionAboveMedia == rhs.captionAboveMedia
            && lhs.replyInfo?.timestamp == rhs.replyInfo?.timestamp
            && lhs.replyInfo?.author == rhs.replyInfo?.author
            && lhs.linkPreview == rhs.linkPreview
    }
}

/// Tellomi（#1519 M-4）：定时消息的记录（KeyValueStore 一个 collection，键 = id）和附件文件（共享容器 `TellomiScheduled/<id>/`）。
///
/// 只在这台 iPhone 上（同安卓）：文件不进 iCloud 备份，记录不进 Signal 备份（备份只导出会话里的消息）。
/// 改动在事务提交后发 `didChange`，执行器据此重排定时器、界面据此刷新。
public enum TellomiScheduledMessageStore {

    public static let didChange = Notification.Name("TellomiScheduledMessageStoreDidChange")
    /// `didChange` 的 userInfo 里：这次变了的会话（`Set<String>`）。会话页、定时消息页只管自己会话的。
    public static let changedThreadUniqueIdsKey = "TellomiScheduledMessageChangedThreadUniqueIds"

    /// 这次的变化和这个会话有没有关系（没带会话的一律算有关）。
    public static func didChange(_ notification: Notification, affect threadUniqueId: String) -> Bool {
        guard let changed = notification.userInfo?[changedThreadUniqueIdsKey] as? Set<String> else {
            return true
        }
        return changed.contains(threadUniqueId)
    }

    private static let store = KeyValueStore(collection: "TellomiScheduledMessage")

    public static func rootDirectory() -> URL {
        OWSFileSystem.appSharedDataDirectoryURL().appendingPathComponent("TellomiScheduled", isDirectory: true)
    }

    public static func directory(for id: String) -> URL {
        rootDirectory().appendingPathComponent(id, isDirectory: true)
    }

    public static func fileUrl(for attachment: TellomiScheduledMessage.Attachment, messageId: String) -> URL {
        directory(for: messageId).appendingPathComponent(attachment.fileName)
    }

    // MARK: - Reads

    /// 全部，按到点时刻（再按排定先后）排好。读不出来的那条跳过（记日志），不连累别的。
    public static func fetchAll(tx: DBReadTransaction) -> [TellomiScheduledMessage] {
        let messages = store.allKeys(transaction: tx).compactMap { key -> TellomiScheduledMessage? in
            do {
                return try store.getCodableValue(forKey: key, failDebugOnParseError: false, transaction: tx)
            } catch {
                Logger.warn("Skipping an unreadable scheduled message: \(error)")
                return nil
            }
        }
        return messages.sorted { lhs, rhs in
            if lhs.scheduledAt != rhs.scheduledAt {
                return lhs.scheduledAt < rhs.scheduledAt
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    public static func fetch(id: String, tx: DBReadTransaction) -> TellomiScheduledMessage? {
        do {
            return try store.getCodableValue(forKey: id, failDebugOnParseError: false, transaction: tx)
        } catch {
            Logger.warn("Couldn't read a scheduled message: \(error)")
            return nil
        }
    }

    /// 发送前最后确认（到点发送在落库的写事务里调）：记录还在，而且没被改到以后。
    public static func isDue(id: String, now: Date, tx: DBReadTransaction) -> Bool {
        guard let message = fetch(id: id, tx: tx) else {
            return false
        }
        return message.scheduledAt <= now
    }

    /// 到点时这个会话还能不能发；不能就说为什么（记日志用），这条丢掉。
    /// 同上游输入框能不能发（`canSendChatMessagesToThread`：退了群、群解散、只许管理员发言、旧版群、Signal 官方会话），加上拉黑。
    public static func reasonNotToSend(to thread: TSThread, tx: DBReadTransaction) -> String? {
        if !thread.canSendChatMessagesToThread() {
            return "the chat doesn't allow sending"
        }
        if SSKEnvironment.shared.blockingManagerRef.isThreadBlocked(thread, transaction: tx) {
            return "the chat is blocked"
        }
        return nil
    }

    /// 到点（`scheduledAt ≤ now`）的，按先后。
    public static func fetchDue(now: Date, tx: DBReadTransaction) -> [TellomiScheduledMessage] {
        fetchAll(tx: tx).filter { $0.scheduledAt <= now }
    }

    public static func nextScheduledAt(tx: DBReadTransaction) -> Date? {
        fetchAll(tx: tx).first?.scheduledAt
    }

    public static func fetchAll(threadUniqueId: String, tx: DBReadTransaction) -> [TellomiScheduledMessage] {
        fetchAll(tx: tx).filter { $0.threadUniqueId == threadUniqueId }
    }

    // MARK: - Writes

    /// 记下一条（文件要先放进 `directory(for:)`）。
    public static func insert(_ message: TellomiScheduledMessage, tx: DBWriteTransaction) throws {
        try store.setCodable(message, key: message.id, transaction: tx)
        postDidChange(threadUniqueIds: [message.threadUniqueId], tx: tx)
    }

    /// 改到点时刻。记录已经没了（发出 / 删掉）返回 false。
    @discardableResult
    public static func reschedule(id: String, to date: Date, tx: DBWriteTransaction) throws -> Bool {
        guard var message = fetch(id: id, tx: tx) else {
            return false
        }
        message.scheduledAt = date
        try store.setCodable(message, key: id, transaction: tx)
        postDidChange(threadUniqueIds: [message.threadUniqueId], tx: tx)
        return true
    }

    /// 删掉记录；事务提交后删文件。记录本来就没有返回 false——到点发送用它「认领」：和消息落库在同一个写事务里，
    /// 谁先删到谁发，崩溃重来、几处同时触发都不会重发。
    @discardableResult
    public static func remove(id: String, tx: DBWriteTransaction) -> Bool {
        guard store.hasValue(id, transaction: tx) else {
            return false
        }
        let threadUniqueId = fetch(id: id, tx: tx)?.threadUniqueId
        store.removeValue(forKey: id, transaction: tx)
        tx.addSyncCompletion {
            deleteDirectory(id: id)
        }
        postDidChange(threadUniqueIds: threadUniqueId.map { [$0] }, tx: tx)
        return true
    }

    /// 删会话时一起删（同安卓：定时消息就在会话的消息表里，跟着会话删）。
    public static func removeAll(threadUniqueId: String, tx: DBWriteTransaction) {
        let ids = fetchAll(threadUniqueId: threadUniqueId, tx: tx).map(\.id)
        guard !ids.isEmpty else { return }
        Logger.info("Removing \(ids.count) scheduled message(s) of a deleted chat.")
        for id in ids {
            remove(id: id, tx: tx)
        }
    }

    /// 会话合并（号码 / PNI 的会话并进 ACI 的会话）：定时消息跟着去合并后的会话（同上游 `mergeThreadReplyInfo`）。
    public static func moveAll(fromThreadUniqueId: String, toThreadUniqueId: String, tx: DBWriteTransaction) {
        let messages = fetchAll(threadUniqueId: fromThreadUniqueId, tx: tx)
        guard !messages.isEmpty else { return }
        for var message in messages {
            message.threadUniqueId = toThreadUniqueId
            do {
                try store.setCodable(message, key: message.id, transaction: tx)
            } catch {
                owsFailDebug("Couldn't move a scheduled message: \(error)")
            }
        }
        postDidChange(threadUniqueIds: [fromThreadUniqueId, toThreadUniqueId], tx: tx)
    }

    /// 没有记录的目录（删记录后、删文件前崩了，或排定时写了文件、没写成记录）：启动时清掉。
    /// 刚建不久的不动：可能正在排（文件已复制、记录还没写）。
    public static func deleteOrphanedDirectories(olderThan cutoff: Date, tx: DBReadTransaction) {
        let ids = Set(store.allKeys(transaction: tx))
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: rootDirectory(), includingPropertiesForKeys: [.creationDateKey])
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return
        } catch {
            Logger.warn("Couldn't list scheduled message files: \(error)")
            return
        }
        for url in contents where !ids.contains(url.lastPathComponent) {
            let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let createdAt, createdAt > cutoff {
                continue
            }
            Logger.info("Deleting orphaned scheduled message files.")
            deleteDirectory(url)
        }
    }

    private static func deleteDirectory(id: String) {
        deleteDirectory(directory(for: id))
    }

    private static func deleteDirectory(_ url: URL) {
        do {
            try OWSFileSystem.deleteFileIfExists(url: url)
        } catch {
            Logger.warn("Couldn't delete scheduled message files: \(error)")
        }
    }

    /// `threadUniqueIds` 为 nil：不知道是哪个会话（读不出来的记录），所有人都当和自己有关。
    private static func postDidChange(threadUniqueIds: Set<String>?, tx: DBWriteTransaction) {
        tx.addSyncCompletion {
            let userInfo = threadUniqueIds.map { [changedThreadUniqueIdsKey: $0] }
            NotificationCenter.default.postOnMainThread(name: didChange, object: nil, userInfo: userInfo)
        }
    }
}
