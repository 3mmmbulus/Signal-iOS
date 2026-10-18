//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 一条帖子在「我的动态」里的审核状态（引擎 `state`）。认不得的当「已发布」画（和 Android 一样），但不让点开、不让申诉。
enum FeedMyPostStatus: Equatable {
    case published
    case pending
    case rejected
    case withdrawn

    init(state: String) {
        switch state {
        case FeedMyPost.statePending: self = .pending
        case FeedMyPost.stateRejected: self = .rejected
        case FeedMyPost.stateWithdrawn: self = .withdrawn
        default: self = .published
        }
    }
}

/// 未通过的原因（引擎 `rejection_reasons`）：四种；认不得的、或者一个原因都没给的，说「不符合社区规范」。
enum FeedRejectionReason: Equatable {
    case prohibitedWords
    case reviewUnavailable
    case accountRestricted
    case communityGuidelines

    init(code: String) {
        switch code {
        case "prohibited_words": self = .prohibitedWords
        case "review_unavailable": self = .reviewUnavailable
        case "account_restricted": self = .accountRestricted
        default: self = .communityGuidelines
        }
    }

    /// 去重、保持引擎给的顺序；空 = 「不符合社区规范」。
    static func list(_ codes: [String]) -> [FeedRejectionReason] {
        var result = [FeedRejectionReason]()
        for code in codes {
            let reason = FeedRejectionReason(code: code)
            if !result.contains(reason) { result.append(reason) }
        }
        return result.isEmpty ? [.communityGuidelines] : result
    }
}

/// 一行下面的说明（纯逻辑，没有文字）：界面按这个挑本地化句子。
enum FeedMyPostNote: Equatable {
    /// 审核中：审核完之前只有自己能看到。
    case pendingHint
    /// 未通过：原因 + 「只有你能看到」。
    case rejected(reasons: [FeedRejectionReason])
    case appealReceived
    case appealUpheld
}

struct FeedMyPostRow: Equatable {
    var id: String
    var kind: String
    var status: FeedMyPostStatus
    var title: String?
    var text: String
    var createdAt: String?
    /// 可见范围；引擎没给或认不得就是 nil（不显示）。
    var visibility: FeedVisibility?
    var notes: [FeedMyPostNote]
    /// 已发布的帖子 / 文章才能点开看（别人看得到的才有详情；评论没有单独的页面）。
    var canOpen: Bool
    /// 自己的都能删（含审核中、未通过、已撤回的）。
    var canDelete: Bool
    /// 只有「未通过、引擎说能申诉、还没申诉过」。已撤回的引擎当前不收申诉，不给按钮。
    var canAppeal: Bool

    init(post: FeedMyPost) {
        id = post.id
        kind = post.kind
        status = FeedMyPostStatus(state: post.state)
        title = post.title?.isEmpty == false ? post.title : nil
        text = post.text ?? ""
        createdAt = post.createdAt
        visibility = post.visibility.flatMap { FeedVisibility(rawValue: $0) }
        var notes = [FeedMyPostNote]()
        switch status {
        case .pending:
            notes = [.pendingHint]
        case .rejected:
            notes = [.rejected(reasons: FeedRejectionReason.list(post.rejectionReasons))]
            switch post.appealState {
            case FeedMyPost.appealReceived?: notes.append(.appealReceived)
            case FeedMyPost.appealUpheld?: notes.append(.appealUpheld)
            default: break
            }
        case .published, .withdrawn:
            break
        }
        self.notes = notes
        canOpen = post.state == FeedMyPost.statePublished
            && (post.kind == FeedCard.kindPost || post.kind == FeedCard.kindArticle)
        canDelete = true
        canAppeal = post.state == FeedMyPost.stateRejected && post.appealable && post.appealState == nil
    }
}

/// 「我的动态」页要画什么（纯逻辑，没有界面）：由 `FeedMyPostsState` 算出来，界面只照着画。
struct FeedMyPostsPresentation: Equatable {
    enum Status: Equatable {
        case loading
        /// 第一页加载失败；限速时带还要等几秒。
        case failed(retryAfterSeconds: Int?)
        case empty
        case loadingMore
        case loadMoreFailed(retryAfterSeconds: Int?)
    }

    enum Row: Equatable {
        case post(FeedMyPostRow)
        case status(Status)
    }

    var rows: [Row]
    /// 滚到底该不该再翻页：有下一页、没有在加载、上一次没失败（失败了只在点「重试」时再来）。
    var canLoadMore: Bool
    /// 引擎说动态被关了：页面该收起。
    var feedHidden: Bool
    /// 申诉按钮要不要禁用（上一个还没回来）。
    var appealBusy: Bool

    init(state: FeedMyPostsState) {
        feedHidden = state.feedHidden
        appealBusy = state.appealing
        canLoadMore = state.nextBefore != nil && !state.loading && !state.loadingMore && !state.loadMoreFailed && !state.failed && !state.feedHidden
        if state.feedHidden {
            rows = []
            return
        }
        if !state.loadedOnce {
            if state.failed {
                rows = [.status(.failed(retryAfterSeconds: state.retryAfterSeconds))]
            } else {
                rows = state.loading ? [.status(.loading)] : []
            }
            return
        }
        var rows = [Row]()
        // 下拉刷新失败：已有的留着，最上面说一句失败 + 重试
        if state.failed { rows.append(.status(.failed(retryAfterSeconds: state.retryAfterSeconds))) }
        if state.posts.isEmpty {
            if !state.failed { rows.append(.status(state.loading ? .loading : .empty)) }
        } else {
            rows += state.posts.map { .post(FeedMyPostRow(post: $0)) }
            if state.loadingMore {
                rows.append(.status(.loadingMore))
            } else if state.loadMoreFailed {
                rows.append(.status(.loadMoreFailed(retryAfterSeconds: state.retryAfterSeconds)))
            }
        }
        self.rows = rows
    }
}
