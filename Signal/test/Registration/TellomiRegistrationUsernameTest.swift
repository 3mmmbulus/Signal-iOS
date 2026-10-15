//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreText
import LibSignalClient
import XCTest

import SignalUI
@testable import Signal
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1215 第二刀）：注册资料页上的「用户名（选填）」，与 Android `TellomiUsernameEntryTest` 同一组规则。
final class TellomiRegistrationUsernameTest: XCTestCase {

    /// 固定种子的随机数，候选可复现。
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            // SplitMix64
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: 本地规则

    func testValidNicknamesPass() {
        XCTAssertNil(TellomiRegistrationUsername.check("kaixin"))
        XCTAssertNil(TellomiRegistrationUsername.check("Kai_xin2026"))
        XCTAssertNil(TellomiRegistrationUsername.check("abc"))
        XCTAssertNil(TellomiRegistrationUsername.check(String(repeating: "a", count: 20)))
    }

    func testMustStartWithALetterIncludingNoLeadingUnderscore() {
        XCTAssertEqual(TellomiRegistrationUsername.check("_kaixin"), .mustStartWithLetter)
        XCTAssertEqual(TellomiRegistrationUsername.check("2kaixin"), .mustStartWithLetter)
        XCTAssertEqual(TellomiRegistrationUsername.check("张三"), .invalidCharacters)
    }

    /// 顺序照 libsignal（Android 直接用它）：先字符、再长度。
    func testCharactersAreCheckedBeforeLength() {
        XCTAssertEqual(TellomiRegistrationUsername.check("ab"), .tooShort)
        XCTAssertEqual(TellomiRegistrationUsername.check(String(repeating: "a", count: 21)), .tooLong)
        XCTAssertEqual(TellomiRegistrationUsername.check("kai-xin"), .invalidCharacters)
        XCTAssertEqual(TellomiRegistrationUsername.check("kai.xin"), .invalidCharacters)
        XCTAssertEqual(TellomiRegistrationUsername.check("a-"), .invalidCharacters)
        XCTAssertEqual(TellomiRegistrationUsername.check(""), .tooShort)
    }

    // MARK: 候选

    func testThreeDistinctValidCandidatesThatDifferFromTheNickname() {
        var random = SeededGenerator(state: 1)
        let candidates = TellomiRegistrationUsername.candidates(for: "Kaixin", using: &random)

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(Set(candidates).count, 3)
        for candidate in candidates {
            XCTAssertNil(TellomiRegistrationUsername.check(candidate), candidate)
            XCTAssertNotEqual(candidate.lowercased(), "kaixin")
            XCTAssertTrue(candidate.hasPrefix("kaixin"), candidate)
        }
    }

