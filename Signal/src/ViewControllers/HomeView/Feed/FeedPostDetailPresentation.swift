//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 帖子详情页（`FeedPostDetailViewController`）画什么：把 `FeedPostDetailState` 翻成「整页状态 / 评论区状态 / 评论行」。
/// 只有逻辑、不碰 UIKit，Linux harness 里跑单测；页面只管照着画。
enum FeedPostDetailPresentation {

    /// 整页：帖子还能看，还是已经看不到了（Card API 说没有了：删了、被屏蔽、没权限）。
    enum Page: Equatable {
        case post
        case postGone
    }

    /// 帖子下面评论区的状态。有评论就一定是 `content`（刷新失败或在加载下一页也不换掉已经有的评论）。
    enum CommentsPhase: Equatable {
        case loading
        case failed
        case empty
        case content
    }

    struct CommentRow: Equatable {
        var comment: FeedCard
        /// 楼里的回复（缩进画）；楼主那条是 false。
        var isReply: Bool
        /// 回复的不是楼主那条时，被回复的人的名字（「回复 @某人」）；回的就是楼主、或名字是空的时为 nil。
        var replyToName: String?
    }

    static func page(for state: FeedPostDetailState) -> Page {
        return state.postGone ? .postGone : .post
    }

    static func commentsPhase(for state: FeedPostDetailState) -> CommentsPhase {
        if !state.comments.isEmpty {
            return .content
        }
        if state.failed {
            return .failed
        }
        // 还没拿到过第一页（`loadedOnce` 是 false）也算在加载，免得一打开就闪一下「还没有评论」
        if state.loading || !state.loadedOnce {
            return .loading
        }
        return .empty
    }

    /// 评论按楼排（`FeedCommentThreads`）：楼主一行，下面是它的回复。
    static func commentRows(for state: FeedPostDetailState) -> [CommentRow] {
        var rows = [CommentRow]()
        for thread in state.threads {
            rows.append(CommentRow(comment: thread.root, isReply: false, replyToName: nil))
            for reply in thread.replies {
                let name = thread.replyTo[reply.id]?.author?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                rows.append(CommentRow(comment: reply, isReply: true, replyToName: (name?.isEmpty ?? true) ? nil : name))
            }
        }
        return rows
    }

    /// 评论还有下一页（列表底下转圈、滑到底再取）。
    static func hasMoreComments(for state: FeedPostDetailState) -> Bool {
        return state.cursor != nil && !state.comments.isEmpty
    }

    /// 一条评论要显示的文字：正文；没有正文（语音评论）就用服务端的转写；都没有是 nil。
    static func displayText(of comment: FeedCard) -> String? {
        let text = comment.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            return comment.text
        }
        let transcript = comment.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? nil : comment.transcript
    }
}
