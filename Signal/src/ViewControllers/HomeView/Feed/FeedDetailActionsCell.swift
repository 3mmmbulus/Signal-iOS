//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 帖子详情页里帖子（或长文）下面的「转发 / 收藏」一行（`TellomiFeed.isDetailExtrasEnabled`；第三节第 26、27 条）。
/// 转发 = 转发到自己的动态，再点一次取消；收藏 = 存进「我的收藏」。哪个按钮显示由 `FeedPostDetailPresentation.actions` 决定。
final class FeedDetailActionsCell: UITableViewCell {
    static let reuseIdentifier = "FeedDetailActionsCell"

    var onRepost: (() -> Void)?
    var onSave: (() -> Void)?
    private var leadingConstraint: NSLayoutConstraint?
    /// 按钮里的文字比按钮边缘缩进 10，所以左边距减掉它，文字正好和正文对齐。
    static let indentedLeading = FeedPollCell.indentedLeading - 10

    /// 单测 / 截图用。
    let repostButton = UIButton(type: .system)
    let saveButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        for button in [repostButton, saveButton] {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 12)
            config.imagePadding = 6
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.dynamicTypeFootnoteClamped
                return attributes
            }
            button.configuration = config
        }
        repostButton.addAction(UIAction { [weak self] _ in self?.onRepost?() }, for: .touchUpInside)
        saveButton.addAction(UIAction { [weak self] _ in self?.onSave?() }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [repostButton, saveButton, UIView.hStretchingSpacer()])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4
        contentView.addSubview(row)
        row.autoPinEdge(toSuperviewEdge: .top, withInset: 0)
        row.autoPinEdge(toSuperviewEdge: .bottom, withInset: 4)
        leadingConstraint = row.autoPinEdge(toSuperviewEdge: .leading, withInset: Self.indentedLeading)
        row.autoPinEdge(toSuperviewEdge: .trailing, withInset: FeedPostCell.horizontalMargin)

        let separator = UIView()
        separator.backgroundColor = UIColor.Signal.opaqueSeparator.withAlphaComponent(0.5)
        contentView.addSubview(separator)
        separator.autoPinEdge(toSuperviewEdge: .leading)
        separator.autoPinEdge(toSuperviewEdge: .trailing)
        separator.autoPinEdge(toSuperviewEdge: .bottom)
        separator.autoSetDimension(.height, toSize: 1 / max(UIScreen.main.scale, 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setIndented(_ indented: Bool) {
        leadingConstraint?.constant = indented ? Self.indentedLeading : FeedArticleCell.horizontalMargin - 10
    }

    func configure(_ actions: FeedDetailActions) {
        repostButton.isHidden = !actions.repost
        saveButton.isHidden = !actions.save

        repostButton.configuration?.image = UIImage(systemName: "arrow.2.squarepath")
        repostButton.configuration?.title = Self.repostTitle(reposted: actions.reposted)
        repostButton.configuration?.baseForegroundColor = actions.reposted ? UIColor.Signal.accent : UIColor.Signal.secondaryLabel
        repostButton.accessibilityLabel = Self.repostTitle(reposted: actions.reposted)

        saveButton.configuration?.image = UIImage(systemName: actions.saved ? "bookmark.fill" : "bookmark")
        saveButton.configuration?.title = Self.saveTitle(saved: actions.saved)
        saveButton.configuration?.baseForegroundColor = actions.saved ? UIColor.Signal.accent : UIColor.Signal.secondaryLabel
        saveButton.accessibilityLabel = Self.saveTitle(saved: actions.saved)
    }

    static func repostTitle(reposted: Bool) -> String {
        return reposted
            ? OWSLocalizedString("TELLOMI_FEED_UNDO_REPOST", comment: "Feed: button that takes back a repost of a post on the user's own feed.")
            : OWSLocalizedString("TELLOMI_FEED_REPOST", comment: "Feed: button that reposts a post to the user's own feed.")
    }

    static func saveTitle(saved: Bool) -> String {
        return saved
            ? OWSLocalizedString("TELLOMI_FEED_UNSAVE", comment: "Feed: button that removes a post from the user's Saved Messages.")
            : OWSLocalizedString("TELLOMI_FEED_SAVE", comment: "Feed: button that saves a post to the user's Saved Messages.")
    }
}
