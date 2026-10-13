//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 动态里的一条帖子，照 Threads 的单栏排法（`dynamic-feed.md` 第三节第 2、3 条）：左边头像，右边名字、正文、图片、操作行。
/// 和 Android `FeedPostCard` 同一组内容。
///
/// 这一刀：文字、长文卡片（标题 + 开头几行）、话题、IP 属地、「已编辑」、AI 生成标记、点赞、「···」里的「不感兴趣」。
/// 图片先画占位（按原图比例的灰块，多张横向滑动），真图等内容引擎的图片地址（`config.media_base_url`）接上；
/// 评论、转发、分享随后面的 PR 加，现在不画这几个按钮，免得点了没反应（评论数只显示，不能点）。
final class FeedPostCell: UITableViewCell {
    static let reuseIdentifier = "FeedPostCell"

    static let avatarSize: CGFloat = 36
    static let horizontalMargin: CGFloat = 16
    static let avatarSpacing: CGFloat = 12
    /// 正文的左边：头像右边再空 12。图片第一张和正文左对齐。
    static var contentStart: CGFloat { horizontalMargin + avatarSize + avatarSpacing }
    static let multiImageHeight: CGFloat = 220
    static let articlePreviewLines = 4

    /// 点过赞的红心颜色。
    static let likedColor = UIColor(rgbHex: 0xE5484D)

    var onLike: ((FeedCard) -> Void)?
    var onNotInterested: ((FeedCard) -> Void)?

    private(set) var card: FeedCard?

    private let avatarView = FeedAvatarView(size: FeedPostCell.avatarSize)
    private let nameLabel = UILabel()
    private let timeLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let moreButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let topicsLabel = UILabel()
    private let aiLabel = UILabel()
    private let mediaContainer = UIView()
    private let likeButton = UIButton(type: .system)
    private let commentView = UIStackView()
    private let commentCountLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLayout() {
        nameLabel.font = .dynamicTypeSubheadlineClamped.semibold()
        nameLabel.textColor = UIColor.Signal.label
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.font = .dynamicTypeFootnoteClamped
        timeLabel.textColor = UIColor.Signal.secondaryLabel
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        subtitleLabel.font = .dynamicTypeFootnoteClamped
        subtitleLabel.textColor = UIColor.Signal.secondaryLabel

        moreButton.setImage(UIImage(named: "more"), for: .normal)
        moreButton.tintColor = UIColor.Signal.secondaryLabel
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_MORE", comment: "Feed: accessibility label for the ··· button on a post.")
        moreButton.autoSetDimensions(to: CGSize(square: 32))

        titleLabel.font = .dynamicTypeHeadline
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.numberOfLines = 0

        bodyLabel.font = .dynamicTypeBody
        bodyLabel.textColor = UIColor.Signal.label
        bodyLabel.lineBreakMode = .byTruncatingTail

        topicsLabel.font = .dynamicTypeSubheadline
        topicsLabel.textColor = UIColor.Signal.accent
        topicsLabel.numberOfLines = 0

        aiLabel.font = .dynamicTypeCaption1Clamped
        aiLabel.textColor = UIColor.Signal.secondaryLabel
        // 文字和样式等法律复核（dynamic-feed.md 第五节 Q-7），先用占位文案
        aiLabel.text = OWSLocalizedString("TELLOMI_FEED_AI_GENERATED", comment: "Feed: label on a post that was generated with AI. Placeholder wording until legal review.")

        let nameRow = UIStackView(arrangedSubviews: [nameLabel, timeLabel, UIView.hStretchingSpacer()])
        nameRow.axis = .horizontal
        nameRow.spacing = 6
        nameRow.alignment = .firstBaseline

        let header = UIStackView(arrangedSubviews: [nameRow, subtitleLabel])
        header.axis = .vertical
        header.spacing = 1

        let headerRow = UIStackView(arrangedSubviews: [header, moreButton])
        headerRow.axis = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 4

        let textColumn = UIStackView(arrangedSubviews: [headerRow, titleLabel, bodyLabel, topicsLabel, aiLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 4
        textColumn.setCustomSpacing(6, after: headerRow)

        let topRow = UIStackView(arrangedSubviews: [avatarView, textColumn])
        topRow.axis = .horizontal
        topRow.alignment = .top
        topRow.spacing = Self.avatarSpacing
        topRow.isLayoutMarginsRelativeArrangement = true
        topRow.layoutMargins = UIEdgeInsets(top: 0, left: Self.horizontalMargin, bottom: 0, right: 8)

        var likeConfig = UIButton.Configuration.plain()
        likeConfig.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
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
        actionRow.isLayoutMarginsRelativeArrangement = true
        // 心形和正文左对齐（按钮自己有 12 的内边距）
        actionRow.layoutMargins = UIEdgeInsets(top: 0, left: Self.contentStart - 12, bottom: 0, right: Self.horizontalMargin)

        let root = UIStackView(arrangedSubviews: [topRow, mediaContainer, actionRow])
        root.axis = .vertical
        root.spacing = 8
        root.setCustomSpacing(2, after: mediaContainer)
        contentView.addSubview(root)
        root.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 12, left: 0, bottom: 4, right: 0))

        let separator = UIView()
        separator.backgroundColor = UIColor.Signal.opaqueSeparator.withAlphaComponent(0.5)
        contentView.addSubview(separator)
        separator.autoPinEdge(toSuperviewEdge: .leading)
        separator.autoPinEdge(toSuperviewEdge: .trailing)
        separator.autoPinEdge(toSuperviewEdge: .bottom)
        separator.autoSetDimension(.height, toSize: 1 / max(UIScreen.main.scale, 1))
    }

