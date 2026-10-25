//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（审计 4.4）：长按菜单「选择文字」。在气泡上盖一层只读、可选中的
/// 纯文本视图，用系统选择手柄选一段，菜单里只有「拷贝」，只拷选中的那一段。
/// 点别处或滚动列表就退出。提及和链接按纯文本处理（不带样式和链接属性）。
/// 区间收紧/映射用已合并的 `TellomiPartialTextSelection`。
enum TellomiTextSelectionModel {

    /// 气泡正文的纯文本：提及展开成显示名，链接只留文字。
    static func plainText(_ value: CVTextValue) -> String {
        switch value {
        case .text(let text):
            return text
        case .attributedText(let attributedText):
            return attributedText.string
        case .messageBody(let messageBody):
            return messageBody.accessibilityDescription
        }
    }

    /// 打开时的初始选区：整段文字（经过收紧，不会切断表情）。
    static func initialRange(in text: String) -> NSRange {
        TellomiPartialTextSelection.snapped(NSRange(location: 0, length: (text as NSString).length), in: text)
    }

    /// 拷贝内容：只拷选中的部分；没选中时返回 nil。
    static func stringToCopy(selectedRange: NSRange, in text: String) -> String? {
        TellomiPartialTextSelection.textToCopy(selectedRange, in: text)
    }
}

/// 只读、可选中的文本视图；「拷贝」只拷纯文本选区。
final class TellomiSelectableTextView: UITextView {

    var plainText: String = ""

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            return selectedRange.length > 0
        }
        if action == #selector(selectAll(_:)) {
            return !TellomiPartialTextSelection.isWholeText(selectedRange, in: plainText)
        }
        return false
    }

    override func copy(_ sender: Any?) {
        guard let string = TellomiTextSelectionModel.stringToCopy(selectedRange: selectedRange, in: plainText) else {
            return
        }
        UIPasteboard.general.string = string
    }
}

/// 盖在会话页上的整屏层：透明背景接住「点别处」，中间是可选中文字。
final class TellomiTextSelectionOverlay: UIView {

    let textView = TellomiSelectableTextView()

    init(text: String, bubbleFrame: CGRect, in hostBounds: CGRect) {
        super.init(frame: hostBounds)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = UIColor.black.withAlphaComponent(0.15)

        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapBackground(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        textView.plainText = text
        textView.text = text
        textView.font = UIFont.dynamicTypeBody
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = Theme.primaryTextColor
        textView.backgroundColor = Theme.backgroundColor
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.dataDetectorTypes = []
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.layer.cornerRadius = 18
        textView.clipsToBounds = true
        textView.accessibilityIdentifier = "tellomi_text_selection_view"

        let width = max(120, min(bubbleFrame.width, hostBounds.width - 24))
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let maxHeight = hostBounds.height * 0.6
        let height = min(max(fitting.height, 44), maxHeight)
        var origin = CGPoint(x: bubbleFrame.minX, y: bubbleFrame.minY)
        origin.x = min(max(12, origin.x), hostBounds.width - 12 - width)
        origin.y = min(max(hostBounds.minY + 60, origin.y), hostBounds.maxY - 60 - height)
        textView.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func beginSelection() {
        textView.becomeFirstResponder()
        textView.selectedRange = TellomiTextSelectionModel.initialRange(in: textView.plainText)
    }

    @objc
    private func didTapBackground(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if textView.frame.contains(point) {
            return
        }
        dismiss()
    }

    func dismiss() {
        textView.resignFirstResponder()
        removeFromSuperview()
    }
}

extension ConversationViewController {

    func tellomiBeginTextSelection(_ itemViewModel: CVItemViewModelImpl) {
        guard !itemViewModel.isViewOnce, let displayableText = itemViewModel.displayableBodyText else {
            return
        }
        let text = TellomiTextSelectionModel.plainText(displayableText.fullTextValue)
        guard !text.isEmpty else {
            return
        }
        tellomiEndTextSelection()

        var bubbleFrame = CGRect(x: 12, y: view.bounds.midY - 40, width: view.bounds.width - 24, height: 80)
        if
            let indexPath = indexPath(forItemViewModel: itemViewModel),
            let cell = collectionView.cellForItem(at: indexPath)
        {
            bubbleFrame = cell.convert(cell.bounds, to: view)
        }
        let overlay = TellomiTextSelectionOverlay(text: text, bubbleFrame: bubbleFrame, in: view.bounds)
        view.addSubview(overlay)
        overlay.beginSelection()
    }

    /// 点别处、滚动列表时调用；没有选择层时什么也不做。
    func tellomiEndTextSelection() {
        for case let overlay as TellomiTextSelectionOverlay in view.subviews {
            overlay.dismiss()
        }
    }
}
