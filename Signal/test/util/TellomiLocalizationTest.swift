//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

/// Tellomi：当前语言缺键时回落英文，而不是把键名显示在界面上；中文三种语言的表必须覆盖英文的全部键。
final class TellomiLocalizationTest: XCTestCase {

    private var tempDirectory: URL!
    private var germanTable: Bundle!
    private var englishTable: Bundle!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        germanTable = try makeTable("de", entries: ["BOTH": "beide"])
        englishTable = try makeTable("en", entries: ["BOTH": "both", "ONLY_EN": "english only"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    /// An `xx.lproj` directory used directly as a bundle: its `Localizable.strings` is the only table it has,
    /// the same way the app's table for the user's language is the only one iOS consults.
    private func makeTable(_ language: String, entries: [String: String]) throws -> Bundle {
        let directory = tempDirectory.appendingPathComponent("\(language).lproj")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = entries.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
        try text.write(to: directory.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(Bundle(path: directory.path))
    }

    func testPlatformShowsTheKeyWhenTheTableLacksIt() {
        // 这条钉住的是平台行为，也是这次修复的前提：缺键时系统返回键名，不会自己回落英文。
        XCTAssertEqual(germanTable.localizedString(forKey: "BOTH", value: "", table: nil), "beide")
        XCTAssertEqual(germanTable.localizedString(forKey: "ONLY_EN", value: "", table: nil), "ONLY_EN")
    }

    func testFallsBackToEnglishWhenTheCurrentLanguageLacksTheKey() {
        func lookup(_ key: String, value: String = "") -> String {
            TellomiLocalization.localizedString(key, tableName: nil, value: value, bundle: germanTable, englishBundle: englishTable)
        }
        XCTAssertEqual(lookup("BOTH"), "beide")
        XCTAssertEqual(lookup("ONLY_EN"), "english only")
        XCTAssertEqual(lookup("NOWHERE"), "NOWHERE")
        XCTAssertEqual(lookup("NOWHERE", value: "default"), "default")
    }

    func testWithoutAnEnglishTableBehavesLikeUpstream() {
        let result = TellomiLocalization.localizedString("ONLY_EN", tableName: nil, value: "", bundle: germanTable, englishBundle: nil)
        XCTAssertEqual(result, "ONLY_EN")
    }

    func testAppHasAnEnglishTable() throws {
        let english = try XCTUnwrap(TellomiLocalization.englishBundle(in: Bundle.main.app))
        XCTAssertEqual(english.localizedString(forKey: "ONBOARDING_SPLASH_TITLE", value: "", table: nil).isEmpty, false)
        XCTAssertNotEqual(english.localizedString(forKey: "ONBOARDING_SPLASH_TITLE", value: "", table: nil), "ONBOARDING_SPLASH_TITLE")
    }

    /// 用 App 里真实的每一张语言表查英文表的每一个键：哪种语言都不能把键名显示出来。
    /// 基线上 `ABOUT_SECTION_FOOTER_TELLOMI` 就只有中英文，没有回落时 de / ja 等 40 多种语言显示的是键名。
    func testNoLanguageShowsRawKeys() throws {
        let app = Bundle.main.app
        let english = try XCTUnwrap(TellomiLocalization.englishBundle(in: app))
        let englishPath = try XCTUnwrap(english.path(forResource: "Localizable", ofType: "strings"))
        let englishTable = try XCTUnwrap(NSDictionary(contentsOfFile: englishPath) as? [String: String])
        let localizations = app.localizations.filter { $0 != "en" && $0 != "Base" }
        XCTAssertGreaterThan(localizations.count, 10, "\(localizations)")
        for localization in localizations {
            let table = try XCTUnwrap(app.path(forResource: localization, ofType: "lproj").flatMap { Bundle(path: $0) }, localization)
            let raw = englishTable
                .filter { key, englishValue in
                    englishValue != key && TellomiLocalization.localizedString(key, tableName: nil, value: "", bundle: table, englishBundle: english) == key
                }
                .keys
                .sorted()
            XCTAssertEqual(raw, [], "\(localization) shows \(raw.count) raw keys")
        }
    }

    /// 中文三种语言是 Tellomi 的主要用户，每个新键都要有中文，不能靠英文回落。
    func testChineseTablesCoverEveryEnglishKey() throws {
        let english = try localizableKeys("en")
        XCTAssertGreaterThan(english.count, 1000, "the English table should be the full app table")
        for localization in ["zh_CN", "zh_HK", "zh_TW"] {
            let missing = english.subtracting(try localizableKeys(localization)).sorted()
            XCTAssertEqual(missing, [], "\(localization) lacks \(missing.count) keys")
        }
    }

    // MARK: - PluralAware.stringsdict

    // 复数文案不在 Localizable.strings 里，上面两条查不到（taishi 审查 b1 不阻塞 2）。一条新条目嵌进上一条的 dict 时
    // `plutil -lint` 照过，运行时按键查不到、界面显示键名；英文表是同一个错时回落也救不了。

    /// 每种语言的每一条都在顶层：值是带 NSStringLocalizedFormatKey 的 dict，里面其余的 dict 只能是变量说明。
    func testPluralAwareEntriesAreAllAtTheTopLevel() throws {
        let localizations = Bundle.main.app.localizations.filter { $0 != "Base" }
        XCTAssertGreaterThan(localizations.count, 10, "\(localizations)")
        for localization in localizations {
            var misplaced = [String]()
            for (key, value) in try pluralAwareTable(localization) {
                guard let entry = value as? [String: Any], entry["NSStringLocalizedFormatKey"] is String else {
                    misplaced.append(key)
                    continue
                }
                for (name, variable) in entry where name != "NSStringLocalizedFormatKey" {
                    if (variable as? [String: Any])?["NSStringFormatSpecTypeKey"] == nil {
                        misplaced.append("\(key) → \(name)")
                    }
                }
            }
            XCTAssertEqual(misplaced.sorted(), [], "\(localization) PluralAware.stringsdict has entries nested in other entries")
        }
    }

    /// 源码里 `tableName: "PluralAware"` 取的每个键，英文表顶层都要有；有了它，其它语言缺键才回落得到英文。
    func testPluralAwareKeysUsedInCodeAreInTheEnglishTable() throws {
        let scan = try scanSources(
            withExtensions: ["swift"],
            excluding: "OWSLocalizedString.swift",
            keyPattern: #"OWSLocalizedString\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*tableName:\s*"PluralAware""#,
            usePattern: #"tableName:\s*"PluralAware""#,
        )
        XCTAssertEqual(scan.matchedUses, scan.allUses, "some PluralAware lookups are not written as OWSLocalizedString(\"KEY\", tableName: \"PluralAware\", …)")
        XCTAssertGreaterThan(scan.keys.count, 100)
        let missing = scan.keys.subtracting(try pluralAwareTable("en").keys).sorted()
        XCTAssertEqual(missing, [], "used in code but not at the top level of en.lproj/PluralAware.stringsdict")
    }

    /// 与 Localizable.strings 一样，复数文案中文三种语言也要齐，不能靠英文回落。
    func testChinesePluralTablesCoverEveryEnglishKey() throws {
        let english = Set(try pluralAwareTable("en").keys)
        XCTAssertGreaterThan(english.count, 100)
        for localization in ["zh_CN", "zh_HK", "zh_TW"] {
            let missing = english.subtracting(try pluralAwareTable(localization).keys).sorted()
            XCTAssertEqual(missing, [], "\(localization) lacks \(missing.count) plural keys")
        }
    }

    // MARK: - Objective-C

    /// ObjC 的 `OWSLocalizedString` 宏（SignalServiceKit.h）直接调 NSBundle，不走上面的英文回落（taishi 审查 b1 不阻塞 1）。
    /// 所以从 ObjC 取的键必须每种语言都有；Tellomi 的新键只写四种语言，只能从 Swift 取。
    func testKeysReadFromObjectiveCExistInEveryLanguage() throws {
        let scan = try scanSources(
            withExtensions: ["h", "m", "mm"],
            excluding: "SignalServiceKit.h",
            keyPattern: #"OWSLocalizedString\(\s*@"((?:[^"\\]|\\.)*)""#,
            usePattern: #"OWSLocalizedString\("#,
        )
        XCTAssertEqual(scan.matchedUses, scan.allUses, "some Objective-C lookups are not written as OWSLocalizedString(@\"KEY\", …)")
        XCTAssertGreaterThan(scan.keys.count, 20)
        let localizations = Bundle.main.app.localizations.filter { $0 != "Base" }
        XCTAssertGreaterThan(localizations.count, 10, "\(localizations)")
        for localization in localizations {
            let missing = scan.keys.subtracting(try localizableKeys(localization)).sorted()
            XCTAssertEqual(missing, [], "\(localization) lacks keys read from Objective-C, which get no English fallback")
        }
    }

    // MARK: - Helpers

    private func localizableKeys(_ localization: String) throws -> Set<String> {
        let path = try XCTUnwrap(
            Bundle.main.app.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization),
            "no Localizable.strings for \(localization)",
        )
        let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], "unreadable table for \(localization)")
        return Set(table.keys)
    }

