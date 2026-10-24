//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 打开一条动态的外链（`tell.cc/m#<id>`，I-16）：先转圈，取到卡就换成帖子详情，取不到写「这条动态已不可见」，
/// 网络失败给「重试」。状态在 `FeedPostLinkStore`（Android `FeedPostLinkActivity` / `FeedPostLinkViewModel`）。
/// 从 App 外面（`UrlOpener`）和聊天里（`ConversationViewController.handleUrl`）都走 `present(link:from:)`。
final class FeedPostLinkViewController: OWSViewController {

    private let store: FeedPostLinkStore
    private let source: FeedSource
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var stateView: UIView?

    init(link: String, feedEnabled: Bool = TellomiFeed.isTabEnabled, source: FeedSource = FeedSources.current()) {
        self.source = source
        self.store = FeedPostLinkStore(link: link, feedEnabled: feedEnabled, source: { source })
        super.init()
        title = OWSLocalizedString("TELLOMI_FEED_DETAIL_TITLE", comment: "Feed: title of the page that shows one post and its comments.")
    }

    /// 盖一层导航（关闭在左上角），里面先是这一页。
    @MainActor
    static func present(link: String, from presenter: UIViewController) {
        let landing = FeedPostLinkViewController(link: link)
        let navigation = OWSNavigationController(rootViewController: landing)
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Signal.background
        navigationItem.leftBarButtonItem = .cancelButton(dismissingFrom: self)
        view.addSubview(spinner)
        spinner.autoCenterInSuperview()
        store.onChange = { [weak self] state in self?.render(state) }
        render(store.state)
        store.load()
    }

    /// 文案（单测钉住键名）。
    static var goneText: String {
        OWSLocalizedString("TELLOMI_FEED_POST_LINK_GONE", comment: "Feed: shown when a link to a feed post is opened but the post can no longer be seen (deleted, hidden, or not open to you).")
    }

    private func render(_ state: FeedPostLinkStore.State) {
        stateView?.removeFromSuperview()
        stateView = nil
        switch state {
        case .loading:
            spinner.startAnimating()
        case .ready(let card):
            spinner.stopAnimating()
            showDetail(card)
        case .gone:
            spinner.stopAnimating()
            let label = UILabel()
            label.text = Self.goneText
            label.font = .dynamicTypeHeadline
            label.textColor = UIColor.Signal.secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            install(label)
        case .failed:
            spinner.stopAnimating()
            install(FeedErrorStateView { [weak self] in self?.store.load() })
        }
    }

    private func install(_ stateView: UIView) {
        view.addSubview(stateView)
        stateView.autoPinEdge(toSuperviewSafeArea: .leading, withInset: 40)
        stateView.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 40)
        stateView.autoVCenterInSuperview()
        self.stateView = stateView
    }

    /// 取到了：这一页换成详情（返回不回到转圈页）。
    private func showDetail(_ card: FeedCard) {
        let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: false)
        detail.navigationItem.leftBarButtonItem = .cancelButton(dismissingFrom: detail)
        guard let navigationController else { return }
        var stack = navigationController.viewControllers
        if let index = stack.firstIndex(of: self) {
            stack[index] = detail
        } else {
            stack.append(detail)
        }
        navigationController.setViewControllers(stack, animated: false)
    }
}