    /// taishi 审查包 4、中转包 8（Android 同一刀）：词库 PREFIX 以非字母数字为边界，`kefu_58`、`tellomi_support27` 都是要拦的形状；
    /// 候选只留原名里的字母和数字（中间的 `_` 也去掉），后面直接接两位或三位数字。
    func testCandidatesKeepOnlyLettersAndDigitsOfTheNicknameAndAppendDigits() throws {
        let pattern = try NSRegularExpression(pattern: "^[a-z][a-z0-9]*[0-9]{2,3}$")
        for nickname in ["kefu", "tellomi", "admin", "Kaixin", "admin_", "kefu__", "tellomi_support", "kefu_tellomi", "kai_xin"] {
            let base = nickname.lowercased().replacingOccurrences(of: "_", with: "")
            for seed in UInt64(0)..<200 {
                var random = SeededGenerator(state: seed)
                let candidates = TellomiRegistrationUsername.candidates(for: nickname, using: &random)
                XCTAssertEqual(candidates.count, 3, nickname)
                for candidate in candidates {
                    XCTAssertTrue(candidate.hasPrefix(base), candidate)
                    XCTAssertFalse(candidate.contains("_"), candidate)
                    XCTAssertNotNil(pattern.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)), candidate)
                }
            }
        }
    }

    /// 超长的原名：去掉 `_` 之后截到 17 位，候选不超 20 位（和 Android 同两组样例）。
    func testALongNicknameIsCutToSeventeenLettersOrDigits() throws {
        for (nickname, base) in [("xitongguanliyuan_ab", "xitongguanliyuana"), ("customer_service_x", "customerservicex")] {
            let pattern = try NSRegularExpression(pattern: "^" + base + "[0-9]{2,3}$")
            for seed in UInt64(0)..<200 {
                var random = SeededGenerator(state: seed)
                let candidates = TellomiRegistrationUsername.candidates(for: nickname, using: &random)
                XCTAssertEqual(candidates.count, 3, nickname)
                for candidate in candidates {
                    XCTAssertNotNil(pattern.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)), candidate)
                    XCTAssertLessThanOrEqual(candidate.count, 20, candidate)
                }
            }
        }
    }

    func testCandidatesStayWithinTwentyCharacters() {
        var random = SeededGenerator(state: 2)
        let candidates = TellomiRegistrationUsername.candidates(for: String(repeating: "a", count: 20), using: &random)

        XCTAssertEqual(candidates.count, 3)
        XCTAssertTrue(candidates.allSatisfy { $0.count <= 20 }, "\(candidates)")
    }

    func testNoCandidatesWhenNothingUsableIsLeftOfTheNickname() {
        var random = SeededGenerator(state: 3)
        XCTAssertEqual(TellomiRegistrationUsername.candidates(for: "张三", using: &random), [])
        XCTAssertEqual(TellomiRegistrationUsername.candidates(for: "_2kaixin", using: &random), [])
    }

    // MARK: 服务端结果

    func testReservationOutcomes() throws {
        let hashed = try Usernames.HashedUsername(forUsername: "kaixin.01")
        let parsed = try XCTUnwrap(Usernames.ParsedUsername(rawUsername: "kaixin.01"))

        XCTAssertEqual(TellomiRegistrationUsername.reservationOutcome(of: .success(.successful(username: parsed, hashedUsername: hashed))), .reserved(hashed))
        XCTAssertEqual(TellomiRegistrationUsername.reservationOutcome(of: .success(.rejected)), .notAvailable)
        XCTAssertEqual(TellomiRegistrationUsername.reservationOutcome(of: .success(.rateLimited)), .tooManyAttempts)
        XCTAssertEqual(TellomiRegistrationUsername.reservationOutcome(of: .failure(.networkError)), .failed)
        XCTAssertEqual(TellomiRegistrationUsername.reservationOutcome(of: .failure(.otherError)), .failed)
    }

    /// taishi 审查包 4：回收号码的新主人继承了 30 天改名冷却；Retry-After 以天计，按天说（与编辑页、Android、Desktop 同一个算法）。
    func testRenameCooldownIsShownInWholeDays() {
        XCTAssertEqual(TellomiRegistrationUsername.reservationOutcome(of: .success(.changeCooldown(retryAfter: 2_591_999))), .cooldown(days: 30))
        XCTAssertEqual(TellomiRegistrationUsername.reservationOutcome(of: .success(.changeCooldown(retryAfter: 86_401))), .cooldown(days: 2))
        XCTAssertEqual(TellomiRegistrationUsername.reservationOutcome(of: .success(.changeCooldown(retryAfter: 7_200))), .cooldown(days: 1))
    }

    func testConfirmationOutcomes() throws {
        let link = try XCTUnwrap(Usernames.UsernameLink(handle: UUID(), entropy: Data(repeating: 7, count: 32)))

        XCTAssertEqual(TellomiRegistrationUsername.confirmationOutcome(of: .success(.success(username: "kaixin.01", usernameLink: link))), .confirmed)
        XCTAssertEqual(TellomiRegistrationUsername.confirmationOutcome(of: .success(.rejected)), .rejected)
        XCTAssertEqual(TellomiRegistrationUsername.confirmationOutcome(of: .success(.rateLimited)), .failed)
        XCTAssertEqual(TellomiRegistrationUsername.confirmationOutcome(of: .failure(.networkError)), .failed)
    }

    // MARK: 重新注册（tellomi/tellomi#1266）

    private typealias AccountIdentity = RegistrationCoordinatorImpl.AccountIdentity

    private func accountIdentity(isReregistration: Bool? = nil) -> AccountIdentity {
        return AccountIdentity(
            aci: .randomForTesting(),
            pni: .randomForTesting(),
            e164: E164("+8613800000001")!,
            hasPreviouslyUsedSVR: false,
            authPassword: "password",
            isReregistration: isReregistration,
        )
    }

    /// 服务端注册回包（`AccountCreationResponse`：身份字段平铺，外加 `reregistration`）→ 协调器存下的身份。
    /// 没有这个键（旧服务端）解出来是 nil，照常显示用户名框。
    func testReregistrationFromTheCreateAccountResponseIsKept() throws {
        let aci = Aci.randomForTesting()
        let pni = Pni.randomForTesting()
        func identity(_ tail: String) throws -> AccountIdentity {
            let body = #"{"uuid":"\#(aci.rawUUID.uuidString)","pni":"\#(pni.rawUUID.uuidString)","number":"+8613800000001","usernameHash":null,"storageCapable":true\#(tail)}"#
            let response = RegistrationCoordinatorImpl.Service.handleCreateAccountResponse(
                authPassword: "password",
                statusCode: 200,
                retryAfterHeader: nil,
                bodyData: Data(body.utf8),
                logger: PrefixedLogger(prefix: "[Test]"),
            )
            guard case .success(let identity) = response else {
                return try XCTUnwrap(nil as AccountIdentity?, "注册回包没解出身份：\(body)")
            }
            XCTAssertEqual(identity.aci, aci)
            return identity
        }

        XCTAssertEqual(try identity(#","reregistration":true"#).isReregistration, true)
        XCTAssertEqual(try identity(#","reregistration":false"#).isReregistration, false)
        XCTAssertNil(try identity("").isReregistration)
    }

    /// 注册做到一半的状态存在库里；加字段之前的版本存下的没有这个键，升级后照样解得出来。
    func testRegistrationStateSavedBeforeTheFlagStillDecodes() throws {
        func fields(_ identity: AccountIdentity) throws -> [String: Any] {
            return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
        }

        // 加字段之前存下的样子：只有这五个键
        var saved = try fields(accountIdentity(isReregistration: true))
        saved["isReregistration"] = nil
        XCTAssertEqual(Set(saved.keys), ["aci", "pni", "e164", "hasPreviouslyUsedSVR", "authPassword"])
        let old = try JSONSerialization.data(withJSONObject: saved)
        XCTAssertNil(try JSONDecoder().decode(AccountIdentity.self, from: old).isReregistration)

        // 新版本存「不知道」也不写这个键，和旧的一样
        XCTAssertNil(try fields(accountIdentity(isReregistration: nil))["isReregistration"])

        let reregistered = try JSONEncoder().encode(accountIdentity(isReregistration: true))
        XCTAssertEqual(try JSONDecoder().decode(AccountIdentity.self, from: reregistered).isReregistration, true)
    }

    /// 只有服务端明说「这个号码之前有账号」才不显示用户名框；新号、旧状态（nil）照常显示。
    func testProfilePageHidesTheUsernameFieldOnlyWhenReregistering() {
        for (isReregistration, showsUsername) in [(true, false), (false, true), (nil, true)] as [(Bool?, Bool)] {
            let identity = accountIdentity(isReregistration: isReregistration)
            XCTAssertEqual(
                RegistrationCoordinatorImpl.profileState(accountIdentity: identity, phoneNumberDiscoverability: .nobody),
                RegistrationProfileState(e164: identity.e164, phoneNumberDiscoverability: .nobody, showsTellomiUsername: showsUsername),
                "isReregistration = \(String(describing: isReregistration))",
            )
        }
    }
}

/// Tellomi（tellomi/tellomi#1215 第二刀）：资料页本身——停顿后保留、只认最后一次输入、三种结果的说法、「下一步」先确认再保存。
/// 用假的 presenter，页面放进窗口里（确认时要弹转圈的遮罩）。页面画默认头像要读库，所以继承 `SignalBaseTest`。
final class TellomiRegistrationProfileUsernameTest: SignalBaseTest {

    @MainActor
    private final class FakePresenter: RegistrationProfilePresenter {
        var reservationOutcomes: [String: TellomiRegistrationUsername.ReservationOutcome] = [:]
        var confirmationOutcome: TellomiRegistrationUsername.ConfirmationOutcome = .confirmed
        /// 某个名字的保留请求故意慢多久（纳秒），用来造「结果回来时框里已经改了」
        var reservationDelays: [String: UInt64] = [:]
        private(set) var events: [String] = []

        func reserveTellomiUsername(nickname: String) async -> TellomiRegistrationUsername.ReservationOutcome {
            events.append("reserve:\(nickname)")
            if let delay = reservationDelays[nickname] {
                try? await Task.sleep(nanoseconds: delay)
            }
            return reservationOutcomes[nickname] ?? .notAvailable
        }

        func confirmTellomiUsername(_ reservedUsername: Usernames.HashedUsername) async -> TellomiRegistrationUsername.ConfirmationOutcome {
            events.append("confirm:\(reservedUsername.usernameString)")
            return confirmationOutcome
        }

        func goToNextStep(givenName: OWSUserProfile.NameComponent, familyName: OWSUserProfile.NameComponent?, avatarData: Data?, phoneNumberDiscoverability: PhoneNumberDiscoverability) {
            events.append("next:\(givenName.stringValue.rawValue)")
        }
    }

    @MainActor
    private struct Page {
        let presenter: FakePresenter
        let viewController: RegistrationProfileViewController
        let window: UIWindow

        var isNextEnabled: Bool {
            return viewController.navigationItem.rightBarButtonItem?.isEnabled == true
        }

        func textField(_ suffix: String) throws -> UITextField {
            func find(_ view: UIView) -> UITextField? {
                if let field = view as? UITextField, field.accessibilityIdentifier == "registration.profile.\(suffix)" {
                    return field
                }
                return view.subviews.lazy.compactMap(find).first
            }
            return try XCTUnwrap(find(viewController.view))
        }

        func subview(_ suffix: String) throws -> UIView {
            func find(_ view: UIView) -> UIView? {
                if view.accessibilityIdentifier == "registration.profile.\(suffix)" {
                    return view
                }
                return view.subviews.lazy.compactMap(find).first
            }
            return try XCTUnwrap(find(viewController.view))
        }

        /// 自己和上面每一层都没藏起来、也挂在窗口上（UIStackView 藏一行只设那一行自己的 isHidden）。
        func isVisible(_ view: UIView) -> Bool {
            return hiddenReason(view) == nil
        }

        /// 看不见的原因，断言失败时打出来
        func hiddenReason(_ view: UIView) -> String? {
            var current: UIView? = view
            while let each = current {
                if each.isHidden || each.alpha == 0 {
                    return "\(Swift.type(of: each)) \(each.accessibilityIdentifier ?? "") isHidden=\(each.isHidden) alpha=\(each.alpha)"
                }
                current = each.superview
            }
            return view.window == nil ? "不在窗口上" : nil
        }

        func type(_ text: String, into suffix: String) throws {
            let field = try textField(suffix)
            field.text = text
            field.sendActions(for: .editingChanged)
        }

        func close() {
            window.isHidden = true
        }
    }

    /// 默认头像上的字用 Inter 字体；App 启动时由 `SUIEnvironment.registerCustomFonts` 注册，单测进程里没有这一步，照同样的办法补上。
    private static let registerFonts: Void = {
        let bundle = Bundle(for: OWSNavigationController.self)
        for url in bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    @MainActor
    private func makePage(showsTellomiUsername: Bool = true) -> Page {
        _ = Self.registerFonts
        let presenter = FakePresenter()
        let viewController = RegistrationProfileViewController(
            state: RegistrationProfileState(
                e164: E164("+8613800000001")!,
                phoneNumberDiscoverability: .nobody,
                showsTellomiUsername: showsTellomiUsername,
            ),
            presenter: presenter,
        )
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = OWSNavigationController(rootViewController: viewController)
        window.makeKeyAndVisible()
        viewController.loadViewIfNeeded()
        // 让导航控制器现在就把页面挂进窗口，不用等下一轮 run loop（判「看得见」要靠它）
        window.layoutIfNeeded()
        return Page(presenter: presenter, viewController: viewController, window: window)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    func testAValidUsernameIsReservedAfterThePauseAndShowsTheLink() async throws {
        let page = makePage()
        defer { page.close() }
        let hashed = try Usernames.HashedUsername(forUsername: "kaixin.01")
        page.presenter.reservationOutcomes["kaixin"] = .reserved(hashed)

        try page.type("开心", into: "givenName")
        try page.type("kaixin", into: "username")

        XCTAssertEqual(page.viewController.tellomiUsernameStatus, .checking)
        XCTAssertFalse(page.isNextEnabled)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(page.presenter.events, [], "停顿 0.5 秒之前不发请求")

        await waitUntil { page.viewController.tellomiUsernameStatus != .checking }

        XCTAssertEqual(page.presenter.events, ["reserve:kaixin"])
        XCTAssertEqual(page.viewController.tellomiUsernameStatus, .reserved(hashed))
        XCTAssertEqual(page.viewController.tellomiUsernameStatusText, "Your link: tell.cc/kaixin")
        XCTAssertTrue(page.isNextEnabled)
    }

    /// ADR-0066 §6.1b：用户名框下面常驻灰色规则提示；粘贴带大写的名字当场转小写、光标在粘贴的字后面，
    /// 提示换成「已自动转成小写」，拿去保留的是小写。自动填充这类直接进框的大写也转。
    @MainActor
    func testTheUsernameFieldShowsTheRuleAndLowercasesUppercase() async throws {
        let page = makePage()
        defer { page.close() }
        let hintView = try XCTUnwrap(page.subview("usernameRuleHint") as? TellomiUsernameInput.RuleHintView)
        XCTAssertTrue(page.isVisible(hintView), page.hiddenReason(hintView) ?? "")
        XCTAssertEqual(hintView.displayedText, TellomiUsernameInput.ruleHint)

        try page.type("开心", into: "givenName")
        let field = try page.textField("username")
        field.becomeFirstResponder()
        XCTAssertFalse(page.viewController.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "KaiXin"))
        XCTAssertEqual(field.text, "kaixin")
        let selected = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selected.start), 6)
        XCTAssertEqual(hintView.displayedText, TellomiUsernameInput.autoLowercasedNotice)
        XCTAssertEqual(page.viewController.tellomiUsernameStatus, .checking)
        await waitUntil { page.viewController.tellomiUsernameStatus != .checking }
        XCTAssertEqual(page.presenter.events, ["reserve:kaixin"])

        // 不经过代理直接进框的大写（钥匙串自动填充）
        try page.type("KaiXin2", into: "username")
        XCTAssertEqual(field.text, "kaixin2")

        // 别的不合规字符照常进框、报红字，不删
        XCTAssertTrue(page.viewController.textField(field, shouldChangeCharactersIn: NSRange(location: 7, length: 0), replacementString: "-"))
        try page.type("kaixin2-", into: "username")
        XCTAssertEqual(field.text, "kaixin2-")
        XCTAssertEqual(page.viewController.tellomiUsernameStatus, .localError(.invalidCharacters))
    }

    @MainActor
    func testOnlyTheLastInputIsCheckedAndAtSignIsDropped() async throws {
        let page = makePage()
        defer { page.close() }
        page.presenter.reservationOutcomes["kaixin2"] = .notAvailable

        try page.type("开心", into: "givenName")
        try page.type("kaixin", into: "username")
        try page.type("@kaixin2", into: "username")

        XCTAssertEqual(try page.textField("username").text, "kaixin2")
        await waitUntil { page.viewController.tellomiUsernameStatus != .checking }

        XCTAssertEqual(page.presenter.events, ["reserve:kaixin2"])
        XCTAssertEqual(page.viewController.tellomiUsernameStatus, .notAvailable)
        XCTAssertEqual(page.viewController.tellomiUsernameCandidates.count, 3)
        XCTAssertFalse(page.isNextEnabled)
    }

    /// 只认最后一次：慢的请求回来时框里已经改了，它的结果丢掉，不能盖住后来那个名字的结果。
    @MainActor
    func testAStaleResultDoesNotOverwriteTheCurrentName() async throws {
        let page = makePage()
        defer { page.close() }
        let hashed = try Usernames.HashedUsername(forUsername: "kaixin2.01")
        page.presenter.reservationOutcomes["kaixin"] = .notAvailable
        page.presenter.reservationDelays["kaixin"] = 1_000_000_000
        page.presenter.reservationOutcomes["kaixin2"] = .reserved(hashed)

        try page.type("开心", into: "givenName")
        try page.type("kaixin", into: "username")
        await waitUntil { page.presenter.events == ["reserve:kaixin"] }

        try page.type("kaixin2", into: "username")
        await waitUntil { page.viewController.tellomiUsernameStatus != .checking }
        XCTAssertEqual(page.viewController.tellomiUsernameStatus, .reserved(hashed))

        // 等慢的那个回来
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(page.presenter.events, ["reserve:kaixin", "reserve:kaixin2"])
        XCTAssertEqual(page.viewController.tellomiUsernameStatus, .reserved(hashed))
        XCTAssertEqual(page.viewController.tellomiUsernameCandidates, [])
        XCTAssertTrue(page.isNextEnabled)
    }

    @MainActor
    func testFormatErrorsAreShownImmediatelyWithoutAsking() async throws {
        let page = makePage()
        defer { page.close() }

        try page.type("开心", into: "givenName")
        try page.type("_kaixin", into: "username")

        XCTAssertEqual(page.viewController.tellomiUsernameStatus, .localError(.mustStartWithLetter))
        XCTAssertEqual(page.viewController.tellomiUsernameStatusText, "Start with a letter")
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(page.presenter.events, [])
        XCTAssertFalse(page.isNextEnabled)

        // 清空就能不设用户名直接进入
        try page.type("", into: "username")
        XCTAssertTrue(page.isNextEnabled)
    }

    @MainActor
    func testCooldownAndRateLimitAreSaidSeparately() async throws {
        let page = makePage()
        defer { page.close() }
        page.presenter.reservationOutcomes["kaixin"] = .cooldown(days: 30)
        page.presenter.reservationOutcomes["nana"] = .tooManyAttempts

        try page.type("开心", into: "givenName")
        try page.type("kaixin", into: "username")
        await waitUntil { page.viewController.tellomiUsernameStatus != .checking }
        XCTAssertEqual(page.viewController.tellomiUsernameStatusText, "You can set a username in 30 days")
        XCTAssertEqual(page.viewController.tellomiUsernameCandidates, [])
        XCTAssertFalse(page.isNextEnabled)

        try page.type("nana", into: "username")
        await waitUntil { page.viewController.tellomiUsernameStatus != .checking }
        XCTAssertEqual(page.viewController.tellomiUsernameStatusText, "Too many attempts. Try again later.")
        XCTAssertFalse(page.isNextEnabled)
    }

    @MainActor
    func testEnteringConfirmsTheUsernameBeforeSavingTheProfile() async throws {
        let page = makePage()
        defer { page.close() }
        let hashed = try Usernames.HashedUsername(forUsername: "kaixin.01")
        page.presenter.reservationOutcomes["kaixin"] = .reserved(hashed)

        try page.type("开心", into: "givenName")
        try page.type("kaixin", into: "username")
        await waitUntil { page.viewController.tellomiUsernameStatus != .checking }

        _ = page.viewController.textFieldShouldReturn(try page.textField("username"))
        await waitUntil { page.presenter.events.contains("next:开心") }

        XCTAssertEqual(page.presenter.events, ["reserve:kaixin", "confirm:kaixin.01", "next:开心"])
        XCTAssertTrue(page.viewController.isTellomiUsernameConfirmed)
        XCTAssertFalse(try page.textField("username").isEnabled, "确认过后锁住：再确认就算改名")
    }

    @MainActor
    func testARejectedConfirmationReservesAgainAndDoesNotSaveTheProfile() async throws {
        let page = makePage()
        defer { page.close() }
        let hashed = try Usernames.HashedUsername(forUsername: "kaixin.01")
        page.presenter.reservationOutcomes["kaixin"] = .reserved(hashed)
        page.presenter.confirmationOutcome = .rejected

        try page.type("开心", into: "givenName")
        try page.type("kaixin", into: "username")
        await waitUntil { page.viewController.tellomiUsernameStatus != .checking }

        page.presenter.reservationOutcomes["kaixin"] = .notAvailable
        _ = page.viewController.textFieldShouldReturn(try page.textField("username"))
        await waitUntil { page.presenter.events.count >= 3 && page.viewController.tellomiUsernameStatus != .checking }

        XCTAssertEqual(page.presenter.events, ["reserve:kaixin", "confirm:kaixin.01", "reserve:kaixin"])
        XCTAssertEqual(page.viewController.tellomiUsernameStatus, .notAvailable)
        XCTAssertFalse(page.viewController.isTellomiUsernameConfirmed)
        XCTAssertFalse(page.isNextEnabled)
    }

    /// tellomi/tellomi#1266：重新注册时没有用户名框和说明行；名字填了就能下一步，名字框回车直接进下一步，不保留任何用户名。
    @MainActor
    func testReregistrationHasNoUsernameFieldAndReturnOnTheNameGoesOn() async throws {
        // 对照：新号的页面上这两样看得见（`isVisible` 本身不是永远说「看不见」）
        let newAccount = makePage()
        XCTAssertNil(newAccount.hiddenReason(try newAccount.textField("username")))
        XCTAssertNil(newAccount.hiddenReason(try newAccount.subview("usernameStatus")))
        XCTAssertEqual(try newAccount.textField("givenName").returnKeyType, .next)
        newAccount.close()

        let page = makePage(showsTellomiUsername: false)
        defer { page.close() }
        XCTAssertFalse(page.isVisible(try page.textField("username")))
        XCTAssertFalse(page.isVisible(try page.subview("usernameStatus")))
        XCTAssertEqual(try page.textField("givenName").returnKeyType, .done)

        try page.type("开心", into: "givenName")
        XCTAssertTrue(page.isNextEnabled)

        // 改一次「谁能通过手机号找到我」会重建页面状态，这之后也不能把用户名框的判断丢了
        page.viewController.setPhoneNumberDiscoverability(.nobody)
        XCTAssertFalse(page.viewController.state.showsTellomiUsername)

        _ = page.viewController.textFieldShouldReturn(try page.textField("givenName"))
        await waitUntil { !page.presenter.events.isEmpty }
        XCTAssertEqual(page.presenter.events, ["next:开心"])
    }
}
