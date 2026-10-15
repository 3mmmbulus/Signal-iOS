//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1214）：验证码页——系统自动填充 / 粘贴一次进来一整串要能整串填满；「收不到验证码？」面板说清出路。
@MainActor
final class TellomiVerificationCodeTest: SignalBaseTest {

    private final class Delegate: RegistrationVerificationCodeViewDelegate {
        var changeCount = 0
        func codeViewDidChange() {
            changeCount += 1
        }
    }

    // MARK: - Finding a code in pasted text

    func testCodeCandidateInPastedText() {
        func candidate(_ text: String) -> String? {
            RegistrationVerificationCodeView.codeCandidate(in: text, digitCount: 6)
        }
        XCTAssertEqual(candidate("123456"), "123456")
        XCTAssertEqual(candidate("123-456"), "123456")
        XCTAssertEqual(candidate("123 456"), "123456")
        XCTAssertEqual(candidate("【Tellomi】您的验证码是 482913，5 分钟内有效，请勿泄露。"), "482913")
        XCTAssertEqual(candidate("Your Tellomi code: 482-913"), "482913")
        // 手机号那样的长串、7 位数字都不是验证码。
        XCTAssertNil(candidate("+86 138 0013 8000"))
        XCTAssertNil(candidate("13800138000"))
        XCTAssertNil(candidate("1234567"))
        XCTAssertNil(candidate("12345"))
        XCTAssertNil(candidate("没有数字"))
    }

    // MARK: - The code view

    private func makeCodeView() -> (RegistrationVerificationCodeView, Delegate) {
        let view = RegistrationVerificationCodeView()
        let delegate = Delegate()
        view.delegate = delegate
        return (view, delegate)
    }

    /// Feeds `text` the way the system does for autofill and paste: one `shouldChangeCharactersIn` call with the whole string.
    private func insert(_ text: String, into view: RegistrationVerificationCodeView) {
        _ = view.textField(UITextField(), shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: text)
    }

    func testAutofillOfTheWholeCodeFillsEveryDigit() {
        let (view, delegate) = makeCodeView()
        insert("482913", into: view)
        XCTAssertEqual(view.verificationCode, "482913")
        XCTAssertTrue(view.isComplete)
        XCTAssertEqual(delegate.changeCount, 1)
    }

    func testPastingTheWholeSMSExtractsTheCode() {
        let (view, _) = makeCodeView()
        insert("【Tellomi】您的验证码是 482913，5 分钟内有效。", into: view)
        XCTAssertEqual(view.verificationCode, "482913")
    }

    func testPastingAFewDigitsContinuesFromTheCurrentDigit() {
        let (view, _) = makeCodeView()
        insert("4", into: view)
        insert("82", into: view)
        XCTAssertEqual(view.verificationCode, "482")
        XCTAssertFalse(view.isComplete)
    }

    func testTypingOneDigitAtATimeStillWorks() {
        let (view, _) = makeCodeView()
        for digit in "482913" {
            insert(String(digit), into: view)
        }
        XCTAssertEqual(view.verificationCode, "482913")
    }

    func testPastingANumberLongerThanTheCodeIsNotTakenAsACode() {
        // taishi 审查 b6：粘进一个手机号，不能取前 6 位自动提交、白白用掉一次机会。
        var rejectedFeedbacks = 0
        let original = RegistrationVerificationCodeView.tellomiRejectedPasteFeedback
        RegistrationVerificationCodeView.tellomiRejectedPasteFeedback = { rejectedFeedbacks += 1 }
        defer { RegistrationVerificationCodeView.tellomiRejectedPasteFeedback = original }

        let (view, delegate) = makeCodeView()
        insert("13800138000", into: view)
        XCTAssertEqual(view.verificationCode, "")
        XCTAssertFalse(view.isComplete)
        XCTAssertEqual(delegate.changeCount, 0)
        // taishi 审查 b6 包 4 不阻塞 3：整串不收时给一次触感，粘错的人知道没粘进去
        XCTAssertEqual(rejectedFeedbacks, 1)

        // 剩下的格子放得下的一小段照常接着填，不震。
        insert("4", into: view)
        insert("82913", into: view)
        XCTAssertEqual(view.verificationCode, "482913")
        XCTAssertEqual(rejectedFeedbacks, 1)
    }

    // MARK: - "Didn't get the code?" sheet

