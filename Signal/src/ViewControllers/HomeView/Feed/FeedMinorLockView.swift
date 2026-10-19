//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 未成年人时限（I-15）的提示页：盖在动态标签上（夜间 22:00–6:00 / 当天用满 40 分钟）。只挡动态，聊天照用。
/// 大字号时能滚动，字不截断。
final class FeedMinorLockView: UIView {
    let iconView = UIImageView()
    let titleLabel = UILabel()
    let bodyLabel = UILabel()
    private let scrollView = UIScrollView()

    private(set) var lock: FeedMinorTime.Lock?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.Signal.background
        accessibilityViewIsModal = true

        iconView.tintColor = UIColor.Signal.secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .largeTitle, scale: .large)
        iconView.isAccessibilityElement = false

        titleLabel.font = UIFont.dynamicTypeTitle2.semibold()
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header

        bodyLabel.font = UIFont.dynamicTypeBody
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = UIColor.Signal.secondaryLabel
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, bodyLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(20, after: iconView)

        addSubview(scrollView)
        scrollView.autoPinEdgesToSuperviewEdges()
        scrollView.alwaysBounceVertical = false
        let content = UIView()
        scrollView.addSubview(content)
        content.autoPinEdgesToSuperviewEdges()
        content.autoMatch(.width, to: .width, of: scrollView)
        content.autoMatch(.height, to: .height, of: scrollView, withOffset: 0, relation: .greaterThanOrEqual)
        content.addSubview(stack)
        stack.autoPinEdge(toSuperviewMargin: .leading)
        stack.autoPinEdge(toSuperviewMargin: .trailing)
        stack.autoPinEdge(toSuperviewEdge: .top, withInset: 32, relation: .greaterThanOrEqual)
        stack.autoPinEdge(toSuperviewEdge: .bottom, withInset: 32, relation: .greaterThanOrEqual)
        stack.autoVCenterInSuperview()
        content.layoutMargins = UIEdgeInsets(top: 0, left: 32, bottom: 0, right: 32)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ lock: FeedMinorTime.Lock) {
        self.lock = lock
        iconView.image = UIImage(systemName: FeedMinorLockPresentation.symbolName(lock))
        titleLabel.text = Self.title(lock)
        bodyLabel.text = Self.body(lock)
    }

    static func title(_ lock: FeedMinorTime.Lock) -> String {
        switch lock {
        case .night:
            return OWSLocalizedString("TELLOMI_FEED_MINOR_LOCK_NIGHT_TITLE", comment: "Feed minor mode: title of the page covering the feed between 22:00 and 6:00.")
        case .daily:
            return OWSLocalizedString("TELLOMI_FEED_MINOR_LOCK_DAILY_TITLE", comment: "Feed minor mode: title of the page covering the feed after 40 minutes of use today.")
        }
    }

    static func body(_ lock: FeedMinorTime.Lock) -> String {
        switch lock {
        case .night:
            return OWSLocalizedString("TELLOMI_FEED_MINOR_LOCK_NIGHT_BODY", comment: "Feed minor mode: explanation that the feed can't be used between 22:00 and 6:00; chats still work.")
        case .daily:
            return OWSLocalizedString("TELLOMI_FEED_MINOR_LOCK_DAILY_BODY", comment: "Feed minor mode: explanation that the feed can be used 40 minutes a day; chats still work.")
        }
    }
}
