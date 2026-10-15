//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
import SignalUI

/// Tellomi（ADR-0066 §6.1b，owner 2026-09-27）：用户名一律小写——显示、保留 / hash / 链接用小写；别的非法字符照旧报错、不删。
final class TellomiUsernameLowercaseTest: XCTestCase {

    // MARK: 显示

    func testDisplayIsAlwaysLowercase() {
        XCTAssertEqual(TellomiLinks.displayUsername("KaiXin.01"), "kaixin")
        XCTAssertEqual(TellomiLinks.displayUsername("KAIXIN"), "kaixin")
        // 别的后缀照旧完整显示，只是也转小写
        XCTAssertEqual(TellomiLinks.displayUsername("KaiXin.57"), "kaixin.57")
        // 别人名字的最后一档回落（@ 提及、会话标题、「新朋友」提示都走它）
        let config = DisplayName.Config(shouldUseSystemContactNicknames: false)
        XCTAssertEqual(DisplayName.username("KaiXin.01").resolvedValue(config: config), "kaixin")
    }

    // MARK: 保留 / hash / 链接

    /// 保留、确认、用户名链接里加密的用户名都取 `generateCandidates` 生成的那个：新设的一律小写。hash 本来就不分大小写（libsignal）。
    func testNewUsernamesAreReservedAndLinkedInLowercase() throws {
        let generated = try Usernames.HashedUsername.generateCandidates(
            forNickname: "KaiXin",
            minNicknameLength: 3,
            maxNicknameLength: 20,
            desiredDiscriminator: nil,
            enforcingLetterFirst: true,
        )
        let hash = try XCTUnwrap(generated.candidateHashes.first)
        XCTAssertEqual(generated.candidate(matchingHash: hash)?.usernameString, "kaixin.01")
        XCTAssertEqual(hash, try Usernames.HashedUsername(forUsername: "kaixin.01").hashString)
    }

    /// 大写之外的不合规字符：不转、不删，照旧报「非法字符」。
    func testOtherInvalidCharactersStillProduceAnError() {
        for nickname in ["Kai-Xin", "kai xin", "kai.xin", "开心", "kaixİn", "ｋａｉ"] {
            XCTAssertThrowsError(try Usernames.HashedUsername.generateCandidates(
                forNickname: nickname,
                minNicknameLength: 3,
                maxNicknameLength: 20,
                desiredDiscriminator: nil,
                enforcingLetterFirst: true,
            ), nickname) { error in
                XCTAssertEqual(error as? Usernames.HashedUsername.CandidateGenerationError, .nicknameContainsInvalidCharacters, nickname)
            }
            XCTAssertEqual(TellomiRegistrationUsername.check(nickname), .invalidCharacters, nickname)
        }
    }

    // MARK: 规则提示与「已自动转成小写」

    func testRuleHintAndAutoLowercasedNoticeInFourLocalizations() throws {
        let expected: [(localization: String, hint: String, notice: String)] = [
            ("en", "Lowercase letters, numbers and underscores only; starts with a letter; 3–20 characters.", "Changed to lowercase"),
            ("zh_CN", "只能用小写字母、数字和下划线，以字母开头，3–20 位。", "已自动转成小写"),
            ("zh_HK", "只能使用小寫字母、數字和底線，以字母開頭，3–20 個字元。", "已自動轉成小寫"),
            ("zh_TW", "只能使用小寫字母、數字和底線，以字母開頭，3–20 個字元。", "已自動轉成小寫"),
        ]
        for (localization, hint, notice) in expected {
            let path = try XCTUnwrap(Bundle.main.path(forResource: localization, ofType: "lproj"), localization)
            let bundle = try XCTUnwrap(Bundle(path: path), localization)
            XCTAssertEqual(bundle.localizedString(forKey: "USERNAME_SELECTION_RULE_HINT_TELLOMI", value: nil, table: nil), hint, localization)
            XCTAssertEqual(bundle.localizedString(forKey: "USERNAME_SELECTION_AUTO_LOWERCASED_TELLOMI", value: nil, table: nil), notice, localization)
        }
        // 页面上实际用的那句（测试按 en 跑）；键名写错时 OWSLocalizedString 原样返回键名
        XCTAssertEqual(TellomiUsernameInput.ruleHint, expected[0].hint)
        XCTAssertEqual(TellomiUsernameInput.autoLowercasedNotice, expected[0].notice)
    }

