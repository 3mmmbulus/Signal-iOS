//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

// 长文阅读页的排版和读完要几分钟（纯逻辑）。

private func span(_ text: String, bold: Bool = false, italic: Bool = false) -> FeedArticleSpan {
    FeedArticleSpan(text: text, bold: bold, italic: italic)
}

private func plain(_ text: String) -> [FeedArticleSpan] { [span(text)] }

final class TellomiFeedArticleBodyTests: XCTestCase {

    // MARK: - 块

    func testParagraphsAreSeparatedByBlankLinesAndKeepSingleNewlines() {
        let blocks = FeedArticleBody.parse("first line\nsecond line\n\nsecond paragraph\n   \n\nthird")
        XCTAssertEqual(blocks, [
            .paragraph(plain("first line\nsecond line")),
            .paragraph(plain("second paragraph")),
            .paragraph(plain("third")),
        ])
    }

    func testEmptyAndWhitespaceOnlyTextHasNoBlocks() {
        XCTAssertEqual(FeedArticleBody.parse(""), [])
        XCTAssertEqual(FeedArticleBody.parse("  \n\n \t\n"), [])
    }

    func testWindowsAndOldMacLineEndingsAreTreatedAsNewlines() {
        XCTAssertEqual(FeedArticleBody.parse("a\r\nb\r\n\r\nc\rd"), [.paragraph(plain("a\nb")), .paragraph(plain("c\nd"))])
    }

    func testHeadingsNeedASpaceAndAtMostSixHashes() {
        let blocks = FeedArticleBody.parse("# One\n## Two\n### Three\n#hashtag\n####### seven\n#\n# ")
        XCTAssertEqual(blocks, [
            .heading(level: 1, spans: plain("One")),
            .heading(level: 2, spans: plain("Two")),
            .heading(level: 2, spans: plain("Three")),
            .paragraph(plain("#hashtag\n####### seven\n#\n#")),
        ])
    }

    func testAHeadingEndsTheParagraphBeforeItAndStartsANewOneAfter() {
        let blocks = FeedArticleBody.parse("text\n# Title\nmore text")
        XCTAssertEqual(blocks, [.paragraph(plain("text")), .heading(level: 1, spans: plain("Title")), .paragraph(plain("more text"))])
    }

    func testConsecutiveQuoteLinesAreOneQuote() {
        let blocks = FeedArticleBody.parse("> one\n> two\n\n> three\n>nospace")
        XCTAssertEqual(blocks, [.quote(plain("one\ntwo")), .quote(plain("three")), .paragraph(plain(">nospace"))])
    }

    func testBulletsAcceptDashStarAndDot() {
        let blocks = FeedArticleBody.parse("- a\n* b\n• c\n-d\n*e")
        XCTAssertEqual(blocks, [.bullets([plain("a"), plain("b"), plain("c")]), .paragraph(plain("-d\n*e"))])
    }

    func testNumberedListsAcceptDotAndParenthesisButNotLongNumbers() {
        let blocks = FeedArticleBody.parse("1. a\n2) b\n10. c\n\n2024. year\n3.x")
        XCTAssertEqual(blocks, [
            .numbered([plain("a"), plain("b"), plain("c")]),
            .paragraph(plain("2024. year\n3.x")),
        ])
    }

    func testDifferentBlockKindsWithoutBlankLinesStillSplit() {
        let blocks = FeedArticleBody.parse("intro\n- a\n- b\ntext\n> q\n1. n\nend")
        XCTAssertEqual(blocks, [
            .paragraph(plain("intro")),
            .bullets([plain("a"), plain("b")]),
            .paragraph(plain("text")),
            .quote(plain("q")),
            .numbered([plain("n")]),
            .paragraph(plain("end")),
        ])
    }

    func testTrailingSpacesAreDroppedButInnerOnesStay() {
        XCTAssertEqual(FeedArticleBody.parse("a  b   \n"), [.paragraph(plain("a  b"))])
    }

