//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//
// I-3 卡片补全（信息流里的卡片）：投票、引用盒、「谁转发了」、收藏、分享菜单（转发 / 引用 / 分享 / 复制链接）。
// 交互照 Android `FeedPostCard.kt` / `FeedQuotedBox.kt` / `FeedPollView.kt`（tellomi 843ca6a1）；Telegram 只作行为参考，没有拷代码。
// 不含「分享到快拍」「发到聊天」（会走相机 / 发送路径，见 REPORT 3.3）。
// NOT COMPILED on Linux（swiftc -parse only）; needs a Mac.
//

import SignalServiceKit
import SignalUI
import UIKit

/// 卡片上要多画哪些东西（纯逻辑，单测用）。
struct FeedCardExtras: Equatable {
    /// 「张三 转发了」那一行；nil = 不画。名字取不到时是「转发」。
    var repostedByText: String?
    var showsPoll: Bool
    var pollInteractive: Bool
    var showsQuote: Bool
    var showsSave: Bool
    var saved: Bool
    /// 分享菜单里的几项；空 = 不画分享按钮。
    var shareItems: [ShareItem]

    enum ShareItem: Equatable {
        case repost(reposted: Bool)
        case quote
        case share
        case copyLink
    }

    /// - extrasEnabled: 卡片补全开关（沿用 `TellomiFeed.isDetailExtrasEnabled`，默认关）。关着时卡片和之前完全一样。
    /// - shareEnabled: `TellomiFeed.isShareEnabled`（默认关）：系统分享面板 / 复制链接。
    /// - saveAvailable: 有「我的收藏」的实现才给收藏（iOS 的实现还没接，见 `FeedSavedMessages`）。
    /// - postingAllowed / pollsAllowed: 引擎 capabilities（转发、引用跟 `posting`；投票跟 `polls`）。
    static func make(
        card: FeedCard,
        extrasEnabled: Bool,
        shareEnabled: Bool,
        saveAvailable: Bool,
        postingAllowed: Bool,
        pollsAllowed: Bool,
        isReadOnly: Bool,
    ) -> FeedCardExtras {
        guard extrasEnabled, card.kind != FeedCard.kindComment else {
            return FeedCardExtras(repostedByText: nil, showsPoll: false, pollInteractive: false, showsQuote: false, showsSave: false, saved: false, shareItems: [])
        }
        var items = [ShareItem]()
        if card.shareable && !isReadOnly {
            if postingAllowed { items.append(.repost(reposted: card.viewer.reposted)) }
            if postingAllowed, FeedQuoteTarget.of(card) != nil { items.append(.quote) }
            if shareEnabled { items += [.share, .copyLink] }
        }
        let hasPoll = (card.poll?.options.isEmpty == false)
        return FeedCardExtras(
            repostedByText: card.repostedBy.map { Self.repostedByText($0.displayName) },
            showsPoll: hasPoll,
            pollInteractive: hasPoll && pollsAllowed && !isReadOnly,
            showsQuote: card.quoted != nil,
            showsSave: saveAvailable && !isReadOnly,
            saved: card.viewer.saved,
            shareItems: items,
        )
    }

    static func repostedByText(_ name: String?) -> String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return String(
                format: OWSLocalizedString("TELLOMI_FEED_REPOSTED_BY", comment: "Feed: line above a post that shows up because someone reposted it. Embeds {{name}}."),
                name,
            )
        }
        return OWSLocalizedString("TELLOMI_FEED_REPOSTED_BY_UNKNOWN", comment: "Feed: line above a reposted post when the reposter's name is unknown.")
    }

    /// 引用盒里的字：作者名 + 开头（标题优先，否则正文、摘要）；看不到了 / 删了是灰字（第 41 条）。
    struct Quote: Equatable {
        var authorName: String?
        var text: String?
        var goneText: String?
    }

    static func quote(_ quoted: FeedQuotedCard) -> Quote {
        guard let inner = quoted.card else {
            let gone = quoted.deleted
                ? OWSLocalizedString("TELLOMI_FEED_QUOTE_DELETED", comment: "Feed: shown in the quote box when the quoted post was deleted by its author.")
                : OWSLocalizedString("TELLOMI_FEED_QUOTE_UNAVAILABLE", comment: "Feed: shown in the quote box when the quoted post can no longer be seen.")
            return Quote(authorName: nil, text: nil, goneText: gone)
        }
        let title = inner.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (title?.isEmpty == false ? title : nil) ?? inner.text ?? inner.summary
        return Quote(authorName: inner.author?.displayName.feedNonBlank, text: text?.feedNonBlank, goneText: nil)
    }
}

// MARK: - 引用盒

/// 被引用的那条：圆角细边框的小框，作者名加开头三行；点开是那条的详情（看不到了就不响应）。
final class FeedQuotedBoxView: UIControl {
    static let textLines = 3

    private let authorLabel = UILabel()
    /// 被引用那条里的网址可以点（`FeedLinkLabel`）；点别的地方照旧打开那条的详情。
    private let bodyLabel = FeedLinkLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor.Signal.opaqueSeparator.cgColor
        backgroundColor = UIColor.Signal.background

