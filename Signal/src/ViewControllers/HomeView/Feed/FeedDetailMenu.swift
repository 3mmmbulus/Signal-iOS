//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 帖子详情页「···」菜单里的一项（`dynamic-feed.md` 第三节第 11、26、32 条）。
enum FeedDetailMenuItem: Equatable {
    /// 别人的帖子：不想看到（报给推荐，页面关掉）。
    case notInterested
    /// 举报这条帖子，或这条评论。
    case report
    /// 删自己的评论。
    case deleteComment
    /// 删自己的帖子。
    case deletePost
    /// 编辑自己的帖子（第 23 条，发布后 15 分钟内；`TellomiFeed.isDetailExtrasEnabled` 开着才有）。
    case edit
    /// 分享（系统分享面板，帖子外链；`TellomiFeed.isShareEnabled` 开着、帖子 `shareable` 才有）。分享完成才报 `share` 事件。
    case share
    /// 复制帖子外链（同上；复制成功算分享完成）。
    case copyLink
    /// 自己帖子的置顶、回复选项、隐藏点赞数、查看数据。
    case own(FeedOwnPostAction)

    /// 红色 / 要二次确认的（删除不可撤销）。
    var isDestructive: Bool {
        switch self {
        case .deleteComment, .deletePost: return true
        case .notInterested, .report, .own, .edit, .share, .copyLink: return false
        }
    }

    var needsConfirmation: Bool { isDestructive }

    /// 菜单文字的本地化键（`own` 的几项以后跟着自己帖子的菜单一起加文案）。
    var titleKey: String {
        switch self {
        case .notInterested: return "TELLOMI_FEED_NOT_INTERESTED"
        case .report: return "TELLOMI_FEED_MENU_REPORT"
        case .deleteComment: return "TELLOMI_FEED_MENU_DELETE_COMMENT"
        case .deletePost: return "TELLOMI_FEED_MENU_DELETE_POST"
        case .edit: return "TELLOMI_FEED_MINE_EDIT"
        case .share: return "TELLOMI_FEED_MENU_SHARE"
        case .copyLink: return "TELLOMI_FEED_MENU_COPY_LINK"
        case .own(let action):
            switch action {
            case .pin: return "TELLOMI_FEED_MENU_PIN"
            case .unpin: return "TELLOMI_FEED_MENU_UNPIN"
            case .hideLikes: return "TELLOMI_FEED_MENU_HIDE_LIKES"
            case .showLikes: return "TELLOMI_FEED_MENU_SHOW_LIKES"
            case .replySettings: return "TELLOMI_FEED_MENU_REPLY_SETTINGS"
            case .insights: return "TELLOMI_FEED_MENU_INSIGHTS"
            }
        }
    }

    /// 确认框的标题键；不需要确认的是 nil。
    var confirmationTitleKey: String? {
        switch self {
        case .deleteComment: return "TELLOMI_FEED_DELETE_COMMENT_CONFIRM"
        case .deletePost: return "TELLOMI_FEED_DELETE_POST_CONFIRM"
        case .notInterested, .report, .own, .edit, .share, .copyLink: return nil
        }
    }
}

/// 哪张卡片的「···」里该有哪几项，按菜单顺序。纯函数，没有界面。
enum FeedDetailMenu {
    /// 帖子本身的「···」。自己的帖子：置顶 / 回复选项 / 点赞数 / 数据，最后是删除；别人的：不感兴趣、举报。
    /// 开放内容（外部作者）也一样能不感兴趣、能举报。
    /// `canEdit`：自己的帖子还能编辑（`FeedPostDetailState.canEditPost`）时，「编辑」排在最前面。
    /// `canShare`：详情页开了分享、这条帖子能分享（`FeedPostDetailState.canSharePost`）时，「分享」「复制链接」排在编辑后面、其它项前面。
    static func items(forPost post: FeedCard, canEdit: Bool = false, canShare: Bool = false) -> [FeedDetailMenuItem] {
        let share: [FeedDetailMenuItem] = canShare ? [.share, .copyLink] : []
        if post.viewer.isAuthor {
            return (canEdit ? [.edit] : []) + share + FeedOwnPostAction.available(for: post).map { .own($0) } + [.deletePost]
        }
        return share + [.notInterested, .report]
    }

    /// 界面上已经做了的项：自己帖子的置顶 / 回复选项 / 点赞数 / 数据（`.own`）还没有页面，先不显示；
    /// 举报要等举报页接上（`reportAvailable`）才显示，免得点了没反应。
    static func shown(_ items: [FeedDetailMenuItem], reportAvailable: Bool) -> [FeedDetailMenuItem] {
        return items.filter { item in
            switch item {
            case .own: return false
            case .report: return reportAvailable
            case .notInterested, .deleteComment, .deletePost, .edit, .share, .copyLink: return true
            }
        }
    }

    /// 一条评论的「···」（长按 / 菜单键）。自己的评论只能删；别人的只能举报。
    /// 还在等帖子作者批准的评论（`held`）别人看不到、也还不是「公开内容」：作者那边走批准 / 拒绝，不在这里给举报。
    static func items(forComment comment: FeedCard) -> [FeedDetailMenuItem] {
        guard comment.kind == FeedCard.kindComment else { return [] }
        if comment.viewer.isAuthor { return [.deleteComment] }
        if comment.held { return [] }
        return [.report]
    }
}