    @MainActor
    func testTheNoticeIsGreyAndTheRuleComesBack() {
        let hintView = TellomiUsernameInput.RuleHintView(font: .systemFont(ofSize: 13), noticeDuration: 0.2)
        XCTAssertEqual(hintView.displayedText, TellomiUsernameInput.ruleHint)
        let ruleColor = hintView.textColor

        hintView.showAutoLowercasedNotice()
        XCTAssertEqual(hintView.displayedText, TellomiUsernameInput.autoLowercasedNotice)
        XCTAssertEqual(hintView.accessibilityLabel, TellomiUsernameInput.autoLowercasedNotice)
        XCTAssertEqual(resolved(hintView.textColor), resolved(ruleColor), "「已自动转成小写」不是报错，和规则一样是灰色")
        XCTAssertEqual(resolved(hintView.textColor), resolved(.Signal.secondaryLabel))
        XCTAssertNotEqual(resolved(hintView.textColor), resolved(.Signal.red))

        // 连着又转了一次：从这次起重新计时
        let secondConversion = expectation(description: "second conversion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            hintView.showAutoLowercasedNotice()
            secondConversion.fulfill()
        }
        wait(for: [secondConversion], timeout: 2)

        let stillShowing = expectation(description: "still showing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            XCTAssertTrue(hintView.isShowingAutoLowercasedNotice)
            stillShowing.fulfill()
        }
        wait(for: [stillShowing], timeout: 2)

        let restored = expectation(description: "restored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertFalse(hintView.isShowingAutoLowercasedNotice)
            XCTAssertEqual(hintView.displayedText, TellomiUsernameInput.ruleHint)
            XCTAssertEqual(hintView.accessibilityLabel, TellomiUsernameInput.ruleHint)
            restored.fulfill()
        }
        wait(for: [restored], timeout: 2)
    }

    /// 动态颜色每次取都是新对象，按浅色 / 深色各解一次再比。
    private func resolved(_ color: UIColor) -> [UIColor] {
        return [UIUserInterfaceStyle.light, .dark].map { color.resolvedColor(with: UITraitCollection(userInterfaceStyle: $0)) }
    }

    // MARK: 大写 → 小写

    private func edit(_ text: String, _ location: Int, _ length: Int, _ replacement: String, max: Int? = 20) -> TellomiUsernameInput.Edit {
        return TellomiUsernameInput.edit(
            text: text,
            range: NSRange(location: location, length: length),
            replacement: replacement,
            maxUnicodeScalarCount: max,
        )
    }

    func testTypingAnUppercaseLetterLowercasesItWhereTheCursorIs() {
        // 「kai|xin」中间打一个 X：光标停在新打的字后面，不跳到末尾
        XCTAssertEqual(edit("kaixin", 3, 0, "X"), .lowercased(text: "kaixxin", cursorOffset: 4))
        XCTAssertEqual(edit("", 0, 0, "K"), .lowercased(text: "k", cursorOffset: 1))
    }

    func testPastingMixedCaseLowercasesAndPutsTheCursorAfterThePaste() {
        // 「ab[c]d」选中 c 粘贴 KaiXin
        XCTAssertEqual(edit("abcd", 2, 1, "KaiXin"), .lowercased(text: "abkaixind", cursorOffset: 8))
        XCTAssertEqual(edit("", 0, 0, "KaiXin_2026"), .lowercased(text: "kaixin_2026", cursorOffset: 11))
    }

