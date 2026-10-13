//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1216）：没有备份服务的部署里，注册的「恢复或转移」只列走得通的路——
/// 不出现「恢复 Tellomi 安全备份」，旧手机是 Android 时不教人去开备份，跳过时不说「以后将无法进行恢复」。
@MainActor
final class TellomiRestoreChoiceTest: SignalBaseTest {

    private final class Presenter: RegistrationChooseRestoreMethodPresenter {
        var chosen: [RegistrationRestoreMethod] = []
        var cancelCount = 0

        func didChooseRestoreMethod(method: RegistrationRestoreMethod) {
            chosen.append(method)
        }

        func didCancelRestoreMethodSelection() {
            cancelCount += 1
        }
    }

    private final class SplashPresenter: RegistrationSplashPresenter {
        func continueFromSplash() {}
        func setHasOldDevice(_ hasOldDevice: Bool) {}
        func switchToDeviceLinkingMode() {}
    }

    // MARK: - Strings (same keys as the view controllers use)

    private let backupsTitle = OWSLocalizedString("ONBOARDING_CHOOSE_RESTORE_METHOD_BACKUPS_TITLE", comment: "")
    private let transferTitle = OWSLocalizedString("ONBOARDING_CHOOSE_RESTORE_METHOD_TRANSFER_TITLE", comment: "")
    private let upstreamSkipTitle = OWSLocalizedString("ONBOARDING_CHOOSE_RESTORE_METHOD_SKIP_RESTORE_TITLE", comment: "")
    private let makeBackupTutorialStep = OWSLocalizedString("REGISTRATION_RESTORE_METHOD_MAKE_BACKUP_TUTORIAL_OPEN_SIGNAL", comment: "")
    private let noneAvailableBody = OWSLocalizedString("ONBOARDING_CHOOSE_RESTORE_METHOD_NONE_AVAILABLE_BODY", comment: "")
    private let registerDirectlyTitle = OWSLocalizedString("ONBOARDING_CHOOSE_RESTORE_METHOD_TELLOMI_REGISTER_DIRECTLY_TITLE", comment: "")
    private let fromAndroidTitle = OWSLocalizedString("ONBOARDING_CHOOSE_RESTORE_METHOD_TELLOMI_FROM_ANDROID_TITLE", comment: "")
    private let tellomiTitle = OWSLocalizedString("ONBOARDING_CHOOSE_RESTORE_METHOD_TELLOMI_TITLE", comment: "")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func requireNoBackupService() throws {
        // 单测默认连 Tellomi 的部署（TSConstants 一律 staging，除非设 USE_PRODUCTION=1）。
        try XCTSkipIf(TSConstants.backupServiceAvailable, "只在没有备份服务的部署上成立")
    }

    // MARK: - Helpers

    private func makeChooser(_ path: RegistrationStep.RestorePath, presenter: Presenter) -> UIViewController {
        let vc = RegistrationChooseRestoreMethodViewController(
            presenter: presenter,
            restorePath: path,
            securityScopedBookmarkAccess: SecurityScopedBookmarkAccessMock(hasAccess: true, url: nil),
        )
        vc.loadViewIfNeeded()
        return vc
    }

    /// Every piece of text the screen shows: labels, button titles, and the accessibility label/hint
    /// that `registrationChoiceButton` sets to its title/subtitle.
    private func texts(in view: UIView) -> [String] {
        var result: [String] = []
        if let label = view as? UILabel, let text = label.text {
            result.append(text)
        }
        if let button = view as? UIButton {
            [button.configuration?.title, button.accessibilityLabel, button.accessibilityHint]
                .compactMap { $0 }
                .forEach { result.append($0) }
        }
        for subview in view.subviews {
            result += texts(in: subview)
        }
        return result
    }

    private func button(titled title: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.configuration?.title == title || button.accessibilityLabel == title {
            return button
        }
        for subview in view.subviews {
            if let found = button(titled: title, in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Tests

    func testSplashShowsOneLineLinkInsteadOfRestoreButton() throws {
        try requireNoBackupService()
        let presenter = SplashPresenter()
        let vc = RegistrationSplashViewController(presenter: presenter)
        vc.loadViewIfNeeded()
        let shown = texts(in: vc.view)

        XCTAssertTrue(shown.contains(OWSLocalizedString("ONBOARDING_SPLASH_NEW_PHONE_LINK_TITLE", comment: "")), "\(shown)")
        // 上游的「Restore or Transfer Account」按钮（键已从语言表里删掉，这里钉英文原文）
        XCTAssertFalse(shown.contains("Restore or Transfer Account"), "\(shown)")
    }

    func testIPhonePathsOfferTransferAndRegisterDirectlyOnly() throws {
        try requireNoBackupService()
        let paths: [RegistrationStep.RestorePath] = [
            .quickRestore(nil, .ios),
            .quickRestore(.free, .ios),
            .quickRestore(.paid, .ios),
            .unspecified,
        ]
        for path in paths {
            let shown = texts(in: makeChooser(path, presenter: Presenter()).view)
            XCTAssertTrue(shown.contains(tellomiTitle), "\(path): \(shown)")
            XCTAssertTrue(shown.contains(transferTitle), "\(path): \(shown)")
            XCTAssertTrue(shown.contains(registerDirectlyTitle), "\(path): \(shown)")
            XCTAssertFalse(shown.contains(backupsTitle), "\(path): \(shown)")
            XCTAssertFalse(shown.contains(upstreamSkipTitle), "\(path): \(shown)")
        }
    }

    func testManualRestoreHasNoBackupOption() throws {
        try requireNoBackupService()
        let shown = texts(in: makeChooser(.manualRestore, presenter: Presenter()).view)
        XCTAssertTrue(shown.contains(registerDirectlyTitle), "\(shown)")
        XCTAssertFalse(shown.contains(backupsTitle), "\(shown)")
        XCTAssertFalse(shown.contains(transferTitle), "\(shown)")
    }

    func testAndroidOldPhoneExplainsInsteadOfBackupTutorial() throws {
        try requireNoBackupService()
        for tier: RegistrationStep.RestorePath.BackupTier? in [nil, .free, .paid] {
            let presenter = Presenter()
            let vc = makeChooser(.quickRestore(tier, .android), presenter: presenter)
            let shown = texts(in: vc.view)
            XCTAssertTrue(shown.contains(fromAndroidTitle), "\(String(describing: tier)): \(shown)")
            XCTAssertFalse(shown.contains(backupsTitle), "\(String(describing: tier)): \(shown)")
            XCTAssertFalse(shown.contains(makeBackupTutorialStep), "\(String(describing: tier)): \(shown)")
            XCTAssertFalse(shown.contains(noneAvailableBody), "\(String(describing: tier)): \(shown)")

            // 「直接注册」不再弹二次确认，直接选 declined；「返回」回到欢迎页。
            let register = try XCTUnwrap(button(titled: registerDirectlyTitle, in: vc.view))
            register.sendActions(for: .primaryActionTriggered)
            guard case .declined = presenter.chosen.last else {
                return XCTFail("expected .declined, got \(presenter.chosen)")
            }
            let back = try XCTUnwrap(button(titled: CommonStrings.backButton, in: vc.view))
            back.sendActions(for: .primaryActionTriggered)
            XCTAssertEqual(presenter.cancelCount, 1)
        }
    }
}
