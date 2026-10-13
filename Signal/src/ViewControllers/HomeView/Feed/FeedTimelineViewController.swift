//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 动态页的一栏（推荐或关注）。这一刀只有空状态；信息流、卡片随后面的 PR 接上
/// （契约 `docs/adr/0071/client-api-2026-10.md` 4.1）。
final class FeedTimelineViewController: OWSViewController {

    let feedTab: FeedTab
    let tableView = UITableView(frame: .zero, style: .plain)

    /// 是不是当前露出的这一栏。点状态栏回顶只交给当前这一栏。
    var isCurrentPage = false {
        didSet { tableView.scrollsToTop = isCurrentPage }
    }

    private lazy var emptyStateView = FeedEmptyStateView(title: feedTab.emptyTitle, body: feedTab.emptyBody)

    init(tab: FeedTab) {
        self.feedTab = tab
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.Signal.background

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.scrollsToTop = isCurrentPage
        view.addSubview(tableView)
        tableView.autoPinEdgesToSuperviewEdges()

        tableView.backgroundView = emptyStateView
    }

    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: true)
    }
}

/// 一栏没有内容时的提示：图标、标题、一句说明，居中。
final class FeedEmptyStateView: UIView {

    init(title: String, body: String) {
        super.init(frame: .zero)

        let imageView = UIImageView(image: UIImage(named: "tab-feed"))
        imageView.tintColor = UIColor.Signal.secondaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.autoSetDimensions(to: CGSize(square: 48))

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .dynamicTypeHeadline
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let bodyLabel = UILabel()
        bodyLabel.text = body
        bodyLabel.font = .dynamicTypeSubheadline
        bodyLabel.textColor = UIColor.Signal.secondaryLabel
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [imageView, titleLabel, bodyLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(16, after: imageView)
        addSubview(stack)
        stack.autoVCenterInSuperview()
        stack.autoPinEdge(toSuperviewEdge: .leading, withInset: 40)
        stack.autoPinEdge(toSuperviewEdge: .trailing, withInset: 40)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
