//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import Signal

class DisplayableTextTest: XCTestCase {
    func testDisplayableText() {
        // show plain text
        let boringText = "boring text"
        XCTAssertEqual(boringText, boringText.filterStringForDisplay())

        // show high byte emojis
        let emojiText = "🇹🇹🌼🇹🇹🌼🇹🇹a👩🏿‍❤️‍💋‍👩🏻b"
        XCTAssertEqual(emojiText, emojiText.filterStringForDisplay())

        // show normal diacritic usage
        let diacriticalText = "Příliš žluťoučký kůň úpěl ďábelské ódy."
        XCTAssertEqual(diacriticalText, diacriticalText.filterStringForDisplay())

        // filter excessive diacritics
        XCTAssertEqual("�ab��👩🏿‍❤️‍💋‍👩🏻c�", "x̸̢̧̛̙̝͈͈̖̳̗̰̆̈́̆̿̈́̅̽͆̈́̿̔͌̚͝abx̸̢̧̛̙̝͈͈̖̳̗̰̆̈́̆̿̈́̅̽͆̈́̿̔͌̚͝x̸̢̧̛̙̝͈͈̖̳̗̰̆̈́̆̿̈́̅̽͆̈́̿̔͌̚͝👩🏿‍❤️‍💋‍👩🏻cx̸̢̧̛̙̝͈͈̖̳̗̰̆̈́̆̿̈́̅̽͆̈́̿̔͌̚͝".filterStringForDisplay())
    }

    func testGlyphCount() {
        // Plain text
        XCTAssertEqual("boring text".glyphCount, 11)

        // Emojis
        XCTAssertEqual("🇹🇹🌼🇹🇹🌼🇹🇹".glyphCount, 5)
        XCTAssertEqual("🇹🇹".glyphCount, 1)
        XCTAssertEqual("🇹🇹 ".glyphCount, 2)
        XCTAssertEqual("👌🏽👌🏾👌🏿".glyphCount, 3)
        XCTAssertEqual("😍".glyphCount, 1)
        XCTAssertEqual("👩🏽".glyphCount, 1)
        XCTAssertEqual("👾🙇💁🙅🙆🙋🙎🙍".glyphCount, 8)
        XCTAssertEqual("🐵🙈🙉🙊".glyphCount, 4)
        XCTAssertEqual("❤️💔💌💕💞💓💗💖💘💝💟💜💛💚💙".glyphCount, 15)
        XCTAssertEqual("✋🏿💪🏿👐🏿🙌🏿👏🏿🙏🏿".glyphCount, 6)
        XCTAssertEqual("🚾🆒🆓🆕🆖🆗🆙🏧".glyphCount, 8)
        XCTAssertEqual("0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟".glyphCount, 11)
        XCTAssertEqual("🇺🇸🇷🇺🇦🇫🇦🇲".glyphCount, 4)
        XCTAssertEqual("🇺🇸🇷🇺🇸 🇦🇫🇦🇲🇸".glyphCount, 7)
        XCTAssertEqual("🇺🇸🇷🇺🇸🇦🇫🇦🇲".glyphCount, 5)
        XCTAssertEqual("🇺🇸🇷🇺🇸🇦".glyphCount, 3)
        XCTAssertEqual("１２３".glyphCount, 3)

        // Normal diacritic usage
        XCTAssertEqual("Příliš žluťoučký kůň úpěl ďábelské ódy.".glyphCount, 39)

        // Excessive diacritics

        XCTAssertEqual("H҉̸̧͘͠A͢͞V̛̛I̴̸N͏̕͏G҉̵͜͏͢ ̧̧́T̶̛͘͡R̸̵̨̢̀O̷̡U͡҉B̶̛͢͞L̸̸͘͢͟É̸ ̸̛͘͏R͟È͠͞A̸͝Ḑ̕͘͜I̵͘҉͜͞N̷̡̢͠G̴͘͠ ͟͞T͏̢́͡È̀X̕҉̢̀T̢͠?̕͏̢͘͢".glyphCount, 28)

        XCTAssertEqual("L̷̳͔̲͝Ģ̵̮̯̤̩̙͍̬̟͉̹̘̹͍͈̮̦̰̣͟͝O̶̴̮̻̮̗͘͡!̴̷̟͓͓".glyphCount, 4)
    }