    func testChangesWithoutUppercaseAreLeftToThePage() {
        XCTAssertEqual(edit("kai", 3, 0, "x"), .passThrough)
        XCTAssertEqual(edit("kaixin", 5, 1, ""), .passThrough, "删字")
        // 别的不合规字符不在这里处理：进框，由页面报红字
        for invalid in ["-", " ", ".", "中", "İ", "Ａ", "ẞ"] {
            XCTAssertEqual(edit("kai", 3, 0, invalid), .passThrough, invalid)
        }
    }

    /// 粘贴里夹着别的不合规字符：只把 A–Z 转小写，别的一个不删（`İ`、全角 `Ａ` 也不动，交给红字）。
    func testInvalidCharactersInAPasteAreKeptNotDeleted() {
        XCTAssertEqual(edit("", 0, 0, "Kai Xin-中"), .lowercased(text: "kai xin-中", cursorOffset: 9))
        XCTAssertEqual(edit("", 0, 0, "KİＡ"), .lowercased(text: "kİＡ", cursorOffset: 3))
    }

    /// 长度上限照上游：打字超长不收，粘贴收下放得下的前一段（按转小写之后算）。
    func testAPasteIsCutAtTheLengthLimitAfterLowercasing() {
        let eighteen = String(repeating: "a", count: 18)
        XCTAssertEqual(edit(eighteen, 18, 0, "BCDE"), .lowercased(text: eighteen + "bc", cursorOffset: 20))
        XCTAssertEqual(edit(eighteen + "aa", 20, 0, "B"), .rejected)
        // 没有上限（注册资料页）：全收
        XCTAssertEqual(edit(eighteen + "aa", 20, 0, "BCD", max: nil), .lowercased(text: eighteen + "aabcd", cursorOffset: 23))
    }

    @MainActor
    private func makeFieldInWindow(text: String) -> (UITextField, UIWindow) {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        window.addSubview(field)
        window.makeKeyAndVisible()
        field.text = text
        field.becomeFirstResponder()
        return (field, window)
    }

    @MainActor
    private func cursor(of field: UITextField) -> (start: Int, end: Int)? {
        return field.selectedTextRange.map {
            (field.offset(from: field.beginningOfDocument, to: $0.start), field.offset(from: field.beginningOfDocument, to: $0.end))
        }
    }

    /// 页面代理里调的那一步：框里换成小写、光标放在粘贴的字后面、照常发 `.editingChanged`（页面靠它去检查）、提示换成「已自动转成小写」。
    @MainActor
    func testTheFieldGetsTheLowercasedTextAndTheCursorStays() throws {
        let (field, window) = makeFieldInWindow(text: "kaixin")
        defer { window.isHidden = true }
        var editingChangedTexts: [String?] = []
        field.addAction(UIAction { _ in editingChangedTexts.append(field.text) }, for: .editingChanged)
        let hintView = TellomiUsernameInput.RuleHintView(font: .systemFont(ofSize: 13))

        let shouldChange = TellomiUsernameInput.handleChange(
            in: field,
            range: NSRange(location: 3, length: 0),
            replacement: "AB",
            maxUnicodeScalarCount: 20,
            hintView: hintView,
        )
        XCTAssertEqual(shouldChange, false)
        XCTAssertEqual(field.text, "kaiabxin")
        let position = try XCTUnwrap(cursor(of: field))
        XCTAssertEqual(position.start, 5)
        XCTAssertEqual(position.end, 5)
        XCTAssertEqual(editingChangedTexts, ["kaiabxin"])
        XCTAssertTrue(hintView.isShowingAutoLowercasedNotice)

        // 没有大写：交回页面，框和提示都不动
        let untouched = TellomiUsernameInput.RuleHintView(font: .systemFont(ofSize: 13))
        XCTAssertNil(TellomiUsernameInput.handleChange(in: field, range: NSRange(location: 8, length: 0), replacement: "-", maxUnicodeScalarCount: 20, hintView: untouched))
        XCTAssertEqual(field.text, "kaiabxin")
        XCTAssertFalse(untouched.isShowingAutoLowercasedNotice)
    }

