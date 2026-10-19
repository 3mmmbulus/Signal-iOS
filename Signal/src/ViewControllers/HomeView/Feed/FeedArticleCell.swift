//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 长文阅读页（`dynamic-feed.md` 第三节第 25 条）：帖子详情页里「帖子」那一行，长文时（`TellomiFeed.isArticleReaderEnabled` 打开）换成这个：
/// 大标题、作者和时间、读完要几分钟、整篇正文（小标题 / 引用 / 列表 / 粗体 / 斜体，见 `FeedArticleBody`）、话题、赞和评论数。
/// 正文占满整行宽度（不像信息流里留出头像那一列），可以选中复制。排版随系统字号走。
/// 图片这一刀不画（信息流里的图片本来也只有占位）。
final class FeedArticleCell: UITableViewCell {
    static let reuseIdentifier = "FeedArticleCell"

    static let horizontalMargin: CGFloat = 20
    static let avatarSize: CGFloat = 32

    var onLike: ((FeedCard) -> Void)?
    /// 点头像 / 名字（作者主页入口）。nil = 不响应。
    var onAuthorTap: ((FeedAuthor) -> Void)? {
        didSet { setAuthorTapEnabled(onAuthorTap != nil) }
    }
    /// 点某个 `#话题`。nil = 不响应。
    var onTopicTap: ((FeedTopic) -> Void)? {
        didSet { topicsLabel.isUserInteractionEnabled = onTopicTap != nil }
    }

    private(set) var card: FeedCard?
    private(set) var presentation: FeedArticleReaderPresentation?

