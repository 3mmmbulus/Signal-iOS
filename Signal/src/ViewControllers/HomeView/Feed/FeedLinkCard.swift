//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import SignalUI
import UIKit

/// 动态帖子里的链接卡片：和聊天里的第三方链接卡同一套样式（`TellomiLinkCardStyle`，参照 Apple「信息」，DESIGN.md §9）。
///
/// 抓取规则跟聊天一致：预览只由发送方抓，收到的一方从不为了画卡去访问对方贴的网址（ADR-0063 §4.4）。
/// 动态的帖子现在不带预览数据（TestFlight 里是本机示例数据），所以卡片只用网址本身画：
/// 只有域名的中性灰横条，右边指南针——正是「完全没信息」的那一种（产品经理 2026-10-19 晚：指南针只给这种卡）。
/// 以后引擎带上预览（标题 / 认领档）时传 `Preview`，样式照 `TellomiLinkCardStyle.kind` 自动换成文字横条。
/// 交互参考 Telegram 的行为（不用它的代码）：点卡片直接打开，长按是「打开链接 / 复制 / 取消」。
struct FeedLinkCard: Equatable {

    /// 引擎给的预览（现在没有来源，预留）。动态这边没有图片管线，不画图标横条 / 大图卡。
    struct Preview: Equatable {
        var title: String?
        /// 认领档（`TellomiLinkCard.isClaimedTier`）：没有图时右边不画指南针。
        var isClaimed: Bool = false
    }

    let url: URL
    let kind: TellomiLinkCardStyle.Kind
    let text: TellomiLinkCardStyle.Text
    let showsCompass: Bool

    /// 帖子正文里的第一条网址做卡片（聊天同样只给第一条链接画卡）；没有网址、长文（点开是阅读页）、取不到域名时是 nil。
    static func make(body: String?, isArticle: Bool, preview: Preview? = nil) -> FeedLinkCard? {
        guard !isArticle, let body, let first = FeedTextLinks.detect(in: body).first else {
            return nil
        }
        return make(url: first.url, preview: preview)
    }

    static func make(url: URL, preview: Preview?) -> FeedLinkCard? {
        let isPlainLink = preview == nil
        guard let text = TellomiLinkCardStyle.text(
            title: isPlainLink ? nil : preview?.title,
            domain: nil,
            urlString: url.absoluteString,
        ) else {
            return nil
        }
        let kind = TellomiLinkCardStyle.kind(
            layout: isPlainLink ? nil : .noImage,
            hasImage: false,
            hasTitle: text.title != nil,
            isPlainLink: isPlainLink,
        )
        return FeedLinkCard(
            url: url,
            kind: kind,
            text: text,
            showsCompass: TellomiLinkCardStyle.showsCompass(kind: kind, isClaimed: preview?.isClaimed ?? false),
        )
    }

    /// 读屏：标题、域名，再加「链接」特征（视图上设）。
    var accessibilityLabel: String {
        [text.title, text.domain].compactMap { $0 }.joined(separator: ", ")
    }
}

/// 卡片视图：数值和聊天的横条一致（`CVLinkPreviewViewAdapterTellomiStrip`）：内边距 9 / 14 / 9 / 10、间距 10、
/// 指南针 26 pt、圆角 18（单独一块的卡片和气泡一样大）、中性灰底（`TellomiLinkCardColors`）。
final class FeedLinkCardView: UIControl {
    static let cornerRadius: CGFloat = 18
    static let compassSize: CGFloat = 26

    private(set) var card: FeedLinkCard?
    weak var presenter: UIViewController?
    /// 测试 / 宿主可以换掉默认的打开方式。
    var onOpen: ((URL) -> Void)?
    var onMenu: ((URL) -> Void)?

    private let titleLabel = UILabel()
    private let domainLabel = UILabel()
    private let compassView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = Self.cornerRadius
        layer.masksToBounds = true
        backgroundColor = TellomiLinkCardColors.neutralBackground

        titleLabel.font = UIFont.dynamicTypeSubheadline.semibold()
        titleLabel.textColor = TellomiLinkCardColors.neutralTitle
        titleLabel.numberOfLines = TellomiLinkCardStyle.maxTitleLines
        titleLabel.lineBreakMode = .byTruncatingTail
        domainLabel.numberOfLines = 1
        domainLabel.lineBreakMode = .byTruncatingTail
        domainLabel.textColor = TellomiLinkCardColors.neutralSecondary

        let configuration = UIImage.SymbolConfiguration(pointSize: Self.compassSize, weight: .regular)
        compassView.image = UIImage(systemName: "safari", withConfiguration: configuration)?.withRenderingMode(.alwaysTemplate)
        compassView.contentMode = .scaleAspectFit
        compassView.tintColor = TellomiLinkCardColors.neutralSecondary
        compassView.autoSetDimensions(to: CGSize(square: Self.compassSize))
        compassView.setContentHuggingPriority(.required, for: .horizontal)
        compassView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, domainLabel])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        let row = UIStackView(arrangedSubviews: [textStack, compassView])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 10))
        // 横条至少和指南针一样高（上下各留 9），没有指南针时高度也一样。
        autoSetDimension(.height, toSize: Self.compassSize + 18, relation: .greaterThanOrEqual)

        addTarget(self, action: #selector(didTap), for: .touchUpInside)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(didLongPress(_:))))
        isAccessibilityElement = true
        accessibilityTraits = .link
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ card: FeedLinkCard?) {
        self.card = card
        isHidden = card == nil
        guard let card else { return }
        titleLabel.text = card.text.title
        titleLabel.isHidden = card.text.title == nil
        // 只有域名时它就是唯一一行：字号和标题一样、不加粗（同聊天）。
        domainLabel.font = card.text.title == nil ? .dynamicTypeSubheadline : .dynamicTypeFootnote
        domainLabel.text = card.text.domain
        compassView.isHidden = !card.showsCompass
        accessibilityLabel = card.accessibilityLabel
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    @objc private func didTap() {
        guard let url = card?.url else { return }
        if let onOpen {
            onOpen(url)
        } else {
            FeedTextLinks.open(url, from: presenter)
        }
    }

    @objc private func didLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let url = card?.url else { return }
        if let onMenu {
            onMenu(url)
        } else {
            FeedTextLinks.showMenu(for: url, from: presenter)
        }
    }

    /// 单测用。
    var titleTextForTesting: String? { titleLabel.isHidden ? nil : titleLabel.text }
    var domainTextForTesting: String? { domainLabel.text }
    var isCompassVisibleForTesting: Bool { !compassView.isHidden }
    func simulateTapForTesting() { didTap() }
}