    private func texts(in view: UIView) -> [String] {
        var result: [String] = []
        if let label = view as? UILabel, let text = label.text {
            result.append(text)
        }
        if let button = view as? UIButton, let title = button.configuration?.title {
            result.append(title)
        }
        for subview in view.subviews {
            result += texts(in: subview)
        }
        return result
    }

    private func firstView<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let found = firstView(of: type, in: subview) {
                return found
            }
        }
        return nil
    }

    private func button(withIdentifier identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier {
            return button
        }
        for subview in view.subviews {
            if let found = button(withIdentifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    func testTellomiHelpSheetOffersWaysOut() throws {
        var changedNumber = 0
        var contactedSupport = 0
        let sheet = RegistrationVerificationHelpSheetViewController(tellomiHelp: .init(
            phoneNumber: "+86 138 0013 8000",
            onChangeNumber: { changedNumber += 1 },
            onContactSupport: { contactedSupport += 1 },
        ))
        sheet.loadViewIfNeeded()
        let shown = texts(in: sheet.view)
        let joined = shown.joined(separator: "\n")

        XCTAssertTrue(shown.contains(RegistrationVerificationHelpSheetViewController.tellomiTitle), joined)
        XCTAssertTrue(joined.contains("+86 138 0013 8000"), joined)
        XCTAssertTrue(joined.contains("support@tellomi.app"), joined)
        if let quota = TSConstants.smsVerificationCodesPerSession {
            XCTAssertTrue(joined.contains(String(quota)), joined)
        }
        // 上游那三条通用提示不再出现。
        XCTAssertFalse(shown.contains(OWSLocalizedString("ONBOARDING_VERIFICATION_HELP_BULLET_2", comment: "")), joined)

        try XCTUnwrap(button(withIdentifier: "registration.verification.help.changeNumber", in: sheet.view))
            .sendActions(for: .primaryActionTriggered)
        try XCTUnwrap(button(withIdentifier: "registration.verification.help.contactSupport", in: sheet.view))
            .sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(changedNumber, 1)
        XCTAssertEqual(contactedSupport, 1)
    }

    func testHelpSheetHasNoChangeNumberWhenTheNumberIsFixed() throws {
        // 重新注册 / 换号流程里 canChangeE164 == false，页面上的「错误的号码？」是隐藏的，面板也不能给改号码的出口。
        let sheet = RegistrationVerificationHelpSheetViewController(tellomiHelp: .init(
            phoneNumber: "+86 138 0013 8000",
            onChangeNumber: nil,
            onContactSupport: {},
        ))
        sheet.loadViewIfNeeded()
        XCTAssertNil(button(withIdentifier: "registration.verification.help.changeNumber", in: sheet.view))
        XCTAssertNotNil(button(withIdentifier: "registration.verification.help.contactSupport", in: sheet.view))
    }

    // MARK: - The verification screen

    private final class Presenter: RegistrationVerificationPresenter {
        var submittedCodes: [String] = []
        func returnToPhoneNumberEntry() {}
        func requestSMSCode() {}
        func requestVoiceCode() {}
        func submitVerificationCode(_ code: String) { submittedCodes.append(code) }
        func exitRegistration() {}
    }

    func testDidntGetTheCodeIsThereBeforeAnyCodeIsSubmitted() throws {
        // taishi 审查 b6：收不到短信的人没有码可交，入口不能等提交过 3 次才出现（ADR-0051 §二）。
        let presenter = Presenter()
        let viewController = RegistrationVerificationViewController(
            state: RegistrationVerificationState(
                e164: E164("+8613800138000")!,
                nextSMSDate: Date().addingTimeInterval(30),
                nextCallDate: nil,
                nextVerificationAttemptDate: nil,
                canChangeE164: true,
                showHelpText: false,
                validationError: nil,
                exitConfiguration: .noExitAllowed,
            ),
            presenter: presenter,
        )
        viewController.loadViewIfNeeded()

        let helpButton = try XCTUnwrap(button(withIdentifier: "registration.verification.helpButton", in: viewController.view))
        XCTAssertFalse(helpButton.isHidden)
    }

    func testHongKongDeploymentAllowsThreeCodesPerSession() {
        // deploy/hk/enable-aliyun-sms.sh：send-sms-verification-code.delays: [30s, 1m, 5m]
        XCTAssertEqual(TSConstants.smsVerificationCodesPerSession, 3)
    }

    func testTheRejectedCodeIsNotSubmittedAgainWhileItIsStillShown() throws {
        // 错码后格子红着停 0.85 秒、输入框还拿着焦点。这时按一个数字键，上游的单字符路径只收文本框里原来那一位，
        // 最后一格不变，凑满的还是刚被判错的那串——不能原样再交一次（白用一次提交机会，还可能撞上次数用尽）。
        let presenter = Presenter()
        let viewController = RegistrationVerificationViewController(state: verificationState(validationError: nil), presenter: presenter)
        viewController.loadViewIfNeeded()
        let codeView = try XCTUnwrap(firstSubview(RegistrationVerificationCodeView.self, in: viewController.view))

        insert("123456", into: codeView)
        XCTAssertEqual(presenter.submittedCodes, ["123456"])

        viewController.updateState(verificationState(validationError: .invalidVerificationCode(invalidCode: "123456")))
        let lastDigitField = UITextField()
        lastDigitField.text = "6"
        _ = codeView.textField(lastDigitField, shouldChangeCharactersIn: NSRange(location: 1, length: 0), replacementString: "7")

        XCTAssertEqual(codeView.verificationCode, "123456")
        XCTAssertEqual(presenter.submittedCodes, ["123456"], "刚被判错的那串不该原样再交一次")
    }

    private func verificationState(validationError: RegistrationVerificationValidationError?) -> RegistrationVerificationState {
        RegistrationVerificationState(
            e164: E164("+8613800138000")!,
            nextSMSDate: Date().addingTimeInterval(30),
            nextCallDate: nil,
            nextVerificationAttemptDate: nil,
            canChangeE164: true,
            showHelpText: false,
            validationError: validationError,
            exitConfiguration: .noExitAllowed,
        )
    }

    private func firstSubview<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let found = firstSubview(type, in: subview) {
                return found
            }
        }
        return nil
    }

    /// taishi 审查 b8 不阻塞 4：ADR-0051 §二 F（`docs/adr/0051-sign-in-ux-redesign.md:108`）——
    /// 「收不到验证码？」在左、「重新发送」在右，同一行，都在验证码格子下面。
    func testDidntGetTheCodeSitsOnTheLeftOfResendInOneRow() throws {
        let viewController = RegistrationVerificationViewController(
            state: RegistrationVerificationState(
                e164: E164("+8613800138000")!,
                nextSMSDate: Date().addingTimeInterval(30),
                nextCallDate: nil,
                nextVerificationAttemptDate: nil,
                canChangeE164: true,
                showHelpText: false,
                validationError: nil,
                exitConfiguration: .noExitAllowed,
            ),
            presenter: Presenter(),
        )
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        defer {
            // Tellomi：用完把页面从窗口上摘干净，让它随用例释放（deinit 里停掉每秒一跳的 nowTimer）。只把窗口藏起来的话，
            // 页面拿着键盘焦点留在内存里，定时器会在后面的用例之间（测试环境已拆）触发、碰到 SSKEnvironment 就崩。
            viewController.view.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()

        let help = try XCTUnwrap(button(withIdentifier: "registration.verification.helpButton", in: viewController.view))
        let resend = try XCTUnwrap(button(withIdentifier: "registration.verification.resendSMSCodeButton", in: viewController.view))
        let code = try XCTUnwrap(firstView(of: RegistrationVerificationCodeView.self, in: viewController.view))
        let helpFrame = help.convert(help.bounds, to: window)
        let resendFrame = resend.convert(resend.bounds, to: window)
        let codeFrame = code.convert(code.bounds, to: window)

        XCTAssertFalse(help.isHidden)
        XCTAssertLessThanOrEqual(helpFrame.maxX, resendFrame.minX, "help \(helpFrame) should be left of resend \(resendFrame)")
        XCTAssertEqual(helpFrame.midY, resendFrame.midY, accuracy: 1, "help \(helpFrame) and resend \(resendFrame) should share a row")
        XCTAssertGreaterThanOrEqual(helpFrame.minY, codeFrame.maxY, "the row should be below the code \(codeFrame)")
        XCTAssertEqual(help.contentHorizontalAlignment, .leading)
        XCTAssertEqual(resend.contentHorizontalAlignment, .trailing)
    }
}