    /// 在 Scripts/translation/auto-genstrings 扫的范围里（五个 target 目录，跳过 test / tests）收集 `keyPattern` 第一组捕获的键。
    /// `usePattern` 数所有用法：键不是字面量、或者换了写法时 `keyPattern` 会静默漏掉，所以调用方要核两个数对得上。
    private func scanSources(
        withExtensions extensions: Set<String>,
        excluding excludedName: String,
        keyPattern: String,
        usePattern: String,
    ) throws -> (keys: Set<String>, matchedUses: Int, allUses: Int) {
        // 本文件在 <仓库>/Signal/test/util/ 下
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let keyExpression = try NSRegularExpression(pattern: keyPattern)
        let useExpression = try NSRegularExpression(pattern: usePattern)
        var keys = Set<String>()
        var matchedUses = 0
        var allUses = 0
        for target in ["Signal", "SignalServiceKit", "SignalUI", "SignalNSE", "SignalShareExtension"] {
            let directory = repository.appendingPathComponent(target)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]), directory.path)
            for case let file as URL in files {
                if ["test", "tests"].contains(file.lastPathComponent), try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    files.skipDescendants()
                    continue
                }
                guard extensions.contains(file.pathExtension), file.lastPathComponent != excludedName else {
                    continue
                }
                let source = try String(contentsOf: file, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                allUses += useExpression.numberOfMatches(in: source, range: range)
                for match in keyExpression.matches(in: source, range: range) {
                    matchedUses += 1
                    let key = try XCTUnwrap(Range(match.range(at: 1), in: source))
                    keys.insert(String(source[key]))
                }
            }
        }
        return (keys, matchedUses, allUses)
    }

    private func pluralAwareTable(_ localization: String) throws -> [String: Any] {
        let path = try XCTUnwrap(
            Bundle.main.app.path(forResource: "PluralAware", ofType: "stringsdict", inDirectory: nil, forLocalization: localization),
            "no PluralAware.stringsdict for \(localization)",
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: Any], "unreadable PluralAware.stringsdict for \(localization)")
    }
}