    func testMarkupCanBeSwitchedOff() {
        FeedArticleBody.interpretsMarkup = false
        defer { FeedArticleBody.interpretsMarkup = true }
        XCTAssertEqual(FeedArticleBody.parse("# Title\n- a\n**b**\n\n> q"), [
            .paragraph(plain("# Title\n- a\n**b**")),
            .paragraph(plain("> q")),
        ])
    }

    func testVeryLongTextIsCutAtTheLimit() {
        let long = String(repeating: "字", count: FeedArticleBody.maxCharacters + 500)
        let blocks = FeedArticleBody.parse(long)
        guard case .paragraph(let spans)? = blocks.first else { return XCTFail("no paragraph") }
        XCTAssertEqual(FeedArticleBody.maxCharacters, 50_000)
        XCTAssertEqual(FeedArticleBody.plainText(spans).count, 50_000)
        let exact = FeedArticleBody.parse(String(repeating: "a", count: 50_001))
        guard case .paragraph(let exactSpans)? = exact.first else { return XCTFail("no paragraph") }
        XCTAssertEqual(FeedArticleBody.plainText(exactSpans).count, 50_000)
    }

    // MARK: - 行内

    func testBoldAndItalic() {
        XCTAssertEqual(FeedArticleBody.inline("a **b** c *d* e"), [
            span("a "), span("b", bold: true), span(" c "), span("d", italic: true), span(" e"),
        ])
    }

    func testBoldItalicNestingAndTripleStars() {
        XCTAssertEqual(FeedArticleBody.inline("***x***"), [span("x", bold: true, italic: true)])
        XCTAssertEqual(FeedArticleBody.inline("*a **b** c*"), [
            span("a ", italic: true), span("b", bold: true, italic: true), span(" c", italic: true),
        ])
        XCTAssertEqual(FeedArticleBody.inline("**a *b* c**"), [
            span("a ", bold: true), span("b", bold: true, italic: true), span(" c", bold: true),
        ])
    }

    func testUnclosedOrSpacedStarsAreLiteral() {
        XCTAssertEqual(FeedArticleBody.inline("a *b"), plain("a *b"))
        XCTAssertEqual(FeedArticleBody.inline("a ** b **"), plain("a ** b **"))
        XCTAssertEqual(FeedArticleBody.inline("* a *"), plain("* a *"))
        XCTAssertEqual(FeedArticleBody.inline("**a"), plain("**a"))
        XCTAssertEqual(FeedArticleBody.inline("**"), plain("**"))
        XCTAssertEqual(FeedArticleBody.inline("a**"), plain("a**"))
    }

    func testStarsInsideWordsAreLiteralButChineseNeighboursAreFine() {
        XCTAssertEqual(FeedArticleBody.inline("2*3*4"), plain("2*3*4"))
        XCTAssertEqual(FeedArticleBody.inline("这是*重点*吧"), [span("这是"), span("重点", italic: true), span("吧")])
        XCTAssertEqual(FeedArticleBody.inline("这是**重点**吧"), [span("这是"), span("重点", bold: true), span("吧")])
    }

    func testAdjacentSpansWithTheSameStyleAreMerged() {
        XCTAssertEqual(FeedArticleBody.inline("a *b* *c*"), [span("a "), span("b", italic: true), span(" "), span("c", italic: true)])
        XCTAssertEqual(FeedArticleBody.inline("a * b"), plain("a * b"))
    }

    func testInlineMarkupWorksInsideEveryBlockKind() {
        let blocks = FeedArticleBody.parse("# **Big** title\n> *quoted*\n\n- **x**\n\n1. *y*")
        XCTAssertEqual(blocks, [
            .heading(level: 1, spans: [span("Big", bold: true), span(" title")]),
            .quote([span("quoted", italic: true)]),
            .bullets([[span("x", bold: true)]]),
            .numbered([[span("y", italic: true)]]),
        ])
    }

    func testAnAsteriskBulletIsNotItalic() {
        XCTAssertEqual(FeedArticleBody.parse("* one *two*"), [.bullets([[span("one "), span("two", italic: true)]])])
    }

