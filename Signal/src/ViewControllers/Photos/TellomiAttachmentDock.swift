//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1115）：附件 Sheet 底部的 dock——相册 · 文件 · 位置 · 投票 · 联系人（owner 2026-09-23 定），
/// 最后临时加回一格 GIF（owner 2026-09-26 定：「+」改成 Sheet 后原来附件面板打不开了，面板上的 GIF 键是 iPhone 上唯一的 GIF 入口；
/// GIF 以后挪到表情面板 #1012，那边做好之前先放在这里）。
/// 图标、文案用 Signal 自己原来附件面板那一套（只有「相册」是新词），不用 Telegram 的任何图标（Telegram 的附件菜单里本来就没有 GIF）。
enum TellomiAttachmentDockItem: CaseIterable {
    case gallery
    case file
    case location
    case poll
    case contact
    case gif

    /// 附件 Sheet 的 dock 实际列出哪几格（会话页用）：GIF 只在这个部署能用 GIF 时列（#1078 `isGifAvailable`，同原来的上游附件面板
    /// `AttachmentFormatPickerView`，2026-10-16 已删）——大陆包 provider = none，入口一起关，包里才没有连境外内容代理的地方。
    static var attachmentSheetItems: [TellomiAttachmentDockItem] {
        let isGifAvailable = RemoteConfig.current.isGifAvailable
        return allCases.filter { $0 != .gif || isGifAvailable }
    }

    var title: String {
        switch self {
        case .gallery:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_TELLOMI_GALLERY", value: "Gallery", comment: "Tellomi: dock button in the attachment sheet that shows the photo grid.")
        case .file:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_FILE", comment: "A button to select a file from the Attachment Keyboard")
        case .location:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_LOCATION", comment: "A button to select a location from the Attachment Keyboard")
        case .poll:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_POLL", comment: "A button to select a poll from the Attachment Keyboard")
        case .contact:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_CONTACT", comment: "A button to select a contact from the Attachment Keyboard")
        case .gif:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_GIF", comment: "A button to select a GIF from the Attachment Keyboard")
        }
    }

    var imageName: String {
        switch self {
        case .gallery: return "album-tilt-28"
        case .file: return "file-28"
        case .location: return "location-28"
        case .poll: return "poll-28"
        case .contact: return "person-circle-28"
        case .gif: return "gif-28"
        }
    }
}

/// 尺寸照 Telegram iOS 的 glass tab bar（`AttachmentPanel`：高 62、胶囊、左右各让 20、离底部安全区 8；格子里图标在上、10 pt 中等字重的字在下），
/// 选中那格底下垫一块淡色胶囊（Telegram iOS 26 用的是私有的 liquid lens，这里只用公开的视图画一块圆角底）。
final class TellomiAttachmentDock: UIView {

    static let height: CGFloat = 62
    static let sideMargin: CGFloat = 20
    static let bottomMargin: CGFloat = 8

    var onSelect: ((TellomiAttachmentDockItem) -> Void)?

    let items: [TellomiAttachmentDockItem]
    private(set) var selectedItem: TellomiAttachmentDockItem
    private var buttons: [TellomiAttachmentDockItem: UIButton] = [:]
    private let background: UIVisualEffectView
    private let selectionPill = UIView()

    init(items: [TellomiAttachmentDockItem], selectedItem: TellomiAttachmentDockItem) {
        self.items = items
        self.selectedItem = selectedItem
        if #available(iOS 26, *) {
            background = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        }
        super.init(frame: .zero)

        background.clipsToBounds = true
        background.layer.cornerRadius = Self.height / 2
        background.layer.cornerCurve = .continuous
        addSubview(background)
        background.autoPinEdgesToSuperviewEdges()

        selectionPill.backgroundColor = UIColor.Signal.accent.withAlphaComponent(0.12)
        selectionPill.layer.cornerCurve = .continuous
        background.contentView.addSubview(selectionPill)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        background.contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(hMargin: 3, vMargin: 0))

        for item in items {
            let button = makeButton(for: item)
            buttons[item] = button
            stack.addArrangedSubview(button)
        }
        updateSelection()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    func select(_ item: TellomiAttachmentDockItem) {
        selectedItem = item
        updateSelection()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let button = buttons[selectedItem] else { return }
        let frame = button.convert(button.bounds, to: background.contentView).insetBy(dx: 0, dy: 3)
        selectionPill.frame = frame
        selectionPill.layer.cornerRadius = frame.height / 2
    }

    private func makeButton(for item: TellomiAttachmentDockItem) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(imageLiteralResourceName: item.imageName)
        configuration.imagePlacement = .top
        configuration.imagePadding = 2
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.attributedTitle = AttributedString(item.title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 10, weight: .medium)]))
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = item.title
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onSelect?(item)
        }, for: .primaryActionTriggered)
        return button
    }

    private func updateSelection() {
        for (item, button) in buttons {
            let isSelected = item == selectedItem
            button.tintColor = isSelected ? .Signal.accent : .Signal.secondaryLabel
            button.configuration?.baseForegroundColor = isSelected ? .Signal.accent : .Signal.secondaryLabel
            button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }
}

#if TESTABLE_BUILD
extension TellomiAttachmentDock {
    func tapForTesting(_ item: TellomiAttachmentDockItem) {
        buttons[item]?.sendActions(for: .primaryActionTriggered)
    }

    var selectedItemTintForTesting: UIColor? { buttons[selectedItem]?.configuration?.baseForegroundColor }
}
#endif
