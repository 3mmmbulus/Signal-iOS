//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import ImageIO
import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（tellomi/tellomi#1519 M-4）：一个会话里还没发的定时消息（照 Telegram 两端的「定时消息」页）。
///
/// 照 TG 两端（只读，代码是自己写的）：
/// - 标题「定时消息」，收藏里叫「提醒」（iOS `ChatTitleView` `.scheduledMessages`，安卓 `MODE_SCHEDULED`）；
/// - 按天分组，组头「定于 10 月 15 日发送」/「定于今天发送」（iOS `ChatMessageDateHeader`，安卓 `MessageScheduledOn`）；
/// - 气泡上的时间是到点时间；空的时候一句「还没有定时消息」，页面不自己关（两端都是）；
/// - 长按：「立即发送」「改时间」（同一个选时间页，带着原来的时间）「复制」「删除」（删除要确认）。
/// - 底下一个输入框（TG 这一页就是聊天页）：写新的 → 选时间 → 排；长按「编辑」改一条的文字（`TellomiScheduledComposeBar`）。
/// 只有一端有的不做（O8）：iOS 的「选择」「全部清除」；安卓删除时的「推迟」（重复消息才有）。
/// 不同：这里是自己画的同样排法的列表，不是会话页（定时消息还不是会话里的消息，会话页的气泡要整条消息的数据）。
final class TellomiScheduledMessagesViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, TellomiScheduledComposeBarDelegate {

    private let threadUniqueId: String
    /// 有会话、而且现在能往里发（`canSendChatMessagesToThread`）才有底下的输入框。
    private let thread: TSThread?
    private let isNoteToSelf: Bool
    private let bubbleColor: ColorOrGradientValue?
    private let sender: TellomiScheduledMessageSender
    private let now: () -> Date

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private var sections = [Section]()
    private var hasScrolledToBottom = false
    private var composeBar: TellomiScheduledComposeBar?
    private var lastTableHeight: CGFloat = 0

    struct Section {
        let day: Date
        let messages: [TellomiScheduledMessage]
    }

    init(
        threadUniqueId: String,
        thread: TSThread? = nil,
        isNoteToSelf: Bool,
        bubbleColor: ColorOrGradientValue?,
        sender: TellomiScheduledMessageSender = .shared,
        now: @escaping () -> Date = { Date() },
    ) {
        self.threadUniqueId = threadUniqueId
        self.thread = thread
        self.isNoteToSelf = isNoteToSelf
        self.bubbleColor = bubbleColor
        self.sender = sender
        self.now = now
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 从会话页打开（整页弹出，同 TG iOS `.modal`）。
    static func present(thread: TSThread, bubbleColor: ColorOrGradientValue?, from presenter: UIViewController) {
        let viewController = TellomiScheduledMessagesViewController(
            threadUniqueId: thread.uniqueId,
            thread: thread,
            isNoteToSelf: thread.isNoteToSelf,
            bubbleColor: bubbleColor,
        )
        let navigationController = OWSNavigationController(rootViewController: viewController)
        presenter.present(navigationController, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background
        title = Self.title(isNoteToSelf: isNoteToSelf)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )

        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.register(ScheduledMessageCell.self, forCellReuseIdentifier: ScheduledMessageCell.reuseIdentifier)
        tableView.register(DayHeader.self, forHeaderFooterViewReuseIdentifier: DayHeader.reuseIdentifier)
        tableView.sectionHeaderTopPadding = 8
        view.addSubview(tableView)
        tableView.autoPinEdge(toSuperviewEdge: .top)
        tableView.autoPinEdge(toSuperviewEdge: .leading)
        tableView.autoPinEdge(toSuperviewEdge: .trailing)
        tableView.keyboardDismissMode = .interactive

        if let thread, thread.canSendChatMessagesToThread() {
            let composeBar = TellomiScheduledComposeBar(thread: thread, isReminder: isNoteToSelf)
            composeBar.delegate = self
            view.addSubview(composeBar)
            composeBar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                composeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                composeBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
                tableView.bottomAnchor.constraint(equalTo: composeBar.topAnchor),
            ])
            self.composeBar = composeBar
        } else {
            tableView.autoPinEdge(toSuperviewEdge: .bottom)
        }

