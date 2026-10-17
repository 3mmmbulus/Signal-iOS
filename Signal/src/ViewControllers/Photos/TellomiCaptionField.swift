//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// 选图面板的说明框（tellomi/tellomi#1261 P-9、P-10）：圆角底、随字数长高（到上限后在框里滚动）、占位字、右下角笑脸 ↔ 键盘。
/// 表情键照 Telegram iOS `AttachmentTextInputPanelNode`：切的是输入框的 `inputView`（[TellomiCaptionEmojiKeyboard]），
/// 收起键盘就回到文字键盘。
///
/// 网格底栏用一个。2026-10-16 起查看器底栏也用一个：owner 发来的方案第 6 节「方案 A」第 1 条要求查看器里也能写说明、直接发送，
/// 照 Telegram `TGMediaPickerGalleryInterfaceView` 的说明栏，那里也带表情键。两个框由选图页同步成同一份说明。
/// 文字、@ 提到由外面设的 `textView.bodyRangesDelegate` 管，这里只管长相、高度和键盘切换。一行没搬 Telegram 代码（GPLv2）。
final class TellomiCaptionField: UIView {

    enum Metrics {
        static let minHeight: CGFloat = 40
        static let maxHeight: CGFloat = 110
        static let emojiButtonSize: CGFloat = 32
    }

    enum InputMode {
        case text
        case emoji
    }

    let textView = BodyRangesTextView()
    private let placeholderLabel = UILabel()
    private var heightConstraint: NSLayoutConstraint?
    private(set) var inputMode = InputMode.text

    private lazy var emojiKeyboard: TellomiCaptionEmojiKeyboard = {
        let keyboard = TellomiCaptionEmojiKeyboard()
        keyboard.onSelectEmoji = { [weak self] emoji in
            self?.textView.insertText(emoji)
        }
        keyboard.onDeleteBackward = { [weak self] in
            self?.textView.deleteBackward()
        }
        keyboard.onSwitchToText = { [weak self] in
            self?.setInputMode(.text)
        }
        return keyboard
    }()

    private(set) lazy var emojiButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .Signal.secondaryLabel
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.toggleInputMode()
        })
        return button
    }()

    init(placeholder: String) {
        super.init(frame: .zero)

        backgroundColor = .Signal.secondaryFill
        layer.cornerRadius = Metrics.minHeight / 2

        textView.font = .dynamicTypeBody
        textView.backgroundColor = .clear
        // 右边让出表情键（离框 4、键 32、再空 4）。
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: Metrics.emojiButtonSize + 8)
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)

        placeholderLabel.text = placeholder
        placeholderLabel.font = .dynamicTypeBody
        placeholderLabel.textColor = .Signal.secondaryLabel
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        updateEmojiButton()
        emojiButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emojiButton)

        let height = textView.heightAnchor.constraint(equalToConstant: Metrics.minHeight)
        heightConstraint = height
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,

            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: emojiButton.leadingAnchor, constant: -4),
            placeholderLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Metrics.minHeight / 2),

            // 多行时贴着最后一行（同 Telegram 的键在输入框右下角）。
            emojiButton.widthAnchor.constraint(equalToConstant: Metrics.emojiButtonSize),
            emojiButton.heightAnchor.constraint(equalToConstant: Metrics.emojiButtonSize),
            emojiButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            emojiButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(Metrics.minHeight - Metrics.emojiButtonSize) / 2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggleInputMode() {
        setInputMode(inputMode == .text ? .emoji : .text)
        if !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
    }

    func setInputMode(_ mode: InputMode) {
        inputMode = mode
        updateEmojiButton()
        let desiredInputView: UIView?
        switch mode {
        case .text:
            desiredInputView = nil
        case .emoji:
            emojiKeyboard.updateHeightForPresentation()
            desiredInputView = emojiKeyboard
        }
        guard textView.inputView !== desiredInputView else { return }
        textView.inputView = desiredInputView
        if textView.isFirstResponder {
            textView.reloadInputViews()
        }
    }

    /// 文字键盘时显示笑脸（点了切表情），表情键盘时显示键盘（点了切回文字）。
    private func updateEmojiButton() {
        switch inputMode {
        case .text:
            emojiButton.configuration?.image = Theme.iconImage(.emojiSmiley)
            emojiButton.accessibilityLabel = OWSLocalizedString(
                "IMAGE_PICKER_TELLOMI_CAPTION_EMOJI_BUTTON",
                comment: "Accessibility label of the button in the photo picker caption field that switches to the emoji keyboard.",
            )
        case .emoji:
            emojiButton.configuration?.image = UIImage(imageLiteralResourceName: "keyboard")
            emojiButton.accessibilityLabel = OWSLocalizedString(
                "INPUT_TOOLBAR_KEYBOARD_BUTTON_ACCESSIBILITY_LABEL",
                comment: "accessibility label for the button which shows the regular keyboard instead of sticker picker",
            )
        }
    }

    /// Tellomi（tellomi/tellomi#1714，ADR-0079 §4.4）：表情键左边再放一个键（查看器里的计时键）。nil = 拿掉。
    /// 文字让出它的位置；藏起来（`isHidden`）时不让——由调用方在写说明时藏起、再调 [updateTrailingAccessoryInset]。
    private(set) var trailingAccessory: UIView?

    func setTrailingAccessory(_ accessory: UIView?) {
        trailingAccessory?.removeFromSuperview()
        trailingAccessory = accessory
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.widthAnchor.constraint(equalToConstant: Metrics.emojiButtonSize),
                accessory.heightAnchor.constraint(equalToConstant: Metrics.emojiButtonSize),
                accessory.trailingAnchor.constraint(equalTo: emojiButton.leadingAnchor),
                accessory.bottomAnchor.constraint(equalTo: emojiButton.bottomAnchor),
            ])
        }
        updateTrailingAccessoryInset()
    }

    func updateTrailingAccessoryInset() {
        let accessoryWidth = trailingAccessory.map { $0.isHidden ? 0 : Metrics.emojiButtonSize } ?? 0
        textView.textContainerInset.right = Metrics.emojiButtonSize + 8 + accessoryWidth
        updatePlaceholderAndHeight()
    }

    /// 高度要按排好之后的真实宽度算（一开始宽度是 0），所以由外面在排版之后、改了字之后调。
    func updatePlaceholderAndHeight() {
        placeholderLabel.isHidden = !textView.isEmpty
        let width = textView.bounds.width
        guard width > 0 else { return }
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fitting, Metrics.minHeight), Metrics.maxHeight)
        textView.isScrollEnabled = fitting > Metrics.maxHeight
        if heightConstraint?.constant != height {
            heightConstraint?.constant = height
        }
    }
}
