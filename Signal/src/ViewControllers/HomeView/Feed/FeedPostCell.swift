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
    // I-3 卡片补全（`FeedCardExtras`）。三个开关要在 `configure` 之前设好；都关着时卡片和之前一样。
    /// 卡片补全：投票、引用盒、「谁转发了」、收藏、分享菜单。默认关（列表页按 `TellomiFeed.isDetailExtrasEnabled` 设）。
    var extrasEnabled = false
    /// 分享菜单里的「分享 / 复制链接」（`TellomiFeed.isShareEnabled`，默认关）。
    var shareEnabled = false
    /// 有「我的收藏」的实现才出收藏按钮。
    var saveAvailable = false
    var onVote: ((FeedCard, [Int]) -> Void)?
    var onRepost: ((FeedCard) -> Void)?
    var onQuote: ((FeedQuoteTarget) -> Void)?
    var onSave: ((FeedCard) -> Void)?
    /// 系统分享面板 / 复制链接；由列表页处理（要报 `share` 事件）。
    var onShare: ((FeedCard) -> Void)?
    var onCopyLink: ((FeedCard) -> Void)?
    /// 点引用盒：打开被引用的那条。
    var onOpenQuoted: ((FeedCard) -> Void)?
    var onNotInterested: ((FeedCard) -> Void)?
    /// 「···」里的「举报」。nil = 默认在最前面的页面弹举报页（`FeedReportStore` + `FeedSources.current()`）。
    /// 举报入口任何模式都有（合规红线），不按 capabilities 藏、不看预览 / 样例。
    var onReport: ((FeedCard) -> Void)?
    /// 点头像 / 名字（作者主页入口）。nil = 不响应，也不拦截点击（整行照旧是「打开帖子」）。
    var onAuthorTap: ((FeedAuthor) -> Void)? {
        didSet { setAuthorTapEnabled(onAuthorTap != nil) }
    }
    /// 点帖子上的某个 `#话题`（话题页入口）。nil = 不响应，也不拦截点击（整行照旧是「打开帖子」）。
    var onTopicTap: ((FeedTopic) -> Void)? {
        didSet { topicsLabel.isUserInteractionEnabled = onTopicTap != nil }
    }
    /// 帖子详情页最上面那条（这一刀只读）：点赞和「···」不响应，免得点了没反应。
    var isReadOnly = false
    /// 只读时点赞仍然可以点（帖子详情页：「···」收起来，赞可以点）。
    var allowsLikeWhenReadOnly = false

    private(set) var card: FeedCard?

    private let avatarView = FeedAvatarView(size: FeedPostCell.avatarSize)
    private let nameLabel = UILabel()
    private let timeLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let moreButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    /// 正文里的网址可以点（短按打开、长按「打开 / 复制」，`FeedLinkLabel`）。
    private let bodyLabel = FeedLinkLabel()
    /// 正文第一条网址的链接卡片（和聊天同一套样式，`FeedLinkCard`）；没有网址、长文时隐藏。
    private let linkCardView = FeedLinkCardView()
    /// 单测用：正文下面的链接卡片。
    var linkCardViewForTesting: FeedLinkCardView { linkCardView }
    private let topicsLabel = UILabel()
    private let aiLabel = UILabel()
    private let mediaContainer = UIView()
    /// 单测 / 截图用：点赞按钮。
    let likeButton = UIButton(type: .system)
    private let commentView = UIStackView()
    private let commentCountLabel = UILabel()
    private let repostedByLabel = UILabel()
    private let repostedByRow = UIStackView()
    let pollView = FeedCardPollView()
    let quoteBox = FeedQuotedBoxView()
    /// 单测 / 截图用。
    let saveButton = UIButton(type: .system)
    let shareButton = UIButton(type: .system)

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

    /// 按点击位置找到点的是哪个话题：照标签同样的字体和宽度排一遍字，问「这个点落在第几个字符」，再交给 `FeedTopicChips`。
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
        // characterIndex 对「文字右边的空白」也会给出最近的字符：点在那一行文字的范围之外（留 8pt 宽松）就不算点中话题
        let glyph = layout.glyphIndexForCharacter(at: character)
        let usedRect = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        guard usedRect.insetBy(dx: -8, dy: -4).contains(point) else { return }
        if let index = FeedTopicChips.index(atCharacter: character, in: card.topics) {
            onTopicTap(card.topics[index])
        }
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

        let textColumn = UIStackView(arrangedSubviews: [headerRow, titleLabel, bodyLabel, linkCardView, pollView, quoteBox, topicsLabel, aiLabel])
        textColumn.axis = .vertical
        textColumn.spacing = 4
        textColumn.setCustomSpacing(6, after: headerRow)
        textColumn.setCustomSpacing(8, after: bodyLabel)
        textColumn.setCustomSpacing(8, after: linkCardView)
        linkCardView.isHidden = true
        textColumn.setCustomSpacing(8, after: pollView)
        textColumn.setCustomSpacing(8, after: quoteBox)
        pollView.isHidden = true
        pollView.onVote = { [weak self] options in
            guard let self, let card = self.card else { return }
            self.onVote?(card, options)
        }
        quoteBox.isHidden = true
        quoteBox.addAction(UIAction { [weak self] _ in
            guard let self, let inner = self.card?.quoted?.card else { return }
            self.onOpenQuoted?(inner)
        }, for: .touchUpInside)

        // 「张三 转发了」：关注流里因为有人转发才出现的（第三节第 26 条），在作者行上面一行，和正文左对齐
        let repostIcon = UIImageView(image: UIImage(systemName: "arrow.2.squarepath"))
        repostIcon.tintColor = UIColor.Signal.secondaryLabel
        repostIcon.contentMode = .scaleAspectFit
        repostIcon.autoSetDimensions(to: CGSize(square: 14))
        repostedByLabel.font = .dynamicTypeFootnoteClamped
        repostedByLabel.textColor = UIColor.Signal.secondaryLabel
        repostedByRow.addArrangedSubviews([repostIcon, repostedByLabel])
        repostedByRow.axis = .horizontal
        repostedByRow.alignment = .center
        repostedByRow.spacing = 6
        repostedByRow.isLayoutMarginsRelativeArrangement = true
        repostedByRow.layoutMargins = UIEdgeInsets(top: 0, left: Self.contentStart - 20, bottom: 0, right: Self.horizontalMargin)
        repostedByRow.isHidden = true

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

        for button in [saveButton, shareButton] {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            config.baseForegroundColor = UIColor.Signal.secondaryLabel
            button.configuration = config
            button.isHidden = true
        }
        saveButton.addAction(UIAction { [weak self] _ in
            guard let self, let card = self.card else { return }
            self.onSave?(card)
        }, for: .touchUpInside)
        shareButton.configuration?.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.showsMenuAsPrimaryAction = true
        shareButton.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_MENU_SHARE", comment: "Feed: ··· menu item that shares the link of a post with the system share sheet.")

        let actionRow = UIStackView(arrangedSubviews: [likeButton, commentView, UIView.hStretchingSpacer(), saveButton, shareButton])
        actionRow.axis = .horizontal
        actionRow.alignment = .center
        actionRow.spacing = 12
        actionRow.isLayoutMarginsRelativeArrangement = true
        // 心形和正文左对齐（按钮自己有 12 的内边距）
        actionRow.layoutMargins = UIEdgeInsets(top: 0, left: Self.contentStart - 12, bottom: 0, right: Self.horizontalMargin)

        let root = UIStackView(arrangedSubviews: [repostedByRow, topRow, mediaContainer, actionRow])
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
        moreButton.isHidden = card.viewer.isAuthor || isReadOnly
        moreButton.menu = UIMenu(children: Self.menuItems(for: card).map { item in
            switch item {
            case .report:
                return UIAction(
                    title: OWSLocalizedString("TELLOMI_FEED_MENU_REPORT", comment: "Feed: ··· menu item that reports a post or a comment."),
                    image: UIImage(systemName: "flag"),
                ) { [weak self] _ in
                    guard let self, let card = self.card else { return }
                    self.report(card)
                }
            default:
                return UIAction(
                    title: OWSLocalizedString("TELLOMI_FEED_NOT_INTERESTED", comment: "Feed: ··· menu item that hides a post and tells the recommender to show fewer like it."),
                    image: UIImage(named: "x-circle"),
                ) { [weak self] _ in
                    guard let self, let card = self.card else { return }
                    self.onNotInterested?(card)
                }
            }
        })

        let title = card.isArticle ? card.title?.nilIfEmpty : nil
        titleLabel.text = title
        titleLabel.isHidden = title == nil

        // 长文在信息流里是卡片（第三节第 25 条）：只露开头几行，点开是阅读页（阅读页在后面的 PR）
        let body = (card.isArticle ? (card.summary ?? card.text) : card.text)?.nilIfEmpty
        bodyLabel.setText(body, font: .dynamicTypeBody, color: UIColor.Signal.label)
        bodyLabel.isHidden = body == nil
        bodyLabel.numberOfLines = card.isArticle ? Self.articlePreviewLines : 0
        linkCardView.configure(FeedLinkCard.make(body: body, isArticle: card.isArticle))

        let topics = FeedTopicChips.text(for: card.topics)
        topicsLabel.text = topics
        topicsLabel.isHidden = topics.isEmpty

        aiLabel.isHidden = !card.aiGenerated

        configureMedia(card.media)
        configureActions(card)
        configureExtras(card, now: now)
    }

    // MARK: - I-3 卡片补全

    private func configureExtras(_ card: FeedCard, now: Date) {
        let extras = FeedCardExtras.make(
            card: card,
            extrasEnabled: extrasEnabled,
            shareEnabled: shareEnabled,
            saveAvailable: saveAvailable && onSave != nil,
            postingAllowed: FeedEngineCapabilities.allows(FeedEngineCapabilities.composeFeatures),
            pollsAllowed: FeedEngineCapabilities.allows(FeedEngineCapabilities.pollFeatures) && onVote != nil,
            isReadOnly: isReadOnly,
        )

        repostedByLabel.text = extras.repostedByText
        repostedByRow.isHidden = extras.repostedByText == nil

        pollView.isHidden = !extras.showsPoll
        if extras.showsPoll {
            pollView.configure(card: card, interactive: extras.pollInteractive, now: now)
        }

        if extras.showsQuote, let quoted = card.quoted {
            quoteBox.configure(FeedCardExtras.quote(quoted))
            quoteBox.isHidden = false
        } else {
            quoteBox.isHidden = true
        }

        saveButton.isHidden = !extras.showsSave
        saveButton.configuration?.image = UIImage(systemName: extras.saved ? "bookmark.fill" : "bookmark")
        saveButton.configuration?.baseForegroundColor = extras.saved ? UIColor.Signal.accent : UIColor.Signal.secondaryLabel
        saveButton.accessibilityLabel = FeedDetailActionsCell.saveTitle(saved: extras.saved)

        shareButton.isHidden = extras.shareItems.isEmpty
        shareButton.menu = extras.shareItems.isEmpty ? nil : UIMenu(children: extras.shareItems.map(shareAction))
    }

    private func shareAction(_ item: FeedCardExtras.ShareItem) -> UIAction {
        switch item {
        case .repost(let reposted):
            return UIAction(title: FeedDetailActionsCell.repostTitle(reposted: reposted), image: UIImage(systemName: "arrow.2.squarepath")) { [weak self] _ in
                guard let self, let card = self.card else { return }
                self.onRepost?(card)
            }
        case .quote:
            return UIAction(
                title: OWSLocalizedString("TELLOMI_FEED_QUOTE", comment: "Feed: share menu item that opens the publish page quoting this post."),
                image: UIImage(systemName: "quote.bubble"),
            ) { [weak self] _ in
                guard let self, let card = self.card, let target = FeedQuoteTarget.of(card) else { return }
                self.onQuote?(target)
            }
        case .share:
            return UIAction(
                title: OWSLocalizedString("TELLOMI_FEED_MENU_SHARE", comment: "Feed: ··· menu item that shares the link of a post with the system share sheet."),
                image: UIImage(systemName: "square.and.arrow.up"),
            ) { [weak self] _ in
                guard let self, let card = self.card else { return }
                self.onShare?(card)
            }
        case .copyLink:
            return UIAction(
                title: OWSLocalizedString("TELLOMI_FEED_MENU_COPY_LINK", comment: "Feed: ··· menu item that copies the link of a post."),
                image: UIImage(systemName: "link"),
            ) { [weak self] _ in
                guard let self, let card = self.card else { return }
                self.onCopyLink?(card)
            }
        }
    }

    /// 信息流里别人帖子的「···」：不感兴趣、举报（和详情页 `FeedDetailMenu.items(forPost:)` 同一组）。纯函数，单测用。
    /// 举报不看 capabilities、预览、样例：能看到内容就能举报。
    static func menuItems(for card: FeedCard) -> [FeedDetailMenuItem] {
        guard !card.viewer.isAuthor else { return [] }
        return [.notInterested, .report]
    }

    private func report(_ card: FeedCard) {
        if let onReport {
            onReport(card)
            return
        }
        guard let presenter = CurrentAppContext().frontmostViewController() else { return }
        let store = FeedReportStore(target: .content(card.id), source: FeedSources.current())
        store.start()
        let report = FeedReportViewController(store: store) { [weak presenter] _ in
            presenter?.dismiss(animated: true)
        }
        presenter.present(OWSNavigationController(rootViewController: report), animated: true)
    }

    private func configureActions(_ card: FeedCard) {
        let liked = card.viewer.liked
        let showCount = !card.stats.likeCountHidden && card.stats.likes > 0
        likeButton.isUserInteractionEnabled = !isReadOnly || allowsLikeWhenReadOnly
        // 引擎没部署点赞（`reactions`）：不显示心形
        likeButton.isHidden = !FeedEngineCapabilities.allows(FeedEngineCapabilities.likeFeatures)
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
