//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 帖子详情页里的投票（`TellomiFeed.isDetailExtrasEnabled`；第三节第 22 条，交互照 Android `FeedPollView`）：
/// - 没投、没截止：单选点一项就投；多选先勾，再点「投票」；
/// - 投过或截止了：每项按票数比例填色、右边百分比、我选的打勾；投了不能改。
/// 投票在帖子那一行下面，宽度和帖子正文对齐（头像那一列的右边）。
final class FeedPollCell: UITableViewCell {
    static let reuseIdentifier = "FeedPollCell"

    /// 点了投票（单选点一项，或多选勾好后点「投票」），参数是选项下标。
    var onVote: (([Int]) -> Void)?

    private let optionsStack = UIStackView()
    private let footerLabel = UILabel()
    private let voteButton = UIButton(type: .system)
    private var selection = FeedPollSelection()
    private var shownState: FeedPollState?
    private var presentation: FeedPollPresentation?
    private var card: FeedCard?
    private var leadingConstraint: NSLayoutConstraint?
    /// 正文那一列（头像右边）的左边距；长文阅读页的正文是通栏的，用 `setIndented(false)`。
    static let indentedLeading = FeedPostCell.horizontalMargin + FeedPostCell.avatarSize + FeedPostCell.avatarSpacing
    private(set) var optionViews = [FeedPollOptionView]()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        optionsStack.axis = .vertical
        optionsStack.spacing = 8

        footerLabel.font = .dynamicTypeFootnoteClamped
        footerLabel.textColor = UIColor.Signal.secondaryLabel
        footerLabel.numberOfLines = 0

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.title = OWSLocalizedString("TELLOMI_FEED_POLL_VOTE", comment: "Feed poll: button that submits the choices of a multiple-choice poll.")
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20)
        voteButton.configuration = config
        voteButton.addAction(UIAction { [weak self] _ in
            guard let self, self.selection.canSubmit else { return }
            self.onVote?(self.selection.submission)
        }, for: .touchUpInside)

        let footerRow = UIStackView(arrangedSubviews: [footerLabel, UIView.hStretchingSpacer(), voteButton])
        footerRow.axis = .horizontal
        footerRow.alignment = .center
        footerRow.spacing = 8

        let root = UIStackView(arrangedSubviews: [optionsStack, footerRow])
        root.axis = .vertical
        root.spacing = 10
        contentView.addSubview(root)
        root.autoPinEdge(toSuperviewEdge: .top, withInset: 4)
        root.autoPinEdge(toSuperviewEdge: .bottom, withInset: 8)
        leadingConstraint = root.autoPinEdge(toSuperviewEdge: .leading, withInset: Self.indentedLeading)
        root.autoPinEdge(toSuperviewEdge: .trailing, withInset: FeedPostCell.horizontalMargin)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setIndented(_ indented: Bool) {
        leadingConstraint?.constant = indented ? Self.indentedLeading : FeedArticleCell.horizontalMargin
    }

    func configure(card: FeedCard, now: Date = Date()) {
        guard let poll = card.poll else { return }
        self.card = card
        // 票数状态换了（投成功了）就清掉多选勾的
        if card.pollState != shownState { selection = FeedPollSelection() }
        shownState = card.pollState
        let presentation = FeedPollPresentation(poll: poll, state: card.pollState, interactive: true, now: now)
        self.presentation = presentation
        rebuildOptions(poll: poll, presentation: presentation)
        voteButton.isHidden = !(presentation.canVote && presentation.multi)
        voteButton.isEnabled = selection.canSubmit
        footerLabel.text = Self.footerText(presentation)
    }

    private func rebuildOptions(poll: FeedPoll, presentation: FeedPollPresentation) {
        optionViews.forEach { $0.removeFromSuperview() }
        optionViews = poll.options.enumerated().map { index, text in
            let view = FeedPollOptionView()
            let mine = presentation.mine.indices.contains(index) && presentation.mine[index]
            view.configure(
                text: text,
                showResults: presentation.showResults,
                percent: presentation.percents.indices.contains(index) ? presentation.percents[index] : 0,
                fraction: presentation.fractions.indices.contains(index) ? presentation.fractions[index] : 0,
                mine: mine,
                checked: selection.checked.contains(index),
                multi: presentation.multi,
                enabled: presentation.canVote
            )
            view.addAction(UIAction { [weak self] _ in self?.tapped(index) }, for: .touchUpInside)
            optionsStack.addArrangedSubview(view)
            return view
        }
    }

    /// 点第 `index` 项（单测直接调它）。
    func tapped(_ index: Int) {
        guard let presentation, presentation.canVote else { return }
        if let immediate = selection.tap(index, multi: presentation.multi) {
            onVote?(immediate)
        } else if let card {
            // 多选勾了 / 取消勾：用现有的数据重画
            configure(card: card)
        }
    }

    /// 页脚：投票数 · 还剩多久 / 已结束 · 可多选。
    static func footerText(_ presentation: FeedPollPresentation) -> String {
        var parts = [String]()
        if presentation.showVotes {
            parts.append(String(
                format: OWSLocalizedString("TELLOMI_FEED_POLL_VOTES_FORMAT", comment: "Feed poll: total number of votes. Embeds {{number of votes}}."),
                OWSFormat.formatInt(presentation.total)
            ))
        }
        switch presentation.remaining {
        case .closed?:
            parts.append(OWSLocalizedString("TELLOMI_FEED_POLL_CLOSED", comment: "Feed poll: shown when the poll has ended and the results are final."))
        case .days(let n)?:
            parts.append(String(format: OWSLocalizedString("TELLOMI_FEED_POLL_DAYS_LEFT_FORMAT", comment: "Feed poll: time left. Embeds {{number of days}}."), OWSFormat.formatInt(n)))
        case .hours(let n)?:
            parts.append(String(format: OWSLocalizedString("TELLOMI_FEED_POLL_HOURS_LEFT_FORMAT", comment: "Feed poll: time left. Embeds {{number of hours}}."), OWSFormat.formatInt(n)))
        case .minutes(let n)?:
            parts.append(String(format: OWSLocalizedString("TELLOMI_FEED_POLL_MINUTES_LEFT_FORMAT", comment: "Feed poll: time left. Embeds {{number of minutes}}."), OWSFormat.formatInt(n)))
        case nil:
            break
        }
        if presentation.multi, presentation.canVote {
            parts.append(OWSLocalizedString("TELLOMI_FEED_POLL_MULTI", comment: "Feed poll: label on a poll where several options can be picked."))
        }
        return parts.joined(separator: " · ")
    }
}