    func testEveryOrderOfTwoDifferentBlockKindsComesOutInTheSameOrder() {
        let kinds: [(String, FeedArticleBlock)] = [
            ("p", .paragraph(plain("p"))),
            ("> q", .quote(plain("q"))),
            ("- b", .bullets([plain("b")])),
            ("1. n", .numbered([plain("n")])),
            ("# h", .heading(level: 1, spans: plain("h"))),
        ]
        for first in kinds {
            for second in kinds where first.0 != second.0 {
                XCTAssertEqual(FeedArticleBody.parse("\(first.0)\n\(second.0)"), [first.1, second.1], "\(first.0) then \(second.0)")
                XCTAssertEqual(FeedArticleBody.parse("\(first.0)\n\(second.0)\n\(first.0)"), [first.1, second.1, first.1])
            }
        }
    }

    func testMarkersWithNothingAfterThemAreText() {
        XCTAssertEqual(FeedArticleBody.parse("# \u{00A0}"), [.paragraph(plain("# \u{00A0}"))])
        XCTAssertEqual(FeedArticleBody.parse("- \u{00A0}"), [.paragraph(plain("- \u{00A0}"))])
        XCTAssertEqual(FeedArticleBody.parse("1. \u{00A0}"), [.paragraph(plain("1. \u{00A0}"))])
        XCTAssertEqual(FeedArticleBody.parse(". item"), [.paragraph(plain(". item"))])
        XCTAssertEqual(FeedArticleBody.parse("3.xyz"), [.paragraph(plain("3.xyz"))])
    }

    func testStarsNextToSpacesAreLiteralEvenWhenAMatchingStarFollows() {
        XCTAssertEqual(FeedArticleBody.inline("x * a* y"), plain("x * a* y"))
        XCTAssertEqual(FeedArticleBody.inline("x *a * y"), plain("x *a * y"))
        XCTAssertEqual(FeedArticleBody.inline("x ** a** y"), plain("x ** a** y"))
        XCTAssertEqual(FeedArticleBody.inline("x **a ** y"), plain("x **a ** y"))
    }

    func testManyStarsDoNotHang() {
        let text = String(repeating: "*a ", count: 1500)
        XCTAssertFalse(FeedArticleBody.parse(text).isEmpty)
    }
}

final class TellomiFeedArticleReadingTests: XCTestCase {

    func testEmptyTextTakesNoTime() {
        XCTAssertEqual(FeedArticleReading.minutes(""), 0)
        XCTAssertEqual(FeedArticleReading.minutes("  \n —— ，。 "), 0)
    }

    func testChineseIsCountedPerCharacter() {
        XCTAssertEqual(FeedArticleReading.count(String(repeating: "字", count: 400)), .init(cjk: 400, words: 0))
        XCTAssertEqual(FeedArticleReading.minutes("字"), 1)
        XCTAssertEqual(FeedArticleReading.minutes(String(repeating: "字", count: 400)), 1)
        XCTAssertEqual(FeedArticleReading.minutes(String(repeating: "字", count: 401)), 2)
        XCTAssertEqual(FeedArticleReading.minutes(String(repeating: "字", count: 4000)), 10)
    }

    func testOtherLanguagesAreCountedPerWord() {
        let words = { (n: Int) in Array(repeating: "word", count: n).joined(separator: " ") }
        XCTAssertEqual(FeedArticleReading.count(words(5)), .init(cjk: 0, words: 5))
        XCTAssertEqual(FeedArticleReading.minutes(words(230)), 1)
        XCTAssertEqual(FeedArticleReading.minutes(words(231)), 2)
        XCTAssertEqual(FeedArticleReading.count("don't stop-now 3.5").words, 6, "标点分开词")
    }

    func testMixedTextAddsBothParts() {
        let text = String(repeating: "字", count: 300) + " " + Array(repeating: "w", count: 115).joined(separator: " ")
        XCTAssertEqual(FeedArticleReading.minutes(text), 2, "0.75 + 0.5 = 1.25 分钟，向上取整")
    }

