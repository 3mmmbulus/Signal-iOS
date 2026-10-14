//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalServiceKit
import SignalUI

protocol TellomiScheduledComposeBarDelegate: AnyObject {
    /// 新写的一条：点了发送键（定时键），接下来选时间。
    func composeBar(_ composeBar: TellomiScheduledComposeBar, didSubmitNew body: MessageBody, linkPreviewDraft: OWSLinkPreviewDraft?)
    /// 改好了一条（`editingMessageId`）。
    func composeBar(_ composeBar: TellomiScheduledComposeBar, didSubmitEditOf messageId: String, body: MessageBody, linkPreviewDraft: OWSLinkPreviewDraft?)
    func composeBarMentionPickerParentView(_ composeBar: TellomiScheduledComposeBar) -> UIView?
}

/// Tellomi（tellomi/tellomi#1519 M-4 第五步）：定时消息页底下的输入框——直接写新的定时消息，或者改一条还没发的。
///
/// 照 Telegram 两端（只读，代码是自己写的）：TG 的定时消息页是完整的聊天页，底下就是输入框——
/// - 发送键换成定时的样子，点了先选时间再排（iOS `ChatControllerNode` `scheduleCurrentMessage`、发送键图标
///   `chatInputPanelScheduleIconImage`；安卓 `ChatActivityEnterView` `isInScheduleMode()` → `input_schedule`，
///   `ChatActivity` `MODE_SCHEDULED` → `createScheduleDatePickerDialog`）；
/// - 长按一条「编辑」：原文进输入框，上面一条「编辑消息」，发送键换成勾，改完保存，到点时刻不变
///   （iOS `canEditMessage` 对定时消息总是能改；安卓 `MessageObject.canEditMessage(…, scheduled)`）；
///   纯文字的改成空的不让存（iOS `editMessage` 里空文字、没有媒体时只震一下），有附件的说明可以删光。
/// 样子用 Signal 自己的（同会话输入框：`BodyRangesTextView` 支持 @ 和样式、链接预览、「编辑消息」那一条），
/// 不搬 TG 的图标。只写文字：附件、贴纸、语音这些在会话页里排（会话页的「+」和长按发送都能定时）。
final class TellomiScheduledComposeBar: UIView, BodyRangesTextViewDelegate {

    weak var delegate: TellomiScheduledComposeBarDelegate?

    private let thread: TSThread
    private let isReminder: Bool

    /// 正在改的那条；nil = 在写新的。
    private(set) var editingMessageId: String?
    /// 正在改的那条有附件：说明可以删光（同 TG）。
    private var editingHasAttachments = false
    /// 开始改之前输入框里写了一半的新消息：改完 / 取消后放回去。
    private var stashedDraft: MessageBody?

    /// 正在存 / 正在排：按钮先不让再点（连点两下会存两遍）。
    var isBusy = false {
        didSet { updateContent(animated: false) }
    }