    func configure(card: FeedCard, showIpRegion: Bool, now: Date = Date()) {
        self.card = card

        avatarView.configure(name: card.author?.displayName)
        nameLabel.text = card.author?.displayName
        timeLabel.text = card.publishedDate.map { Self.relativeTime($0, now: now) }
        let subtitle = Self.subtitle(for: card, showIpRegion: showIpRegion)
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty

        // 自己的帖子「···」里是编辑 / 删除等（第三节第 26 条），随后面的 PR 做；现在只有别人的帖子有「不感兴趣」
        moreButton.isHidden = card.viewer.isAuthor
        moreButton.menu = UIMenu(children: [
            UIAction(
                title: OWSLocalizedString("TELLOMI_FEED_NOT_INTERESTED", comment: "Feed: ··· menu item that hides a post and tells the recommender to show fewer like it."),
                image: UIImage(named: "x-circle"),
            ) { [weak self] _ in
                guard let self, let card = self.card else { return }
                self.onNotInterested?(card)
            },
        ])

        let title = card.isArticle ? card.title?.nilIfEmpty : nil
        titleLabel.text = title
        titleLabel.isHidden = title == nil

        // 长文在信息流里是卡片（第三节第 25 条）：只露开头几行，点开是阅读页（阅读页在后面的 PR）
        let body = (card.isArticle ? (card.summary ?? card.text) : card.text)?.nilIfEmpty
        bodyLabel.text = body
        bodyLabel.isHidden = body == nil
        bodyLabel.numberOfLines = card.isArticle ? Self.articlePreviewLines : 0

        let topics = card.topics.map { "#\($0.label)" }.joined(separator: "  ")
        topicsLabel.text = topics
        topicsLabel.isHidden = topics.isEmpty

        aiLabel.isHidden = !card.aiGenerated

        configureMedia(card.media)
        configureActions(card)
    }

    private func configureActions(_ card: FeedCard) {
        let liked = card.viewer.liked
        let showCount = !card.stats.likeCountHidden && card.stats.likes > 0
        likeButton.configuration?.image = UIImage(named: liked ? "heart-fill-compact" : "heart")
        likeButton.configuration?.baseForegroundColor = liked ? Self.likedColor : UIColor.Signal.secondaryLabel
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

    // MARK: - Media

    /// 多图横滑，可以拖到最左、不做整张吸附（`10-feed-prototype-log.md` 第 28 行）。第一张和正文左对齐。
    /// 只有一张时按原图比例占满宽度（比例限制在 3:4 到 16:9 之间）。
    private func configureMedia(_ media: [FeedMedia]) {
        mediaContainer.removeAllSubviews()
        mediaContainer.isHidden = media.isEmpty
        guard !media.isEmpty else { return }

        if media.count == 1, let item = media.first {
            let placeholder = FeedMediaPlaceholderView(media: item)
            mediaContainer.addSubview(placeholder)
            placeholder.autoPinEdge(toSuperviewEdge: .top)
            placeholder.autoPinEdge(toSuperviewEdge: .bottom)
            placeholder.autoPinEdge(toSuperviewEdge: .leading, withInset: Self.contentStart)
            placeholder.autoPinEdge(toSuperviewEdge: .trailing, withInset: Self.horizontalMargin)
            placeholder.autoMatch(.height, to: .width, of: placeholder, withMultiplier: 1 / item.clampedAspectRatio)
            return
        }

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.scrollsToTop = false
        scrollView.contentInset = UIEdgeInsets(top: 0, left: Self.contentStart, bottom: 0, right: Self.horizontalMargin)
        mediaContainer.addSubview(scrollView)
        scrollView.autoPinEdgesToSuperviewEdges()
        scrollView.autoSetDimension(.height, toSize: Self.multiImageHeight)

        let row = UIStackView(arrangedSubviews: media.map { item in
            let placeholder = FeedMediaPlaceholderView(media: item)
            placeholder.autoSetDimensions(to: CGSize(width: (Self.multiImageHeight * item.clampedAspectRatio).rounded(), height: Self.multiImageHeight))
            return placeholder
        })
        row.axis = .horizontal
        row.spacing = 6
        scrollView.addSubview(row)
        row.autoPinEdgesToSuperviewEdges()
        row.autoMatch(.height, to: .height, of: scrollView)
        scrollView.contentOffset = CGPoint(x: -Self.contentStart, y: 0)
    }

    // MARK: - Text

    /// 「@handle · IP 属地：四川 · 已编辑」；没设 ID 的人显示「Tellomi 号：xxxx」（第三节第 8 条）。
    static func subtitle(for card: FeedCard, showIpRegion: Bool) -> String {
        var parts = [String]()
        if let handle = card.author?.handle?.nilIfEmpty {
            parts.append("@\(handle)")
        } else if let number = card.author?.tellomiNumber?.nilIfEmpty {
            parts.append(String(
                format: OWSLocalizedString("TELLOMI_FEED_TELLOMI_NUMBER_FORMAT", comment: "Feed: shown under the name of someone who has not set an ID. Embeds {{the 10-digit Tellomi number}}."),
                number,
            ))
        }
        if showIpRegion, let region = card.ipRegionLabel?.nilIfEmpty {
            parts.append(String(
                format: OWSLocalizedString("TELLOMI_FEED_IP_REGION_FORMAT", comment: "Feed: where the author's IP address is, shown under their name in mainland China. Embeds {{province name}}."),
                region,
            ))
        }
        if card.edited {
            parts.append(OWSLocalizedString("TELLOMI_FEED_EDITED", comment: "Feed: shown under the name when the post was edited after posting."))
        }
        return parts.joined(separator: " · ")
    }

    /// 「刚刚」「5分」「3时」「2天」「1周」，和快拍列表同一种短写法。
    static func relativeTime(_ date: Date, now: Date) -> String {
        let clamped = min(date, now)
        let seconds = now.timeIntervalSince(clamped)
        if seconds < 60 {
            return OWSLocalizedString("DATE_NOW", comment: "The present; the current time.")
        }
        return DateUtil.formatDuration(seconds: UInt32(min(seconds, Double(UInt32.max))), useShortFormat: true)
    }
}

/// 头像：现在只有名字的第一个字（内容引擎的头像地址还没接上）。
final class FeedAvatarView: UIView {
    private let label = UILabel()

