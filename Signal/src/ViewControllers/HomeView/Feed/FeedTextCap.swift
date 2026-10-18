//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedTextCap.swift (new file)
// One place for "cut this text to N Unicode code points without splitting a character".
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 内容引擎的字数上限都按 Unicode 码点数（Go `utf8.RuneCountInString`）：评论 / 动态 500、标题 100、昵称 32、简介 200、
/// 申诉理由 500、举报说明 500、举报关系 40、投票选项 40、关键词 20、搜索词 50……
/// Swift 的 `String.count` 数的是 `Character`（用户看到的一个字），`prefix(n)` 也是；一个国旗是 2 个码点，一个 ZWJ 家庭 emoji 最多 7 个，
/// 一个带肤色的手势 2 个，`é` 写成 e + 组合符是 2 个——按 Character 截会放过引擎的 400。Kotlin 的 `take(n)` 数 UTF-16 单元，
/// 会劈开 emoji，但对 BMP 之外的字不会超过引擎的上限。
///
/// 这里按码点数截，并且只在 Character 的边界上截：放不下的那个字整个去掉，不留半个。
enum FeedTextCap {
    /// 码点数（和引擎同口径）。
    static func count(_ text: String) -> Int {
        return text.unicodeScalars.count
    }

    /// 最多 `codePoints` 个码点；已经够短就原样返回。`codePoints <= 0` 得到空串。
    static func cap(_ text: String, codePoints: Int) -> String {
        guard codePoints > 0 else { return "" }
        if text.unicodeScalars.count <= codePoints { return text }
        var used = 0
        var out = String()
        for character in text {
            let size = character.unicodeScalars.count
            if used + size > codePoints { break }
            used += size
            out.append(character)
        }
        return out
    }

    static func fits(_ text: String, codePoints: Int) -> Bool {
        return count(text) <= codePoints
    }
}