    private let titleLabel = UILabel()
    private let avatarView = FeedAvatarView(size: FeedArticleCell.avatarSize)
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()
    private let bodyView = UITextView()
    private let summaryNoteLabel = UILabel()
    private let topicsLabel = UILabel()
    private let aiLabel = UILabel()
    /// 单测 / 截图用：点赞按钮。
    let likeButton = UIButton(type: .system)
    private let commentView = UIStackView()
    private let commentCountLabel = UILabel()
    private var shownCategory: UIContentSizeCategory?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        buildLayout()
        for view in [avatarView, nameLabel] {
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
        }
        setAuthorTapEnabled(false)
        topicsLabel.isUserInteractionEnabled = false
        topicsLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(topicsTapped(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setAuthorTapEnabled(_ enabled: Bool) {
        for view in [avatarView, nameLabel] {
            view.isUserInteractionEnabled = enabled
        }
    }

    @objc private func authorTapped() {
        guard let author = card?.author, tellomiFeedCanOpenProfile(of: author) else { return }
        onAuthorTap?(author)
    }

    /// 和 `FeedPostCell` 同一套：照标签的字体和宽度排一遍字，问点的是第几个字符。
    @objc private func topicsTapped(_ gesture: UITapGestureRecognizer) {
        guard let card, let onTopicTap, !card.topics.isEmpty else { return }
        let storage = NSTextStorage(string: FeedTopicChips.text(for: card.topics), attributes: [.font: topicsLabel.font as UIFont])
        let container = NSTextContainer(size: topicsLabel.bounds.size)
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let point = gesture.location(in: topicsLabel)
        let character = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        let glyph = layout.glyphIndexForCharacter(at: character)
        let usedRect = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        guard usedRect.insetBy(dx: -8, dy: -4).contains(point) else { return }
        if let index = FeedTopicChips.index(atCharacter: character, in: card.topics) {
            onTopicTap(card.topics[index])
        }
    }

    private func buildLayout() {
        titleLabel.font = .dynamicTypeTitle2.bold()
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.numberOfLines = 0

        nameLabel.font = .dynamicTypeSubheadlineClamped.semibold()
        nameLabel.textColor = UIColor.Signal.label
        metaLabel.font = .dynamicTypeFootnoteClamped
        metaLabel.textColor = UIColor.Signal.secondaryLabel
        metaLabel.numberOfLines = 0

        let names = UIStackView(arrangedSubviews: [nameLabel, metaLabel])
        names.axis = .vertical
        names.spacing = 1
        let byline = UIStackView(arrangedSubviews: [avatarView, names, UIView.hStretchingSpacer()])
        byline.axis = .horizontal
        byline.alignment = .center
        byline.spacing = 10

        bodyView.isScrollEnabled = false
        bodyView.isEditable = false
        bodyView.isSelectable = true
        bodyView.backgroundColor = .clear
        bodyView.textContainerInset = .zero
        bodyView.textContainer.lineFragmentPadding = 0
        bodyView.textColor = UIColor.Signal.label

        summaryNoteLabel.font = .dynamicTypeFootnoteClamped
        summaryNoteLabel.textColor = UIColor.Signal.secondaryLabel
        summaryNoteLabel.numberOfLines = 0
        summaryNoteLabel.text = OWSLocalizedString("TELLOMI_FEED_ARTICLE_SUMMARY_ONLY", comment: "Feed article page: shown under the opening of an article when the full text has not arrived yet.")

        topicsLabel.font = .dynamicTypeSubheadline
        topicsLabel.textColor = UIColor.Signal.accent
        topicsLabel.numberOfLines = 0

        aiLabel.font = .dynamicTypeCaption1Clamped
        aiLabel.textColor = UIColor.Signal.secondaryLabel
        aiLabel.text = OWSLocalizedString("TELLOMI_FEED_AI_GENERATED", comment: "Feed: label on a post that was generated with AI. Placeholder wording until legal review.")

        var likeConfig = UIButton.Configuration.plain()
        likeConfig.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 12)
        likeConfig.imagePadding = 4
        likeConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.dynamicTypeFootnoteClamped
            attributes.foregroundColor = UIColor.Signal.secondaryLabel
            return attributes
        }
        likeButton.configuration = likeConfig
        likeButton.addAction(UIAction { [weak self] _ in
            guard let self, let card = self.card else { return }
            self.onLike?(card)
        }, for: .touchUpInside)

        let commentIcon = UIImageView(image: UIImage(named: "chat"))
        commentIcon.tintColor = UIColor.Signal.secondaryLabel
        commentIcon.autoSetDimensions(to: CGSize(square: 20))
        commentCountLabel.font = .dynamicTypeFootnoteClamped
        commentCountLabel.textColor = UIColor.Signal.secondaryLabel
        commentView.addArrangedSubviews([commentIcon, commentCountLabel])
        commentView.axis = .horizontal
        commentView.alignment = .center
        commentView.spacing = 4
        commentView.isAccessibilityElement = true

        let actionRow = UIStackView(arrangedSubviews: [likeButton, commentView, UIView.hStretchingSpacer()])
        actionRow.axis = .horizontal
        actionRow.alignment = .center
        actionRow.spacing = 12

        let root = UIStackView(arrangedSubviews: [titleLabel, byline, bodyView, summaryNoteLabel, topicsLabel, aiLabel, actionRow])
        root.axis = .vertical
        root.spacing = 8
        root.setCustomSpacing(16, after: titleLabel)
        root.setCustomSpacing(20, after: byline)
        root.setCustomSpacing(16, after: bodyView)
        root.isLayoutMarginsRelativeArrangement = true
        root.layoutMargins = UIEdgeInsets(top: 16, left: Self.horizontalMargin, bottom: 4, right: Self.horizontalMargin)
        contentView.addSubview(root)
        root.autoPinEdgesToSuperviewEdges()

        let separator = UIView()
        separator.backgroundColor = UIColor.Signal.opaqueSeparator.withAlphaComponent(0.5)
        contentView.addSubview(separator)
        separator.autoPinEdge(toSuperviewEdge: .leading)
        separator.autoPinEdge(toSuperviewEdge: .trailing)
        separator.autoPinEdge(toSuperviewEdge: .bottom)
        separator.autoSetDimension(.height, toSize: 1 / max(UIScreen.main.scale, 1))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 字号变了：正文的字体是排版时定下来的，要重新排
        if let presentation, traitCollection.preferredContentSizeCategory != shownCategory {
            applyBody(presentation)
        }
    }

    func configure(card: FeedCard, showIpRegion: Bool, now: Date = Date()) {
        self.card = card
        let presentation = FeedArticleReaderPresentation(card: card)
        self.presentation = presentation

        titleLabel.text = presentation.title
        titleLabel.isHidden = presentation.title == nil

        avatarView.configure(name: card.author?.displayName)
        nameLabel.text = card.author?.displayName
        metaLabel.text = Self.metaText(card: card, minutes: presentation.minutes, showIpRegion: showIpRegion, now: now)

        applyBody(presentation)
        summaryNoteLabel.isHidden = !presentation.summaryOnly

        let topics = FeedTopicChips.text(for: card.topics)
        topicsLabel.text = topics
        topicsLabel.isHidden = topics.isEmpty
        aiLabel.isHidden = !card.aiGenerated
        configureActions(card)
    }

    private func applyBody(_ presentation: FeedArticleReaderPresentation) {
        shownCategory = traitCollection.preferredContentSizeCategory
        bodyView.attributedText = FeedArticleAttributedText.make(presentation.blocks)
        bodyView.isHidden = presentation.blocks.isEmpty
    }

