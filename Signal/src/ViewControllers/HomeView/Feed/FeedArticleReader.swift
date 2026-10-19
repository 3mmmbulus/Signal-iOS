//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// 长文阅读页（`dynamic-feed.md` 第三节第 25 条：标题 + 简单排版（粗体、斜体、引用、列表、小标题），最多 1 万字；动态里是卡片，点开是阅读页）。
// 阅读页就是帖子详情页里「帖子」那一行换成整篇长文（评论、赞、「···」、举报都还在原来的位置）：这里是它的纯逻辑——
// 把正文排成块（小标题、引用、列表、段落）和块里的粗体 / 斜体，估计读完要几分钟。画出来的是 `FeedArticleCell`。
//
// 排版标记（契约里正文只是一段文字，没有规定格式；下面是常见的 Markdown 子集，行首标记后要有空格，避免把普通文字误当标记）：
//   `# 标题` / `## 小标题`（多于两个 # 也当小标题）、`> 引用`、`- 列表` / `* 列表` / `• 列表`、`1. 编号列表`、`**粗体**`、`*斜体*`。
// 没有标记的正文就是一段一段的文字：空行分段，段内的换行保留。
// 想关掉排版、一律当普通文字：`FeedArticleBody.interpretsMarkup = false`。

struct FeedArticleSpan: Equatable {
    var text: String
    var bold = false
    var italic = false
}

enum FeedArticleBlock: Equatable {
    case paragraph([FeedArticleSpan])
    /// `level` 1 = 小标题（`# `），2 = 更小的（`## ` 以及更多的 #）。
    case heading(level: Int, spans: [FeedArticleSpan])
    case quote([FeedArticleSpan])
    case bullets([[FeedArticleSpan]])
    case numbered([[FeedArticleSpan]])
}

enum FeedArticleBody {
    /// 开着：按上面的标记排版；关了：每一块都是普通段落，标记原样显示。
    static var interpretsMarkup = true
    /// 最多读这么多个字符（契约上限 1 万字；多出来的不排，免得一篇异常长的文字卡住界面）。
    static let maxCharacters = 50_000

    static func parse(_ text: String) -> [FeedArticleBlock] {
        let normalized = String(text.prefix(maxCharacters))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { trimTrailing(String($0)) }
        guard interpretsMarkup else { return plainParagraphs(lines) }
        return blocks(from: lines)
    }

    // MARK: - 块

    private enum LineKind {
        case blank
        case heading(Int, String)
        case quote(String)
        case bullet(String)
        case number(String)
        case text(String)
    }

