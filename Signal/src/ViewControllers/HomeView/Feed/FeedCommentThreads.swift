//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedCommentThreads.swift (new file)
// Mirror of Android `detail/FeedCommentThreads.kt`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 一条直接评论帖子的评论，和它下面的全部回复（不管回复的是它还是它下面的回复）。
/// `replyTo` 记下每条回复回的是谁（评论 id → 被回复的评论）：回的不是楼主那条时，界面写「回复 @某人」。
struct FeedCommentThread: Equatable {
    var root: FeedCard
    var replies = [FeedCard]()
    var replyTo = [String: FeedCard]()
}

enum FeedCommentThreads {
    /// 把引擎给的平铺评论（按时间正序，契约第五节）排成楼中楼：楼按时间正序，楼里的回复也按时间正序。
    ///
    /// 父评论不在这一页（还没加载、被删、被屏蔽）的回复，往上找不到楼主时自己成一楼，不丢。
    /// 父链成环时在环上截断，不死循环。
    static func build(_ comments: [FeedCard]) -> [FeedCommentThread] {
        let byId = comments.reduce(into: [String: FeedCard]()) { $0[$1.id] = $1 }   // 同 id 以后出现的为准（Kotlin `associateBy`）

        func top(of comment: FeedCard) -> FeedCard {
            var current = comment
            var seen: Set<String> = [current.id]
            while true {
                guard let parentId = current.parentId, let parent = byId[parentId] else { return current }
                if !seen.insert(parent.id).inserted { return current }
                current = parent
            }
        }

        var rootOrder = [String]()
        var roots = [String: FeedCard]()
        var replies = [String: [FeedCard]]()
        for comment in comments {
            let root = top(of: comment)
            if root.id == comment.id {
                if roots[comment.id] == nil { rootOrder.append(comment.id) }
                roots[comment.id] = comment
            } else {
                if roots[root.id] == nil {
                    rootOrder.append(root.id)
                    roots[root.id] = root
                }
                replies[root.id, default: []].append(comment)
            }
        }

        return rootOrder.map { id in
            let root = roots[id]!
            let threadReplies = replies[id] ?? []
            var replyTo = [String: FeedCard]()
            for reply in threadReplies {
                if let parentId = reply.parentId, let parent = byId[parentId], parent.id != root.id {
                    replyTo[reply.id] = parent
                }
            }
            return FeedCommentThread(root: root, replies: threadReplies, replyTo: replyTo)
        }
    }
}
