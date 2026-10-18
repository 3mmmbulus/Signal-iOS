//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 搜索页、话题页这类「列表里的帖子不是信息流自己的」页面，和信息流共用同一份卡片的办法（`FeedProfilePageStore` 里的同一套，抽出来给两处用）：
/// - 新取回来的卡片先 `ingest` 进 `FeedStore`（信息流里同一张换成最新的），再 `retain` 借着（信息流刷新也不会把它清掉）；页面上画的是信息流里现在的样子。
/// - 订阅 `FeedStore`：卡片变了（别处点了赞…）或者没了（屏蔽了作者、删了帖子）就叫页面重新投影；赞失败要提示也从这里来。
/// - 页面离开时 `detach()`：不再订阅、放掉借着的卡片。
@MainActor
final class FeedCardMirror {
    private let feed: FeedStore
    private var leases = [FeedCardLease]()
    private var subscription: FeedSubscription?

    /// 页面现在显示着哪些帖子（订阅到通知时用来判断和自己有没有关系）。
    var shownIds: () -> Set<String> = { [] }
    /// 信息流里的卡片变了 / 没了：页面该重新 `project`。
    var onChange: (() -> Void)?
    /// 页面上某条帖子的动作（点赞）失败了，已经改回来。
    var onActionFailed: (() -> Void)?

    init(feed: FeedStore) {
        self.feed = feed
        subscription = feed.subscribe { [weak self] change in
            self?.received(change)
        }
    }

    var isObserving: Bool { subscription?.isActive == true }
    var leaseCount: Int { leases.count }

    func detach() {
        subscription?.cancel()
        subscription = nil
        leases = []
        onChange = nil
        onActionFailed = nil
    }

    /// 重新取第一页之前：放掉旧的借用。
    func releaseAll() {
        leases = []
    }

    /// 一页新取回来的帖子：换进信息流、借着，返回信息流里现在的样子。
    func adopt(_ cards: [FeedCard]) -> [FeedCard] {
        var adopted = [FeedCard]()
        for card in cards where !feed.isRemoved(card) {
            feed.ingest(card)
            leases.append(feed.retain(card))
            adopted.append(feed.card(id: card.id) ?? card)
        }
        return adopted
    }

    /// 页面上的帖子换成信息流里现在的样子；屏蔽了作者、删了帖子的去掉。
    func project(_ cards: [FeedCard]) -> [FeedCard] {
        return cards.compactMap { feed.isRemoved($0) ? nil : (feed.card(id: $0.id) ?? $0) }
    }

    func has(_ id: String) -> Bool {
        return feed.card(id: id) != nil
    }

    func update(_ id: String, _ change: (FeedCard) -> FeedCard) {
        feed.updateCard(id) { $0 = change($0) }
    }

    func toggleLike(id: String) {
        feed.toggleLike(id: id)
    }

    func waitForActions() async {
        await feed.waitForActions()
    }

    private func received(_ change: FeedChange) {
        let shown = shownIds()
        switch change {
        case .cards(let ids):
            if !ids.isDisjoint(with: shown) { onChange?() }
        case .list:
            onChange?()
        case .actionFailed(let cardId):
            if shown.contains(cardId) { onActionFailed?() }
        }
    }
}
