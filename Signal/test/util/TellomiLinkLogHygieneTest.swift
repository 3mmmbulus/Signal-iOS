//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

/// ADR-0063 §6.5、§8.1 第 9 行：日志里查不到完整 URL 和 `#` 片段（贴纸包、群邀请、通话链接的秘密都在 `#` 后面）。
/// `owsFailDebug` 在任何构建里都会写 `logger.error`，而且在 Debug 里紧接着中断进程，所以这些分支没法在单测里真的走一遍去看日志；
/// 这里把话反过来说：链接相关的源码里，任何 `owsFailDebug` / `owsAssertDebug` / `Logger` / `logger` 调用的文字都不许插值 URL。
/// 和 `TellomiLocalizationTest` 扫 `OWSLocalizedString` 的键同一个做法（按本文件的位置找到仓库）。
final class TellomiLinkLogHygieneTest: XCTestCase {

    /// 扫的文件：链接预览、链接点开、链接卡片相关的全部（不含测试）。
    private static let directories = [
        "SignalUI/LinkPreview",
        "SignalServiceKit/Messages/Interactions/LinkPreview",
    ]
    private static let files = [
        "SignalServiceKit/Util/LinkValidator.swift",
        "SignalServiceKit/Util/TellomiLinks.swift",
        "Signal/ConversationView/ConversationViewController+BodyTextItems.swift",
        "Signal/ConversationView/ConversationViewController+CVComponentDelegate.swift",
        "Signal/ConversationView/ConversationViewController+TellomiLinkOpen.swift",
        "Signal/ConversationView/Components/CVComponentLinkPreview.swift",
        "Signal/ConversationView/Components/CVComponentState.swift",
        "Signal/ConversationView/Components/CVComponentState+GroupLink.swift",
        "Signal/ConversationView/CellViews/CVLinkPreviewView.swift",
    ]

    private var repository: URL {
        // 本文件在 <仓库>/Signal/test/util/ 下。解析符号链接：检出在 /tmp 下时 #filePath 和目录遍历给出的
        // 一个带 /private、一个不带，按长度截相对路径会截错（同 TellomiRegionsTest 的做法）。
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    // MARK: - 检测器

    /// 日志调用的起点。
    private static let logCall = try! NSRegularExpression(pattern: #"\b(?:owsFailDebug|owsAssertDebug|owsFail|Logger\.[a-z]+|logger\.[a-z]+)\("#)
    /// 插值里出现这些名字就算带了 URL。
    private static let urlName = try! NSRegularExpression(pattern: #"(?i)\b(?:url|urlString|urls|href|uri|absoluteString)\b|\.url\b"#)

    /// 从 `open` 起（已经在 `(` 后面）走到配对的 `)`，返回括号里的文字；字符串字面量里的括号不算，`\( … )` 插值要配对。
    private static func balancedBody(in text: [Character], from start: Int) -> String? {
        var depth = 1
        var index = start
        var inString = false
        var interpolationDepths = [Int]()
        while index < text.count {
            let character = text[index]
            if inString {
                if character == "\\", index + 1 < text.count {
                    if text[index + 1] == "(" {
                        interpolationDepths.append(depth)
                        depth += 1
                        inString = false
                        index += 2
                        continue
                    }
                    index += 2
                    continue
                }
                if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "(":
                    depth += 1
                case ")":
                    depth -= 1
                    if let last = interpolationDepths.last, depth == last {
                        interpolationDepths.removeLast()
                        inString = true
                    } else if depth == 0 {
                        return String(text[start..<index])
                    }
                default:
                    break
                }
            }
            index += 1
        }
        return nil
    }

    /// 文字里所有 `\( … )` 插值的内容。
    private static func interpolations(in call: String) -> [String] {
        var result = [String]()
        let characters = Array(call)
        var index = 0
        while index + 1 < characters.count {
            if characters[index] == "\\", characters[index + 1] == "(" {
                var depth = 1
                var end = index + 2
                while end < characters.count, depth > 0 {
                    if characters[end] == "(" { depth += 1 }
                    if characters[end] == ")" { depth -= 1 }
                    end += 1
                }
                result.append(String(characters[(index + 2)..<max(index + 2, end - 1)]))
                index = end
            } else {
                index += 1
            }
        }
        return result
    }

    /// 源码里每一处「日志调用的文字插值了 URL」：返回（行号，那一处插值的内容）。
    static func offenders(in source: String) -> [(line: Int, interpolation: String)] {
        let characters = Array(source)
        let range = NSRange(source.startIndex..., in: source)
        var found = [(Int, String)]()
        for match in logCall.matches(in: source, range: range) {
            guard let matchRange = Range(match.range, in: source) else { continue }
            let offset = source.distance(from: source.startIndex, to: matchRange.upperBound)
            guard let body = balancedBody(in: characters, from: offset) else { continue }
            let line = source[..<matchRange.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            for interpolation in interpolations(in: body) {
                if urlName.firstMatch(in: interpolation, range: NSRange(interpolation.startIndex..., in: interpolation)) != nil {
                    found.append((line, interpolation))
                }
            }
        }
        return found
    }

    // MARK: - 用例

    /// 检测器自己得先红：这几种写法都要被抓到，没带 URL 的不能误报。
    func testTheDetectorCatchesUrlsInLogCalls() {
        let bad = #"""
        owsFailDebug("Could not parse sticker pack share URL: \(url)")
        Logger.warn("x \(dataItem.url) y")
        owsFailDebug("Invalid url: \(urlString).")
        logger.info("a \(link.url.absoluteString)")
        owsAssertDebug(ok, "Unfronted: \(String(describing: url))")
        owsFailDebug(
            "multi line \(url)"
        )
        """#
        XCTAssertEqual(Self.offenders(in: bad).count, 6)
        let good = #"""
        owsFailDebug("Could not parse sticker pack share URL.")
        Logger.info("Opened a link via \(took ?? "nothing")")
        Logger.warn("First-party link lookup failed: \(type(of: error))")
        Logger.info("card \(card.provider ?? "-")/\(card.route ?? "-") \(card.level.rawValue) (\(reason))")
        let x = "\(url)"
        """#
        XCTAssertEqual(Self.offenders(in: good).count, 0)
    }

    func testNoLogCallInTheLinkCodeWritesAUrl() throws {
        var paths = Self.files
        for directory in Self.directories {
            let root = repository.appendingPathComponent(directory)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil), root.path)
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let name = file.lastPathComponent
                // 测试文件不扫（`*Test.swift` / `*Tests.swift`）
                guard !name.hasSuffix("Test.swift"), !name.hasSuffix("Tests.swift") else { continue }
                let path = file.resolvingSymlinksInPath().path
                guard path.hasPrefix(repository.path + "/") else {
                    XCTFail("\(path) is outside \(repository.path)")
                    continue
                }
                paths.append(String(path.dropFirst(repository.path.count + 1)))
            }
        }
        XCTAssertGreaterThan(paths.count, 25, "扫的文件数不对：\(paths.count)")
        var offenders = [String]()
        for path in paths.sorted() {
            let source = try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
            for (line, interpolation) in Self.offenders(in: source) {
                offenders.append("\(path):\(line) 插值了 \\(\(interpolation))")
            }
        }
        XCTAssertEqual(offenders, [], "日志里不许出现 URL（ADR-0063 §6.5）")
    }
}
