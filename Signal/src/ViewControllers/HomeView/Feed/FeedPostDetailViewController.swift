//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 帖子详情（`dynamic-feed.md` 第三节第 2、4 条）：整条帖子在最上面，下面是评论（按楼排，楼里的回复缩进）。
/// 在信息流里点一条帖子打开（`FeedViewController.openPost`）。数据在 `FeedPostDetailStore`，画什么由 `FeedPostDetailPresentation` 决定。
///
/// 这一刀只读：帖子上的点赞和「···」不能点（`FeedPostCell.isReadOnly`），没有评论输入框；评论区有「加载中 / 加载失败（重试）/ 还没有评论」，
/// 帖子已经看不到了显示「已不可见」。点赞、评论、转发、收藏等随后面的步骤接。
final class FeedPostDetailViewController: OWSViewController {

    /// 离评论列表底部还剩几行时取下一页。
    static let loadMoreThreshold = 3

    private enum Row {
        case post
        case comment(FeedPostDetailPresentation.CommentRow)
        case status(FeedPostDetailPresentation.CommentsPhase)
    }

    private let store: FeedPostDetailStore
    private let fallbackShowIpRegion: Bool
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let footerSpinner = UIActivityIndicatorView(style: .medium)
    private lazy var goneView = FeedEmptyStateView(
        title: OWSLocalizedString("TELLOMI_FEED_DETAIL_GONE_TITLE", comment: "Feed: title of the post page when the post was deleted or can no longer be seen."),
        body: OWSLocalizedString("TELLOMI_FEED_DETAIL_GONE_BODY", comment: "Feed: explanation under the title when the post can no longer be seen."),
    )

    private var rows = [Row]()
    private var post: FeedCard
    private var showIpRegion: Bool

    /// - Parameters:
    ///   - post: 信息流里带过来的那张卡片，先用它画出来，再向 Card API 取最新的。
    ///   - showIpRegion: 信息流里是不是显示 IP 属地；详情拿到自己的配置后以配置为准。
    init(post: FeedCard, source: FeedSource, showIpRegion: Bool) {
        self.post = post
        self.showIpRegion = showIpRegion
        fallbackShowIpRegion = showIpRegion
        store = FeedPostDetailStore(initial: post, source: source)
        super.init()
        // 和 Telegram 一样：推进去以后底栏收起来
        hidesBottomBarWhenPushed = true
        title = OWSLocalizedString("TELLOMI_FEED_DETAIL_TITLE", comment: "Feed: title of the page that shows one post and its comments.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.Signal.background
        navigationItem.largeTitleDisplayMode = .never

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(FeedPostCell.self, forCellReuseIdentifier: FeedPostCell.reuseIdentifier)
        tableView.register(FeedCommentCell.self, forCellReuseIdentifier: FeedCommentCell.reuseIdentifier)
        tableView.register(FeedDetailStatusCell.self, forCellReuseIdentifier: FeedDetailStatusCell.reuseIdentifier)
        view.addSubview(tableView)
        tableView.autoPinEdgesToSuperviewEdges()

        goneView.isHidden = true
        view.addSubview(goneView)
        goneView.autoPinEdgesToSuperviewEdges()

        footerSpinner.frame = CGRect(x: 0, y: 0, width: 0, height: 56)

        store.onChange = { [weak self] state in
            self?.apply(state)
        }
        apply(store.state)
        store.start()
    }

    /// 把 `store` 的状态画出来。
    private func apply(_ state: FeedPostDetailState) {
        guard isViewLoaded else { return }

        switch FeedPostDetailPresentation.page(for: state) {
        case .postGone:
            tableView.isHidden = true
            goneView.isHidden = false
            return
        case .post:
            tableView.isHidden = false
            goneView.isHidden = true
        }

        post = state.post
        showIpRegion = state.showIpRegion || fallbackShowIpRegion

        var newRows: [Row] = [.post]
        let phase = FeedPostDetailPresentation.commentsPhase(for: state)
        if phase == .content {
            newRows += FeedPostDetailPresentation.commentRows(for: state).map { Row.comment($0) }
        } else {
            newRows.append(.status(phase))
        }
        rows = newRows
        tableView.reloadData()

        if FeedPostDetailPresentation.hasMoreComments(for: state) {
            footerSpinner.startAnimating()
            tableView.tableFooterView = footerSpinner
        } else {
            footerSpinner.stopAnimating()
            tableView.tableFooterView = nil
        }
    }
}

extension FeedPostDetailViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .post:
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedPostCell.reuseIdentifier, for: indexPath) as! FeedPostCell
            cell.isReadOnly = true
            cell.configure(card: post, showIpRegion: showIpRegion)
            return cell
        case .comment(let row):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedCommentCell.reuseIdentifier, for: indexPath) as! FeedCommentCell
            cell.configure(row: row)
            return cell
        case .status(let phase):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedDetailStatusCell.reuseIdentifier, for: indexPath) as! FeedDetailStatusCell
            cell.configure(phase: phase) { [weak self] in
                self?.store.refreshComments()
            }
            return cell
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if cell is FeedCommentCell, indexPath.row >= rows.count - Self.loadMoreThreshold {
            store.loadMoreComments()
        }
    }
}

/// 评论区还没有评论时占一行：加载中转圈；加载失败「加载失败」+「重试」；没有评论「还没有评论」。
private final class FeedDetailStatusCell: UITableViewCell {
    static let reuseIdentifier = "FeedDetailStatusCell"

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var onRetry: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        titleLabel.font = .dynamicTypeHeadline
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        bodyLabel.font = .dynamicTypeSubheadline
        bodyLabel.textColor = UIColor.Signal.secondaryLabel
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        retryButton.setTitle(OWSLocalizedString("TELLOMI_FEED_RETRY", comment: "Feed: button that tries loading the feed again."), for: .normal)
        retryButton.titleLabel?.font = .dynamicTypeBody.semibold()
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, bodyLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        contentView.addSubview(stack)
        stack.autoPinEdge(toSuperviewEdge: .top, withInset: 40)
        stack.autoPinEdge(toSuperviewEdge: .bottom, withInset: 40)
        stack.autoPinEdge(toSuperviewEdge: .leading, withInset: 40)
        stack.autoPinEdge(toSuperviewEdge: .trailing, withInset: 40)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(phase: FeedPostDetailPresentation.CommentsPhase, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        switch phase {
        case .loading, .content:
            // `.content` 不会来到这里（有评论就画评论）；万一来了就当加载中，不显示文字
            spinner.isHidden = false
            spinner.startAnimating()
            titleLabel.isHidden = true
            bodyLabel.isHidden = true
            retryButton.isHidden = true
        case .failed:
            spinner.stopAnimating()
            spinner.isHidden = true
            titleLabel.text = OWSLocalizedString("TELLOMI_FEED_COMMENTS_LOAD_FAILED", comment: "Feed: shown under a post when its comments could not be loaded.")
            titleLabel.isHidden = false
            bodyLabel.isHidden = true
            retryButton.isHidden = false
        case .empty:
            spinner.stopAnimating()
            spinner.isHidden = true
            titleLabel.text = OWSLocalizedString("TELLOMI_FEED_COMMENTS_EMPTY_TITLE", comment: "Feed: shown under a post that has no comments yet.")
            titleLabel.isHidden = false
            bodyLabel.text = OWSLocalizedString("TELLOMI_FEED_COMMENTS_EMPTY_BODY", comment: "Feed: explanation under 'No comments yet'.")
            bodyLabel.isHidden = false
            retryButton.isHidden = true
        }
    }
}