        emptyLabel.text = Self.emptyText(isNoteToSelf: isNoteToSelf)
        emptyLabel.font = .dynamicTypeSubheadline
        emptyLabel.textColor = .Signal.secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        view.addSubview(emptyLabel)
        emptyLabel.autoAlignAxis(toSuperviewAxis: .vertical)
        // 空的提示在列表那块的正中（有输入框时不压到它上面）
        emptyLabel.autoAlignAxis(.horizontal, toSameAxisOf: tableView)
        emptyLabel.autoPinEdge(toSuperviewMargin: .leading, relation: .greaterThanOrEqual)
        emptyLabel.autoPinEdge(toSuperviewMargin: .trailing, relation: .greaterThanOrEqual)

        NotificationCenter.default.addObserver(self, selector: #selector(storeDidChange(_:)), name: TellomiScheduledMessageStore.didChange, object: nil)
        reload()
    }

    @objc
    private func storeDidChange(_ notification: Notification) {
        guard SSKEnvironment.hasShared, TellomiScheduledMessageStore.didChange(notification, affect: threadUniqueId) else { return }
        reload()
    }

    /// 没变就不动（别的会话的变化、同样的内容）；变了重画，不跳动滚动位置（只在第一次打开时滚到底）。
    private func reload() {
        let messages = SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiScheduledMessageStore.fetchAll(threadUniqueId: threadUniqueId, tx: tx)
        }
        let newSections = Self.sections(for: messages)
        // 正在改的那条没了（到点发出去了）：收起编辑，说一声改动没存上。
        // 自己点的「立即发送」「删除」在那里先收起了；保存时撞上的由保存那边说，这里先收起、它就不再说一遍。
        if let composeBar, let editingId = composeBar.editingMessageId, !messages.contains(where: { $0.id == editingId }) {
            composeBar.endEditing()
            showAlreadySentNotice()
        }
        // 一开始 `sections` 是空的、空提示是显示着的：空会话不用动。
        guard newSections.map(\.messages) != sections.map(\.messages) else {
            return
        }
        sections = newSections
        emptyLabel.isHidden = !messages.isEmpty
        tableView.reloadData()
        view.setNeedsLayout()
    }

    /// 同聊天页：条目少时贴着底部，多时第一次打开滚到最下面（最晚发的那条）。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.layoutIfNeeded()
        let visibleHeight = tableView.bounds.height - tableView.safeAreaInsets.top - tableView.safeAreaInsets.bottom
        let topInset = max(0, visibleHeight - tableView.contentSize.height)
        if abs(tableView.contentInset.top - topInset) > 0.5 {
            tableView.contentInset.top = topInset
        }
        if !hasScrolledToBottom, tableView.bounds.height > 0, !sections.isEmpty {
            hasScrolledToBottom = true
            scrollToBottom()
        }
        // 键盘起来、列表变矮：同聊天页，最后一条跟着上去；在改的时候让改的那条留在眼前
        let tableHeight = tableView.bounds.height
        if tableHeight < lastTableHeight - 0.5, let composeBar, composeBar.isTyping {
            if let editingId = composeBar.editingMessageId {
                scroll(to: editingId, animated: false)
            } else {
                scrollToBottom()
            }
        }
        lastTableHeight = tableHeight
    }

    private func scrollToBottom(animated: Bool = false) {
        guard let lastSection = sections.indices.last, let lastRow = sections[lastSection].messages.indices.last else { return }
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: lastRow, section: lastSection), at: .bottom, animated: animated)
    }

    private func scroll(to messageId: String, animated: Bool = true) {
        for (sectionIndex, section) in sections.enumerated() {
            if let row = section.messages.firstIndex(where: { $0.id == messageId }) {
                tableView.layoutIfNeeded()
                tableView.scrollToRow(at: IndexPath(row: row, section: sectionIndex), at: .middle, animated: animated)
                return
            }
        }
    }

    static func sections(for messages: [TellomiScheduledMessage], calendar: Calendar = .current) -> [Section] {
        var sections = [Section]()
        for message in messages {
            let day = calendar.startOfDay(for: message.scheduledAt)
            if let last = sections.last, last.day == day {
                sections[sections.count - 1] = Section(day: day, messages: last.messages + [message])
            } else {
                sections.append(Section(day: day, messages: [message]))
            }
        }
        return sections
    }

    // MARK: - Texts

    static func title(isNoteToSelf: Bool) -> String {
        isNoteToSelf
            ? OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_REMINDERS_TITLE", comment: "Title of the list of reminders (scheduled messages to yourself) in Saved Messages.")
            : OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_TITLE", comment: "Title of the list of messages scheduled to be sent later in a chat.")
    }

    static func emptyText(isNoteToSelf: Bool) -> String {
        isNoteToSelf
            ? OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_REMINDERS_EMPTY", comment: "Shown in the reminders list in Saved Messages when there are none.")
            : OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_EMPTY", comment: "Shown in the scheduled messages list of a chat when there are none.")
    }

    static func dayTitle(for day: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_FOR_TODAY", comment: "Day header in the scheduled messages list for messages due later today.")
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMMd" : "yMMMMd")
        return String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_FOR_DAY_FORMAT", comment: "Day header in the scheduled messages list. Embeds {{date, e.g. 'October 15'}}."),
            formatter.string(from: day),
        )
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ScheduledMessageCell.reuseIdentifier, for: indexPath) as! ScheduledMessageCell
        cell.configure(with: sections[indexPath.section].messages[indexPath.row], text: plainText(for: sections[indexPath.section].messages[indexPath.row]), bubbleColor: bubbleColor)
        return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: DayHeader.reuseIdentifier) as! DayHeader
        header.label.text = Self.dayTitle(for: sections[section].day, now: now())
        return header
    }

    /// 正文里的 @ 换成名字（复制、显示用）。
    private func plainText(for message: TellomiScheduledMessage) -> String? {
        guard let body = try? message.messageBody(), !body.text.isEmpty else { return nil }
        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            body.hydrating(mentionHydrator: ContactsMentionHydrator.mentionHydrator(transaction: tx)).asPlaintext()
        }
    }

    // MARK: - Actions

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let message = sections[indexPath.section].messages[indexPath.row]
        let text = plainText(for: message)
        return UIContextMenuConfiguration(identifier: message.id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: self.menuElements(for: message, text: text))
        }
    }

    func menuElements(for message: TellomiScheduledMessage, text: String?) -> [UIMenuElement] {
        var elements: [UIMenuElement] = [
            UIAction(
                title: OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_SEND_NOW", comment: "Context menu item on a scheduled message: send it right away."),
                image: UIImage(systemName: "paperplane"),
            ) { [weak self] _ in self?.sendNow(message) },
            UIAction(
                title: OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_RESCHEDULE", comment: "Context menu item on a scheduled message: choose a different time."),
                image: UIImage(systemName: "calendar.badge.clock"),
            ) { [weak self] _ in self?.reschedule(message) },
        ]
        if let text {
            elements.append(UIAction(title: CommonStrings.copyButton, image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
            })
        }
        // 「编辑」：同 TG iOS 排在复制后面、删除前面（会话现在不能发的时候没有输入框，也就不能改）。
        // 阅后即焚的不给改：它不许带说明（同会话页排定时那条路）
        if composeBar != nil, !message.isViewOnce {
            elements.append(UIAction(title: CommonStrings.editButton, image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.beginEditing(message)
            })
        }
        // 删除要再点一次确认（同 TG iOS：子菜单里只有一项红色的「删除定时消息」）。
        let confirm = UIAction(
            title: isNoteToSelf
                ? OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_DELETE_REMINDER", comment: "Destructive confirmation in the reminders list: delete this reminder.")
                : OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_DELETE_MESSAGE", comment: "Destructive confirmation in the scheduled messages list: delete this scheduled message."),
            image: UIImage(systemName: "trash"),
            attributes: .destructive,
        ) { [weak self] _ in self?.delete(message) }
        elements.append(UIMenu(title: CommonStrings.deleteButton, image: UIImage(systemName: "trash"), options: .destructive, children: [confirm]))
        return elements
    }

    private func sendNow(_ message: TellomiScheduledMessage) {
        if composeBar?.editingMessageId == message.id {
            composeBar?.endEditing()
        }
        let sender = self.sender
        Task { await sender.sendNow(id: message.id) }
    }

    private func reschedule(_ message: TellomiScheduledMessage) {
        let sender = self.sender
        let sheet = TellomiScheduleTimeSheet(isReminder: isNoteToSelf, initialDate: message.scheduledAt) { date in
            Task { await sender.reschedule(id: message.id, to: date) }
        }
        sheet.present(from: self)
    }

    private func delete(_ message: TellomiScheduledMessage) {
        if composeBar?.editingMessageId == message.id {
            composeBar?.endEditing()
        }
        SSKEnvironment.shared.databaseStorageRef.asyncWrite { tx in
            TellomiScheduledMessageStore.remove(id: message.id, tx: tx)
        }
    }

    // MARK: - Writing and editing

    private func beginEditing(_ message: TellomiScheduledMessage) {
        guard let composeBar else { return }
        let body = try? message.messageBody()
        let linkPreviewDraft = message.linkPreview?.draft(in: TellomiScheduledMessageStore.directory(for: message.id))
        composeBar.beginEditing(message, body: body, thumbnail: nil, linkPreviewDraft: linkPreviewDraft)
        scroll(to: message.id)
        // 有附件的带一张小图（同会话输入框改消息时）
        guard let first = message.attachments.first, MimeTypeUtil.isSupportedVisualMediaMimeType(first.mimeType) else { return }
        let url = TellomiScheduledMessageStore.fileUrl(for: first, messageId: message.id)
        let isVideo = MimeTypeUtil.isSupportedVideoMimeType(first.mimeType)
        Task { [weak composeBar] in
            let image = await ScheduledMessageCell.thumbnail(url: url, isVideo: isVideo, pixelSize: 60)
            guard let composeBar, composeBar.editingMessageId == message.id, let image else { return }
            composeBar.setEditThumbnail(image)
        }
    }

    func composeBarMentionPickerParentView(_ composeBar: TellomiScheduledComposeBar) -> UIView? {
        view
    }

    /// 新写的一条：先选时间（同 TG 两端在定时消息页点发送），然后同会话页长按发送那条路——拉黑先解除、安全码先确认，再排。
    func composeBar(_ composeBar: TellomiScheduledComposeBar, didSubmitNew body: MessageBody, linkPreviewDraft: OWSLinkPreviewDraft?) {
        guard let thread else { return }
        let capacity = SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiScheduledMessageSender.remainingCapacity(threadUniqueId: thread.uniqueId, tx: tx)
        }
        guard capacity > 0 else {
            OWSActionSheets.showActionSheet(message: TellomiScheduledMessageSender.ScheduleError.tooManyScheduled.localizedDescription, fromViewController: self)
            return
        }
        let sheet = TellomiScheduleTimeSheet(isReminder: isNoteToSelf) { [weak self] date in
            Task { await self?.scheduleNew(body: body, linkPreviewDraft: linkPreviewDraft, at: date) }
        }
        sheet.present(from: self)
    }

    private func scheduleNew(body: MessageBody, linkPreviewDraft: OWSLinkPreviewDraft?, at date: Date) async {
        guard let thread, let composeBar else { return }
        let isBlocked = SSKEnvironment.shared.databaseStorageRef.read { tx in
            SSKEnvironment.shared.blockingManagerRef.isThreadBlocked(thread, transaction: tx)
        }
        if isBlocked {
            composeBar.resignFirstResponder()
            let stillBlocked = await withCheckedContinuation { continuation in
                BlockListUIUtils.showUnblockThreadActionSheet(thread, from: self) { isBlocked in
                    continuation.resume(returning: isBlocked)
                }
            }
            guard !stillBlocked else { return }
        }
        let identityIsConfirmed = await SafetyNumberConfirmationSheet.presentRepeatedlyAsNecessary(
            for: { thread.recipientAddressesWithSneakyTransaction },
            from: self,
            confirmationText: SafetyNumberStrings.confirmSendButton,
            untrustedThreshold: Date().addingTimeInterval(-OWSIdentityManagerImpl.Constants.defaultUntrustedInterval),
        )
        guard identityIsConfirmed else { return }
        composeBar.isBusy = true
        defer { composeBar.isBusy = false }
        do {
            // 解除拉黑、确认安全码花的时间里已经过了点也照排：执行器马上发出去
            let message = try await sender.schedule(
                body: body,
                attachments: [],
                isViewOnce: false,
                thread: thread,
                quotedReplyDraft: nil,
                linkPreviewDraft: linkPreviewDraft,
                captionAboveMedia: false,
                at: date,
            )
            composeBar.clearAfterSubmit()
            reload()
            scroll(to: message.id)
        } catch TellomiScheduledMessageSender.ScheduleError.tooManyScheduled {
            OWSActionSheets.showActionSheet(message: TellomiScheduledMessageSender.ScheduleError.tooManyScheduled.localizedDescription, fromViewController: self)
        } catch {
            Logger.warn("Couldn't schedule a message from the scheduled list: \(error)")
            OWSActionSheets.showErrorAlert(message: CommonStrings.somethingWentWrongError)
        }
    }

    /// 改好了一条：换掉文字和预览，到点时刻不变。改的这会儿已经发出去了就说一声。
    func composeBar(_ composeBar: TellomiScheduledComposeBar, didSubmitEditOf messageId: String, body: MessageBody, linkPreviewDraft: OWSLinkPreviewDraft?) {
        let sender = self.sender
        composeBar.isBusy = true
        Task { [weak self, weak composeBar] in
            defer { composeBar?.isBusy = false }
            do {
                let edited = try await sender.edit(id: messageId, body: body, linkPreviewDraft: linkPreviewDraft)
                guard let self else { return }
                // 还在改这一条：先收起（`reload` 才不会把它当成「改的那条没了」）；没存上就说一声。
                // 已经不在改了：是 `reload` 先看到它没了，已经收起、说过了
                guard self.composeBar?.editingMessageId == messageId else { return }
                self.composeBar?.endEditing()
                if edited {
                    self.reload()
                } else {
                    self.showAlreadySentNotice()
                }
            } catch {
                Logger.warn("Couldn't edit a scheduled message: \(error)")
                OWSActionSheets.showErrorAlert(message: CommonStrings.somethingWentWrongError)
            }
        }
    }

    private func showAlreadySentNotice() {
        OWSActionSheets.showActionSheet(
            message: isNoteToSelf
                ? OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_EDIT_REMINDER_ALREADY_SENT", comment: "Alert in the reminders list when the reminder being edited was sent before the changes were saved.")
                : OWSLocalizedString("TELLOMI_SCHEDULED_MESSAGES_EDIT_ALREADY_SENT", comment: "Alert in the scheduled messages list when the message being edited was sent before the changes were saved."),
            fromViewController: self,
        )
    }

