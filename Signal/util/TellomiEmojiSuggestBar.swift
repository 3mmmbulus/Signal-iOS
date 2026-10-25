//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（Telegram 对照 3.4 / F22）：输入框上方的表情建议栏的纯逻辑，方便单测。
enum TellomiEmojiSuggestBarModel {
    /// 栏里最多显示几个。
    static let maxVisible = TellomiEmojiSuggest.maxResults

    /// 当前文字和光标下要显示的表情（去重、最多 8 个）；没有建议时为空，栏隐藏。
    static func visibleEmoji(text: String, selectedRange: NSRange) -> [String] {
        guard
            selectedRange.length == 0,
            let suggestion = TellomiEmojiSuggest.suggestion(text: text, selectedRange: selectedRange)
        else {
            return []
        }
        var seen = Set<String>()
        return Array(suggestion.emoji.filter { seen.insert($0).inserted }.prefix(maxVisible))
    }

    /// 点了某个表情：在当前文字里替换掉查询词，返回新文字、被替换的范围和新光标位置。
    static func applying(
        emoji: String,
        text: String,
        selectedRange: NSRange,
    ) -> (text: String, replacedRange: NSRange, cursor: Int)? {
        guard
            selectedRange.length == 0,
            let suggestion = TellomiEmojiSuggest.suggestion(text: text, selectedRange: selectedRange),
            suggestion.emoji.contains(emoji)
        else {
            return nil
        }
        let result = TellomiEmojiSuggest.apply(suggestion, emoji: emoji, to: text)
        return (result.text, suggestion.replacementRange, result.cursor)
    }
}

/// 输入框上方一行横向的表情按钮；没有建议时隐藏。
final class TellomiEmojiSuggestBar: UIView {

    static let height: CGFloat = 40

    var onSelect: ((String) -> Void)?

    private(set) var emoji: [String] = []

    private let scrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }()

    private let stackView: UIStackView = {
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.spacing = 2
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        accessibilityLabel = OWSLocalizedString(
            "TELLOMI_EMOJI_SUGGESTIONS_ACCESSIBILITY_LABEL",
            comment: "Accessibility label for the row of emoji suggestions shown above the message input while typing.",
        )
        addSubview(scrollView)
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 换一组表情；返回显示状态是否变了（调用方据此重新算输入栏高度）。
    @discardableResult
    func update(emoji newEmoji: [String]) -> Bool {
        let wasHidden = isHidden
        if newEmoji != emoji {
            emoji = newEmoji
            stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for item in newEmoji {
                stackView.addArrangedSubview(makeButton(item))
            }
            scrollView.contentOffset = .zero
        }
        isHidden = newEmoji.isEmpty
        return wasHidden != isHidden
    }

    private func makeButton(_ item: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(item, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 26)]))
        configuration.contentInsets = .init(top: 2, leading: 6, bottom: 2, trailing: 6)
        let button = UIButton(
            configuration: configuration,
            primaryAction: UIAction { [weak self] _ in
                self?.onSelect?(item)
            },
        )
        button.accessibilityLabel = item
        return button
    }
}
