//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 帖子详情页底部「评论输入框」画什么：把 `FeedPostDetailState` 翻成输入框的外观和发送按钮的状态。
/// 只有逻辑、不碰 UIKit，Linux harness 里跑单测；页面只管照着画。字数上限、截断、组字规则都在 `FeedInputLimit`（按码点，500）和
/// `FeedPostDetailStore.onDraftEdit` / `onDraftChanged`，这里不重复实现，只读它们算好的 `draftRemaining` / `draftLimitHit`。
struct FeedCommentInputPresentation: Equatable {

    enum Placeholder: Equatable {
        /// 直接评论帖子。
        case comment
        /// 回复某条评论；名字是空的就是 nil（界面写不带名字的「回复」）。
        case reply(name: String?)
        /// 作者关了评论：输入框灰掉。
        case closed
    }

    /// 发送这件事现在处在哪一步。**只有 `.ready` 时发送按钮可点**（和 `FeedPostDetailState.canSend` 一致，单测逐一对过）。
    enum Submit: Equatable {
        /// 评论关了（`canComment == false`）。
        case cannotComment
        /// 正在发（按钮换成转圈，输入框先不让改，免得发出去后清掉新敲的字）。
        case sending
        /// 超了字数上限（输入法组字时可能超）：按钮灰、计数变红。
        case overLimit
        /// 没有可发的字（空的或只有空白）。
        case empty
        case ready
    }

    /// 剩余字数 ≤ 这个数才显示计数；平时不显示，不打扰。
    static let counterThreshold = 50

    var placeholder: Placeholder
    var submit: Submit
    /// 输入框能不能编辑（评论关了、或正在发就不能）。
    var isEditable: Bool
    /// 顶上「正在回复 xxx」的一行；不是在回复就没有。
    var replyBanner: ReplyBanner?
    /// 要显示的剩余字数（可以是负数）；不需要显示是 nil。
    var counterRemaining: Int?
    /// 碰到了上限（拦下或粘贴被截）：计数抖一下。
    var limitHit: Bool

    struct ReplyBanner: Equatable {
        var name: String?
    }

    init(state: FeedPostDetailState) {
        let name = Self.replyName(state.replyTarget)
        if !state.canComment {
            placeholder = .closed
        } else if state.replyTarget != nil {
            placeholder = .reply(name: name)
        } else {
            placeholder = .comment
        }

        let remaining = state.draftRemaining
        if !state.canComment {
            submit = .cannotComment
        } else if state.sending {
            submit = .sending
        } else if remaining < 0 {
            submit = .overLimit
        } else if state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            submit = .empty
        } else {
            submit = .ready
        }

        isEditable = state.canComment && !state.sending
        replyBanner = state.canComment && state.replyTarget != nil ? ReplyBanner(name: name) : nil
        counterRemaining = state.canComment && remaining <= Self.counterThreshold ? remaining : nil
        limitHit = state.draftLimitHit
    }

    var canSend: Bool {
        return submit == .ready
    }

    private static func replyName(_ target: FeedCard?) -> String? {
        let name = target?.author?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty ?? true) ? nil : name
    }
}

/// 帖子上「赞」的外观（列表卡片和详情页同一套规则）。
struct FeedLikePresentation: Equatable {
    var isLiked: Bool
    /// 要显示的赞数；作者隐藏了赞数、或还是 0 就不显示（nil）。
    var count: Int?

    init(card: FeedCard) {
        isLiked = card.viewer.liked
        count = !card.stats.likeCountHidden && card.stats.likes > 0 ? card.stats.likes : nil
    }
}