    init(thread: TSThread, isReminder: Bool) {
        self.thread = thread
        self.isReminder = isReminder
        super.init(frame: .zero)
        setUpViews()
        updateContent(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - API

    var messageBody: MessageBody { textView.messageBodyForSending }

    /// 开始改一条：原文进输入框，上面出「编辑消息」（有图的带一张小图），链接预览接着用原来的。
    func beginEditing(_ message: TellomiScheduledMessage, body: MessageBody?, thumbnail: UIImage?, linkPreviewDraft: OWSLinkPreviewDraft?) {
        if editingMessageId == nil {
            let draft = textView.messageBodyForSending
            stashedDraft = draft.text.isEmpty ? nil : draft
        }
        editingMessageId = message.id
        editingHasAttachments = !message.attachments.isEmpty
        linkPreviewFetchState = nil
        editThumbnailView.image = thumbnail
        editThumbnailView.isHidden = thumbnail == nil
        linkPreviewFetchState = makeLinkPreviewFetchState(initialDraft: linkPreviewDraft)
        textView.setMessageBody(body, txProvider: DependenciesBridge.shared.db.readTxProvider)
        updateContent(animated: true)
        _ = textView.becomeFirstResponder()
    }

    /// 改的那条有图：「编辑消息」后面带一张小图（图是异步取的）。
    func setEditThumbnail(_ image: UIImage) {
        editThumbnailView.image = image
        editThumbnailView.isHidden = false
    }

    /// 不改了（点了「编辑消息」那条上的叉，或者改的那条已经发出去 / 删掉了）：放回原来写了一半的新消息。
    func endEditing() {
        guard editingMessageId != nil else { return }
        editingMessageId = nil
        editingHasAttachments = false
        editThumbnailView.image = nil
        linkPreviewFetchState = makeLinkPreviewFetchState(initialDraft: nil)
        textView.setMessageBody(stashedDraft, txProvider: DependenciesBridge.shared.db.readTxProvider)
        stashedDraft = nil
        updateContent(animated: true)
    }

    /// 排好了一条新的：清空。排的这会儿已经开始改另一条了，就丢掉放在一边的那份（它就是刚排的那条），不动正在改的字。
    func clearAfterSubmit() {
        if editingMessageId != nil {
            stashedDraft = nil
            return
        }
        linkPreviewFetchState = makeLinkPreviewFetchState(initialDraft: nil)
        textView.setMessageBody(nil, txProvider: DependenciesBridge.shared.db.readTxProvider)
        updateContent(animated: true)
    }

    /// 现在能不能点发送 / 保存：新的要有字；改的要有字，或者那条有附件（说明可以删光）。
    var canSubmit: Bool {
        if isBusy {
            return false
        }
        if !textView.isWhitespaceOrEmpty {
            return true
        }
        return editingMessageId != nil && editingHasAttachments
    }

    /// 键盘是不是这个输入框的。
    var isTyping: Bool { textView.isFirstResponder }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        textView.becomeFirstResponder()
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        textView.resignFirstResponder()
    }

    // MARK: - Views

    private enum Metrics {
        static let minTextBoxHeight: CGFloat = 40
        static let minTextViewHeight: CGFloat = 35
        static var maxTextViewHeight: CGFloat {
            // 同会话输入框：竖屏大约四行，横屏三行
            UIDevice.current.orientation.isLandscape ? 100 : 160
        }
        static let buttonSize: CGFloat = 40
    }

    private let column = UIStackView()

    private lazy var textView: BodyRangesTextView = {
        let textView = BodyRangesTextView()
        textView.textColor = .Signal.label
        textView.tintColor = .Signal.accent
        textView.backgroundColor = .clear
        textView.font = .dynamicTypeBody
        textView.adjustsFontForContentSizeCategory = true
        textView.bodyRangesDelegate = self
        textView.accessibilityIdentifier = "tellomi_scheduled_compose_text"
        return textView
    }()

    private let placeholderLabel = UILabel()
    private var placeholderLeadingConstraint: NSLayoutConstraint!
    private var textViewHeightConstraint: NSLayoutConstraint!

    private let editHeader = UIView()
    private let editThumbnailView = UIImageView()

    private let linkPreviewWrapper = UIView()
    private var linkPreviewView: LinkPreviewView?

    private lazy var submitButton: UIButton = {
        let button: UIButton
        if #available(iOS 26, *) {
            button = UIButton(configuration: .prominentGlass())
            button.tintColor = .Signal.accent
        } else {
            var configuration = UIButton.Configuration.filled()
            configuration.baseBackgroundColor = .Signal.accent
            button = UIButton(configuration: configuration)
        }
        button.configuration?.baseForegroundColor = .white
        button.configuration?.cornerStyle = .capsule
        button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        button.configuration?.contentInsets = .zero
        button.isPointerInteractionEnabled = true
        button.addAction(UIAction { [weak self] _ in self?.submit() }, for: .primaryActionTriggered)
        button.accessibilityIdentifier = "tellomi_scheduled_compose_submit"
        return button
    }()

