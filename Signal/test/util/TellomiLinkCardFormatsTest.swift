//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

/// card-visual §3.9（格式）与 §3.10（类型文字、第一方按钮）：卡片上的数量、日期和文案，在 en / zh_CN / zh_HK / zh_TW 四种语言下
/// 用 App 里**真实的语言表**钉住（以前的测试只用假字符串）。产品里的 `localized(locale:…)` 在 `TellomiLocalization.withBundleForTests`
/// 里读指定语言的表、数字和日期按该地区排，所以一个用例就能把四种语言都过一遍，走的是产品代码的那条路径，不是测试里另拼的。
final class TellomiLinkCardFormatsTest: XCTestCase {

    private struct Language {
        /// `Signal/translations/<folder>.lproj`
        let folder: String
        /// 数字（千分位）和日期按这个地区的习惯排。
        let locale: Locale
    }

    private static let languages = [
        Language(folder: "en", locale: Locale(identifier: "en_US")),
        Language(folder: "zh_CN", locale: Locale(identifier: "zh_Hans_CN")),
        Language(folder: "zh_HK", locale: Locale(identifier: "zh_Hant_HK")),
        Language(folder: "zh_TW", locale: Locale(identifier: "zh_Hant_TW")),
    ]

    // MARK: - Helpers

    private func languageBundle(_ folder: String) -> Bundle? {
        Bundle.main.app.path(forResource: folder, ofType: "lproj").flatMap { Bundle(path: $0) }
    }

    /// 让 `OWSLocalizedString` 读 `folder` 这种语言的真实语言表（缺键同样回落到 App 里的英文表，和产品一样）。
    private func withLanguage<T>(_ folder: String, _ body: () throws -> T) throws -> T {
        let bundle = try XCTUnwrap(languageBundle(folder), "no \(folder).lproj in the app")
        return try TellomiLocalization.withBundleForTests(bundle, english: TellomiLocalization.englishBundle(in: Bundle.main.app), body)
    }