    func testContainsOnlyEmoji() {
        // Plain text
        XCTAssertFalse("boring text".containsOnlyEmoji)

        // Emojis
        XCTAssertTrue("🇹🇹🌼🇹🇹🌼🇹🇹".containsOnlyEmoji)
        XCTAssertTrue("🇹🇹".containsOnlyEmoji)
        XCTAssertFalse("🇹🇹 ".containsOnlyEmoji)
        XCTAssertTrue("👌🏽👌🏾👌🏿".containsOnlyEmoji)
        XCTAssertTrue("😍".containsOnlyEmoji)
        XCTAssertTrue("👩🏽".containsOnlyEmoji)
        XCTAssertTrue("👾🙇💁🙅🙆🙋🙎🙍".containsOnlyEmoji)
        XCTAssertTrue("🐵🙈🙉🙊".containsOnlyEmoji)
        XCTAssertTrue("❤️💔💌💕💞💓💗💖💘💝💟💜💛💚💙".containsOnlyEmoji)
        XCTAssertTrue("✋🏿💪🏿👐🏿🙌🏿👏🏿🙏🏿".containsOnlyEmoji)
        XCTAssertTrue("🚾🆒🆓🆕🆖🆗🆙🏧".containsOnlyEmoji)
        XCTAssertFalse("0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟".containsOnlyEmoji)
        XCTAssertTrue("🇺🇸🇷🇺🇦🇫🇦🇲".containsOnlyEmoji)
        XCTAssertFalse("🇺🇸🇷🇺🇸 🇦🇫🇦🇲🇸".containsOnlyEmoji)
        XCTAssertTrue("🇺🇸🇷🇺🇸🇦🇫🇦🇲".containsOnlyEmoji)
        XCTAssertTrue("🇺🇸🇷🇺🇸🇦".containsOnlyEmoji)
        // Unicode standard doesn't consider these to be Emoji.
        XCTAssertFalse("１２３".containsOnlyEmoji)

        // Normal diacritic usage
        XCTAssertFalse("Příliš žluťoučký kůň úpěl ďábelské ódy.".containsOnlyEmoji)

        // Excessive diacritics
        XCTAssertFalse("H҉̸̧͘͠A͢͞V̛̛I̴̸N͏̕͏G҉̵͜͏͢ ̧̧́T̶̛͘͡R̸̵̨̢̀O̷̡U͡҉B̶̛͢͞L̸̸͘͢͟É̸ ̸̛͘͏R͟È͠͞A̸͝Ḑ̕͘͜I̵͘҉͜͞N̷̡̢͠G̴͘͠ ͟͞T͏̢́͡È̀X̕҉̢̀T̢͠?̕͏̢͘͢".containsOnlyEmoji)
        XCTAssertFalse("L̷̳͔̲͝Ģ̵̮̯̤̩̙͍̬̟͉̹̘̹͍͈̮̦̰̣͟͝O̶̴̮̻̮̗͘͡!̴̷̟͓͓".containsOnlyEmoji)
    }

    func testContainsOnlyEmojiIgnoringWhitespace() {
        // Plain text
        XCTAssertFalse("boring text".containsOnlyEmojiIgnoringWhitespace)

        // Emojis
        XCTAssertTrue("🇵🇸🌼🇵🇸🌼🇵🇸".containsOnlyEmojiIgnoringWhitespace)
        XCTAssertTrue("🏳️‍🌈".containsOnlyEmojiIgnoringWhitespace)
        XCTAssertFalse("🏳️‍⚧️!".containsOnlyEmojiIgnoringWhitespace)
        XCTAssertTrue("🏴‍☠️ ".containsOnlyEmojiIgnoringWhitespace)
        XCTAssertTrue("❤️   💜".containsOnlyEmojiIgnoringWhitespace)
        XCTAssertTrue("❤️\n💜".containsOnlyEmojiIgnoringWhitespace)
        XCTAssertTrue("🇺🇸🇷🇺🇸 🇦🇫🇦🇲🇸".containsOnlyEmojiIgnoringWhitespace)
        XCTAssertFalse("１２３".containsOnlyEmojiIgnoringWhitespace)
    }

    func testJumbomojiCount() {
        let testCases: [(String, UInt)] = [
            ("", 0),
            ("👌🏽", 1),
            ("❤️💜💛💚💙", 5),
            ("❤️💜💛💚💙❤️", 0),
            ("❤️💜💛💚💙❤️💜", 0),
            ("❤️A", 0),
            ("A💜", 0),
            ("❤️A💜", 0),
            ("A💜B", 0),
            ("❤️ 💜", 2),
            ("❤️ ", 1),
            ("❤️\n💜", 2),
            ("Signal", 0),
            ("Signal Messenger", 0),
            ("Noise", 0),
        ]
        for (textValue, expectedCount) in testCases {
            let displayableText: DisplayableText = .testOnlyInit(fullContent: .text(textValue), truncatedContent: nil)
            XCTAssertEqual(displayableText.jumbomojiCount, expectedCount, "textValue: \(textValue)")
        }
    }