    private static func classify(_ line: String) -> LineKind {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
        let hashes = line.prefix { $0 == "#" }.count
        if hashes >= 1, hashes <= 6 {
            let rest = line.dropFirst(hashes)
            if rest.first == " " {
                let title = rest.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return .heading(hashes == 1 ? 1 : 2, title) }
            }
        }
        if line.hasPrefix("> ") {
            return .quote(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let item = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            if !item.isEmpty { return .bullet(item) }
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                let item = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { return .number(item) }
            }
        }
        return .text(line)
    }

    private static func blocks(from lines: [String]) -> [FeedArticleBlock] {
        var result = [FeedArticleBlock]()
        var paragraph = [String]()
        var quote = [String]()
        var bullets = [String]()
        var numbers = [String]()

        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(inline(paragraph.joined(separator: "\n")))); paragraph = [] }
            if !quote.isEmpty { result.append(.quote(inline(quote.joined(separator: "\n")))); quote = [] }
            if !bullets.isEmpty { result.append(.bullets(bullets.map { inline($0) })); bullets = [] }
            if !numbers.isEmpty { result.append(.numbered(numbers.map { inline($0) })); numbers = [] }
        }

        for line in lines {
            switch classify(line) {
            case .blank:
                flush()
            case .heading(let level, let title):
                flush()
                result.append(.heading(level: level, spans: inline(title)))
            case .quote(let text):
                if quote.isEmpty { flush() }
                quote.append(text)
            case .bullet(let text):
                if bullets.isEmpty { flush() }
                bullets.append(text)
            case .number(let text):
                if numbers.isEmpty { flush() }
                numbers.append(text)
            case .text(let text):
                if paragraph.isEmpty { flush() }
                paragraph.append(text)
            }
        }
        flush()
        return result
    }

    /// 不排版：空行分段，段内换行保留，文字原样。
    private static func plainParagraphs(_ lines: [String]) -> [FeedArticleBlock] {
        var result = [FeedArticleBlock]()
        var current = [String]()
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(.paragraph([FeedArticleSpan(text: current.joined(separator: "\n"))])); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(.paragraph([FeedArticleSpan(text: current.joined(separator: "\n"))])) }
        return result
    }

    private static func trimTrailing(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex, line[line.index(before: end)] == " " || line[line.index(before: end)] == "\t" {
            end = line.index(before: end)
        }
        return String(line[line.startIndex..<end])
    }

    // MARK: - 行内

    /// `**粗体**`、`*斜体*`（`***两者***` 也行）。开头的 `*` 后面、结尾的 `*` 前面不能是空白；开头的 `*` 前面不能是英文字母数字（`2*3*4` 不动；汉字前面可以，中文里没有空格）；
    /// 找不到结尾的 `*` 就是普通字符。
    static func inline(_ text: String) -> [FeedArticleSpan] {
        var spans = [FeedArticleSpan]()
        parseInline(Array(text), bold: false, italic: false, into: &spans)
        return merged(spans)
    }

    private static func parseInline(_ chars: [Character], bold: Bool, italic: Bool, into spans: inout [FeedArticleSpan]) {
        var literal = ""
        func flushLiteral() {
            if !literal.isEmpty { spans.append(FeedArticleSpan(text: literal, bold: bold, italic: italic)); literal = "" }
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*", canOpen(chars, at: i) {
                let isBold = i + 1 < chars.count && chars[i + 1] == "*"
                let width = isBold ? 2 : 1
                if let close = closing(chars, from: i + width, width: width) {
                    flushLiteral()
                    parseInline(Array(chars[(i + width)..<close]), bold: bold || isBold, italic: italic || !isBold, into: &spans)
                    i = close + width
                    continue
                }
            }
            literal.append(c)
            i += 1
        }
        flushLiteral()
    }

    private static func isASCIIAlphanumeric(_ c: Character) -> Bool {
        return c.isASCII && (c.isLetter || c.isNumber)
    }

    private static func canOpen(_ chars: [Character], at i: Int) -> Bool {
        if i > 0, isASCIIAlphanumeric(chars[i - 1]) { return false }
        let width = (i + 1 < chars.count && chars[i + 1] == "*") ? 2 : 1
        let next = i + width
        guard next < chars.count else { return false }
        return !chars[next].isWhitespace
    }

    /// 从 `start` 往后找和开头同宽的结尾：前面不是空白、中间有字；两个宽的结尾后面不能再跟 `*`（`***` 里先结斜体再结粗体）。
    /// 找单个 `*` 的结尾时，成对的 `**` 整个跳过（斜体里夹着粗体）。
    private static func closing(_ chars: [Character], from start: Int, width: Int) -> Int? {
        var j = start
        while j < chars.count {
            guard chars[j] == "*" else { j += 1; continue }
            let paired = j + 1 < chars.count && chars[j + 1] == "*"
            if width == 1 {
                if paired { j += 2; continue }
                if j > start, !chars[j - 1].isWhitespace { return j }
                j += 1
            } else {
                guard paired else { j += 1; continue }
                let after = j + 2
                if j > start, !chars[j - 1].isWhitespace, after >= chars.count || chars[after] != "*" { return j }
                j += 1
            }
        }
        return nil
    }

    private static func merged(_ spans: [FeedArticleSpan]) -> [FeedArticleSpan] {
        var result = [FeedArticleSpan]()
        for span in spans where !span.text.isEmpty {
            if var last = result.last, last.bold == span.bold, last.italic == span.italic {
                last.text += span.text
                result[result.count - 1] = last
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// 一块的纯文字（读屏 / 单测用）。
    static func plainText(_ spans: [FeedArticleSpan]) -> String {
        return spans.map(\.text).joined()
    }
}

// MARK: - 读完要几分钟

enum FeedArticleReading {
    /// 中日韩每分钟读这么多字、其他文字每分钟读这么多词（常见的估法）。
    static let cjkPerMinute = 400.0
    static let wordsPerMinute = 230.0

    struct Count: Equatable {
        var cjk = 0
        var words = 0
    }

    static func count(_ text: String) -> Count {
        var count = Count()
        var inWord = false
        for scalar in text.unicodeScalars.prefix(FeedArticleBody.maxCharacters) {
            if isCJK(scalar) {
                count.cjk += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { count.words += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }

    /// 至少 1 分钟（有字的话）；没字是 0。
    static func minutes(_ text: String) -> Int {
        let c = count(text)
        guard c.cjk + c.words > 0 else { return 0 }
        let value = Double(c.cjk) / cjkPerMinute + Double(c.words) / wordsPerMinute
        return max(1, Int(value.rounded(.up)))
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2A6DF:
            return true
        default:
            return false
        }
    }
}

// MARK: - 阅读页要画什么

/// 阅读页上面一块：标题、正文的块、读完要几分钟。
struct FeedArticleReaderPresentation: Equatable {
    var title: String?
    var blocks: [FeedArticleBlock]
    var minutes: Int
    /// 正文是不是只有信息流里的摘要（详情还没取回完整的长文）。
    var summaryOnly: Bool

    init(card: FeedCard) {
        let title = card.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = title.isEmpty ? nil : title
        let full = (card.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (card.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = full.isEmpty ? summary : full
        summaryOnly = full.isEmpty && !summary.isEmpty
        blocks = FeedArticleBody.parse(body)
        minutes = FeedArticleReading.minutes(body)
    }
}
