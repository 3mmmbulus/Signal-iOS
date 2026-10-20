//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 帖子详情页里的一条评论：左边小头像，右边名字、时间、（回复别人时的「回复 @某人」）、正文。楼里的回复整体往右缩进。
/// 这一刀只显示，不能点赞、回复（发评论随后面的步骤做）。
final class FeedCommentCell: UITableViewCell {
    static let reuseIdentifier = "FeedCommentCell"

    static let avatarSize: CGFloat = 28
    static let horizontalMargin: CGFloat = 16
    static let replyIndent: CGFloat = 40

    private let avatarView = FeedAvatarView(size: FeedCommentCell.avatarSize)
    private let nameLabel = UILabel()
    private let timeLabel = UILabel()
    private let replyLabel = UILabel()
    private let bodyLabel = UILabel()
    private var leadingConstraint: NSLayoutConstraint?
    private var author: FeedAuthor?

    // 详情页补全（`TellomiFeed.isDetailExtrasEnabled`）才用到的几样：语音评论、等批准的回复
    private let transcriptLabel = UILabel()
    private let voiceRow = UIStackView()
    private let voiceButton = UIButton(type: .system)
    private let voiceProgress = UIProgressView(progressViewStyle: .default)
    private let voiceTimeLabel = UILabel()
    private let voiceFailedLabel = UILabel()
    private let moderationRow = UIStackView()
    private let moderationLabel = UILabel()
    private let approveButton = UIButton(type: .system)
    private let declineButton = UIButton(type: .system)
    private var voice: FeedMedia?

    /// 点语音那一行的播放 / 暂停。
    var onVoiceToggle: ((FeedMedia) -> Void)?
    /// 帖子作者批准 / 拒绝一条等着的回复。
    var onApprove: (() -> Void)?
    var onDecline: (() -> Void)?

    /// 点头像 / 名字（作者主页入口）。nil = 不响应，也不拦截点击（点整行照旧是「回复」）。
    var onAuthorTap: ((FeedAuthor) -> Void)? {
        didSet { setAuthorTapEnabled(onAuthorTap != nil) }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        buildLayout()
        for view in [avatarView, nameLabel] {
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
        }
        setAuthorTapEnabled(false)
    }

    private func setAuthorTapEnabled(_ enabled: Bool) {
        for view in [avatarView, nameLabel] {
            view.isUserInteractionEnabled = enabled
        }
    }

    @objc private func authorTapped() {
        guard let author, tellomiFeedCanOpenProfile(of: author) else { return }
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

        replyLabel.font = .dynamicTypeFootnoteClamped
        replyLabel.textColor = UIColor.Signal.secondaryLabel
        replyLabel.numberOfLines = 0

        bodyLabel.font = .dynamicTypeBody
        bodyLabel.textColor = UIColor.Signal.label
        bodyLabel.numberOfLines = 0

        let nameRow = UIStackView(arrangedSubviews: [nameLabel, timeLabel, UIView.hStretchingSpacer()])
        nameRow.axis = .horizontal
        nameRow.spacing = 6
        nameRow.alignment = .firstBaseline

        transcriptLabel.font = .dynamicTypeBody
        transcriptLabel.textColor = UIColor.Signal.label
        transcriptLabel.numberOfLines = 0

        var playConfig = UIButton.Configuration.plain()
        playConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 8)
        voiceButton.configuration = playConfig
        voiceButton.addAction(UIAction { [weak self] _ in
            guard let self, let voice = self.voice else { return }
            self.onVoiceToggle?(voice)
        }, for: .touchUpInside)
        voiceProgress.setContentHuggingPriority(.defaultLow, for: .horizontal)
        voiceProgress.autoSetDimension(.width, toSize: 80, relation: .greaterThanOrEqual)
        voiceTimeLabel.font = .dynamicTypeFootnoteClamped
        voiceTimeLabel.textColor = UIColor.Signal.secondaryLabel
        voiceTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
        voiceRow.axis = .horizontal
        voiceRow.alignment = .center
        voiceRow.spacing = 8
        voiceRow.addArrangedSubviews([voiceButton, voiceProgress, voiceTimeLabel])
        voiceFailedLabel.font = .dynamicTypeFootnoteClamped
        voiceFailedLabel.textColor = UIColor.Signal.red
        voiceFailedLabel.numberOfLines = 0
        voiceFailedLabel.text = OWSLocalizedString("TELLOMI_FEED_VOICE_PLAY_FAILED", comment: "Feed: shown under a voice comment that could not be played.")

