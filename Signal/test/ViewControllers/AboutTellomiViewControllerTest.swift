//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

import SignalServiceKit
@testable import Signal
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1165）：「关于 Tellomi」页的每一行都做它该做的事，地址一个字都不能错（与 Android `AboutSettingsScreenTest` 同一张表）。
final class AboutTellomiViewControllerTest: XCTestCase {
    private final class RecordingActions: AboutTellomiActions {
        var events: [String] = []
        func copy(_ text: String) { events.append("copy:\(text)") }
        func openInAppBrowser(_ url: URL) { events.append("open:\(url.absoluteString)") }
        func writeEmail(to address: String) { events.append("email:\(address)") }
        func showLicenses() { events.append("licenses") }
    }

    private func makeViewController(_ actions: RecordingActions) -> AboutTellomiViewController {
        let viewController = AboutTellomiViewController(actions: actions, versionName: "0.1.2", buildNumber: "175101", updateOffer: nil)
        viewController.loadViewIfNeeded()
        return viewController
    }

    /// tellomi/tellomi#1491（需求 3.4「可选更新」）：有新版本时「更新」一组第一行是「Tellomi x 可用」，点了去清单里的 TestFlight 链接。
    func testANewerVersionAddsARowThatOpensTheUpdate() {
        let offer = TellomiUpdateManifests.Offer(
            tier: .optional,
            version: "0.1.1",
            build: 6,
            updateUrl: URL(string: "https://testflight.apple.com/join/AbCdEfGh"),
            notesUrl: nil,
        )
        var opened: [TellomiUpdateManifests.Offer] = []
        let actions = RecordingActions()
        let viewController = AboutTellomiViewController(
            actions: actions,
            versionName: "0.1.0",
            buildNumber: "5",
            updateOffer: offer,
            openUpdate: { opened.append($0) },
        )
        viewController.loadViewIfNeeded()

        let updates = viewController.contents.sections[1]
        XCTAssertEqual(updates.items.count, 2, "the new version row comes before 'Check for updates'")
        updates.items[0].actionBlock?()
        XCTAssertEqual(opened, [offer])
        XCTAssertEqual(actions.events, [])
    }

    func testTappingTheVersionCopiesTheFullVersion() {
        let actions = RecordingActions()
        makeViewController(actions).didTapVersion()
        XCTAssertEqual(actions.events, ["copy:0.1.2 (175101)"])
    }

    /// 从上到下点一遍所有能点的行：更新 → 官网 → 三个邮箱（点按复制）→ 六份法律文件（App 内浏览器）→ 开源许可。
    /// owner 2026-09-25：「源代码 github.com/tellomi」那一行去掉了（源代码的说明挪到「开源许可」页最上面，见下面两条）
    func testEveryRowDoesWhatItSays() {
        let actions = RecordingActions()
        let viewController = makeViewController(actions)

        for section in viewController.contents.sections {
            for item in section.items {
                item.actionBlock?()
            }
        }

        XCTAssertEqual(actions.events, [
            "open:https://www.tellomi.app/download/",
            "open:https://www.tellomi.app/",
            "copy:support@tellomi.app",
            "copy:privacy@tellomi.app",
            "copy:abuse@tellomi.app",
            "open:https://www.tellomi.app/legal/terms/",
            "open:https://www.tellomi.app/legal/privacy/",
            "open:https://www.tellomi.app/legal/pi-collection/",
            "open:https://www.tellomi.app/legal/third-party/",
            "open:https://www.tellomi.app/legal/permissions/",
            "open:https://www.tellomi.app/legal/complaints/",
            "licenses",
        ])
    }

    /// 长按邮箱出「写邮件」：只有三个邮箱行有长按菜单
    func testOnlyEmailRowsHaveTheWriteEmailMenu() {
        let viewController = makeViewController(RecordingActions())
        let itemsWithMenus = viewController.contents.sections.flatMap(\.items).filter { $0.contextMenuActionProvider != nil }
        XCTAssertEqual(itemsWithMenus.count, 3)
    }

    /// 页脚三行署名（#984）：上游署名、我们对修改部分的署名、许可证。
    /// owner 2026-09-24：修改部分写营业执照上的公司全称（不写品牌名），许可证写正式名称「GNU AGPLv3」，与 Android 同一句。
    func testFooterKeepsTheAttribution() {
        let viewController = makeViewController(RecordingActions())
        XCTAssertEqual(
            viewController.contents.sections.last?.footerTitle,
            "Copyright Signal Messenger\nModifications Copyright 重庆半格智能科技有限公司\nLicensed under the GNU AGPLv3",
        )
    }