    private func setUpViews() {
        column.axis = .vertical
        column.spacing = 0
        addSubview(column)
        column.autoPinEdgesToSuperviewEdges()

        // 「编辑消息」那一条（同会话输入框改消息时：铅笔 + 字 + 小图），右边一个叉取消
        let editIcon = UIImageView(image: Theme.iconImage(.compose16))
        editIcon.tintColor = .Signal.label
        editIcon.contentMode = .scaleAspectFit
        editIcon.setContentHuggingHigh()
        let editLabel = UILabel()
        editLabel.text = OWSLocalizedString("INPUT_TOOLBAR_EDIT_MESSAGE_LABEL", comment: "Label at the top of the input text when editing a message")
        editLabel.font = UIFont.dynamicTypeSubheadlineClamped.semibold()
        editLabel.textColor = .Signal.label
        editThumbnailView.layer.cornerRadius = 4
        editThumbnailView.clipsToBounds = true
        editThumbnailView.contentMode = .scaleAspectFill
        editThumbnailView.autoSetDimensions(to: CGSize(square: 20))
        let cancelButton = UIButton(type: .system)
        cancelButton.setImage(Theme.iconImage(.xBold), for: .normal)
        cancelButton.tintColor = .Signal.secondaryLabel
        cancelButton.accessibilityLabel = CommonStrings.cancelButton
        cancelButton.accessibilityIdentifier = "tellomi_scheduled_compose_cancel_edit"
        cancelButton.addAction(UIAction { [weak self] _ in self?.endEditing() }, for: .primaryActionTriggered)
        cancelButton.autoSetDimensions(to: CGSize(square: 28))
        let headerRow = UIStackView(arrangedSubviews: [editIcon, editLabel, editThumbnailView, UIView.hStretchingSpacer(), cancelButton])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 4
        editHeader.addSubview(headerRow)
        headerRow.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 8, leading: OWSTableViewController2.defaultHOuterMargin + 12, bottom: 2, trailing: OWSTableViewController2.defaultHOuterMargin))
        column.addArrangedSubview(editHeader)

        linkPreviewWrapper.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: OWSTableViewController2.defaultHOuterMargin, bottom: 2, trailing: OWSTableViewController2.defaultHOuterMargin)
        column.addArrangedSubview(linkPreviewWrapper)

        // 输入框 + 定时键
        let textBackground: UIView
        let textContent: UIView
        if #available(iOS 26, *) {
            let glass = UIVisualEffectView(effect: ConversationInputToolbar.Style.glassEffect(isInteractive: true))
            glass.cornerConfiguration = .uniformCorners(radius: .fixed(Metrics.minTextBoxHeight / 2))
            textBackground = glass
            textContent = glass.contentView
        } else {
            textBackground = UIView()
            textBackground.backgroundColor = .Signal.tertiaryFill
            textBackground.layer.cornerRadius = Metrics.minTextBoxHeight / 2
            textContent = textBackground
        }
        placeholderLabel.text = OWSLocalizedString("INPUT_TOOLBAR_MESSAGE_PLACEHOLDER", comment: "Placeholder text displayed in empty input box in chat screen.")
        placeholderLabel.font = .dynamicTypeBody
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .Signal.secondaryLabel
        textContent.addSubview(placeholderLabel)
        textContent.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: Metrics.minTextViewHeight)
        textBackground.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textBackground.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minTextBoxHeight),
            textViewHeightConstraint,
            textView.topAnchor.constraint(greaterThanOrEqualTo: textBackground.topAnchor),
            textView.centerYAnchor.constraint(equalTo: textBackground.centerYAnchor),
            textView.leadingAnchor.constraint(equalTo: textBackground.leadingAnchor, constant: 8),
            textView.trailingAnchor.constraint(equalTo: textBackground.trailingAnchor, constant: -8),
        ])
        // 和打出来的字对齐：文字区的内边距 + 行首留白（`layoutSubviews` 里按当时的值改）
        placeholderLeadingConstraint = placeholderLabel.autoPinEdge(.leading, to: .leading, of: textView, withOffset: 5)
        placeholderLabel.autoPinEdge(.trailing, to: .trailing, of: textView, withOffset: -5, relation: .lessThanOrEqual)
        placeholderLabel.autoAlignAxis(.horizontal, toSameAxisOf: textView)

        submitButton.autoSetDimensions(to: CGSize(square: Metrics.buttonSize))
        let inputRow = UIStackView(arrangedSubviews: [textBackground, submitButton])
        inputRow.axis = .horizontal
        inputRow.alignment = .bottom
        inputRow.spacing = 10
        inputRow.isLayoutMarginsRelativeArrangement = true
        inputRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: OWSTableViewController2.defaultHOuterMargin, bottom: 8, trailing: OWSTableViewController2.defaultHOuterMargin)
        column.addArrangedSubview(inputRow)
    }

    // MARK: - State

    private func updateContent(animated: Bool) {
        updateTextViewHeight()
        placeholderLabel.isHidden = !textView.isEmpty
        let isEditing = editingMessageId != nil
        if editHeader.isHidden == isEditing {
            editHeader.isHidden = !isEditing
        }
        if isEditing {
            submitButton.configuration?.image = Theme.iconImage(.checkmark)
            submitButton.accessibilityLabel = CommonStrings.saveButton
        } else {
            submitButton.configuration?.image = UIImage(systemName: "calendar.badge.clock")
            submitButton.accessibilityLabel = TellomiScheduleTimeSheet.title(isReminder: isReminder)
        }
        submitButton.isEnabled = canSubmit
        submitButton.alpha = canSubmit ? 1 : 0.4
        updateLinkPreview(animated: animated)
    }

    private func updateTextViewHeight() {
        let width = textView.frame.width > 0 ? textView.frame.width : bounds.width - 120
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = CGFloat.clamp(fitting.height, min: Metrics.minTextViewHeight, max: Metrics.maxTextViewHeight)
        if textViewHeightConstraint.constant != height {
            textViewHeightConstraint.constant = height
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let textLeading = textView.textContainerInset.left + textView.textContainer.lineFragmentPadding
        if placeholderLeadingConstraint.constant != textLeading {
            placeholderLeadingConstraint.constant = textLeading
        }
        updateTextViewHeight()
    }

    private func submit() {
        textView.acceptAutocorrectSuggestion()
        guard canSubmit else { return }
        let body = textView.messageBodyForSending
        let linkPreviewDraft = linkPreviewFetchState?.linkPreviewDraftIfLoaded
        if let editingMessageId {
            delegate?.composeBar(self, didSubmitEditOf: editingMessageId, body: body, linkPreviewDraft: linkPreviewDraft)
        } else {
            delegate?.composeBar(self, didSubmitNew: body, linkPreviewDraft: linkPreviewDraft)
        }
    }

    // MARK: - Link preview

    /// 建得晚：没写字时用不着；单元测试里没有取预览的环境（`linkPreviewFetcher` 是 nil）就不取。
    private var linkPreviewFetchState: LinkPreviewFetchState? {
        didSet { oldValue?.onStateChange = nil }
    }

    private func makeLinkPreviewFetchState(initialDraft: OWSLinkPreviewDraft?) -> LinkPreviewFetchState? {
        // 改带附件的那条：不取预览（同排定时那条路——有附件的消息不带链接预览）
        guard
            !editingHasAttachments,
            initialDraft != nil || !textView.isEmpty || editingMessageId != nil,
            let linkPreviewFetcher = SUIEnvironment.shared.linkPreviewFetcher
        else {
            return nil
        }
        let state = LinkPreviewFetchState(
            db: DependenciesBridge.shared.db,
            linkPreviewFetcher: linkPreviewFetcher,
            linkPreviewSettingStore: DependenciesBridge.shared.linkPreviewSettingStore,
            linkPreviewDraft: initialDraft,
        )
        state.onStateChange = { [weak self] in self?.updateLinkPreviewView(animated: true) }
        return state
    }

    private func updateLinkPreview(animated: Bool) {
        if linkPreviewFetchState == nil, !textView.isEmpty, !editingHasAttachments {
            linkPreviewFetchState = makeLinkPreviewFetchState(initialDraft: nil)
        }
        linkPreviewFetchState?.update(textView.messageBodyForSending, enableIfEmpty: true)
        updateLinkPreviewView(animated: animated)
    }

    private func updateLinkPreviewView(animated: Bool) {
        let state = linkPreviewFetchState?.currentState ?? .none
        let shouldShow: Bool
        switch state {
        case .none:
            shouldShow = false
        case .failed where state.failureMessageToShow == nil:
            // 同会话输入框（ADR-0063 §5.1 铁律 2）：取不到预览就不显示预览区
            shouldShow = false
        case .failed, .loading, .loaded:
            shouldShow = true
        }
        if shouldShow {
            if let linkPreviewView {
                linkPreviewView.configure(withState: state)
            } else {
                let view = LinkPreviewView(state: state)
                view.cancelButton.addAction(UIAction { [weak self] _ in
                    self?.linkPreviewFetchState?.disable()
                }, for: .primaryActionTriggered)
                linkPreviewWrapper.addSubview(view)
                view.autoPinEdgesToSuperviewMargins()
                linkPreviewView = view
            }
        }
        guard linkPreviewWrapper.isHidden == shouldShow else { return }
        let change = { self.linkPreviewWrapper.isHidden = !shouldShow }
        if animated, window != nil {
            UIView.animate(withDuration: 0.2) {
                change()
                self.superview?.layoutIfNeeded()
            }
        } else {
            change()
        }
    }

    // MARK: - BodyRangesTextViewDelegate

    func textViewDidBeginTypingMention(_ textView: BodyRangesTextView) {}

    func textViewDidEndTypingMention(_ textView: BodyRangesTextView) {}

    func textViewMentionPickerParentView(_ textView: BodyRangesTextView) -> UIView? {
        delegate?.composeBarMentionPickerParentView(self)
    }

    func textViewMentionPickerReferenceView(_ textView: BodyRangesTextView) -> UIView? {
        self
    }

    /// 同会话输入框（`ConversationViewController+BodyRangesTextViewDelegate`）。
    func textViewMentionPickerPossibleAcis(_ textView: BodyRangesTextView, tx: DBReadTransaction) -> [Aci] {
        thread.allowsMentionSend ? thread.recipientAddresses(with: tx).compactMap(\.aci) : []
    }

    func textViewMentionCacheInvalidationKey(_ textView: BodyRangesTextView) -> String {
        thread.uniqueId
    }

    func textViewDisplayConfiguration(_ textView: BodyRangesTextView) -> HydratedMessageBody.DisplayConfiguration {
        .composing(textViewColor: textView.textColor)
    }

    func mentionPickerStyle(_ textView: BodyRangesTextView) -> MentionPickerStyle {
        .default
    }

    func textViewDidChange(_ textView: UITextView) {
        updateContent(animated: true)
    }

#if TESTABLE_BUILD
    func setTextForTesting(_ text: String) {
        textView.setMessageBody(MessageBody(text: text, ranges: .empty), txProvider: DependenciesBridge.shared.db.readTxProvider)
        updateContent(animated: false)
    }

    var isEditHeaderShownForTesting: Bool { !editHeader.isHidden }
    var submitButtonForTesting: UIButton { submitButton }
    func submitForTesting() { submit() }
#endif
}