#if TESTABLE_BUILD
    var composeBarForTesting: TellomiScheduledComposeBar? { composeBar }
    func beginEditingForTesting(_ message: TellomiScheduledMessage) { beginEditing(message) }
    func scheduleNewForTesting(body: MessageBody, at date: Date) async { await scheduleNew(body: body, linkPreviewDraft: nil, at: date) }
    var sectionsForTesting: [Section] { sections }
    func plainTextForTesting(_ message: TellomiScheduledMessage) -> String? { plainText(for: message) }
    var isEmptyShownForTesting: Bool { !emptyLabel.isHidden }
    var tableViewForTesting: UITableView { tableView }
    func sendNowForTesting(_ message: TellomiScheduledMessage) { sendNow(message) }
    func deleteForTesting(_ message: TellomiScheduledMessage) { delete(message) }
    /// 同「改时间」选好了时间（不弹选时间页）。
    func rescheduleForTesting(_ message: TellomiScheduledMessage, to date: Date) async { await sender.reschedule(id: message.id, to: date) }
#endif
}

// MARK: - Day header

private final class DayHeader: UITableViewHeaderFooterView {
    static let reuseIdentifier = "TellomiScheduledDayHeader"

    let label = UILabel()
    private let pill = UIView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()
        pill.backgroundColor = UIColor.Signal.secondaryFill
        pill.layer.cornerRadius = 12
        label.font = .dynamicTypeFootnote.semibold()
        label.textColor = .Signal.secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        contentView.addSubview(pill)
        pill.addSubview(label)
        label.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        pill.autoHCenterInSuperview()
        pill.autoPinEdge(toSuperviewEdge: .top, withInset: 6)
        pill.autoPinEdge(toSuperviewEdge: .bottom, withInset: 6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Message cell

/// 发出去的样子：靠右的气泡（会话的气泡颜色），上面是附件（最多 4 个，多的写「+N」），下面是正文，右下角是到点时间。
private final class ScheduledMessageCell: UITableViewCell {
    static let reuseIdentifier = "TellomiScheduledScheduledMessageCell"

    private let bubble = UIView()
    private let bubbleColorView = CVColorOrGradientView()
    private let stack = UIStackView()
    private let mediaRow = UIStackView()
    private let bodyLabel = UILabel()
    private let timeLabel = UILabel()
    private var loadTasks = [Task<Void, Never>]()

    private static let thumbnailCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 200
        return cache
    }()
    private static let maxTiles = 4
    private static let tileSize: CGFloat = 64

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        bubble.layer.cornerRadius = 18
        bubble.clipsToBounds = true
        contentView.addSubview(bubble)
        bubble.addSubview(bubbleColorView)
        bubbleColorView.autoPinEdgesToSuperviewEdges()

        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .trailing
        bubble.addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))

        mediaRow.axis = .horizontal
        mediaRow.spacing = 2
        bodyLabel.numberOfLines = 0
        bodyLabel.font = .dynamicTypeBody
        bodyLabel.adjustsFontForContentSizeCategory = true
        timeLabel.font = .dynamicTypeCaption1
        timeLabel.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubviews([mediaRow, bodyLabel, timeLabel])

        bubble.autoPinEdge(toSuperviewEdge: .top, withInset: 3)
        bubble.autoPinEdge(toSuperviewEdge: .bottom, withInset: 3)
        bubble.autoPinEdge(toSuperviewMargin: .trailing)
        bubble.autoPinEdge(toSuperviewMargin: .leading, relation: .greaterThanOrEqual).constant = 48
        bodyLabel.setContentHuggingHorizontalHigh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTasks.forEach { $0.cancel() }
        loadTasks = []
        bubbleColorView.reset()
    }

    func configure(with message: TellomiScheduledMessage, text: String?, bubbleColor: ColorOrGradientValue?) {
        bubbleColorView.configure(value: bubbleColor ?? .solidColor(color: .Signal.accent), referenceView: bubble)
        bodyLabel.text = text
        bodyLabel.isHidden = text == nil
        bodyLabel.textColor = .white
        timeLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        timeLabel.text = formatter.string(from: message.scheduledAt)

        mediaRow.removeAllSubviews()
        mediaRow.isHidden = message.attachments.isEmpty
        for (index, attachment) in message.attachments.prefix(Self.maxTiles).enumerated() {
            let tile = UIImageView()
            tile.contentMode = .scaleAspectFill
            tile.clipsToBounds = true
            tile.layer.cornerRadius = 8
            tile.backgroundColor = UIColor.white.withAlphaComponent(0.2)
            tile.autoSetDimensions(to: CGSize(square: Self.tileSize))
            mediaRow.addArrangedSubview(tile)
            let isLastShown = index == Self.maxTiles - 1
            let extra = message.attachments.count - Self.maxTiles
            if isLastShown, extra > 0 {
                let more = UILabel()
                more.text = "+\(extra)"
                more.font = .dynamicTypeHeadline
                more.textColor = .white
                more.textAlignment = .center
                more.backgroundColor = UIColor.black.withAlphaComponent(0.35)
                tile.addSubview(more)
                more.autoPinEdgesToSuperviewEdges()
            }
            let url = TellomiScheduledMessageStore.fileUrl(for: attachment, messageId: message.id)
            if let cached = Self.thumbnailCache.object(forKey: url as NSURL) {
                tile.image = cached
                continue
            }
            if !MimeTypeUtil.isSupportedVisualMediaMimeType(attachment.mimeType) {
                tile.image = UIImage(systemName: "doc")
                tile.contentMode = .center
                tile.tintColor = .white
                continue
            }
            let isVideo = MimeTypeUtil.isSupportedVideoMimeType(attachment.mimeType)
            loadTasks.append(Task { [weak tile] in
                let image = await Self.thumbnail(url: url, isVideo: isVideo, pixelSize: Self.tileSize * 3)
                guard !Task.isCancelled, let image else { return }
                Self.thumbnailCache.setObject(image, forKey: url as NSURL)
                tile?.image = image
            })
        }
    }

    @concurrent
    fileprivate static func thumbnail(url: URL, isVideo: Bool, pixelSize: CGFloat) async -> UIImage? {
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(square: pixelSize)
            let image: CGImage?
            if #available(iOS 16.0, *) {
                image = try? await generator.image(at: .zero).image
            } else {
                image = try? generator.copyCGImage(at: .zero, actualTime: nil)
            }
            return image.map(UIImage.init(cgImage:))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