/// 一个选项：底下按比例填色的条，左边文字（多选没投时前面是方框），右边百分比（有结果时）和「我选的」勾。
final class FeedPollOptionView: UIControl {
    private let fillView = UIView()
    private let marker = UIImageView()
    private let titleLabel = UILabel()
    private let percentLabel = UILabel()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor.Signal.opaqueSeparator.cgColor
        backgroundColor = UIColor.Signal.secondaryBackground

        fillView.backgroundColor = UIColor.Signal.accent.withAlphaComponent(0.18)
        fillView.isUserInteractionEnabled = false
        addSubview(fillView)

        marker.contentMode = .scaleAspectFit
        marker.tintColor = UIColor.Signal.accent
        marker.setContentHuggingPriority(.required, for: .horizontal)
        marker.autoSetDimensions(to: CGSize(square: 20))

        titleLabel.font = .dynamicTypeSubheadlineClamped
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.numberOfLines = 0
        percentLabel.font = .dynamicTypeSubheadlineClamped.semibold()
        percentLabel.textColor = UIColor.Signal.secondaryLabel
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)
        percentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [marker, titleLabel, percentLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        autoSetDimension(.height, toSize: 40, relation: .greaterThanOrEqual)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, showResults: Bool, percent: Int, fraction: Double, mine: Bool, checked: Bool, multi: Bool, enabled: Bool) {
        titleLabel.text = text
        self.fraction = CGFloat(fraction)
        fillView.isHidden = !showResults
        percentLabel.isHidden = !showResults
        percentLabel.text = showResults ? "\(OWSFormat.formatInt(percent))%" : nil
        isEnabled = enabled
        if showResults {
            marker.isHidden = !mine
            marker.image = UIImage(systemName: "checkmark.circle.fill")
        } else if multi {
            marker.isHidden = false
            marker.image = UIImage(systemName: checked ? "checkmark.square.fill" : "square")
        } else {
            marker.isHidden = true
        }
        accessibilityLabel = text
        accessibilityValue = showResults ? "\(percent)%" : nil
        accessibilityTraits = enabled ? [.button] : []
        if mine { accessibilityHint = OWSLocalizedString("TELLOMI_FEED_POLL_YOUR_CHOICE", comment: "Feed poll: accessibility hint on the option the user voted for.") }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fillView.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
    }
}
