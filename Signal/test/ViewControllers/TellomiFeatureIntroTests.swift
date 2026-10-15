//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 新功能提示卡（`docs/product/specs/whats-new-cards.md`）：谁看得到、一次只弹一张、弹过不再弹、卡片内容。
final class TellomiFeatureIntroTests: SignalBaseTest {

    private let before = Date(timeIntervalSince1970: 1_792_166_400 - 86_400)
    private let after = Date(timeIntervalSince1970: 1_792_166_400 + 60)

    /// 新装用户不弹：只给卡片出来之前注册的人；还没注册（拿不到注册时间）的不弹；读过的不弹。
    func testShowsOnlyToAccountsRegisteredBeforeTheCardAndOnlyOnce() {
        for intro in TellomiFeatureIntro.allCases {
            XCTAssertTrue(TellomiFeatureIntro.shouldShow(intro, registrationDate: before, hasSeen: false), intro.rawValue)
            XCTAssertFalse(TellomiFeatureIntro.shouldShow(intro, registrationDate: after, hasSeen: false), "\(intro.rawValue)：之后注册的新用户")
            XCTAssertFalse(TellomiFeatureIntro.shouldShow(intro, registrationDate: nil, hasSeen: false), "\(intro.rawValue)：还没注册")
            XCTAssertFalse(TellomiFeatureIntro.shouldShow(intro, registrationDate: before, hasSeen: true), "\(intro.rawValue)：读过了")
        }
    }

    /// 功能 ID 是文档里定的那几个（记已读用它当 key，不能改）。
    func testFeatureIdsMatchTheSpec() {
        XCTAssertEqual(TellomiFeatureIntro.allCases.map(\.rawValue), ["attachment_sheet_v2", "photo_picker_v2", "forward_grid_v1"])
    }

    /// 附件面板第一次打开时两张都满足：只弹「附件面板」，记已读；下次打开弹「选图」；再下次什么都不弹。
    @MainActor
    func testOneCardAtATimeInOrderAndNeverTwice() async throws {
        let host = try makeHost()
        defer { host.window.isHidden = true }

        let first = TellomiFeatureIntro.presentFirstDue([.attachmentSheet, .photoPicker], from: host.root, registrationDate: before)
        XCTAssertEqual(first, .attachmentSheet)
        XCTAssertTrue(host.root.presentedViewController is HeroSheetViewController)
        XCTAssertNil(
            TellomiFeatureIntro.presentFirstDue([.photoPicker], from: host.root, registrationDate: before),
            "上面已经盖着一张卡，不叠着弹",
        )
        await dismissPresented(host.root)

        XCTAssertEqual(TellomiFeatureIntro.presentFirstDue([.attachmentSheet, .photoPicker], from: host.root, registrationDate: before), .photoPicker)
        await dismissPresented(host.root)

        XCTAssertNil(TellomiFeatureIntro.presentFirstDue([.attachmentSheet, .photoPicker], from: host.root, registrationDate: before))
        XCTAssertNil(host.root.presentedViewController)

        read { tx in
            XCTAssertTrue(TellomiFeatureIntro.hasSeen(.attachmentSheet, tx: tx))
            XCTAssertTrue(TellomiFeatureIntro.hasSeen(.photoPicker, tx: tx))
            XCTAssertFalse(TellomiFeatureIntro.hasSeen(.forwardGrid, tx: tx))
        }
    }

    /// 之后注册的新用户：一张都不弹，也不记已读。
    @MainActor
    func testNewAccountsSeeNoCards() throws {
        let host = try makeHost()
        defer { host.window.isHidden = true }
        XCTAssertNil(TellomiFeatureIntro.presentFirstDue(TellomiFeatureIntro.allCases, from: host.root, registrationDate: after))
        XCTAssertNil(host.root.presentedViewController)
        read { tx in
            for intro in TellomiFeatureIntro.allCases {
                XCTAssertFalse(TellomiFeatureIntro.hasSeen(intro, tx: tx))
            }
        }
    }

    /// 卡片内容：条数同文档（2 / 3 / 1），英文、简体都有字（不是 key 本身）；图标都是存在的 SF Symbol，画进正方形。
    func testCardContents() {
        let counts: [TellomiFeatureIntro: Int] = [.attachmentSheet: 2, .photoPicker: 3, .forwardGrid: 1]
        for intro in TellomiFeatureIntro.allCases {
            let content = intro.content
            XCTAssertEqual(content.items.count, counts[intro], intro.rawValue)
            XCTAssertFalse(content.title.hasPrefix("TELLOMI_INTRO_"), "\(intro.rawValue) 标题没翻译")
            for item in content.items {
                XCTAssertFalse(item.text.hasPrefix("TELLOMI_INTRO_"), "\(intro.rawValue) 条目没翻译")
                XCTAssertNotNil(UIImage(systemName: item.symbol), item.symbol)
                XCTAssertEqual(TellomiFeatureIntro.symbolImage(item.symbol, side: 24).size, CGSize(width: 24, height: 24))
            }
            XCTAssertNotNil(UIImage(systemName: content.symbol), content.symbol)
        }
        for (locale, expected) in [("en", "Got it"), ("zh_CN", "知道了"), ("zh_TW", "知道了"), ("zh_HK", "知道了")] {
            let bundle = Bundle(for: TellomiFeatureIntroTests.self)
            let path = Bundle.main.path(forResource: locale, ofType: "lproj") ?? bundle.path(forResource: locale, ofType: "lproj")
            let localized = path.flatMap(Bundle.init(path:))?.localizedString(forKey: "TELLOMI_INTRO_GOT_IT", value: nil, table: nil)
            XCTAssertEqual(localized, expected, locale)
        }
    }

    /// 三张卡的样子（只在 TELLOMI_SHOTS=1 时截）。
    @MainActor
    func testCardScreenshots() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        for intro in TellomiFeatureIntro.allCases {
            let host = try makeHost()
            host.root.present(intro.makeSheet(), animated: false)
            // 上游的 InteractiveSheet 量完内容再把高度调上去（带动画），等它停下来再拍。
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try save(render(host.window), name: "whats-new-\(intro.rawValue).png", width: host.window.bounds.size.width)
            // 单测的 TestAppContext 只有 300×400，Sheet 最高约 300 pt，内容在 Sheet 里滚；真机（874 pt 高）放得下。
            // 再拍一张滚到底的，看下半截（最后几条和「知道了」）。
            if let sheet = host.root.presentedViewController, let scrollView = Self.firstScrollView(in: sheet.view) {
                scrollView.layoutIfNeeded()
                let bottom = max(0, scrollView.contentSize.height - scrollView.bounds.size.height)
                scrollView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                try await Task.sleep(nanoseconds: 300_000_000)
                try save(render(host.window), name: "whats-new-\(intro.rawValue)-bottom.png", width: host.window.bounds.size.width)
            }
            host.root.dismiss(animated: false)
            host.window.isHidden = true
        }
    }

    // MARK: -

    private struct Host {
        let window: UIWindow
        let root: UIViewController
    }

    @MainActor
    private func makeHost() throws -> Host {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let root = UIViewController()
        root.view.backgroundColor = .Signal.background
        window.rootViewController = root
        window.isHidden = false
        return Host(window: window, root: root)
    }

    @MainActor
    private func dismissPresented(_ root: UIViewController) async {
        root.dismiss(animated: false)
        let deadline = Date().addingTimeInterval(5)
        while root.presentedViewController != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func save(_ image: UIImage, name: String, width: CGFloat) throws {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }
}
