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

        let textColumn = UIStackView(arrangedSubviews: [nameRow, replyLabel, bodyLabel])
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

    func configure(row: FeedPostDetailPresentation.CommentRow, now: Date = Date()) {
        let comment = row.comment
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

        let text = FeedPostDetailPresentation.displayText(of: comment)
        bodyLabel.text = text
        bodyLabel.isHidden = text == nil
    }
}