        authorLabel.font = .dynamicTypeSubheadlineClamped.semibold()
        authorLabel.textColor = UIColor.Signal.label
        bodyLabel.font = .dynamicTypeSubheadlineClamped
        bodyLabel.numberOfLines = Self.textLines
        bodyLabel.lineBreakMode = .byTruncatingTail

        let column = UIStackView(arrangedSubviews: [authorLabel, bodyLabel])
        column.axis = .vertical
        column.spacing = 2
        column.isUserInteractionEnabled = false
        // 外层不接触摸，链接的手势靠 `hitTest` 把点中链接的触摸交给正文
        addSubview(column)
        column.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ quote: FeedCardExtras.Quote) {
        if let gone = quote.goneText {
            authorLabel.isHidden = true
            bodyLabel.setText(gone, font: .dynamicTypeSubheadlineClamped, color: UIColor.Signal.secondaryLabel)
            // 提示语不是用户写的字：不认网址
            bodyLabel.isUserInteractionEnabled = false
            isEnabled = false
            accessibilityLabel = gone
            accessibilityTraits = .staticText
            return
        }
        authorLabel.text = quote.authorName
        authorLabel.isHidden = quote.authorName == nil
        bodyLabel.setText(quote.text, font: .dynamicTypeSubheadlineClamped, color: UIColor.Signal.label)
        bodyLabel.isHidden = quote.text == nil
        isEnabled = true
        accessibilityLabel = [quote.authorName, quote.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = .button
    }

    /// 点中正文里的链接时交给正文（打开 / 长按菜单），别的地方还是整个框（打开那条的详情）。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if isEnabled, bodyLabel.isUserInteractionEnabled, !bodyLabel.isHidden {
            let local = convert(point, to: bodyLabel)
            if bodyLabel.bounds.contains(local), bodyLabel.link(at: local) != nil {
                return bodyLabel
            }
        }
        return hit
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = UIColor.Signal.opaqueSeparator.cgColor
    }

    /// 单测用。
    var bodyLabelForTesting: FeedLinkLabel { bodyLabel }
}

// MARK: - 卡片里的投票

/// 卡片里的投票：和详情页 `FeedPollCell` 同一套逻辑（`FeedPollPresentation` / `FeedPollSelection` / `FeedPollOptionView`），
/// 只是做成一个 view 放进卡片。单选点一项就投；多选勾好后点「投票」。投票不能撤回，等服务端回了票数再换（`FeedStore.vote`）。
final class FeedCardPollView: UIView {
    var onVote: (([Int]) -> Void)?

    private let optionsStack = UIStackView()
    private let footerLabel = UILabel()
    private let voteButton = UIButton(type: .system)
    private var selection = FeedPollSelection()
    private var shownState: FeedPollState?
    private var presentation: FeedPollPresentation?
    private var card: FeedCard?
    private var interactive = false
    private(set) var optionViews = [FeedPollOptionView]()

    override init(frame: CGRect) {
        super.init(frame: frame)
        optionsStack.axis = .vertical
        optionsStack.spacing = 8

        footerLabel.font = .dynamicTypeFootnoteClamped
        footerLabel.textColor = UIColor.Signal.secondaryLabel
        footerLabel.numberOfLines = 0

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.title = OWSLocalizedString("TELLOMI_FEED_POLL_VOTE", comment: "Feed poll: button that submits the choices of a multiple-choice poll.")
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
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
        root.spacing = 8
        addSubview(root)
        root.autoPinEdgesToSuperviewEdges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `interactive == false`（引擎没部署 `polls`、只读）：只看结果 / 选项，点不了。
    func configure(card: FeedCard, interactive: Bool, now: Date = Date()) {
        guard let poll = card.poll else { return }
        if card.id != self.card?.id || card.pollState != shownState { selection = FeedPollSelection() }
        self.card = card
        self.interactive = interactive
        shownState = card.pollState
        let presentation = FeedPollPresentation(poll: poll, state: card.pollState, interactive: interactive, now: now)
        self.presentation = presentation
        optionViews.forEach { $0.removeFromSuperview() }
        optionViews = poll.options.enumerated().map { index, text in
            let view = FeedPollOptionView()
            view.configure(
                text: text,
                showResults: presentation.showResults,
                percent: presentation.percents.indices.contains(index) ? presentation.percents[index] : 0,
                fraction: presentation.fractions.indices.contains(index) ? presentation.fractions[index] : 0,
                mine: presentation.mine.indices.contains(index) && presentation.mine[index],
                checked: selection.checked.contains(index),
                multi: presentation.multi,
                enabled: presentation.canVote,
            )
            view.addAction(UIAction { [weak self] _ in self?.tapped(index) }, for: .touchUpInside)
            optionsStack.addArrangedSubview(view)
            return view
        }
        voteButton.isHidden = !(presentation.canVote && presentation.multi)
        voteButton.isEnabled = selection.canSubmit
        footerLabel.text = FeedPollCell.footerText(presentation)
    }

    func tapped(_ index: Int) {
        guard let presentation, presentation.canVote else { return }
        if let immediate = selection.tap(index, multi: presentation.multi) {
            onVote?(immediate)
        } else if let card {
            configure(card: card, interactive: interactive)
        }
    }
}

private extension String {
    var feedNonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}