    /// 四种语言都一样：公司全称一字不差（繁体界面也不转字，名称以营业执照为准），许可证带 GNU，不再出现品牌名。
    func testFooterNamesTheCompanyAndTheFullLicenseInEveryLanguage() throws {
        for language in ["en", "zh_CN", "zh_HK", "zh_TW"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language), language)
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], language)
            let footer = try XCTUnwrap(table["ABOUT_SECTION_FOOTER_TELLOMI"], language)
            XCTAssertEqual(footer.components(separatedBy: "\n").count, 3, language)
            XCTAssertTrue(footer.contains("Signal Messenger"), language)
            XCTAssertTrue(footer.contains("重庆半格智能科技有限公司"), language)
            XCTAssertTrue(footer.contains("GNU AGPLv3"), language)
            XCTAssertFalse(footer.contains("Tellomi"), language)
        }
    }

    /// 「开源许可」页最上面一句：许可证 + 源代码在官网哪一页（AGPL：给了别人 App，就要让人拿得到源代码）。不可点，只是一句话。
    func testLicensesPageStartsWithWhereToGetTheSourceCode() throws {
        let viewController = TellomiAcknowledgementsViewController()
        viewController.loadViewIfNeeded()
        let firstSection = try XCTUnwrap(viewController.contents.sections.first)
        XCTAssertEqual(firstSection.items.count, 1)
        let item = try XCTUnwrap(firstSection.items.first)
        XCTAssertNil(item.actionBlock)
        let cell = try XCTUnwrap(item.getOrBuildCustomCell(UITableView()))
        let texts = labels(in: cell).compactMap(\.text)
        XCTAssertEqual(texts, [TellomiAcknowledgementsViewController.sourceCodeNotice])
        XCTAssertEqual(TellomiAboutLinks.sourceCodePage.absoluteString, "https://www.tellomi.app/source/")
        XCTAssertTrue(texts[0].contains("www.tellomi.app/source"))
        XCTAssertFalse(texts[0].lowercased().contains("github"))
    }

    /// 四种语言都写了这一句（iOS 缺键会直接显示键名，不回落英文），都带官网地址和许可证名，都不出现 GitHub；
    /// 也不写「基于 Signal」（owner 2026-09-26，与官网 /source 同口径，超级仓库 docs/product/specs/about-page.md）
    func testSourceCodeNoticeInEveryLanguage() throws {
        for language in ["en", "zh_CN", "zh_HK", "zh_TW"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language), language)
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], language)
            let notice = try XCTUnwrap(table["SETTINGS_ABOUT_TELLOMI_SOURCE_CODE_NOTICE"], language)
            XCTAssertTrue(notice.contains("www.tellomi.app/source"), language)
            XCTAssertTrue(notice.contains("GNU AGPLv3"), language)
            XCTAssertFalse(notice.lowercased().contains("github"), language)
            XCTAssertFalse(notice.contains("Signal"), language)
            XCTAssertNil(table["SETTINGS_ABOUT_TELLOMI_SOURCE_CODE"], language)
        }
    }

    /// 给人看的截图（TELLOMI_SHOTS=1 时才跑）：「关于」页拉到底（开源一组只剩「开源许可」）、「开源许可」页顶上那一句。
    /// 写到 `TELLOMI_SHOTS_DIR/<屏宽>/`，屏宽就是跑这条用例的模拟器的屏宽。
    @MainActor
    func testShotsOfOpenSourceSectionAndLicensesPage() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(UIScreen.main.bounds.size.width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func shoot(_ viewController: UIViewController, name: String, scrollToBottom: Bool) async throws {
            let window = UIWindow.tellomiTestWindow(frame: UIScreen.main.bounds)
            window.rootViewController = UINavigationController(rootViewController: viewController)
            window.isHidden = false
            window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 500_000_000)
            if scrollToBottom, let tableView = (viewController as? OWSTableViewController2)?.tableView {
                // 行高、页脚高是估算后才定下来的：滚到底、等一下、再按新的内容高度滚一次，直到不再变
                for _ in 0..<4 {
                    tableView.layoutIfNeeded()
                    let visibleHeight = tableView.bounds.size.height
                    let bottom = max(-tableView.adjustedContentInset.top, tableView.contentSize.height - visibleHeight + tableView.adjustedContentInset.bottom)
                    tableView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
            window.isHidden = true
            window.rootViewController = nil
        }

        try await shoot(makeViewController(RecordingActions()), name: "about-bottom", scrollToBottom: true)
        try await shoot(TellomiAcknowledgementsViewController(), name: "licenses-top", scrollToBottom: false)
    }

    private func labels(in view: UIView) -> [UILabel] {
        (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    /// 「开源许可」读的是 App 里的 Settings.bundle/Acknowledgements.plist（系统「设置」App 显示的同一份）
    func testLicensesLoadFromTheSettingsBundle() {
        let entries = TellomiAcknowledgements.load()
        XCTAssertGreaterThan(entries.count, 100)
        XCTAssertFalse(entries.contains { $0.title == "Acknowledgements" })
        XCTAssertTrue(entries.allSatisfy { !$0.text.isEmpty })
    }
}
