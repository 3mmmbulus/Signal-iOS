//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 「我的动态」顶上的草稿入口：本机存着没写完的长文时给一行「继续写」，点开是发布页（会把草稿接回来）。
/// 写什么由 `FeedComposeDraftEntry` 算（有单测）。
final class FeedDraftEntryHeader: UIView {

    var onTap: (() -> Void)?

    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        addSubview(button)
        button.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16))
        let divider = UIView()
        divider.backgroundColor = UIColor.Signal.opaqueSeparator
        addSubview(divider)
        divider.autoPinEdge(toSuperviewEdge: .leading)
        divider.autoPinEdge(toSuperviewEdge: .trailing)
        divider.autoPinEdge(toSuperviewEdge: .bottom)
        divider.autoSetDimension(.height, toSize: 1 / max(UIScreen.main.scale, 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static var titleText: String {
        return OWSLocalizedString("TELLOMI_FEED_MINE_DRAFT_TITLE", comment: "Feed my posts page: title of the row that continues an unfinished article saved on this phone.")
    }

    static func subtitleText(_ entry: FeedComposeDraftEntry) -> String {
        let count = String(
            format: OWSLocalizedString("TELLOMI_FEED_MINE_DRAFT_COUNT", comment: "Feed my posts page: length of the unfinished article. Embeds {{number of characters}}."),
            OWSFormat.formatInt(entry.characterCount),
        )
        return "\(entry.headline) · \(count)"
    }

    func configure(_ entry: FeedComposeDraftEntry) {
        var config = UIButton.Configuration.plain()
        config.title = Self.titleText
        config.subtitle = Self.subtitleText(entry)
        config.image = UIImage(systemName: "square.and.pencil")
        config.imagePadding = 12
        config.contentInsets = .zero
        config.titleAlignment = .leading
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.dynamicTypeBodyClamped.semibold()
            return attributes
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.dynamicTypeSubheadlineClamped
            attributes.foregroundColor = UIColor.Signal.secondaryLabel
            return attributes
        }
        button.configuration = config
        button.accessibilityLabel = Self.titleText
        button.accessibilityValue = Self.subtitleText(entry)
        invalidateIntrinsicContentSize()
    }
}
