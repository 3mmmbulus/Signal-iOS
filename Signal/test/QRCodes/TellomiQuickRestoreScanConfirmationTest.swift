//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

import SignalServiceKit
@testable import Signal
@testable import SignalUI

/// Tellomi：扫码页（设置 → 头像旁二维码 → 扫描）用相机扫到新手机上的「转移帐户」码，先弹防骗确认，不直接进转移页。
/// 应用内相机（`PhotoCaptureViewController`）用的是同一个确认框，那里要真相机，没有用例。
@MainActor
final class TellomiQuickRestoreScanConfirmationTest: SignalBaseTest {

    private final class NoopScanDelegate: UsernameLinkScanDelegate {
        func usernameLinkScanned(_ usernameLink: Usernames.UsernameLink) {}
        func plainUsernameScanned(_ username: String) {}
    }

    private let transferCode = "tellomi://rereg?uuid=asd&pub_key=BQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    private func texts(in view: UIView) -> [String] {
        let own: [String]
        switch view {
        case let label as UILabel: own = [label.text, label.attributedText?.string].compactMap { $0 }
        case let textView as UITextView: own = [textView.text, textView.attributedText?.string].compactMap { $0 }
        default: own = []
        }
        return own + view.subviews.flatMap { texts(in: $0) }
    }

    func testACameraScannedTransferCodeAsksBeforeOpeningTheTransferPage() throws {
        let delegate = NoopScanDelegate()
        let scanner = UsernameLinkScanQRCodeViewController(scanDelegate: delegate)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = scanner
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        XCTAssertEqual(scanner.handleTellomiScannedString(transferCode, source: .camera), .stopScanning)

        let sheet = try XCTUnwrap(scanner.presentedViewController as? ActionSheetController, "扫到转移码应当先弹确认，不是直接进转移页")
        sheet.loadViewIfNeeded()
        let shown = texts(in: sheet.view)
        XCTAssertTrue(shown.contains(TellomiQuickRestoreScanConfirmation.title), "\(shown)")
        XCTAssertTrue(shown.contains(TellomiQuickRestoreScanConfirmation.message), "\(shown)")
        XCTAssertEqual(sheet.actions.count, 2, "继续 / 取消")
    }

    /// 四种语言都点明「别人让你扫的就取消」，不能只剩一句「转移帐户」。
    func testTheWarningIsWrittenInEveryLanguage() throws {
        let expectations = [
            "en": ["transfers your account", "someone else asked you"],
            "zh_CN": ["转移帐户", "别人让你扫的"],
            "zh_HK": ["轉移帳戶", "別人叫你掃的"],
            "zh_TW": ["轉移帳號", "別人要你掃的"],
        ]
        for (language, phrases) in expectations {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language), language)
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], language)
            let title = try XCTUnwrap(table["QUICK_RESTORE_SCAN_CONFIRMATION_TITLE_TELLOMI"], language)
            let message = try XCTUnwrap(table["QUICK_RESTORE_SCAN_CONFIRMATION_MESSAGE_TELLOMI"], language)
            XCTAssertTrue((title + message).contains(phrases[0]), "\(language): \(title)")
            XCTAssertTrue(message.contains(phrases[1]), "\(language): \(message)")
        }
    }
}