    init(size: CGFloat) {
        super.init(frame: .zero)
        autoSetDimensions(to: CGSize(square: size))
        layer.cornerRadius = size / 2
        clipsToBounds = true
        backgroundColor = UIColor.Signal.secondaryFill
        label.font = .dynamicTypeSubheadlineClamped.semibold()
        label.textColor = UIColor.Signal.secondaryLabel
        label.textAlignment = .center
        addSubview(label)
        label.autoPinEdgesToSuperviewEdges()
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String?) {
        label.text = name?.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)
    }
}

/// 图片占位：圆角灰块，按原图比例。内容引擎的图片地址（`config.media_base_url`）接上之前，
/// 只有本机样例里自己刚发的图（`FeedLocalImages`）能显示出来。
final class FeedMediaPlaceholderView: UIView {
    init(media: FeedMedia) {
        super.init(frame: .zero)
        backgroundColor = UIColor.Signal.secondaryFill
        layer.cornerRadius = 10
        clipsToBounds = true
        if let image = FeedLocalImages.shared.image(for: media.key) {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            addSubview(imageView)
            imageView.autoPinEdgesToSuperviewEdges()
        }
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = media.alt.nilIfEmpty ?? OWSLocalizedString("TELLOMI_FEED_IMAGE", comment: "Feed: accessibility label for an image in a post that has no description.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 本机样例里自己发的图：只在内存，重启就没了。内容引擎给的 key 不会是 `local:` 开头。
final class FeedLocalImages {
    static let shared = FeedLocalImages()

    private let cache = NSCache<NSString, UIImage>()

    static func key(for id: String) -> String {
        return "local:\(id)"
    }

    func set(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    func image(for key: String) -> UIImage? {
        guard key.hasPrefix("local:") else { return nil }
        return cache.object(forKey: key as NSString)
    }
}

/// 点了「不感兴趣」之后，原地留下的小反馈卡：「已隐藏，会减少这类内容」+「撤销」（第三节第 11 条）。
final class FeedHiddenCell: UITableViewCell {
    static let reuseIdentifier = "FeedHiddenCell"

    var onUndo: (() -> Void)?

    private let messageLabel = UILabel()
    private let undoButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        messageLabel.font = .dynamicTypeSubheadline
        messageLabel.textColor = UIColor.Signal.secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.text = OWSLocalizedString("TELLOMI_FEED_HIDDEN", comment: "Feed: shown in place of a post after tapping Not interested.")

        undoButton.setTitle(OWSLocalizedString("TELLOMI_FEED_UNDO", comment: "Feed: button that brings back a post hidden with Not interested."), for: .normal)
        undoButton.titleLabel?.font = .dynamicTypeSubheadline.semibold()
        undoButton.setContentHuggingPriority(.required, for: .horizontal)
        undoButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        undoButton.addAction(UIAction { [weak self] _ in self?.onUndo?() }, for: .touchUpInside)

        let box = UIStackView(arrangedSubviews: [messageLabel, undoButton])
        box.axis = .horizontal
        box.alignment = .center
        box.spacing = 12
        box.isLayoutMarginsRelativeArrangement = true
        box.layoutMargins = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        box.backgroundColor = UIColor.Signal.secondaryBackground
        box.layer.cornerRadius = 12
        contentView.addSubview(box)
        box.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 8, left: FeedPostCell.horizontalMargin, bottom: 8, right: FeedPostCell.horizontalMargin))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