    /// 兜底：自动填充这类不经过代理进框的大写，在 `.editingChanged` 里就地转小写，选区原样。
    @MainActor
    func testAutofilledUppercaseIsLowercasedInPlaceKeepingTheSelection() throws {
        let (field, window) = makeFieldInWindow(text: "KaiXin")
        defer { window.isHidden = true }
        let start = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 2))
        let end = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 4))
        field.selectedTextRange = field.textRange(from: start, to: end)
        let hintView = TellomiUsernameInput.RuleHintView(font: .systemFont(ofSize: 13))

        XCTAssertTrue(TellomiUsernameInput.lowercaseInPlace(field, hintView: hintView))
        XCTAssertEqual(field.text, "kaixin")
        let selection = try XCTUnwrap(cursor(of: field))
        XCTAssertEqual(selection.start, 2)
        XCTAssertEqual(selection.end, 4)
        XCTAssertTrue(hintView.isShowingAutoLowercasedNotice)

        // 已经是小写：什么都不做
        let untouched = TellomiUsernameInput.RuleHintView(font: .systemFont(ofSize: 13))
        XCTAssertFalse(TellomiUsernameInput.lowercaseInPlace(field, hintView: untouched))
        XCTAssertFalse(untouched.isShowingAutoLowercasedNotice)
    }

    // MARK: 选用户名页

    /// 老数据里带大写的用户名，打开编辑页时框里就是小写；只差大小写算「没改」，不会去改服务端。
    @MainActor
    func testSettingsFieldStartsWithTheLowercasedNickname() throws {
        let existing = try XCTUnwrap(Usernames.ParsedUsername(rawUsername: "KaiXin.01"))
        let field = UsernameSelectionViewController.UsernameTextField(forUsername: existing)
        XCTAssertEqual(field.text, "kaixin")

        XCTAssertTrue(UsernameSelectionViewController.tellomiIsUnchanged(existing: existing, nicknameFromTextField: "kaixin"))
        XCTAssertFalse(UsernameSelectionViewController.tellomiIsUnchanged(existing: existing, nicknameFromTextField: "kaixin2"))
        XCTAssertTrue(UsernameSelectionViewController.tellomiIsUnchanged(existing: nil, nicknameFromTextField: nil))
        XCTAssertFalse(UsernameSelectionViewController.tellomiIsUnchanged(existing: nil, nicknameFromTextField: "kaixin"))
    }
}

/// 选用户名页本身（设置 / 修改 / 拿回旧名）：规则提示常驻、打大写当场转小写、拿去保留的是小写、别的非法字符照旧报红字。
/// 用假的 `LocalUsernameManager` 记下保留请求，不连服务端。
final class TellomiUsernameSelectionLowercaseTest: SignalBaseTest {

    private final class FakeLocalUsernameManager: LocalUsernameManager {
        private(set) var reservedUsernames: [String] = []

        func usernameState(tx: DBReadTransaction) -> Usernames.LocalUsernameState { .unset }
        func setLocalUsername(username: String, usernameLink: Usernames.UsernameLink, tx: DBWriteTransaction) {}
        func setLocalUsernameWithCorruptedLink(username: String, tx: DBWriteTransaction) {}
        func setLocalUsernameCorrupted(tx: DBWriteTransaction) {}
        func clearLocalUsername(tx: DBWriteTransaction) {}
        func usernameLinkQRCodeColor(tx: DBReadTransaction) -> QRCodeColor { .blue }
        func setUsernameLinkQRCodeColor(color: QRCodeColor, tx: DBWriteTransaction) {}

        func reserveUsername(
            usernameCandidates: Usernames.HashedUsername.GeneratedCandidates,
            chatServiceAuth: ChatServiceAuth,
        ) async -> Usernames.RemoteMutationResult<Usernames.ReservationResult> {
            for hash in usernameCandidates.candidateHashes {
                if let candidate = usernameCandidates.candidate(matchingHash: hash) {
                    reservedUsernames.append(candidate.usernameString)
                }
            }
            return .success(.rejected)
        }

