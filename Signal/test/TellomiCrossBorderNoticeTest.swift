//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1338）：跨境告知定稿（需求 `privacy-compliance-hk-cross-border.md` 第六节）。
/// - ① 告知版本改成独立的 `cb-1`：同意过草稿版 `0.1.0-draft` 的设备要再同意一次；协议与隐私政策版本常量改成 `2.0.0`。
/// - 法务项 c：已注册设备升级后的盖页，最上面是「《隐私政策》已更新至 2.0.0 版。」和链接；新用户注册的不加。
/// - ④ 关联设备只出只读版：一个「知道了」，点了和同意一样在本机记下 `cb-1`、放开网络；
///   但它不是这台设备的单独同意，这台设备要是改走主设备注册，发号码之前仍要完整同意。
/// - 6.6（owner 2026-09-27 下午）：整页改成两行小弹窗，9 项全文放到弹窗里「查看《个人信息出境告知》」打开的全文页。
@MainActor
final class TellomiCrossBorderNoticeTest: SignalBaseTest {

    /// `TellomiCrossBorderConsent` 记在 `appUserDefaults()` 里的键（`AppExpiry.swift` 末尾）。
    private let versionKey = "TellomiCrossBorderConsent.version"
    private let dateKey = "TellomiCrossBorderConsent.date"
    private let linkedOnlyKey = "TellomiCrossBorderConsent.linkedDeviceAcknowledgementOnly"
    /// `TellomiLegalConsent` 记在 `UserDefaults.standard` 里的键（`RegistrationPhoneNumberViewController.swift`）。
    private let termsKey = "TellomiLegalConsent.termsAndPrivacy.version"
    private let termsDateKey = "TellomiLegalConsent.termsAndPrivacy.date"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        forgetConsent()
    }

    override func tearDown() {
        forgetConsent()
        super.tearDown()
    }

    // MARK: - Helpers

    private func forgetConsent() {
        let defaults = CurrentAppContext().appUserDefaults()
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: dateKey)
        defaults.removeObject(forKey: linkedOnlyKey)
        UserDefaults.standard.removeObject(forKey: termsKey)
        UserDefaults.standard.removeObject(forKey: termsDateKey)
    }

    private func localized(_ key: String) -> String {
        OWSLocalizedString(key, comment: "")
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func label(_ text: String, in view: UIView) -> UILabel? {
        allSubviews(of: view).lazy.compactMap { $0 as? UILabel }.first { $0.text == text }
    }

    private func button(identifier: String, in view: UIView) -> UIButton? {
        allSubviews(of: view).lazy.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == identifier }
    }

    /// 按 iPhone 17 Pro 的尺寸排一次版，取某个子视图在整页里的纵坐标。
    private func layOut(_ notice: UIViewController) {
        notice.loadViewIfNeeded()
        notice.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        notice.view.setNeedsLayout()
        notice.view.layoutIfNeeded()
    }

    private func minY(of subview: UIView, in notice: UIViewController) -> CGFloat {
        subview.convert(subview.bounds, to: notice.view).minY
    }

    // MARK: - ① 版本

    func testNoticeVersionIsCb1SoDevicesThatAgreedToTheDraftAreAskedAgain() {
        XCTAssertEqual(TellomiCrossBorderConsent.noticeVersion, "cb-1", "告知版本按第六节 ① 改成独立的 cb-1")

        // 升级前同意过草稿版的设备。
        CurrentAppContext().appUserDefaults().set("0.1.0-draft", forKey: versionKey)
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed, "同意过 0.1.0-draft 的设备要重新出这一页")

        TellomiCrossBorderConsent.recordAgreement()
        XCTAssertEqual(CurrentAppContext().appUserDefaults().string(forKey: versionKey), "cb-1")
        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed)
    }

    func testLegalDocumentsVersionIs2_0_0SoTermsAgreedAt1_0_0AreAskedAgain() {
        XCTAssertEqual(TellomiLegalConsent.documentsVersion, "2.0.0", "协议与隐私政策的版本常量按第六节 ① 改成 2.0.0")

        UserDefaults.standard.set("1.0.0", forKey: termsKey)
        XCTAssertFalse(TellomiLegalConsent.hasAgreedToTerms, "勾过 1.0.0 的，号码页的勾选框要重新变成未勾")
    }

    func testLegalLinksUseTheCanonicalWwwAddresses() {
        // 需求第六节 6.3：PRIVACY_LINK / POLICY_UPDATED_LINK / THIRD_PARTY_LINK 打开 www 下的地址，和 Android、关于页一致。
        XCTAssertEqual(TellomiLegalConsent.privacyURL.absoluteString, "https://www.tellomi.app/legal/privacy/")
        XCTAssertEqual(TellomiLegalConsent.termsURL.absoluteString, "https://www.tellomi.app/legal/terms/")
        XCTAssertEqual(TellomiLegalConsent.thirdPartyURL.absoluteString, "https://www.tellomi.app/legal/third-party/")
    }

    // MARK: - ④ 关联设备只读版

    func testLinkedDeviceAcknowledgementRecordsCb1AndLiftsTheGates() async {
        let changed = expectation(forNotification: TellomiCrossBorderConsent.didChangeNotification, object: nil)

        TellomiCrossBorderConsent.recordLinkedDeviceAcknowledgement()

        XCTAssertEqual(
            CurrentAppContext().appUserDefaults().string(forKey: versionKey),
            "cb-1",
            "「知道了」和同意一样在本机记下 cb-1",
        )
        XCTAssertNotNil(CurrentAppContext().appUserDefaults().object(forKey: dateKey), "也记下时间")
        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed, "记下之后网络闸放开")
        await fulfillment(of: [changed], timeout: 5)

        XCTAssertFalse(
            TellomiCrossBorderConsent.hasGivenSeparateConsent,
            "只读版写的是「同意在手机上取得」：这台设备改走主设备注册时，发号码之前仍要完整同意",
        )
        TellomiCrossBorderConsent.recordAgreement()
        XCTAssertTrue(TellomiCrossBorderConsent.hasGivenSeparateConsent, "之后在这台设备上点了「同意并继续」，就是单独同意")
    }

    func testAgreeingIsSeparateConsent() {
        TellomiCrossBorderConsent.recordAgreement()
        XCTAssertTrue(TellomiCrossBorderConsent.hasGivenSeparateConsent)
    }

    // MARK: - 6.6 弹窗：新用户注册 / 恢复 / 转移（完整同意）

    /// 把弹窗真的弹在一个窗口上：点「不同意」「返回」、点外面，要看弹窗在不在、上面有没有盖全文页。
    private func presentInWindow(_ dialog: UIViewController) -> (UIWindow, UIViewController) {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.present(dialog, animated: false)
        window.layoutIfNeeded()
        return (window, root)
    }

    /// 等转场动画结束（dismiss 用的是 animated: true）。
    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// 需求 2.3 的 9 项正文；弹窗里一项都不许有（6.6 判据 1），全文页里要全有。
    private let itemBodyKeys = [
        "TELLOMI_CROSS_BORDER_ITEM_WHERE_BODY",
        "TELLOMI_CROSS_BORDER_ITEM_RECIPIENTS_BODY",
        "TELLOMI_CROSS_BORDER_ITEM_CONTACT_BODY",
        "TELLOMI_CROSS_BORDER_ITEM_PURPOSE_BODY",
        "TELLOMI_CROSS_BORDER_ITEM_METHOD_BODY",
        "TELLOMI_CROSS_BORDER_ITEM_KINDS_BODY",
        "TELLOMI_CROSS_BORDER_ITEM_RIGHTS_BODY",
        "TELLOMI_CROSS_BORDER_ITEM_PROCEDURE_BODY",
    ]

    func testNewUserDialogIsShortWithFullNoticeLinkAndTwoButtons() throws {
        let dialog = TellomiCrossBorderNoticeViewController(onAgree: {})
        layOut(dialog)
        let view: UIView = dialog.view

        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_DIALOG_TITLE"), in: view), "标题「个人信息出境」")
        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_DIALOG_BODY"), in: view), "两行正文")
        let link = try XCTUnwrap(button(identifier: "tellomi.crossBorder.fullNoticeLink", in: view), "「查看《个人信息出境告知》」")
        XCTAssertEqual(link.configuration?.title, localized("TELLOMI_CROSS_BORDER_DIALOG_FULL_NOTICE_LINK"))
        for key in itemBodyKeys + ["TELLOMI_CROSS_BORDER_ITEM_CONSENT_BODY"] {
            XCTAssertNil(label(localized(key), in: view), "弹窗里不放 9 项全文（\(key)）")
        }
        XCTAssertNil(label(localized("TELLOMI_CROSS_BORDER_DIALOG_POLICY_UPDATED"), in: view), "新用户不出「已更新至 2.0.0」")
        XCTAssertNil(button(identifier: "tellomi.crossBorder.policyUpdatedLink", in: view))
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.disagree", in: view))
        XCTAssertNil(button(identifier: "tellomi.crossBorder.linkedAck", in: view))

        let agree = try XCTUnwrap(button(identifier: "tellomi.crossBorder.agree", in: view))
        agree.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(TellomiCrossBorderConsent.hasGivenSeparateConsent)
    }

    func testDisagreeShowsHintUnderTheBodyAndKeepsTheDialogOpen() throws {
        var agreed = 0
        let dialog = TellomiCrossBorderNoticeViewController(onAgree: { agreed += 1 })
        let (window, root) = presentInWindow(dialog)
        defer { window.isHidden = true }

        let disagree = try XCTUnwrap(button(identifier: "tellomi.crossBorder.disagree", in: dialog.view))
        disagree.sendActions(for: .primaryActionTriggered)
        dialog.view.layoutIfNeeded()

        let hint = try XCTUnwrap(label(localized("TELLOMI_CROSS_BORDER_DISAGREE_HINT"), in: dialog.view))
        XCTAssertFalse(hint.isHidden, "点「不同意」后出说明")
        let body = try XCTUnwrap(label(localized("TELLOMI_CROSS_BORDER_DIALOG_BODY"), in: dialog.view))
        XCTAssertLessThan(minY(of: body, in: dialog), minY(of: hint, in: dialog), "说明在正文下面")
        XCTAssertTrue(root.presentedViewController === dialog, "「不同意」不关弹窗")
        XCTAssertEqual(agreed, 0)
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed)
    }

    func testNewUserDialogCanBeClosedWithoutAgreeing() {
        var agreed = 0
        let dialog = TellomiCrossBorderNoticeViewController(onAgree: { agreed += 1 })
        let (window, root) = presentInWindow(dialog)
        defer { window.isHidden = true }

        dialog.didTapOutsideDialog()
        waitUntil(root.presentedViewController == nil)

        XCTAssertNil(root.presentedViewController, "点弹窗外面 = 关掉，回到号码页")
        XCTAssertEqual(agreed, 0, "关掉不是同意，什么都不发")
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed)
    }

    func testFullNoticeOpensOverTheDialogFromLocalStringsAndBackReturnsToIt() throws {
        let dialog = TellomiCrossBorderNoticeViewController(onAgree: {})
        let (window, root) = presentInWindow(dialog)
        defer { window.isHidden = true }

        let link = try XCTUnwrap(button(identifier: "tellomi.crossBorder.fullNoticeLink", in: dialog.view))
        link.sendActions(for: .primaryActionTriggered)
        waitUntil(dialog.presentedViewController is TellomiCrossBorderFullNoticeViewController)
        let fullNotice = try XCTUnwrap(dialog.presentedViewController as? TellomiCrossBorderFullNoticeViewController, "全文盖在弹窗上面")
        layOut(fullNotice)
        let view: UIView = fullNotice.view

        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_FULL_NOTICE_TITLE"), in: view), "全文标题「个人信息出境告知」")
        for key in itemBodyKeys + ["TELLOMI_CROSS_BORDER_ITEM_CONSENT_BODY"] {
            XCTAssertNotNil(label(localized(key), in: view), "全文有 9 项（\(key)）")
        }
        XCTAssertNil(label(localized("TELLOMI_CROSS_BORDER_LINKED_ITEM_CONSENT_BODY"), in: view))
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.privacyLink", in: view))
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.thirdPartyLink", in: view))

        let close = try XCTUnwrap(button(identifier: "tellomi.crossBorder.fullNoticeClose", in: view), "「返回」")
        XCTAssertEqual(close.configuration?.title, localized("TELLOMI_CROSS_BORDER_FULL_NOTICE_CLOSE"))
        close.sendActions(for: .primaryActionTriggered)
        waitUntil(dialog.presentedViewController == nil)

        XCTAssertNil(dialog.presentedViewController, "「返回」关掉全文")
        XCTAssertTrue(root.presentedViewController === dialog, "回到弹窗，弹窗还在")
        XCTAssertFalse(TellomiCrossBorderConsent.hasAgreed, "看全文不是同意")
    }

    // MARK: - 6.6 弹窗：关联设备（只读）

    func testLinkedDeviceDialogHasOnlyAcknowledgeAndReadOnlyFullNotice() throws {
        var acknowledged = 0
        let dialog = TellomiCrossBorderNoticeViewController(mode: .linkedDevice, onAgree: { acknowledged += 1 })
        let (window, root) = presentInWindow(dialog)
        defer { window.isHidden = true }
        let view: UIView = dialog.view

        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_DIALOG_TITLE"), in: view))
        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_LINKED_DIALOG_BODY"), in: view), "只读版正文")
        XCTAssertNil(label(localized("TELLOMI_CROSS_BORDER_DIALOG_BODY"), in: view), "不问「是否单独同意？」")
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.fullNoticeLink", in: view))
        XCTAssertNil(button(identifier: "tellomi.crossBorder.agree", in: view), "没有「同意并继续」")
        XCTAssertNil(button(identifier: "tellomi.crossBorder.disagree", in: view), "没有「不同意」")

        dialog.didTapOutsideDialog()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(root.presentedViewController === dialog, "关联设备弹窗照旧只能点「知道了」")

        let link = try XCTUnwrap(button(identifier: "tellomi.crossBorder.fullNoticeLink", in: view))
        link.sendActions(for: .primaryActionTriggered)
        waitUntil(dialog.presentedViewController is TellomiCrossBorderFullNoticeViewController)
        let fullNotice = try XCTUnwrap(dialog.presentedViewController as? TellomiCrossBorderFullNoticeViewController)
        layOut(fullNotice)
        XCTAssertNotNil(label(localized("TELLOMI_CROSS_BORDER_LINKED_ITEM_CONSENT_BODY"), in: fullNotice.view), "只读版全文第 9 项")
        XCTAssertNil(label(localized("TELLOMI_CROSS_BORDER_ITEM_CONSENT_BODY"), in: fullNotice.view))
        fullNotice.dismiss(animated: false)

        let ack = try XCTUnwrap(button(identifier: "tellomi.crossBorder.linkedAck", in: view), "唯一的按钮「知道了」")
        XCTAssertEqual(ack.configuration?.title, localized("TELLOMI_CROSS_BORDER_LINKED_ACK"))
        ack.sendActions(for: .primaryActionTriggered)
        waitUntil(acknowledged == 1)

        XCTAssertEqual(acknowledged, 1)
        XCTAssertEqual(CurrentAppContext().appUserDefaults().string(forKey: versionKey), "cb-1")
        XCTAssertTrue(TellomiCrossBorderConsent.hasAgreed, "点完照旧放开网络")
        XCTAssertFalse(TellomiCrossBorderConsent.hasGivenSeparateConsent, "不算单独同意")
    }

    // MARK: - 6.6 弹窗：已注册设备升级后的盖页（法务项 c）

    func testUpgradeBlockingDialogShowsPolicyUpdatedFirstAndCannotBeClosed() throws {
        // 走的是 WindowManager 里真的接线：盖页窗口的根就是这个工厂造的。
        let dialog = WindowManager.makeCrossBorderConsentBlockingViewController()
        layOut(dialog)
        let view: UIView = dialog.view

        let title = try XCTUnwrap(label(localized("TELLOMI_CROSS_BORDER_DIALOG_TITLE"), in: view))
        let policyUpdated = try XCTUnwrap(
            label(localized("TELLOMI_CROSS_BORDER_DIALOG_POLICY_UPDATED"), in: view),
            "盖页要有「《隐私政策》已更新至 2.0.0 版。」",
        )
        let policyUpdatedLink = try XCTUnwrap(button(identifier: "tellomi.crossBorder.policyUpdatedLink", in: view))
        XCTAssertEqual(policyUpdatedLink.configuration?.title, localized("TELLOMI_CROSS_BORDER_POLICY_UPDATED_LINK"))
        let body = try XCTUnwrap(label(localized("TELLOMI_CROSS_BORDER_DIALOG_BODY"), in: view))
        XCTAssertLessThan(minY(of: title, in: dialog), minY(of: policyUpdated, in: dialog))
        XCTAssertLessThan(minY(of: policyUpdated, in: dialog), minY(of: policyUpdatedLink, in: dialog))
        XCTAssertLessThan(minY(of: policyUpdatedLink, in: dialog), minY(of: body, in: dialog), "放在正文上面")
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.fullNoticeLink", in: view))
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.disagree", in: view))
        XCTAssertNotNil(button(identifier: "tellomi.crossBorder.agree", in: view))
        XCTAssertNil(button(identifier: "tellomi.crossBorder.linkedAck", in: view))
        XCTAssertFalse(dialog.allowsClosingWithoutAnswer, "盖页关不掉")
        XCTAssertEqual(view.backgroundColor, Theme.launchScreenBackgroundColor, "背后是空白盖页（品牌底色），不是半透明遮罩")
    }

    // MARK: - 6.6 判据 5：删掉的 5 个 key 不再出现在资源文件里

    func testRemovedKeysAreGoneFromAllFourStringsFiles() throws {
        let removed = [
            "TELLOMI_CROSS_BORDER_TITLE",
            "TELLOMI_CROSS_BORDER_INTRO",
            "TELLOMI_CROSS_BORDER_LINKED_TITLE",
            "TELLOMI_CROSS_BORDER_LINKED_INTRO",
            "TELLOMI_CROSS_BORDER_POLICY_UPDATED",
        ]
        for localization in ["en", "zh_CN", "zh_HK", "zh_TW"] {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization),
                localization,
            )
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], localization)
            for key in removed {
                XCTAssertNil(table[key], "\(localization) 还有 \(key)")
            }
            XCTAssertNotNil(table["TELLOMI_CROSS_BORDER_DIALOG_TITLE"], "\(localization) 缺 DIALOG_TITLE")
        }
    }

    // MARK: - owner 2026-09-27：弹窗正文缩成一句（需求 6.6 `DIALOG_BODY`）

    func testDialogBodyIsOneSentenceInAllFourLanguages() throws {
        let expected = [
            "en": "Some of your personal information will be transferred outside mainland China for processing. Do you agree?",
            "zh_CN": "您的部分个人信息将传输到中国大陆境外处理，是否同意？",
            "zh_HK": "您的部分個人信息將傳輸到中國大陸境外處理，是否同意？",
            "zh_TW": "您的部分個人信息將傳輸到中國大陸境外處理，是否同意？",
        ]
        for (localization, body) in expected {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization),
                localization,
            )
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], localization)
            XCTAssertEqual(table["TELLOMI_CROSS_BORDER_DIALOG_BODY"], body, localization)
        }
    }
}
