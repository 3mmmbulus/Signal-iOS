//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 帖子详情页底部的评论输入框：左边多行输入框（长高到几行后里面滚动），右边「发送」；
/// 回复某条评论时上面多一行「正在回复 xxx」+ 取消；剩余字数 ≤ 50 时在发送旁显示计数（超了变红）。
///
/// 这里只画、只转发事件，不做任何判断：画什么由 `FeedCommentInputPresentation`（`apply`）决定，
/// 字数上限（500 个码点）、组字、粘贴截断都在 `FeedPostDetailStore.onDraftEdit` / `onDraftChanged`（`FeedInputLimit`），这里只调用。
/// 评论关了（`.cannotComment`）整个输入框收起来（`isHidden`，放在 `UIStackView` 里就不占位）。
final class FeedCommentInputView: UIView {

    static let minTextHeight: CGFloat = 36
    static let maxTextHeight: CGFloat = 120

    /// 输入框里要改文字了：交给 store 按码点判定（区间、替换的文字、是不是在组字）；回 nil 就照常输入。
    var onEdit: ((NSRange, String, Bool) -> FeedInputEdit?)?
    /// 文字变了（组字结束后也会来一次，store 按码点截）：文字、是不是在组字。
    var onChanged: ((String, Bool) -> Void)?
    var onSend: (() -> Void)?
    var onCancelReply: (() -> Void)?

    /// 单测 / 截图用。
    let textView = UITextView()
    let sendButton = UIButton(type: .system)
    let counterLabel = UILabel()
    let replyLabel = UILabel()
    let replyBanner = UIStackView()
    let cancelReplyButton = UIButton(type: .system)
    private let placeholderLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var textHeightConstraint: NSLayoutConstraint?
    private var lastLayoutWidth: CGFloat = 0
    /// 正在处理 `shouldChangeTextIn`：这时 store 的文字已经是改完的，不能再往输入框里写（UIKit 马上要自己改，写了会插两遍）。
    private var isHandlingEdit = false

    private(set) var presentation: FeedCommentInputPresentation?

