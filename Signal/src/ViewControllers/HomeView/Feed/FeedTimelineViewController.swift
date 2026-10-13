//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 动态页的一栏（推荐或关注，契约 `docs/adr/0071/client-api-2026-10.md` 4.1）：
/// 下拉刷新、滑到底自动取下一页、点赞、「不感兴趣」可撤销。和 Android `FeedListPane` 的 `FeedTimeline` 同一套行为。
final class FeedTimelineViewController: OWSViewController {

    /// 离列表底部还剩几条时取下一页。
    static let loadMoreThreshold = 4

    let feedTab: FeedTab
    let tableView = UITableView(frame: .zero, style: .plain)
    private let store: FeedStore

    /// 是不是当前露出的这一栏。点状态栏回顶只交给当前这一栏。
    var isCurrentPage = false {
        didSet {
            tableView.scrollsToTop = isCurrentPage
            reportVisibleCards()
        }
    }

    /// 动态页现在在屏幕上（不是在别的标签、不在后台）。
    var isFeedVisible = false {
        didSet { reportVisibleCards() }
    }

    private lazy var emptyStateView = FeedEmptyStateView(title: feedTab.emptyTitle, body: feedTab.emptyBody)
    private lazy var errorStateView = FeedErrorStateView { [weak self] in
        guard let self else { return }
        self.store.refresh(self.feedTab)
    }
    private let loadingView = UIActivityIndicatorView(style: .medium)
    private let footerSpinner = UIActivityIndicatorView(style: .medium)
    private let refreshControl = UIRefreshControl()

    /// 上一次画出来的行（id + 是不是反馈卡）。没变时只就地更新可见的格子，不整表重载。
    private var renderedRows = [Row]()

    struct Row: Equatable {
        var card: FeedCard
        var isHidden: Bool
    }

    init(tab: FeedTab, store: FeedStore) {
        self.feedTab = tab
        self.store = store
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.Signal.background

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.scrollsToTop = isCurrentPage
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 160
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(FeedPostCell.self, forCellReuseIdentifier: FeedPostCell.reuseIdentifier)
        tableView.register(FeedHiddenCell.self, forCellReuseIdentifier: FeedHiddenCell.reuseIdentifier)
        // 右下角的发布按钮不挡最后一条
        tableView.contentInset.bottom = FeedViewController.composeButtonSize + 24
        view.addSubview(tableView)
        tableView.autoPinEdgesToSuperviewEdges()

        refreshControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.store.refresh(self.feedTab)
        }, for: .valueChanged)
        tableView.refreshControl = refreshControl

        footerSpinner.frame = CGRect(x: 0, y: 0, width: 0, height: 56)

        apply()
    }

    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: true)
    }

    /// 把 `store` 里这一栏的状态画出来。
    func apply() {
        guard isViewLoaded else { return }
        let state = store.tab(feedTab)
        let rows = state.cards.map { Row(card: $0, isHidden: store.hiddenIds.contains($0.id)) }

        if rows.map(\.card.id) == renderedRows.map(\.card.id), rows.map(\.isHidden) == renderedRows.map(\.isHidden) {
            renderedRows = rows
            for case let cell as FeedPostCell in tableView.visibleCells {
                guard let indexPath = tableView.indexPath(for: cell), let row = rows[safe: indexPath.row] else { continue }
                cell.configure(card: row.card, showIpRegion: store.showsIpRegion)
            }
        } else {
            renderedRows = rows
            tableView.reloadData()
        }

        if state.cards.isEmpty, state.loading || !state.loadedOnce {
            loadingView.startAnimating()
            tableView.backgroundView = loadingView
        } else if state.cards.isEmpty, state.failed {
            tableView.backgroundView = errorStateView
        } else if state.cards.isEmpty {
            tableView.backgroundView = emptyStateView
        } else {
            tableView.backgroundView = nil
        }

        if state.nextCursor != nil, !state.cards.isEmpty {
            footerSpinner.startAnimating()
            tableView.tableFooterView = footerSpinner
        } else {
            footerSpinner.stopAnimating()
            tableView.tableFooterView = nil
        }

        if !state.refreshing, refreshControl.isRefreshing {
            refreshControl.endRefreshing()
        }

        reportVisibleCards()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reportVisibleCards()
    }

    /// 曝光（契约 6.1）：露出过半的帖子交给 `FeedStore` 计时；不是当前这一栏、动态页不在屏幕上时报空。
    /// 「不感兴趣」后的反馈卡不算。
    func reportVisibleCards() {
        guard isViewLoaded else { return }
        store.onCardsVisible(feedTab, visibleCardIds())
    }

    func visibleCardIds() -> Set<String> {
        guard isCurrentPage, isFeedVisible else { return [] }
        let viewportMinY = tableView.contentOffset.y + tableView.adjustedContentInset.top
        let viewportMaxY = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom
        var ids = Set<String>()
        for case let cell as FeedPostCell in tableView.visibleCells {
            guard let card = cell.card else { continue }
            let fraction = FeedImpressionTracker.visibleFraction(
                itemMinY: cell.frame.minY,
                itemHeight: cell.frame.height,
                viewportMinY: viewportMinY,
                viewportMaxY: viewportMaxY,
            )
            if fraction >= FeedImpressionTracker.minVisibleFraction {
                ids.insert(card.id)
            }
        }
        return ids
    }

    var rows: [Row] {
        return renderedRows
    }
}

extension FeedTimelineViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return renderedRows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = renderedRows[indexPath.row]
        if row.isHidden {
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedHiddenCell.reuseIdentifier, for: indexPath) as! FeedHiddenCell
            let cardId = row.card.id
            cell.onUndo = { [weak self] in self?.store.undoNotInterested(cardId) }
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: FeedPostCell.reuseIdentifier, for: indexPath) as! FeedPostCell
        cell.configure(card: row.card, showIpRegion: store.showsIpRegion)
        cell.onLike = { [weak self] card in self?.store.toggleLike(card) }
        cell.onNotInterested = { [weak self] card in self?.store.notInterested(card) }
        return cell
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportVisibleCards()
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row >= renderedRows.count - Self.loadMoreThreshold {
            store.loadMore(feedTab)
        }
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

/// 第一次加载就失败（列表是空的）：「加载失败」+「重试」。有内容时失败只弹一句提示，不换掉列表。
final class FeedErrorStateView: UIView {

    init(onRetry: @escaping () -> Void) {
        super.init(frame: .zero)

        let titleLabel = UILabel()
        titleLabel.text = OWSLocalizedString("TELLOMI_FEED_LOAD_FAILED", comment: "Feed: shown when the first page of a feed tab could not be loaded.")
        titleLabel.font = .dynamicTypeHeadline
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let retryButton = UIButton(type: .system)
        retryButton.setTitle(OWSLocalizedString("TELLOMI_FEED_RETRY", comment: "Feed: button that tries loading the feed again."), for: .normal)
        retryButton.titleLabel?.font = .dynamicTypeBody.semibold()
        retryButton.addAction(UIAction { _ in onRetry() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
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