    func testKanaAndHangulCountLikeChinese() {
        XCTAssertEqual(FeedArticleReading.count("あいうエオ한국어"), .init(cjk: 8, words: 0))
    }

    func testEmojiAreNotWords() {
        XCTAssertEqual(FeedArticleReading.count("😀😀 hi 😀"), .init(cjk: 0, words: 1))
    }
}

final class TellomiFeedArticleReaderPresentationTests: XCTestCase {

    private func article(title: String? = "Title", text: String? = nil, summary: String? = nil) -> FeedCard {
        FeedCard(id: "a1", kind: FeedCard.kindArticle, title: title, text: text, summary: summary)
    }

    func testTheFullTextIsPreferredOverTheSummary() {
        let p = FeedArticleReaderPresentation(card: article(text: "# H\n\nbody", summary: "short"))
        XCTAssertEqual(p.title, "Title")
        XCTAssertEqual(p.blocks, [.heading(level: 1, spans: plain("H")), .paragraph(plain("body"))])
        XCTAssertFalse(p.summaryOnly)
    }

    func testWithoutTheFullTextTheSummaryIsShownAndMarked() {
        let p = FeedArticleReaderPresentation(card: article(text: nil, summary: "short"))
        XCTAssertEqual(p.blocks, [.paragraph(plain("short"))])
        XCTAssertTrue(p.summaryOnly)
        let blank = FeedArticleReaderPresentation(card: article(text: "  \n", summary: "short"))
        XCTAssertTrue(blank.summaryOnly, "只有空白的正文当没有")
    }

    func testNoTextAtAll() {
        let p = FeedArticleReaderPresentation(card: article(text: nil, summary: nil))
        XCTAssertEqual(p.blocks, [])
        XCTAssertFalse(p.summaryOnly)
        XCTAssertEqual(p.minutes, 0)
    }

    func testTheTitleIsTrimmedAndBlankMeansNone() {
        XCTAssertEqual(FeedArticleReaderPresentation(card: article(title: "  Hi \n")).title, "Hi")
        XCTAssertNil(FeedArticleReaderPresentation(card: article(title: "   ")).title)
        XCTAssertNil(FeedArticleReaderPresentation(card: article(title: nil)).title)
    }

    func testMinutesComeFromTheShownText() {
        let p = FeedArticleReaderPresentation(card: article(text: String(repeating: "字", count: 900)))
        XCTAssertEqual(p.minutes, 3)
    }
}

final class TellomiFeedSampleArticleTests: XCTestCase {
    func testTheSampleArticleHasEveryKindOfBlockAndStyle() async throws {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let cardOptional = try await source.card(contentId: "mine-seed-5")
        let card = try XCTUnwrap(cardOptional)
        XCTAssertTrue(card.isArticle)
        XCTAssertEqual(card.summary, "My sample post 5", "信息流里的卡片还是摘要")
        let p = FeedArticleReaderPresentation(card: card)
        XCTAssertFalse(p.summaryOnly)
        XCTAssertGreaterThanOrEqual(p.minutes, 1)
        var kinds = Set<String>()
        var styles = Set<String>()
        for block in p.blocks {
            switch block {
            case .paragraph(let spans): kinds.insert("p"); styles.formUnion(spans.map { "\($0.bold)\($0.italic)" })
            case .heading(let level, _): kinds.insert("h\(level)")
            case .quote: kinds.insert("q")
            case .bullets: kinds.insert("b")
            case .numbered: kinds.insert("n")
            }
        }
        XCTAssertEqual(kinds, ["p", "h1", "h2", "q", "b", "n"])
        XCTAssertTrue(styles.contains("truefalse") && styles.contains("falsetrue"), "有粗体也有斜体")
    }

    func testOnlyArticlesGetTheLongBody() async throws {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let postOptional = try await source.card(contentId: "mine-seed-1")
        let post = try XCTUnwrap(postOptional)
        XCTAssertEqual(post.text, "My sample post 1")
        XCTAssertNil(post.summary)
    }
}