    init() {
        super.init(frame: .zero)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLayout() {
        backgroundColor = UIColor.Signal.background

        let divider = UIView()
        divider.backgroundColor = UIColor.Signal.opaqueSeparator
        divider.autoSetDimension(.height, toSize: 1 / max(UIScreen.main.scale, 1))

        replyLabel.font = .dynamicTypeFootnoteClamped
        replyLabel.textColor = UIColor.Signal.secondaryLabel
        cancelReplyButton.setImage(UIImage(named: "x-circle"), for: .normal)
        cancelReplyButton.tintColor = UIColor.Signal.secondaryLabel
        cancelReplyButton.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_COMMENT_CANCEL_REPLY", comment: "Feed: accessibility label of the button that stops replying to a comment and goes back to commenting on the post.")
        cancelReplyButton.autoSetDimensions(to: CGSize(square: 32))
        cancelReplyButton.addAction(UIAction { [weak self] _ in self?.onCancelReply?() }, for: .touchUpInside)
        replyBanner.addArrangedSubview(replyLabel)
        replyBanner.addArrangedSubview(UIView.hStretchingSpacer())
        replyBanner.addArrangedSubview(cancelReplyButton)
        replyBanner.axis = .horizontal
        replyBanner.alignment = .center
        replyBanner.spacing = 8
        replyBanner.isLayoutMarginsRelativeArrangement = true
        replyBanner.layoutMargins = UIEdgeInsets(top: 4, left: 16, bottom: 0, right: 8)
        replyBanner.isHidden = true

        textView.font = .dynamicTypeBody
        textView.textColor = UIColor.Signal.label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.isScrollEnabled = false
        textView.delegate = self

        placeholderLabel.font = .dynamicTypeBody
        placeholderLabel.textColor = UIColor.Signal.secondaryLabel
        placeholderLabel.isUserInteractionEnabled = false

        let textBackground = UIView()
        textBackground.backgroundColor = UIColor.Signal.secondaryBackground
        textBackground.layer.cornerRadius = 18
        textBackground.clipsToBounds = true
        textBackground.addSubview(textView)
        textBackground.addSubview(placeholderLabel)
        textView.autoPinEdgesToSuperviewEdges()
        textHeightConstraint = textView.autoSetDimension(.height, toSize: Self.minTextHeight)
        // 和输入框里文字的起点对齐（容器内边距 8 + 行首留白 5）
        placeholderLabel.autoPinEdge(toSuperviewEdge: .leading, withInset: 13)
        placeholderLabel.autoPinEdge(toSuperviewEdge: .trailing, withInset: 8)
        placeholderLabel.autoPinEdge(toSuperviewEdge: .top, withInset: 8)

        sendButton.setTitle(OWSLocalizedString("TELLOMI_FEED_COMMENT_SEND", comment: "Feed: button that sends the comment typed at the bottom of a post page."), for: .normal)
        sendButton.titleLabel?.font = .dynamicTypeBody.semibold()
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        sendButton.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .touchUpInside)

        spinner.hidesWhenStopped = true
        spinner.isHidden = true

        counterLabel.font = .dynamicTypeFootnoteClamped.monospaced()
        counterLabel.textAlignment = .right
        counterLabel.isHidden = true

        let buttonSlot = UIStackView(arrangedSubviews: [sendButton, spinner])
        buttonSlot.axis = .horizontal
        buttonSlot.alignment = .center
        buttonSlot.autoSetDimension(.height, toSize: Self.minTextHeight)

        let trailing = UIStackView(arrangedSubviews: [counterLabel, buttonSlot])
        trailing.axis = .vertical
        trailing.alignment = .trailing
        trailing.spacing = 0
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        let inputRow = UIStackView(arrangedSubviews: [textBackground, trailing])
        inputRow.axis = .horizontal
        inputRow.alignment = .bottom
        inputRow.spacing = 10
        inputRow.isLayoutMarginsRelativeArrangement = true
        inputRow.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let column = UIStackView(arrangedSubviews: [divider, replyBanner, inputRow])
        column.axis = .vertical
        addSubview(column)
        column.autoPinEdgesToSuperviewEdges()

        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    /// 把 `FeedCommentInputPresentation` 画出来；`draft` 是 store 里现在的草稿（发送成功后清空就靠它）。
    func apply(_ presentation: FeedCommentInputPresentation, draft: String) {
        self.presentation = presentation
        isHidden = presentation.submit == .cannotComment

        let name = presentation.replyBanner?.name
        switch presentation.placeholder {
        case .comment, .closed:
            placeholderLabel.text = OWSLocalizedString("TELLOMI_FEED_COMMENT_PLACEHOLDER", comment: "Feed: placeholder of the comment box at the bottom of a post page.")
        case .reply(let replyName):
            if let replyName {
                placeholderLabel.text = String(
                    format: OWSLocalizedString("TELLOMI_FEED_COMMENT_REPLY_PLACEHOLDER_FORMAT", comment: "Feed: placeholder of the comment box while replying to someone. Embeds {{the name of the person being replied to}}."),
                    replyName,
                )
            } else {
                placeholderLabel.text = OWSLocalizedString("TELLOMI_FEED_COMMENT_REPLY_PLACEHOLDER", comment: "Feed: placeholder of the comment box while replying to a comment whose author has no name.")
            }
        }
        textView.accessibilityLabel = placeholderLabel.text

        if presentation.replyBanner != nil {
            if let name {
                replyLabel.text = String(
                    format: OWSLocalizedString("TELLOMI_FEED_COMMENT_REPLYING_TO_FORMAT", comment: "Feed: line above the comment box while replying to someone. Embeds {{the name of the person being replied to}}."),
                    name,
                )
            } else {
                replyLabel.text = OWSLocalizedString("TELLOMI_FEED_COMMENT_REPLYING", comment: "Feed: line above the comment box while replying to a comment whose author has no name.")
            }
            replyBanner.isHidden = false
        } else {
            replyBanner.isHidden = true
        }

        // 发送成功清了草稿、或程序改了草稿：同步到输入框；用户正在敲（组字 / 正在处理一次输入）时不动
        if !isHandlingEdit, textView.markedTextRange == nil, textView.text != draft {
            textView.text = draft
            updateTextHeight()
        }
        textView.isEditable = presentation.isEditable
        placeholderLabel.isHidden = !textView.text.isEmpty

        let sending = presentation.submit == .sending
        sendButton.isEnabled = presentation.canSend
        sendButton.isHidden = sending
        if sending {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }

        if let remaining = presentation.counterRemaining {
            counterLabel.text = OWSFormat.formatInt(remaining)
            counterLabel.textColor = remaining < 0 || presentation.limitHit ? UIColor.Signal.red : UIColor.Signal.secondaryLabel
            counterLabel.isHidden = false
        } else {
            counterLabel.isHidden = true
        }
    }

    /// 回复某条评论后把光标放进输入框。
    func focus() {
        textView.becomeFirstResponder()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 宽度变了（转屏、分屏）重新算输入框的高度
        if bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            updateTextHeight()
        }
    }

    /// 输入框随文字长高，到 `maxTextHeight` 为止，再多就在里面滚动。
    private func updateTextHeight() {
        let width = textView.bounds.width > 0 ? textView.bounds.width : max(bounds.width - 120, 100)
        let fitting = textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        let height = min(max(fitting, Self.minTextHeight), Self.maxTextHeight)
        if textHeightConstraint?.constant != height {
            textHeightConstraint?.constant = height
        }
        textView.isScrollEnabled = fitting > Self.maxTextHeight
    }
}

extension FeedCommentInputView: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        isHandlingEdit = true
        let result = onEdit?(range, text, textView.markedTextRange != nil)
        isHandlingEdit = false
        guard let edit = result else { return true }
        if edit.accepted { return true }
        // 拦下了、或粘贴被截：自己设成该显示的文字，光标放到截断处，不让 UIKit 再插一遍
        textView.text = edit.text
        textView.selectedRange = NSRange(location: edit.caret, length: 0)
        placeholderLabel.isHidden = !edit.text.isEmpty
        updateTextHeight()
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateTextHeight()
        onChanged?(textView.text, textView.markedTextRange != nil)
    }
}
