//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// `FeedStore` 里什么变了。列表页和帖子详情页**订阅同一个** `FeedStore`，各自不留一份卡片副本：
/// 谁点了赞，store 里改一次，两边都收到通知、都从 store 里重新读。
enum FeedChange: Equatable {
    /// 某一栏（nil = 全部 / 说不清）的列表、加载状态、已隐藏的卡片变了。
    case list(FeedTab?)
    /// 这些卡片自己的内容变了（赞、收藏、转发、投票、置顶、评论数、重新取到了最新的）。
    case cards(Set<String>)
    /// 卡片上的一个动作（现在是点赞）失败了，已经改回来；订阅者可以在自己的页面上提示。
    case actionFailed(cardId: String)
    /// 通知的未读数变了（`FeedStore.notificationUnread`）：动态页的红点和通知页共用这一份。
    case unread
}

/// `FeedStore.subscribe` 的回执：**拿着它就订着**。`cancel()`、或者把它放掉（页面销毁）就不再收到通知，
/// store 里只弱引用它，所以页面忘了取消也不会泄漏、也不会收到销毁后的回调。
@MainActor
final class FeedSubscription {
    private var handler: ((FeedChange) -> Void)?

    init(_ handler: @escaping (FeedChange) -> Void) {
        self.handler = handler
    }

    var isActive: Bool {
        return handler != nil
    }

    func cancel() {
        handler = nil
    }

    func deliver(_ change: FeedChange) {
        handler?(change)
    }
}

/// 一个页面（帖子详情）把一张卡片「借」在 `FeedStore` 里的凭证：拿着它，这张卡片就一直在 store 里，
/// 就算这张卡片所在的那一栏刷新后不再包含它（或者它本来就不在两栏里：从个人主页、通知打开的帖子）。
/// 放掉凭证（页面销毁）后，不在任何一栏里的那张卡片就从 store 里清掉，不会越攒越多。
@MainActor
final class FeedCardLease {
    let id: String

    init(id: String) {
        self.id = id
    }
}
