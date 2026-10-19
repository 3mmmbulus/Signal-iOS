//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 发布页底栏「可见范围」菜单和导航栏的样子（纯逻辑，由 `FeedComposeState` 算出来，界面照着画）。
struct FeedComposeLayout: Equatable {
    enum Title: Equatable {
        /// 新建：顶部「动态 / 长文」切换。
        case kindSwitch
        case editPost
        case editArticle
    }

    enum PublishButton: Equatable {
        case publish
        case save
    }

    enum Availability: Equatable {
        case available
        /// 要选人的两档：已选了几个人（0 = 还没选）。
        case picksPeople(count: Int)
        /// 引擎没开 `audience_tokens` 或者没有候选人来源：显示但不能选。
        case comingSoon
    }

    struct VisibilityOption: Equatable {
        var visibility: FeedVisibility
        var selected: Bool
        var availability: Availability
    }

    var title: Title
    var showsKindSwitch: Bool
    var showsTitleField: Bool
    var showsPhotoButton: Bool
    var showsVisibilityButton: Bool
    var publishButton: PublishButton
    /// 新写的长文会自动存在本机：有东西时导航栏给一个「放弃草稿」。
    var showsDiscardDraft: Bool
    var visibilityOptions: [VisibilityOption]

    /// `pickerAvailable`：发布页有候选人来源（样例源 / 以后的真实好友来源）。
    static func make(_ state: FeedComposeState, pickerAvailable: Bool) -> FeedComposeLayout {
        let editing = state.editing != nil
        let draft = state.draft
        let options = FeedVisibility.allowed(minorMode: state.minorMode).map { visibility -> VisibilityOption in
            let availability: Availability
            if !visibility.needsAudience {
                availability = .available
            } else if state.audienceAvailable && pickerAvailable {
                availability = .picksPeople(count: draft.visibility == visibility ? draft.audience.count : 0)
            } else {
                availability = .comingSoon
            }
            return VisibilityOption(visibility: visibility, selected: visibility == draft.visibility, availability: availability)
        }
        let title: Title
        if editing {
            title = draft.kind == .article ? .editArticle : .editPost
        } else {
            title = .kindSwitch
        }
        return FeedComposeLayout(
            title: title,
            showsKindSwitch: !editing,
            showsTitleField: draft.kind == .article,
            showsPhotoButton: !editing && draft.kind == .post,
            showsVisibilityButton: !editing,
            publishButton: editing ? .save : .publish,
            showsDiscardDraft: state.autosavesArticle && !draft.isEmpty,
            visibilityOptions: options,
        )
    }
}

/// 发布页的「草稿入口」：本机存着没写完的长文（第 25 条自动保存）时，「我的动态」页顶上给一行「继续写」，
/// 点开就是发布页（打开发布页本来就会把它接回来）。这里只算那一行写什么。
struct FeedComposeDraftEntry: Equatable {
    /// 一行里的标题：长文标题；标题是空的就拿正文第一个非空行；都空 = 没有入口（`make` 回 nil）。
    var headline: String
    /// 标题 + 正文一共多少个字符（界面显示「共 N 字」）。
    var characterCount: Int

    static let maxHeadline = 40

    static func make(_ saved: FeedSavedArticle?) -> FeedComposeDraftEntry? {
        guard let saved else { return nil }
        let title = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = saved.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty && text.isEmpty { return nil }
        var headline = title
        if headline.isEmpty {
            headline = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? text
        }
        if headline.count > maxHeadline {
            headline = String(headline.prefix(maxHeadline)) + "…"
        }
        return FeedComposeDraftEntry(headline: headline, characterCount: title.count + text.count)
    }
}