    private func table(_ folder: String, _ name: String = "Localizable", _ ext: String = "strings") throws -> [String: Any] {
        let path = try XCTUnwrap(
            Bundle.main.app.path(forResource: name, ofType: ext, inDirectory: nil, forLocalization: folder),
            "no \(name).\(ext) for \(folder)",
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: Any], "unreadable \(name).\(ext) for \(folder)")
    }

    private func displayStrings(_ language: Language, now: Date = Date()) throws -> TellomiLinkDisplay.Strings {
        try withLanguage(language.folder) { TellomiLinkDisplay.Strings.localized(locale: language.locale, now: { now }) }
    }

    private func firstPartyStrings(_ language: Language) throws -> TellomiFirstPartyCard.Strings {
        try withLanguage(language.folder) { TellomiFirstPartyCard.Strings.localized(locale: language.locale) }
    }

    // MARK: - §3.9 数量：曲目数、成员数、贴纸数（1 的单数、常见的 12 / 24 / 128、千分位 12,345）

    /// 一个数量在某种语言里的「一」「其他」两种写法；`{n}` 换成写好的数字。中文没有单复数，两种写法一样。
    private struct Forms {
        let one: String
        let other: String

        init(_ one: String, _ other: String) {
            self.one = one
            self.other = other
        }

        func text(_ count: Int, shown: String) -> String {
            (count == 1 ? one : other).replacingOccurrences(of: "{n}", with: shown)
        }
    }

    private struct CountWords {
        let tracks: Forms
        let members: Forms
        let stickers: Forms
    }

    /// 文档 §3.9：曲目「N 首 / N tracks（1 时 1 track）」、成员「N 位成员（简体）/ N 個成員（繁体）/ N members」、
    /// 贴纸「N 个贴纸 / N 個貼圖 / N stickers」。
    private static let countWords: [String: CountWords] = [
        "en": CountWords(
            tracks: Forms("{n} track", "{n} tracks"),
            members: Forms("{n} member", "{n} members"),
            stickers: Forms("{n} sticker", "{n} stickers"),
        ),
        "zh_CN": CountWords(
            tracks: Forms("{n} 首", "{n} 首"),
            members: Forms("{n} 位成员", "{n} 位成员"),
            stickers: Forms("{n} 个贴纸", "{n} 个贴纸"),
        ),
        "zh_HK": CountWords(
            tracks: Forms("{n} 首", "{n} 首"),
            members: Forms("{n} 個成員", "{n} 個成員"),
            stickers: Forms("{n} 個貼圖", "{n} 個貼圖"),
        ),
        "zh_TW": CountWords(
            tracks: Forms("{n} 首", "{n} 首"),
            members: Forms("{n} 個成員", "{n} 個成員"),
            stickers: Forms("{n} 個貼圖", "{n} 個貼圖"),
        ),
    ]

    func testCountsInEveryLanguageAreRightAndHaveThousandsSeparators() throws {
        let numbers: [(count: Int, shown: String)] = [(0, "0"), (1, "1"), (12, "12"), (24, "24"), (128, "128"), (999, "999"), (1000, "1,000"), (12345, "12,345")]
        for language in Self.languages {
            let words = try XCTUnwrap(Self.countWords[language.folder])
            let display = try displayStrings(language)
            let firstParty = try firstPartyStrings(language)
            try withLanguage(language.folder) {
                for (count, shown) in numbers {
                    XCTAssertEqual(display.trackCount(count), words.tracks.text(count, shown: shown), "\(language.folder) tracks \(count)")
                    XCTAssertEqual(firstParty.memberCount(count), words.members.text(count, shown: shown), "\(language.folder) members \(count)")
                    XCTAssertEqual(firstParty.stickerCount(count), words.stickers.text(count, shown: shown), "\(language.folder) stickers \(count)")
                }
                // 数字写全，不缩写成「1.2 万」「1.2K」
                for text in [display.trackCount(12345), firstParty.memberCount(12345), firstParty.stickerCount(12345)] {
                    XCTAssertTrue(text.hasPrefix("12,345"), "\(language.folder)：\(text)")
                    XCTAssertFalse(text.contains("万") || text.contains("萬") || text.contains("K") || text.contains("1.2"), "\(language.folder)：\(text)")
                }
            }
        }
    }

    /// 文档 §3.9「例」一列的句子，逐字。
    func testTheDocsOwnExamples() throws {
        let simplified = try XCTUnwrap(Self.languages.first { $0.folder == "zh_CN" })
        let display = try displayStrings(simplified)
        let firstParty = try firstPartyStrings(simplified)
        try withLanguage("zh_CN") {
            XCTAssertEqual(display.trackCount(12), "12 首")
            XCTAssertEqual(firstParty.memberCount(128), "128 位成员")
            XCTAssertEqual(firstParty.stickerCount(24), "24 个贴纸")
            XCTAssertEqual(firstParty.memberCount(12345), "12,345 位成员")
        }
    }

    /// 千分位按该地区的习惯排：德国的地区格式是「12.345」，文案仍是界面语言（这里是英文）的。
    func testTheThousandsSeparatorFollowsTheRegion() throws {
        let strings = try withLanguage("en") { TellomiFirstPartyCard.Strings.localized(locale: Locale(identifier: "de_DE")) }
        try withLanguage("en") {
            XCTAssertEqual(strings.memberCount(12345), "12.345 members")
            XCTAssertEqual(strings.memberCount(1), "1 member")
        }
    }

    /// 复数文案在 PluralAware.stringsdict 里（文档 §3.9「iOS `.stringsdict`」，不自己拼单复数）：四种语言的表里都有，
    /// 英文有「一」「其他」两种写法，中文只有「其他」；旧的 `_ONE` / `_OTHER` 键对不再留在任何一张 Localizable.strings 里。
    func testTheCountsAreInThePluralTablesAndTheOldPairsAreGone() throws {
        let keys = ["TELLOMI_LINK_CARD_TRACK_COUNT_%ld", "TELLOMI_LINK_CARD_MEMBER_COUNT_%ld", "TELLOMI_LINK_CARD_STICKER_COUNT_%ld"]
        for language in Self.languages {
            let plural = try table(language.folder, "PluralAware", "stringsdict")
            for key in keys {
                let entry = try XCTUnwrap(plural[key] as? [String: Any], "\(language.folder) PluralAware.stringsdict lacks \(key)")
                XCTAssertEqual(entry["NSStringLocalizedFormatKey"] as? String, "%#@text@", "\(language.folder) \(key)")
                let variable = try XCTUnwrap(entry["text"] as? [String: Any], "\(language.folder) \(key)")
                XCTAssertEqual(variable["NSStringFormatSpecTypeKey"] as? String, "NSStringPluralRuleType", "\(language.folder) \(key)")
                XCTAssertEqual(variable["NSStringFormatValueTypeKey"] as? String, "ld", "\(language.folder) \(key)：计数是 %ld")
                XCTAssertNotNil(variable["other"], "\(language.folder) \(key)")
                XCTAssertEqual(variable["one"] != nil, language.folder == "en", "\(language.folder) \(key)：英文有「一」，中文只有「其他」")
            }
            let strings = try table(language.folder)
            for name in ["TRACK", "MEMBER", "STICKER"] {
                for suffix in ["ONE", "OTHER"] {
                    XCTAssertNil(strings["TELLOMI_LINK_CARD_\(name)_COUNT_\(suffix)"], "\(language.folder) still has the old TELLOMI_LINK_CARD_\(name)_COUNT_\(suffix)")
                }
            }
        }
    }

    /// 其他语言（tellomi/tellomi#1526 补译以后都有这几条复数文案）：按那种语言自己的复数显示，不回落英文、不显示键名。
    /// 缺键时回落英文的机制由 `TellomiLocalizationTest` 用合成的语言表测，不再依赖哪种真实语言缺键。
    func testTheBackfilledLanguagesUseTheirOwnPlurals() throws {
        let languages: [(folder: String, locale: String, one: String, word: String)] = [
            ("de", "de_DE", "1 Mitglied", "Mitglieder"),
            ("fr", "fr_FR", "1 membre", "membres"),
            ("ja", "ja_JP", "メンバー1人", "メンバー"),
        ]
        for (folder, localeIdentifier, one, word) in languages {
            let plural = try table(folder, "PluralAware", "stringsdict")
            XCTAssertNotNil(plural["TELLOMI_LINK_CARD_MEMBER_COUNT_%ld"], folder)
            let strings = try withLanguage(folder) { TellomiFirstPartyCard.Strings.localized(locale: Locale(identifier: localeIdentifier)) }
            try withLanguage(folder) {
                XCTAssertEqual(strings.memberCount(1), one, folder)
                let many = strings.memberCount(12345)
                XCTAssertFalse(many.contains("TELLOMI"), "\(folder)：不能显示键名：\(many)")
                XCTAssertTrue(many.contains(word) && many.contains("12") && many.contains("345"), "\(folder)：\(many)")
            }
        }
    }

    // MARK: - §3.9 发布日期：按界面语言的「中等长度日期」，今年的不带年

    func testPublishDatesInEveryLanguage() throws {
        let iso = ISO8601DateFormatter()
        let now = try XCTUnwrap(iso.date(from: "2026-09-29T12:00:00Z"))
        let thisYear = try XCTUnwrap(iso.date(from: "2026-09-03T12:00:00Z"))
        let lastYear = try XCTUnwrap(iso.date(from: "2025-12-01T12:00:00Z"))
        let expected: [String: (thisYear: String, lastYear: String)] = [
            "en": ("Sep 3", "Dec 1, 2025"),
            "zh_CN": ("9月3日", "2025年12月1日"),
            "zh_HK": ("9月3日", "2025年12月1日"),
            "zh_TW": ("9月3日", "2025年12月1日"),
        ]
        for language in Self.languages {
            let strings = try displayStrings(language, now: now)
            let want = try XCTUnwrap(expected[language.folder])
            XCTAssertEqual(strings.date(thisYear), want.thisYear, "\(language.folder) 今年的不带年")
            XCTAssertEqual(strings.date(lastYear), want.lastYear, "\(language.folder) 去年的带年")
        }
    }

    // MARK: - §3.10 类型文字（品牌壳副行）：16 个 kind × 4 种语言

    private struct KindName {
        let kind: String
        /// `TELLOMI_LINK_CARD_KIND_<key>`
        let key: String
        let zhHans: String
        let zhHK: String
        let zhTW: String
        let en: String

        init(_ kind: String, _ key: String, _ zhHans: String, _ zhHK: String, _ zhTW: String, _ en: String) {
            self.kind = kind
            self.key = key
            self.zhHans = zhHans
            self.zhHK = zhHK
            self.zhTW = zhTW
            self.en = en
        }

        func name(in folder: String) -> String {
            switch folder {
            case "zh_CN": zhHans
            case "zh_HK": zhHK
            case "zh_TW": zhTW
            default: en
            }
        }
    }

    /// 文档 §3.10 第一张表，原样抄在这里当期望值。香港、台湾繁体同一列，两地有别的只有两处：
    /// `music.playlist`（香港「歌單」、台灣「播放清單」）和 `app`（香港「應用程式」、台灣「App」）。
    private static let kindNames = [
        KindName("video", "VIDEO", "视频", "影片", "影片", "Video"),
        KindName("channel", "CHANNEL", "频道", "頻道", "頻道", "Channel"),
        KindName("music.track", "MUSIC_TRACK", "单曲", "單曲", "單曲", "Song"),
        KindName("music.album", "MUSIC_ALBUM", "专辑", "專輯", "專輯", "Album"),
        KindName("music.playlist", "MUSIC_PLAYLIST", "歌单", "歌單", "播放清單", "Playlist"),
        KindName("place", "PLACE", "地点", "地點", "地點", "Place"),
        KindName("app", "APP", "应用", "應用程式", "App", "App"),
        KindName("repo", "REPO", "代码仓库", "程式碼倉庫", "程式碼倉庫", "Repository"),
        KindName("article", "ARTICLE", "文章", "文章", "文章", "Article"),
        KindName("product", "PRODUCT", "商品", "商品", "商品", "Product"),
        KindName("package", "PACKAGE", "快递", "包裹", "包裹", "Package"),
        KindName("question", "QUESTION", "问答", "問答", "問答", "Q&A"),
        KindName("deal", "DEAL", "团购", "團購", "團購", "Deal"),
        KindName("ride", "RIDE", "行程", "行程", "行程", "Ride"),
        KindName("payment", "PAYMENT", "支付", "付款", "付款", "Payment"),
        KindName("web", "WEB", "网页", "網頁", "網頁", "Web page"),
    ]

    func testEveryKindNameInEveryLanguageMatchesTheDocTable() throws {
        XCTAssertEqual(Self.kindNames.count, 16, "§3.10 has 16 kinds")
        for language in Self.languages {
            let strings = try table(language.folder)
            let display = try displayStrings(language)
            try withLanguage(language.folder) {
                for row in Self.kindNames {
                    let want = row.name(in: language.folder)
                    XCTAssertEqual(strings["TELLOMI_LINK_CARD_KIND_\(row.key)"] as? String, want, "\(language.folder) \(row.kind)：语言表")
                    XCTAssertEqual(display.kindName(row.kind), want, "\(language.folder) \(row.kind)：产品取到的")
                }
                // 表里没有的 kind：副行留空，不显示 kind 的英文 id
                XCTAssertNil(display.kindName("podcast"), language.folder)
            }
        }
    }

    // MARK: - §3.10 第一方卡的按钮文案：6 条 × 4 种语言

    /// 文档 §3.10 第二张表：用户「发消息」、群没加入「加入群聊」、群已加入 / 官网「打开」、通话「加入通话」、贴纸没添加「添加」/ 已添加「查看」。
    func testTheFirstPartyButtonsInEveryLanguageMatchTheDocTable() throws {
        struct Buttons {
            let message: String
            let joinGroup: String
            let open: String
            let joinCall: String
            let add: String
            let view: String
        }
        let expected: [String: Buttons] = [
            "zh_CN": Buttons(message: "发消息", joinGroup: "加入群聊", open: "打开", joinCall: "加入通话", add: "添加", view: "查看"),
            "zh_HK": Buttons(message: "傳送訊息", joinGroup: "加入群組", open: "開啟", joinCall: "加入通話", add: "新增", view: "查看"),
            "zh_TW": Buttons(message: "傳送訊息", joinGroup: "加入群組", open: "開啟", joinCall: "加入通話", add: "新增", view: "查看"),
            "en": Buttons(message: "Message", joinGroup: "Join Group", open: "Open", joinCall: "Join Call", add: "Add", view: "View"),
        ]
        for language in Self.languages {
            let want = try XCTUnwrap(expected[language.folder])
            let strings = try table(language.folder)
            let keyed: [(key: String, value: String)] = [
                ("TELLOMI_LINK_CARD_ACTION_MESSAGE", want.message),
                ("TELLOMI_LINK_CARD_ACTION_JOIN_GROUP", want.joinGroup),
                ("TELLOMI_LINK_CARD_ACTION_OPEN", want.open),
                ("TELLOMI_LINK_CARD_ACTION_JOIN_CALL", want.joinCall),
                ("TELLOMI_LINK_CARD_ACTION_ADD_STICKERS", want.add),
                ("TELLOMI_LINK_CARD_ACTION_VIEW_STICKERS", want.view),
            ]
            XCTAssertEqual(keyed.count, 6, "§3.10 has 6 button texts")
            for (key, value) in keyed {
                XCTAssertEqual(strings[key] as? String, value, "\(language.folder) \(key)：语言表")
            }
            let card = try firstPartyStrings(language)
            XCTAssertEqual(card.actionMessage, want.message, language.folder)
            XCTAssertEqual(card.actionJoinGroup, want.joinGroup, language.folder)
            XCTAssertEqual(card.actionOpen, want.open, language.folder)
            XCTAssertEqual(card.actionJoinCall, want.joinCall, language.folder)
            XCTAssertEqual(card.actionAddStickers, want.add, language.folder)
            XCTAssertEqual(card.actionViewStickers, want.view, language.folder)
        }
    }
}