    private func configureActions(_ card: FeedCard) {
        let liked = card.viewer.liked
        let showCount = !card.stats.likeCountHidden && card.stats.likes > 0
        likeButton.configuration?.image = UIImage(named: liked ? "heart-fill-compact" : "heart")
        likeButton.configuration?.baseForegroundColor = liked ? FeedPostCell.likedColor : UIColor.Signal.secondaryLabel
        likeButton.configuration?.title = showCount ? OWSFormat.formatInt(card.stats.likes) : nil
        likeButton.accessibilityLabel = liked
            ? OWSLocalizedString("TELLOMI_FEED_UNLIKE", comment: "Feed: accessibility label for the heart on a post you already liked.")
            : OWSLocalizedString("TELLOMI_FEED_LIKE", comment: "Feed: accessibility label for the heart on a post.")
        likeButton.accessibilityValue = showCount ? OWSFormat.formatInt(card.stats.likes) : nil

        commentView.isHidden = card.stats.comments <= 0
        commentCountLabel.text = OWSFormat.formatInt(card.stats.comments)
        commentView.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_COMMENTS", comment: "Feed: accessibility label for the comment count on a post.")
        commentView.accessibilityValue = OWSFormat.formatInt(card.stats.comments)
    }

    /// 名字下面一行：@ID · 属地 · 已编辑 · 时间 · N 分钟阅读。
    static func metaText(card: FeedCard, minutes: Int, showIpRegion: Bool, now: Date) -> String {
        var parts = [String]()
        let subtitle = FeedPostCell.subtitle(for: card, showIpRegion: showIpRegion)
        if !subtitle.isEmpty { parts.append(subtitle) }
        if let date = card.publishedDate { parts.append(FeedPostCell.relativeTime(date, now: now)) }
        if minutes > 0 {
            parts.append(String(
                format: OWSLocalizedString("TELLOMI_FEED_ARTICLE_MINUTES_FORMAT", comment: "Feed article page: how long the article takes to read. Embeds {{number of minutes}}."),
                OWSFormat.formatInt(minutes),
            ))
        }
        return parts.joined(separator: " · ")
    }
}

/// 把排好的块变成带字体的文字（`FeedArticleBody` 只管块和粗斜体，这里管字号、缩进、段间距）。
enum FeedArticleAttributedText {
    static func make(_ blocks: [FeedArticleBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let color = UIColor.Signal.label
        let secondary = UIColor.Signal.secondaryLabel

        func append(_ spans: [FeedArticleSpan], base: UIFont, color: UIColor, style: NSParagraphStyle, prefix: String? = nil) {
            if !result.string.isEmpty { result.append(NSAttributedString(string: "\n")) }
            let paragraph = NSMutableAttributedString()
            if let prefix {
                paragraph.append(NSAttributedString(string: prefix, attributes: [.font: base, .foregroundColor: color]))
            }
            for span in spans {
                paragraph.append(NSAttributedString(string: span.text, attributes: [.font: font(base, span), .foregroundColor: color]))
            }
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            result.append(paragraph)
        }

        for block in blocks {
            switch block {
            case .paragraph(let spans):
                append(spans, base: .dynamicTypeBody, color: color, style: paragraphStyle(spacing: 14))
            case .heading(let level, let spans):
                let base: UIFont = level == 1 ? .dynamicTypeTitle3.bold() : .dynamicTypeHeadline
                append(spans, base: base, color: color, style: paragraphStyle(spacing: 10, before: 8))
            case .quote(let spans):
                append(spans, base: .dynamicTypeBody.italic(), color: secondary, style: paragraphStyle(spacing: 14, indent: 16))
            case .bullets(let items):
                for (index, item) in items.enumerated() {
                    let spacing: CGFloat = index == items.count - 1 ? 14 : 6
                    append(item, base: .dynamicTypeBody, color: color, style: listStyle(spacing: spacing), prefix: "•\t")
                }
            case .numbered(let items):
                for (index, item) in items.enumerated() {
                    let spacing: CGFloat = index == items.count - 1 ? 14 : 6
                    append(item, base: .dynamicTypeBody, color: color, style: listStyle(spacing: spacing), prefix: "\(OWSFormat.formatInt(index + 1)).\t")
                }
            }
        }
        return result
    }

    private static func font(_ base: UIFont, _ span: FeedArticleSpan) -> UIFont {
        var font = base
        if span.bold { font = font.bold() }
        if span.italic { font = font.italic() }
        return font
    }

    private static func paragraphStyle(spacing: CGFloat, before: CGFloat = 0, indent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    private static func listStyle(spacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = spacing
        style.firstLineHeadIndent = 0
        style.headIndent = 24
        style.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
        return style
    }
}