/// Tellomi：「消息到时间自动消失」这个功能两端统一叫「限时消息」，繁体叫「限時訊息」（owner 2026-09-26，两端差异清单 N3）。
/// 上游中文把它叫成「阅后即焚」「自動銷毀訊息」「訊息銷毀」等，而「阅后即焚」在 Signal 中文里还指「一次性查看」，两个功能撞名。
/// 只管点名这个功能的字符串：英文原文讲 disappearing message 的，中文三种语言里都不许再出现旧称。
final class TellomiDisappearingMessagesTermTest: XCTestCase {

    private static let featureName = ["zh_CN": "限时消息", "zh_HK": "限時訊息", "zh_TW": "限時訊息", "yue": "限時訊息"]
    private static let oldNames = ["阅后即焚", "閱後即焚", "自動銷毀", "訊息銷毀", "銷毀的訊息", "過眼雲煙"]

    func testTheFeatureHasTheSameNameEverywhere() throws {
        for (localization, name) in Self.featureName {
            let table = try localizable(localization)
            XCTAssertEqual(table["DISAPPEARING_MESSAGES"], name, localization)
            XCTAssertEqual(table["SETTINGS_DISAPPEARING_MESSAGES"], name, localization)
        }
    }

    func testNoStringAboutDisappearingMessagesUsesAnOldName() throws {
        let keys = try localizable("en").filter { $0.value.localizedCaseInsensitiveContains("disappearing message") }.keys
        let pluralKeys = try plurals("en").filter { $0.value.contains { $0.localizedCaseInsensitiveContains("disappearing message") } }.keys
        XCTAssertGreaterThan(keys.count, 10)
        XCTAssertFalse(pluralKeys.isEmpty)

        for localization in Self.featureName.keys.sorted() {
            let table = try localizable(localization)
            let pluralTable = try plurals(localization)
            let texts = keys.map { ($0, [table[$0] ?? ""]) } + pluralKeys.map { ($0, pluralTable[$0] ?? []) }
            let offenders = texts
                .flatMap { key, values in values.map { (key, $0) } }
                .filter { _, text in Self.oldNames.contains { text.contains($0) } }
                .map { key, text in "\(key): \(text)" }
                .sorted()
            XCTAssertEqual(offenders, [], localization)
        }
    }

