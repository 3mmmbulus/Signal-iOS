//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedInputLimit.swift (new file)
// Input limits for text fields: block typing at the limit, clip a paste to the limit, remaining-count (Telegram style).
// Foundation-only logic; the UIKit hook (UITextFieldDelegate / UITextViewDelegate) is NOT drafted here — see the usage note below.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 决定（tellomi测试，2026-10-16）：评论 500、长文标题 100、昵称 32、简介 200 这四个输入框**到上限就不让再输入**，并显示剩余字数；
/// 粘贴超长时按码点数截到上限（不劈开一个字）；不做事后截断。数字和引擎一致（按 Unicode 码点数，`utf8.RuneCountInString`）。
///
/// 用法（UI 由 Claude 接，这里只给逻辑）：
/// ```
/// func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
///     let edit = store.onDraftEdit(range: range, replacement: text, composing: tv.markedTextRange != nil)
///     if edit.accepted { updateCounter(edit.remaining); return true }        // 照常输入
///     tv.text = edit.text; tv.selectedRange = NSRange(location: edit.caret, length: 0)   // 截了一部分 / 一个都放不下
///     updateCounter(edit.remaining); return false
/// }
/// func textViewDidChange(_ tv: UITextView) { if tv.markedTextRange == nil { store.onDraftChanged(tv.text) } }   // 输入法结束组字后补一次
/// ```
/// 输入法组字（`markedTextRange != nil`，拼音 / 假名候选）：UIKit 每敲一个键都会调 `shouldChange…`，那时候截或拦会把组字弄坏，
/// 所以 `composing: true` 时**一律放行**（`accepted`，剩余数可以是负的，`isOver`），组字结束后 `onDraftChanged` 再按码点截一次
/// （这是唯一的「事后」截断，只发生在组字刚结束时）。发送 / 保存按钮在 `isOver` 时不可用。
enum FeedInputLimit {
    // MARK: 引擎的上限（content-engine `api/*.go`，按码点数）
    /// 评论（`MaxCommentChars = MaxPostChars`）。
    static let commentText = 500
    /// 长文标题（`MaxTitleChars`）。
    static let articleTitle = 100
    /// 昵称（`MaxNameChars`）。
    static let profileName = 32
    /// 简介（`MaxBioChars`）。
    static let profileBio = 200
    /// 动态正文、长文正文：以 `GET /v1/feed/config` 的 `limits` 为准，这里是引擎默认值（`MaxPostChars` / `MaxArticleChars`）。
    static let postText = 500
    static let articleText = 10_000
    static let appealReason = 500
    static let reportDetail = 500
    static let reportRelationship = 40
    static let pollOption = 40
    static let keyword = 20
    static let searchQuery = 50

    /// 剩余字数（码点）；超了是负数。
    static func remaining(_ text: String, limit: Int) -> Int {
        return limit - FeedTextCap.count(text)
    }

    static func fits(_ text: String, limit: Int) -> Bool {
        return FeedTextCap.fits(text, codePoints: limit)
    }

    /// `shouldChangeCharactersIn:replacementString:` / `shouldChangeTextIn:replacementText:` 这种钩子：把 `current` 里 `range`（UTF-16 区间，
    /// 就是 UIKit 给的那个）换成 `replacement`，结果受 `limit`（码点）限制。
    /// - 删除（`replacement` 为空）永远放行。
    /// - 放得下：原样放行（`accepted`）。
    /// - 放不下：把 `replacement` 按码点截到还剩的位置（`clipped`，调用方要自己设文本并返回 false）；一个字都放不下（已满，或下一个字比剩余的还大，
    ///   如剩 3 个位置却来了个 7 码点的 emoji）就整个拦下（`blocked`，文本不变）。
    /// - `range` 不合法（越界）：拦下，文本不变。
    /// - `composing`：输入法组字中，一律放行（见类型说明）。
    static func edit(current: String, range: NSRange, replacement: String, limit: Int, composing: Bool = false) -> FeedInputEdit {
        let limit = max(limit, 0)
        let utf16Count = current.utf16.count
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0, range.location + range.length <= utf16Count,
              let swiftRange = Range(range, in: current)
        else {
            return FeedInputEdit(current: current, text: current, inserted: "", remaining: remaining(current, limit: limit), accepted: false, blocked: true, clipped: false,
                                 caret: min(max(range.location, 0), utf16Count))
        }
        let prefix = String(current[..<swiftRange.lowerBound])
        let suffix = String(current[swiftRange.upperBound...])
        let kept = FeedTextCap.count(prefix) + FeedTextCap.count(suffix)
        func result(inserted: String, accepted: Bool, blocked: Bool, clipped: Bool) -> FeedInputEdit {
            if blocked {
                return FeedInputEdit(current: current, text: current, inserted: "", remaining: remaining(current, limit: limit), accepted: false, blocked: true, clipped: false,
                                     caret: range.location + range.length)
            }
            let text = prefix + inserted + suffix
            return FeedInputEdit(current: current, text: text, inserted: inserted, remaining: remaining(text, limit: limit), accepted: accepted, blocked: false, clipped: clipped,
                                 caret: prefix.utf16.count + inserted.utf16.count)
        }
        if composing || replacement.isEmpty || kept + FeedTextCap.count(replacement) <= limit {
            return result(inserted: replacement, accepted: true, blocked: false, clipped: false)
        }
        let room = limit - kept
        let inserted = room > 0 ? FeedTextCap.cap(replacement, codePoints: room) : ""
        if inserted.isEmpty {
            return result(inserted: "", accepted: false, blocked: true, clipped: false)
        }
        return result(inserted: inserted, accepted: false, blocked: false, clipped: true)
    }

    /// 整段文本被换掉（粘贴后整体设置、恢复草稿、没有走 `shouldChange…` 的输入框）：超过上限就按码点截到上限。
    /// `composing` 为 true 时不动（组字结束后再调一次）。
    static func clip(_ text: String, limit: Int, composing: Bool = false) -> FeedInputEdit {
        let limit = max(limit, 0)
        if composing || FeedTextCap.fits(text, codePoints: limit) {
            return FeedInputEdit(current: text, text: text, inserted: text, remaining: remaining(text, limit: limit), accepted: true, blocked: false, clipped: false, caret: text.utf16.count)
        }
        let cut = FeedTextCap.cap(text, codePoints: limit)
        return FeedInputEdit(current: text, text: cut, inserted: cut, remaining: remaining(cut, limit: limit), accepted: false, blocked: false, clipped: true, caret: cut.utf16.count)
    }
}

/// 一次输入的结果。
struct FeedInputEdit: Equatable {
    /// 输入之前的文本。
    var current: String
    /// 输入之后该显示的文本（拦下时 = `current`）。
    var text: String
    /// 实际放进去的那一段（可能比用户给的短；拦下是空）。
    var inserted: String
    /// 还能再输入多少个码点；超了（组字中、程序设置过长的文本）是负数。
    var remaining: Int
    /// 用户的改动**原样**生效：UIKit 钩子返回 true。
    var accepted: Bool
    /// 一个字都没放进去（已满 / 放不下 / 区间不合法）；文本没变。
    var blocked: Bool
    /// 放进去了一部分（粘贴被截）；调用方要自己设文本并返回 false。
    var clipped: Bool
    /// 输入后光标的 UTF-16 位置（`blocked` 时是原选区的末尾）。
    var caret: Int

    var changed: Bool { text != current }
    /// 碰到了上限（拦下或截了）——UI 可以抖一下计数。
    var limitHit: Bool { blocked || clipped }
    var isOver: Bool { remaining < 0 }
}