    func test_shouldAllowLinkification() {
        func assertLinkifies(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
            let displayableText = DisplayableText.testOnlyInit(fullContent: .text(text), truncatedContent: nil)
            XCTAssert(displayableText.shouldAllowLinkification, "was not linkifiable text: \(text)", file: file, line: line)
        }

        func assertNotLinkifies(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
            let displayableText = DisplayableText.testOnlyInit(fullContent: .text(text), truncatedContent: nil)
            XCTAssertFalse(displayableText.shouldAllowLinkification, "was linkifiable text: \(text)", file: file, line: line)
        }

        // some basic happy paths
        assertLinkifies("foo google.com")
        assertLinkifies("google.com/foo")
        assertLinkifies("blah google.com/foo")
        assertLinkifies("foo http://google.com")
        assertLinkifies("foo https://google.com")

        // Tellomi (PM 2026-10-19): a link with / glued to a zero-width or bidi character is not linkified
        assertNotLinkifies("foo https://signal.org/a\u{200B}b")
        assertNotLinkifies("https://signal.org/abc\u{200F} next")
        assertNotLinkifies("https://signal.org/abc\u{2066}")
        assertNotLinkifies("https://signal.org/a/中\u{2060}文")
        // …but a hidden character after a normal end of the link is not part of it
        assertLinkifies("https://signal.org/abc \u{200B}")
        assertLinkifies("https://signal.org/abc\n\u{200B}")
        assertLinkifies("https://signal.org/a/中文\n下一行")
        assertLinkifies("foo \u{200B} https://signal.org/abc")

        // cyrillic host with ascii tld
        assertNotLinkifies("foo http://asĸ.com")
        assertNotLinkifies("http://asĸ.com")
        assertNotLinkifies("asĸ.com")
        assertLinkifies("Https://ask.com")
        assertLinkifies("HTTP://ask.com")
        assertLinkifies("HttPs://ask.com")

        // Mixed latin and cyrillic text, but it's not a link
        // (nothing to linkify, but there's nothing illegal here)
        assertLinkifies("asĸ")

        // Cyrillic host with cyrillic TLD
        assertLinkifies("http://кц.рф")
        assertLinkifies("https://кц.рф")
        assertLinkifies("кц.рф")
        assertLinkifies("https://кц.рф/foo")
        assertLinkifies("https://кц.рф/кц")
        assertLinkifies("https://кц.рф/кцfoo")

        // ascii text outside of the link, with cyrillic host + cyrillic domain
        assertLinkifies("some text: кц.рф")

        // Mixed ascii/cyrillic text outside of the link, with cyrillic host + cyrillic domain
        assertLinkifies("asĸ кц.рф")

        assertLinkifies("google.com")
        assertLinkifies("foo.google.com")
        assertLinkifies("https://foo.google.com")
        assertLinkifies("https://foo.google.com/some/path.html")

        assertNotLinkifies("asĸ.com")
        assertNotLinkifies("https://кц.cфm")
        assertNotLinkifies("https://google.cфm")
        assertNotLinkifies("Https://google.cфm")

        assertLinkifies("кц.рф")
        assertLinkifies("кц.рф/some/path")
        assertLinkifies("https://кц.рф/some/path")
        assertNotLinkifies("http://foo.кц.рф")

        // Forbidden bidi characters anywhere in the string
        assertNotLinkifies("hello \u{202C} https://google.com")
        assertNotLinkifies("hello \u{202D} https://google.com")
        assertNotLinkifies("hello \u{202E} https://google.com")
        assertNotLinkifies("hello https://google.com \u{202C} goodbye")
        assertNotLinkifies("hello https://google.com \u{202D} goodbye")
        assertNotLinkifies("hello https://google.com \u{202E} goodbye")

        // Forbidden box drawing characters in the link
        assertLinkifies("hello ┋ https://google.com")
        assertLinkifies("hello ▛ https://google.com")
        assertLinkifies("hello ◷ https://google.com")
        assertNotLinkifies("hello https://google┋.com goodbye")
        assertNotLinkifies("hello https://google▛.com goodbye")
        assertNotLinkifies("hello https://google◷.com goodbye")
    }
}