    private func localizable(_ localization: String) throws -> [String: String] {
        let path = try XCTUnwrap(
            Bundle.main.app.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization),
            "no Localizable.strings for \(localization)",
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], "unreadable table for \(localization)")
    }

    /// PluralAware.stringsdict：每个键下各个复数分支（one / other …）的文字。
    private func plurals(_ localization: String) throws -> [String: [String]] {
        let path = try XCTUnwrap(
            Bundle.main.app.path(forResource: "PluralAware", ofType: "stringsdict", inDirectory: nil, forLocalization: localization),
            "no PluralAware.stringsdict for \(localization)",
        )
        let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: Any], "unreadable PluralAware.stringsdict for \(localization)")
        return table.mapValues { Self.texts(in: $0) }
    }

    private static func texts(in value: Any) -> [String] {
        switch value {
        case let text as String:
            return [text]
        case let entry as [String: Any]:
            return entry
                .filter { $0.key != "NSStringFormatSpecTypeKey" && $0.key != "NSStringFormatValueTypeKey" }
                .values
                .flatMap { texts(in: $0) }
        default:
            return []
        }
    }
}

/// Tellomi（tellomi/tellomi#1401）：`PluralAware.stringsdict` 里用户看得见的文字不许再出现「Signal」。
/// 品牌替换脚本（超级仓库 `scripts/brand/rename-strings.py`）原来只扫 `.strings`，漏了 `.stringsdict`，
/// 中文界面上还写着「Signal 群组…」「所有 Signal 密友…」。需要点名 Signal 的法律 / 署名文字要进白名单并写明理由——目前一条都没有。
final class TellomiStringsdictBrandTest: XCTestCase {

    private static let localizations = ["en", "zh_CN", "zh_HK", "zh_TW"]
    /// 键 → 理由。只放法律或署名上必须点名 Signal 的。
    private static let allowlist: [String: String] = [:]

    func testNoUserVisiblePluralStringSaysSignal() throws {
        for localization in Self.localizations {
            let path = try XCTUnwrap(
                Bundle.main.app.path(forResource: "PluralAware", ofType: "stringsdict", inDirectory: nil, forLocalization: localization),
                "no PluralAware.stringsdict for \(localization)",
            )
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: Any], "unreadable PluralAware.stringsdict for \(localization)")
            XCTAssertGreaterThan(table.count, 50, localization)
            let offenders = table
                .filter { Self.allowlist[$0.key] == nil }
                .flatMap { key, value in Self.texts(in: value).map { (key, $0) } }
                .filter { _, text in text.contains("Signal") }
                .map { key, text in "\(key): \(text)" }
                .sorted()
            XCTAssertEqual(offenders, [], localization)
        }
    }

    /// 用户看得见的是 NSStringLocalizedFormatKey 和各复数分支；两个类型键的值（NSStringPluralRuleType / d）不是文字。
    private static func texts(in value: Any) -> [String] {
        switch value {
        case let text as String:
            return [text]
        case let entry as [String: Any]:
            return entry
                .filter { $0.key != "NSStringFormatSpecTypeKey" && $0.key != "NSStringFormatValueTypeKey" }
                .values
                .flatMap { texts(in: $0) }
        default:
            return []
        }
    }
}

/// 跨境告知、同意勾选与首次启动提示是法律文本，只有 zh_CN / zh_HK / zh_TW / en 四种定稿（privacy-compliance-hk-cross-border §6.3）。
/// 其余语言显示英文定稿，粤语显示繁体（香港）定稿，不放未经审定的翻译。
final class TellomiLegalTextLanguagesTest: XCTestCase {

    private static let legalPrefixes = ["TELLOMI_CROSS_BORDER_", "TELLOMI_CONSENT_", "TELLOMI_FIRST_LAUNCH_"]

    func testOtherLanguagesShowTheReviewedText() throws {
        let english = try localizable("en")
        let hongKong = try localizable("zh_HK")
        let legalKeys = english.keys.filter { key in Self.legalPrefixes.contains { key.hasPrefix($0) } }
        XCTAssertGreaterThan(legalKeys.count, 40)
        let localizations = Bundle.main.app.localizations.filter { !["Base", "en", "zh_CN", "zh_HK", "zh_TW"].contains($0) }
        XCTAssertGreaterThan(localizations.count, 10, "\(localizations)")
        for localization in localizations {
            let table = try localizable(localization)
            let reviewed = localization == "yue" ? hongKong : english
            let drifted = legalKeys.filter { key in table[key].map { $0 != reviewed[key] } ?? false }.sorted()
            XCTAssertEqual(drifted, [], localization)
        }
    }

    private func localizable(_ localization: String) throws -> [String: String] {
        let path = try XCTUnwrap(
            Bundle.main.app.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization),
            "no Localizable.strings for \(localization)",
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], "unreadable table for \(localization)")
    }
}
