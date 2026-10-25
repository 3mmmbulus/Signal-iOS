//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 审计 3.4（F22）第一步：打字时的表情建议——只有纯逻辑，还没接到输入框 UI。
///
/// 规则（行为参考 Telegram，代码自写）：
/// - 光标前以 `:` 开头、后面跟至少 2 个 ASCII 字母/数字/下划线的词（如 `:smi`）：按关键词前缀匹配，替换整个 `:smi`。
/// - 光标前最后一个词（英文按空白/标点切，中文取光标前紧挨的 1–4 个汉字中最长的完整关键词）**完整**等于关键词：给出建议，替换这个词。
/// - 光标不在末尾的词中间、文字含选区、或以 `::` / URL 形式（`http:`）出现时不出建议。
/// - 结果去重、保持表顺序，最多 `maxResults` 个。
public struct TellomiEmojiSuggestion: Equatable {
    /// 要被替换掉的范围（UTF-16，NSRange 口径，方便直接给 UITextView 用）。
    public let replacementRange: NSRange
    public let query: String
    public let emoji: [String]
}

public enum TellomiEmojiSuggest {
    public static let maxResults = 8
    static let minColonQueryLength = 2

    /// 关键词 → 表情。小写英文、中文都放这里；顺序即优先级。
    static let table: [(keyword: String, emoji: [String])] = [
        ("smile", ["😄", "😊", "🙂"]),
        ("laugh", ["😂", "🤣"]),
        ("lol", ["😂", "🤣"]),
        ("love", ["❤️", "😍", "🥰"]),
        ("heart", ["❤️", "💕"]),
        ("kiss", ["😘", "💋"]),
        ("cry", ["😢", "😭"]),
        ("sad", ["😢", "😞"]),
        ("angry", ["😠", "😡"]),
        ("ok", ["👌", "🆗"]),
        ("yes", ["👍"]),
        ("no", ["🙅", "👎"]),
        ("thanks", ["🙏"]),
        ("thumbsup", ["👍"]),
        ("clap", ["👏"]),
        ("fire", ["🔥"]),
        ("party", ["🎉", "🥳"]),
        ("cool", ["😎"]),
        ("think", ["🤔"]),
        ("sleep", ["😴"]),
        ("wow", ["😮", "🤩"]),
        ("cat", ["🐱"]),
        ("dog", ["🐶"]),
        ("coffee", ["☕️"]),
        ("beer", ["🍺"]),
        ("cake", ["🎂"]),
        ("sun", ["☀️"]),
        ("rain", ["🌧️"]),
        ("哈哈", ["😂", "🤣", "😄"]),
        ("笑", ["😄", "😂"]),
        ("爱", ["❤️", "😍"]),
        ("爱你", ["😘", "❤️"]),
        ("哭", ["😭", "😢"]),
        ("难过", ["😢", "😞"]),
        ("生气", ["😠", "😡"]),
        ("好的", ["👌", "👍"]),
        ("好", ["👍", "👌"]),
        ("谢谢", ["🙏", "😊"]),
        ("赞", ["👍"]),
        ("鼓掌", ["👏"]),
        ("厉害", ["👍", "🔥"]),
        ("生日快乐", ["🎂", "🎉"]),
        ("晚安", ["😴", "🌙"]),
        ("早安", ["☀️", "😊"]),
        ("思考", ["🤔"]),
        ("咖啡", ["☕️"]),
        ("啤酒", ["🍺"]),
        ("猫", ["🐱"]),
        ("狗", ["🐶"]),
    ]

    private static let maxHanKeywordLength = 4

    public static func suggestion(text: String, selectedRange: NSRange) -> TellomiEmojiSuggestion? {
        let ns = text as NSString
        guard
            selectedRange.length == 0,
            selectedRange.location != NSNotFound,
            selectedRange.location <= ns.length else { return nil }
        let cursor = selectedRange.location
        // 光标后紧跟字母/数字/汉字 = 在词中间，不出。
        if cursor < ns.length, let next = Unicode.Scalar(ns.character(at: cursor)), isWordScalar(next) || isHan(next) {
            return nil
        }
        let before = ns.substring(to: cursor)
        let scalars = Array(before.unicodeScalars)

        // 1) `:query`
        var i = scalars.count
        while i > 0, isAsciiWord(scalars[i - 1]) { i -= 1 }
        let wordLen = scalars.count - i
        if wordLen > 0 {
            let word = String(String.UnicodeScalarView(scalars[i...])).lowercased()
            let utf16Len = word.utf16.count
            if i > 0, scalars[i - 1] == ":" {
                let colonIdx = i - 1
                let precededOK = colonIdx == 0 || isBoundary(scalars[colonIdx - 1])
                guard precededOK, wordLen >= minColonQueryLength else { return nil }
                let emoji = collect { $0.hasPrefix(word) && $0.unicodeScalars.allSatisfy(isAsciiWord) }
                guard !emoji.isEmpty else { return nil }
                return TellomiEmojiSuggestion(
                    replacementRange: NSRange(location: cursor - utf16Len - 1, length: utf16Len + 1),
                    query: word,
                    emoji: emoji,
                )
            }
            // 2) 完整英文词
            guard i == 0 || isBoundary(scalars[i - 1]) else { return nil }
            let emoji = collect { $0 == word }
            guard !emoji.isEmpty else { return nil }
            return TellomiEmojiSuggestion(
                replacementRange: NSRange(location: cursor - utf16Len, length: utf16Len),
                query: word,
                emoji: emoji,
            )
        }

        // 3) 中文：光标前连续汉字里，取最长的、完整等于关键词的后缀。
        var h = scalars.count
        while h > 0, isHan(scalars[h - 1]), scalars.count - h < maxHanKeywordLength { h -= 1 }
        guard h < scalars.count else { return nil }
        for start in h..<scalars.count {
            let candidate = String(String.UnicodeScalarView(scalars[start...]))
            let emoji = collect { $0 == candidate }
            if !emoji.isEmpty {
                let len = candidate.utf16.count
                return TellomiEmojiSuggestion(
                    replacementRange: NSRange(location: cursor - len, length: len),
                    query: candidate,
                    emoji: emoji,
                )
            }
        }
        return nil
    }

    /// 选中一个建议后的新文字和光标位置。
    public static func apply(_ s: TellomiEmojiSuggestion, emoji: String, to text: String) -> (text: String, cursor: Int) {
        let ns = text as NSString
        let out = ns.replacingCharacters(in: s.replacementRange, with: emoji)
        return (out, s.replacementRange.location + (emoji as NSString).length)
    }

    private static func collect(_ match: (String) -> Bool) -> [String] {
        var out: [String] = []
        for row in table where match(row.keyword) {
            for e in row.emoji where !out.contains(e) {
                out.append(e)
                if out.count == maxResults { return out }
            }
        }
        return out
    }

    static func isAsciiWord(_ s: Unicode.Scalar) -> Bool {
        s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "_")
    }

    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(s) && !isHan(s)
    }

    private static func isBoundary(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(s) || isHan(s)
            || (CharacterSet.punctuationCharacters.contains(s) && s != ":" && s != "/")
    }

    static func isHan(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
    }
}
