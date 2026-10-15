//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// ADR-0063 §8.1 第 9 行：「设置 → 聊天」里的链接预览说明与「展开短链接」开关（tellomi/tellomi#1423）。
///
/// 在内存环境里把真实的 `ChatsSettingsViewController` 放进窗口排版（不连服务端、不建真账号）。
/// 截图只在 `TELLOMI_SHOTS=1` 时存（xcodebuild 用 `TEST_RUNNER_TELLOMI_SHOTS=1` 传进来），写到 `TELLOMI_SHOTS_DIR`。
final class TellomiLinkPreviewSettingsTest: SignalBaseTest {

    private let shortLinkSwitchId = "tellomi_expand_short_links"

    @MainActor
    private func present() async throws -> UIWindow {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = OWSNavigationController(rootViewController: ChatsSettingsViewController())
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        return window
    }

    private func views<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        var result = [T]()
        if let view = view as? T {
            result.append(view)
        }
        for subview in view.subviews {
            result += views(of: type, in: subview)
        }
        return result
    }

    @MainActor
    private func shortLinkSwitch(in window: UIWindow) throws -> UISwitch {
        return try XCTUnwrap(views(of: UISwitch.self, in: window).first(where: { $0.accessibilityIdentifier == shortLinkSwitchId }))
    }

    @MainActor
    private func saveShot(_ window: UIWindow, name: String) throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else { return }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let language = Locale.preferredLanguages.first ?? "unknown"
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name)-\(language).png"))
    }

    @MainActor
    func testShortLinkSwitchDefaultsOnIsLocalAndFollowsTheLinkPreviewSwitch() async throws {
        let window = try await present()
        // 开关名是 UILabel，分组说明是 UITextView
        let labels = views(of: UILabel.self, in: window).compactMap(\.text) + views(of: UITextView.self, in: window).compactMap(\.text)
        XCTAssertTrue(labels.contains(OWSLocalizedString("TELLOMI_SETTINGS_LINK_PREVIEWS_FOOTER", comment: "")), "\(labels)")
        XCTAssertTrue(labels.contains(OWSLocalizedString("TELLOMI_SETTINGS_EXPAND_SHORT_LINKS", comment: "")), "\(labels)")
        XCTAssertTrue(labels.contains(OWSLocalizedString("TELLOMI_SETTINGS_EXPAND_SHORT_LINKS_FOOTER", comment: "")), "\(labels)")
        // 上游的说明（键已从语言表里删掉，这里钉英文原文）
        XCTAssertFalse(labels.contains("Retrieve link previews directly from websites for messages you send."), "上游的说明换掉了")

        // 默认开
        let shortLinkSwitch = try shortLinkSwitch(in: window)
        XCTAssertTrue(shortLinkSwitch.isOn)
        XCTAssertTrue(shortLinkSwitch.isEnabled)
        try saveShot(window, name: "settings-chats-link-previews")

        // 关掉：只写本机的集合
        shortLinkSwitch.isOn = false
        shortLinkSwitch.sendActions(for: .valueChanged)
        XCTAssertFalse(read { TellomiLinkPreviewLocalSettings.isShortLinkExpansionEnabled(tx: $0) })
        XCTAssertTrue(read { DependenciesBridge.shared.linkPreviewSettingStore.areLinkPreviewsEnabled(tx: $0) })

        // 总开关关掉以后它变灰
        write { tx in
            DependenciesBridge.shared.linkPreviewSettingManager.setAreLinkPreviewsEnabled(false, shouldSendSyncMessage: false, tx: tx)
        }
        let windowWithPreviewsOff = try await present()
        XCTAssertFalse(try self.shortLinkSwitch(in: windowWithPreviewsOff).isEnabled)
        try saveShot(windowWithPreviewsOff, name: "settings-chats-link-previews-off")
    }
}