        moderationLabel.font = .dynamicTypeFootnoteClamped
        moderationLabel.textColor = UIColor.Signal.secondaryLabel
        moderationLabel.numberOfLines = 0
        for (button, title, color) in [
            (approveButton, OWSLocalizedString("TELLOMI_FEED_DETAIL_APPROVE", comment: "Feed: post author's button that approves a reply that is waiting for them."), UIColor.Signal.accent),
            (declineButton, OWSLocalizedString("TELLOMI_FEED_DETAIL_DECLINE", comment: "Feed: post author's button that declines (deletes) a reply that is waiting for them."), UIColor.Signal.red),
        ] {
            var config = UIButton.Configuration.plain()
            config.title = title
            config.baseForegroundColor = color
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.dynamicTypeFootnoteClamped.semibold()
                return attributes
            }
            button.configuration = config
        }
        approveButton.addAction(UIAction { [weak self] _ in self?.onApprove?() }, for: .touchUpInside)
        declineButton.addAction(UIAction { [weak self] _ in self?.onDecline?() }, for: .touchUpInside)
        moderationRow.axis = .horizontal
        moderationRow.alignment = .center
        moderationRow.spacing = 4
        moderationRow.addArrangedSubviews([moderationLabel, approveButton, declineButton, UIView.hStretchingSpacer()])

        let textColumn = UIStackView(arrangedSubviews: [nameRow, replyLabel, bodyLabel, voiceRow, voiceFailedLabel, transcriptLabel, moderationRow])
        textColumn.axis = .vertical
        textColumn.spacing = 2

        let row = UIStackView(arrangedSubviews: [avatarView, textColumn])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        contentView.addSubview(row)
        row.autoPinEdge(toSuperviewEdge: .top, withInset: 10)
        row.autoPinEdge(toSuperviewEdge: .bottom, withInset: 10)
        row.autoPinEdge(toSuperviewEdge: .trailing, withInset: Self.horizontalMargin)
        leadingConstraint = row.autoPinEdge(toSuperviewEdge: .leading, withInset: Self.horizontalMargin)
    }

    /// - Parameters:
    ///   - extras: 详情页补全开着时才传：语音、等批准、定位高亮。nil（默认）= 和以前一样，只显示文字。
    ///   - playback: 现在语音放到哪（`FeedVoicePlayer.playback`）。
    func configure(row: FeedPostDetailPresentation.CommentRow, extras: FeedCommentExtras? = nil, playback: FeedVoicePlayback = FeedVoicePlayback(), now: Date = Date()) {
        let comment = row.comment
        author = comment.author
        leadingConstraint?.constant = Self.horizontalMargin + (row.isReply ? Self.replyIndent : 0)

        avatarView.configure(name: comment.author?.displayName)
        nameLabel.text = comment.author?.displayName
        timeLabel.text = comment.publishedDate.map { FeedPostCell.relativeTime($0, now: now) }

        if let name = row.replyToName {
            replyLabel.text = String(
                format: OWSLocalizedString("TELLOMI_FEED_COMMENT_REPLY_TO_FORMAT", comment: "Feed: shown above a comment that replies to another comment. Embeds {{the name of the person being replied to}}."),
                name,
            )
            replyLabel.isHidden = false
        } else {
            replyLabel.text = nil
            replyLabel.isHidden = true
        }

        voice = extras?.voice
        let text: String?
        if let extras {
            text = FeedCommentExtras.bodyText(of: comment, hasVoiceRow: extras.voice != nil)
        } else {
            text = FeedPostDetailPresentation.displayText(of: comment)
        }
        bodyLabel.text = text
        bodyLabel.isHidden = text == nil

        contentView.backgroundColor = extras?.highlighted == true ? UIColor.Signal.accent.withAlphaComponent(0.12) : .clear

        // 引擎没部署语音评论（`voice_comments`）：不画播放行
        if extras?.voice != nil, FeedEngineCapabilities.allows(FeedEngineCapabilities.voiceCommentFeatures) {
            voiceRow.isHidden = false
            let transcript = FeedCommentExtras.transcript(of: comment)
            transcriptLabel.text = transcript
            transcriptLabel.isHidden = transcript == nil
            updatePlayback(playback)
        } else {
            voiceRow.isHidden = true
            voiceFailedLabel.isHidden = true
            transcriptLabel.isHidden = true
        }

        switch extras?.moderation ?? .nothing {
        case .nothing:
            moderationRow.isHidden = true
        case .forYou:
            moderationRow.isHidden = false
            moderationLabel.text = OWSLocalizedString("TELLOMI_FEED_DETAIL_HELD_FOR_YOU", comment: "Feed: label on a reply that is waiting for the post author (shown to the author).")
            approveButton.isHidden = false
            declineButton.isHidden = false
        case .waiting:
            moderationRow.isHidden = false
            moderationLabel.text = OWSLocalizedString("TELLOMI_FEED_DETAIL_HELD_WAITING", comment: "Feed: label on the user's own reply that others can see only after the post author approves it.")
            approveButton.isHidden = true
            declineButton.isHidden = true
        }
    }

    /// 语音放到哪变了：只更新语音那一行（播放 / 暂停图标、进度、时间、失败提示），不重画整行。
    func updatePlayback(_ playback: FeedVoicePlayback) {
        guard let voice else { return }
        let active = playback.isActive(voice.key)
        let playing = active && playback.playing
        voiceButton.configuration?.image = UIImage(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
        voiceButton.configuration?.showsActivityIndicator = active && playback.loading
        voiceButton.accessibilityLabel = playing
            ? OWSLocalizedString("TELLOMI_FEED_VOICE_PAUSE", comment: "Feed: accessibility label for the pause button on a voice comment.")
            : OWSLocalizedString("TELLOMI_FEED_VOICE_PLAY", comment: "Feed: accessibility label for the play button on a voice comment.")
        voiceProgress.progress = Float(playback.progress(for: voice))
        voiceTimeLabel.text = FeedVoiceDuration.format(playback.shownMs(for: voice))
        voiceFailedLabel.isHidden = playback.failedKey != voice.key
    }

    /// 单测 / 截图用。
    var voiceButtonForTesting: UIButton { voiceButton }
    var approveButtonForTesting: UIButton { approveButton }
    var declineButtonForTesting: UIButton { declineButton }
    var isVoiceRowVisible: Bool { !voiceRow.isHidden }
    var isModerationVisible: Bool { !moderationRow.isHidden }
    var voiceTimeText: String? { voiceTimeLabel.text }
    var isVoiceFailedVisible: Bool { !voiceFailedLabel.isHidden }
}