        func confirmUsername(
            reservedUsername: Usernames.HashedUsername,
            chatServiceAuth: ChatServiceAuth,
        ) async -> Usernames.RemoteMutationResult<Usernames.ConfirmationResult> { .failure(.otherError) }
        func deleteUsername() async -> Usernames.RemoteMutationResult<Void> { .failure(.otherError) }
        func rotateUsernameLink() async -> Usernames.RemoteMutationResult<Usernames.UsernameLink> { .failure(.otherError) }
        func updateVisibleCaseOfExistingUsername(newUsername: String) async -> Usernames.RemoteMutationResult<Void> { .failure(.otherError) }
    }

    @MainActor
    private func find<T: UIView>(_ type: T.Type, in view: UIView, where predicate: (T) -> Bool) -> T? {
        if let match = view as? T, predicate(match) {
            return match
        }
        for subview in view.subviews {
            if let match = find(type, in: subview, where: predicate) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    func testTheSettingsPageLowercasesUppercaseAndReservesTheLowercaseName() async throws {
        let usernameManager = FakeLocalUsernameManager()
        let viewController = UsernameSelectionViewController(
            existingUsername: Usernames.ParsedUsername(rawUsername: "KaiXin.01"),
            isAttemptingRecovery: false,
            context: .init(
                networkManager: SSKEnvironment.shared.networkManagerRef,
                databaseStorage: DependenciesBridge.shared.db,
                localUsernameManager: usernameManager,
                storageServiceManager: SSKEnvironment.shared.storageServiceManagerRef,
            ),
        )
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = OWSNavigationController(rootViewController: viewController)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()

        let field = try XCTUnwrap(find(UITextField.self, in: viewController.view) { $0.accessibilityIdentifier == "username_textfield" })
        let hintView = try XCTUnwrap(find(TellomiUsernameInput.RuleHintView.self, in: viewController.view) { _ in true })
        XCTAssertEqual(field.text, "kaixin", "老数据的大写只在显示时转")
        XCTAssertEqual(hintView.displayedText, TellomiUsernameInput.ruleHint)
        XCTAssertFalse(hintView.isHidden)
        XCTAssertEqual(viewController.navigationItem.rightBarButtonItem?.isEnabled, false, "只差大小写算没改")

        // 末尾粘贴「2Go」：转小写、光标在末尾、提示换成「已自动转成小写」、拿去保留的是小写
        field.becomeFirstResponder()
        XCTAssertFalse(viewController.textField(field, shouldChangeCharactersIn: NSRange(location: 6, length: 0), replacementString: "2Go"))
        XCTAssertEqual(field.text, "kaixin2go")
        let selected = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selected.start), 9)
        XCTAssertEqual(hintView.displayedText, TellomiUsernameInput.autoLowercasedNotice)
        await waitUntil { !usernameManager.reservedUsernames.isEmpty }
        XCTAssertEqual(usernameManager.reservedUsernames, ["kaixin2go.01"])

        // 别的不合规字符照常进框、不删，报红字
        XCTAssertTrue(viewController.textField(field, shouldChangeCharactersIn: NSRange(location: 9, length: 0), replacementString: "-"))
        field.text = "kaixin2go-"
        field.sendActions(for: .editingChanged)
        let invalidCharactersMessage = "Usernames may only contain a-z, 0-9, and _"
        await waitUntil { self.find(UITextView.self, in: viewController.view) { $0.text == invalidCharactersMessage } != nil }
        let errorView = try XCTUnwrap(find(UITextView.self, in: viewController.view) { $0.text == invalidCharactersMessage })
        let red = UIColor.Signal.red
        XCTAssertEqual(errorView.textColor?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)), red.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        XCTAssertEqual(field.text, "kaixin2go-")
        XCTAssertEqual(usernameManager.reservedUsernames, ["kaixin2go.01"], "非法字符不去保留")
    }
}
