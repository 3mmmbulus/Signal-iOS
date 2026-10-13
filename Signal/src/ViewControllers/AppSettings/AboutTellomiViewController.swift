//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SafariServices
import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1165）：「关于」里的地址，与 Android `TellomiAboutLinks` 同一张表。
/// 法律页用官网的规范地址（`tellomi.app/legal/…` 会 301 到 `www`），邮箱照 `docs/product/BRAND.md` 的邮箱表。
enum TellomiAboutLinks {
    static let website = URL(string: "https://www.tellomi.app/")!
    static let websiteLabel = "www.tellomi.app"
    /// iOS 还没有上架，「版本更新」先去下载页（与 Signal-iOS #23 的「去更新」同一个页）
    static let download = URL(string: "https://www.tellomi.app/download/")!
    /// 源代码的获取页（AGPL-3.0：分发二进制时要让用户拿得到对应源代码）。owner 2026-09-25：「关于」里不放 GitHub 地址，
    /// 改成「开源许可」页最上面一句说明，指向官网这一页（官网那页再列各仓库）。
    static let sourceCodePage = URL(string: "https://www.tellomi.app/source/")!

    static let supportEmail = "support@tellomi.app"
    static let privacyEmail = "privacy@tellomi.app"
    static let abuseEmail = "abuse@tellomi.app"

    struct LegalDocument {
        let title: String
        let url: URL
    }

    /// 行名照需求 3.2，其中三份是官网标题的简称（用户服务协议、隐私政策（个人信息处理规则）、投诉举报、侵权通知与申诉处理规则）
    static var legalDocuments: [LegalDocument] {
        [
            LegalDocument(
                title: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_TERMS_OF_SERVICE", value: "Terms of Service", comment: "Tellomi: row in About Tellomi that opens the Terms of Service page."),
                url: URL(string: "https://www.tellomi.app/legal/terms/")!,
            ),
            LegalDocument(
                title: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_PRIVACY_POLICY", value: "Privacy Policy", comment: "Tellomi: row in About Tellomi that opens the Privacy Policy page."),
                url: URL(string: "https://www.tellomi.app/legal/privacy/")!,
            ),
            LegalDocument(
                title: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_PERSONAL_INFORMATION_COLLECTED", value: "Personal information we collect", comment: "Tellomi: row in About Tellomi that opens the list of personal information collected."),
                url: URL(string: "https://www.tellomi.app/legal/pi-collection/")!,
            ),
            LegalDocument(
                title: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_THIRD_PARTY_SHARING", value: "Third-party sharing and SDKs", comment: "Tellomi: row in About Tellomi that opens the list of third-party sharing and SDKs."),
                url: URL(string: "https://www.tellomi.app/legal/third-party/")!,
            ),
            LegalDocument(
                title: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_SYSTEM_PERMISSIONS", value: "System permissions we use", comment: "Tellomi: row in About Tellomi that opens the list of system permissions the app uses."),
                url: URL(string: "https://www.tellomi.app/legal/permissions/")!,
            ),
            LegalDocument(
                title: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_COMPLAINTS_AND_REPORTS", value: "Complaints and reporting rules", comment: "Tellomi: row in About Tellomi that opens the complaints and reporting rules page."),
                url: URL(string: "https://www.tellomi.app/legal/complaints/")!,
            ),
        ]
    }
}

/// 「关于 Tellomi」每一行做什么。抽出来只为单测能记下「点了哪一行、打开哪个地址」（与 Android `AboutSettingsCallbacks` 同一个做法）。
protocol AboutTellomiActions: AnyObject {
    func copy(_ text: String)
    /// App 内浏览器（`SFSafariViewController`）：需求判据 3「不跳出 App」
    func openInAppBrowser(_ url: URL)
    func writeEmail(to address: String)
    func showLicenses()
}

/// Tellomi（tellomi/tellomi#1165，需求 `docs/product/specs/about-page.md` 3.1、3.2）：「关于 Tellomi」从「帮助」里拿出来，
/// 在设置页里与「帮助」平级。顶部图标 + 名称 + 版本（点按复制），下面四组：更新 · 联系我们 · 法律与合规 · 开源，页脚三行署名（#984）。
/// 只放 Tellomi 真有的东西：没有客服电话、没有推荐算法，就不放对应的行。与 Android `AboutSettingsFragment` 同一张表。
final class AboutTellomiViewController: OWSTableViewController2 {

    private let versionName: String
    private let buildNumber: String
    private var actions: AboutTellomiActions!
    private var defaultActions: DefaultAboutTellomiActions?
    /// Tellomi（tellomi/tellomi#1491，需求 3.4「可选更新」）：清单里有比这台新的版本时，「更新」一组多一行「Tellomi x 可用」。
    private let updateOffer: TellomiUpdateManifests.Offer?
    private let openUpdate: (TellomiUpdateManifests.Offer) -> Void

    init(
        actions: AboutTellomiActions? = nil,
        versionName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        buildNumber: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        updateOffer: TellomiUpdateManifests.Offer? = AboutTellomiViewController.currentUpdateOffer(),
        openUpdate: ((TellomiUpdateManifests.Offer) -> Void)? = nil,
    ) {
        self.versionName = versionName
        self.buildNumber = buildNumber
        self.updateOffer = updateOffer
        self.openUpdate = openUpdate ?? { offer in
            MainActor.assumeIsolated {
                TellomiUpdateOffersUI.openUpdate(offer)
            }
        }
        super.init()
        if let actions {
            self.actions = actions
        } else {
            let defaultActions = DefaultAboutTellomiActions(viewController: self)
            self.defaultActions = defaultActions
            self.actions = defaultActions
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateTableContents()
    }

    static func currentUpdateOffer() -> TellomiUpdateManifests.Offer? {
        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiUpdateManifests.currentOffer(tx: tx, appExpiry: DependenciesBridge.shared.appExpiry)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 进了「关于」：这一版看过了，设置入口的小红点消失
        if let updateOffer {
            SSKEnvironment.shared.databaseStorageRef.write { tx in
                TellomiUpdateManifests.markSeenInAbout(build: updateOffer.build, tx: tx)
            }
        }
    }

    override func themeDidChange() {
        super.themeDidChange()
        updateTableContents()
    }

    /// 与「帮助」里原来的版本行复制同一个串（`AppVersion.prettyAppVersion` 的形状：`0.1.2 (175101)`）
    func didTapVersion() {
        actions.copy("\(versionName) (\(buildNumber))")
    }

    private func updateTableContents() {
        let contents = OWSTableContents(title: OWSLocalizedString(
            "SETTINGS_ABOUT_TELLOMI_TITLE",
            value: "About Tellomi",
            comment: "Tellomi: title of the About Tellomi page and of its row in settings.",
        ))

        let headerSection = OWSTableSection()
        headerSection.hasBackground = false
        headerSection.add(OWSTableItem(customCellBlock: { [weak self] in
            self?.headerCell() ?? UITableViewCell()
        }))
        contents.add(headerSection)

        let updatesSection = OWSTableSection()
        updatesSection.headerTitle = OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_SECTION_UPDATES", value: "Updates", comment: "Tellomi: section header in About Tellomi.")
        if let updateOffer {
            updatesSection.add(.item(
                name: TellomiUpdateOffersUI.title(updateOffer),
                accessoryText: OWSLocalizedString(
                    "APP_EXPIRED_TELLOMI_BLOCKING_UPDATE_BUTTON",
                    value: "Update now",
                    comment: "Tellomi: The main button on the 'update required' page. Opens the page where the new version can be installed.",
                ),
                accessoryType: .disclosureIndicator,
                accessibilityIdentifier: "tellomi.about.updateAvailable",
                actionBlock: { [weak self] in self?.openUpdate(updateOffer) },
            ))
        }
        updatesSection.add(.disclosureItem(
            withText: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_CHECK_FOR_UPDATES", value: "Check for updates", comment: "Tellomi: row in About Tellomi that opens the download page."),
            actionBlock: { [weak self] in self?.actions.openInAppBrowser(TellomiAboutLinks.download) },
        ))
        contents.add(updatesSection)

        let contactSection = OWSTableSection()
        contactSection.headerTitle = OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_SECTION_CONTACT", value: "Contact us", comment: "Tellomi: section header in About Tellomi.")
        contactSection.add(.item(
            name: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_OFFICIAL_WEBSITE", value: "Official website", comment: "Tellomi: row in About Tellomi that opens the website."),
            subtitle: TellomiAboutLinks.websiteLabel,
            accessoryType: .disclosureIndicator,
            actionBlock: { [weak self] in self?.actions.openInAppBrowser(TellomiAboutLinks.website) },
        ))
        contactSection.add(emailItem(
            title: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_CONTACT_SUPPORT", value: "Customer support", comment: "Tellomi: row in About Tellomi showing the support email address."),
            address: TellomiAboutLinks.supportEmail,
        ))
        contactSection.add(emailItem(
            title: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_PRIVACY_AND_PERSONAL_DATA", value: "Privacy and personal data", comment: "Tellomi: row in About Tellomi showing the privacy email address."),
            address: TellomiAboutLinks.privacyEmail,
        ))
        contactSection.add(emailItem(
            title: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_REPORT_ABUSE", value: "Report abuse", comment: "Tellomi: row in About Tellomi showing the abuse report email address."),
            address: TellomiAboutLinks.abuseEmail,
        ))
        contents.add(contactSection)

        let legalSection = OWSTableSection()
        legalSection.headerTitle = OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_SECTION_LEGAL", value: "Legal and compliance", comment: "Tellomi: section header in About Tellomi.")
        for document in TellomiAboutLinks.legalDocuments {
            legalSection.add(.disclosureItem(
                withText: document.title,
                actionBlock: { [weak self] in self?.actions.openInAppBrowser(document.url) },
            ))
        }
        contents.add(legalSection)

        let openSourceSection = OWSTableSection()
        openSourceSection.headerTitle = OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_SECTION_OPEN_SOURCE", value: "Open source", comment: "Tellomi: section header in About Tellomi.")
        openSourceSection.add(.disclosureItem(
            withText: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_OPEN_SOURCE_LICENSES", value: "Open source licenses", comment: "Tellomi: row in About Tellomi that lists third-party licenses."),
            actionBlock: { [weak self] in self?.actions.showLicenses() },
        ))
        // 页脚三行署名从「帮助」原样搬过来（#984，owner 2026-09-23 定），和 Android 一字一句对齐：
        //   Copyright Signal Messenger        ← 上游署名，AGPL 要求派生作品保留，不能换成我们自己
        //   Modifications Copyright 重庆半格智能科技有限公司   ← 我们对修改部分的署名：营业执照上的公司全称，不写品牌名
        //   Licensed under the GNU AGPLv3     ← 许可证的正式名称（LICENSE 第一行），和 Android 上游同一个写法
        // （owner 2026-09-24，taishi 中转包 7 第〇节；规则见 docs/legal/dev/SOURCE_COPYRIGHT.md）
        // 上游还有第四行「Signal is a 501c3 nonprofit」，去掉了：Tellomi 不是非营利组织，换个名字就是一句关于自身法律主体的假话。
        // （这条之前错过一次：把上游那行整个换成了「Copyright Tellomi」，等于在 AGPL 派生作品里移除原作者署名。）
        openSourceSection.footerTitle = OWSLocalizedString(
            "ABOUT_SECTION_FOOTER_TELLOMI",
            comment: "Footer for the 'about' help section: copyright and license only.",
        )
        contents.add(openSourceSection)

        self.contents = contents
    }

    /// 邮箱行：点一下复制（右侧写着「点击复制」），长按出「写邮件」（需求 3.2：长按 / 次级动作）
    private func emailItem(title: String, address: String) -> OWSTableItem {
        let tapToCopy = OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_TAP_TO_COPY", value: "Tap to copy", comment: "Tellomi: accessory text on email rows in About Tellomi; tapping the row copies the address.")
        let writeEmail = OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_WRITE_EMAIL", value: "Write email", comment: "Tellomi: context menu action on email rows in About Tellomi.")
        return OWSTableItem(
            customCellBlock: {
                OWSTableItem.buildCell(itemName: title, subtitle: address, accessoryText: tapToCopy)
            },
            actionBlock: { [weak self] in self?.actions.copy(address) },
            contextMenuActionProvider: { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: writeEmail, image: UIImage(systemName: "envelope")) { _ in
                        self?.actions.writeEmail(to: address)
                    },
                ])
            },
        )
    }

    private func headerCell() -> UITableViewCell {
        let cell = OWSTableItem.newCell()
        cell.selectionStyle = .none

        // 图标：与 App 图标同一个深色底（AppIcon.icon 的填充色）+ Tellomi 标，矢量，不随屏幕糊
        let iconView = UIView()
        iconView.backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        iconView.layer.cornerRadius = 16
        iconView.layer.cornerCurve = .continuous
        iconView.autoSetDimensions(to: CGSize(square: 72))
        let logoView = UIImageView(image: UIImage(named: "signal-logo-128")?.withRenderingMode(.alwaysTemplate))
        logoView.tintColor = .white
        logoView.contentMode = .scaleAspectFit
        iconView.addSubview(logoView)
        logoView.autoCenterInSuperview()
        logoView.autoSetDimensions(to: CGSize(square: 48))
        iconView.isAccessibilityElement = false

        let nameLabel = UILabel()
        nameLabel.text = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Tellomi"
        nameLabel.font = .dynamicTypeTitle2.semibold()
        nameLabel.textColor = .Signal.label
        nameLabel.textAlignment = .center

        // 版本：点按复制完整版本号（保留「帮助」里原来那一行的行为，提示「已复制」）
        let versionLabel = UILabel()
        versionLabel.text = String(
            format: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_VERSION_FORMAT", value: "Version %1$@ (build %2$@)", comment: "Tellomi: version line at the top of About Tellomi. Embeds {{ version }} and {{ build number }}."),
            versionName,
            buildNumber,
        )
        versionLabel.font = .dynamicTypeSubheadline
        versionLabel.textColor = .Signal.secondaryLabel
        versionLabel.textAlignment = .center
        versionLabel.numberOfLines = 0
        versionLabel.isUserInteractionEnabled = true
        versionLabel.accessibilityTraits = .button
        versionLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(versionLabelTapped)))

        let stack = UIStackView(arrangedSubviews: [iconView, nameLabel, versionLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(12, after: iconView)
        cell.contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewMargins()
        return cell
    }

    @objc
    private func versionLabelTapped() {
        didTapVersion()
    }
}

// MARK: - 默认动作

private final class DefaultAboutTellomiActions: AboutTellomiActions {
    private weak var viewController: UIViewController?

    init(viewController: UIViewController) {
        self.viewController = viewController
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        viewController?.presentToast(
            text: OWSLocalizedString("COPIED_TO_CLIPBOARD", comment: "Indicator that a value has been copied to the clipboard."),
            image: UIImage(named: "check"),
        )
    }

    func openInAppBrowser(_ url: URL) {
        viewController?.present(SFSafariViewController(url: url), animated: true)
    }

    /// 写邮件：交给系统的邮件 App。没配邮件时说清楚，并把地址复制好（上游 `EMAIL_SIGNAL_MESSAGE` 写死了 support@，不适合另外两个地址）
    func writeEmail(to address: String) {
        guard ComposeSupportEmailOperation.canSendEmails, let url = URL(string: "mailto:\(address)") else {
            UIPasteboard.general.string = address
            let sheet = ActionSheetController(
                title: OWSLocalizedString("EMAIL_SIGNAL_TITLE", comment: "Title for the fallback support sheet if user cannot send email"),
                message: OWSLocalizedString(
                    "SETTINGS_ABOUT_TELLOMI_EMAIL_UNAVAILABLE_MESSAGE",
                    value: "Your device isn't set up to send email. The address has been copied, so you can paste it into another email app.",
                    comment: "Tellomi: shown when the user long-presses an email in About Tellomi but no mail account is set up.",
                ),
            )
            sheet.addAction(ActionSheetAction(title: CommonStrings.okButton))
            viewController?.presentActionSheet(sheet)
            return
        }
        UIApplication.shared.open(url)
    }

    func showLicenses() {
        viewController?.navigationController?.pushViewController(TellomiAcknowledgementsViewController(), animated: true)
    }
}

// MARK: - 开源许可

/// Tellomi（#1165）：「开源许可」页。上游 iOS 的第三方许可只在系统「设置」App 里（`Settings.bundle/Acknowledgements.plist`），
/// App 内没有入口；这里原样读同一份清单，和 Android 的「许可证」页对应。
enum TellomiAcknowledgements {
    struct Entry: Equatable {
        let title: String
        let text: String
    }

    static func load(from bundle: Bundle = .main) -> [Entry] {
        guard
            let url = bundle.url(forResource: "Acknowledgements", withExtension: "plist", subdirectory: "Settings.bundle"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let specifiers = plist["PreferenceSpecifiers"] as? [[String: Any]]
        else {
            owsFailDebug("Missing acknowledgements")
            return []
        }
        // 第一条是「Acknowledgements / This application makes use of…」的标题组，不是许可
        return specifiers.dropFirst().compactMap { specifier in
            guard
                let title = (specifier["Title"] as? String)?.nilIfEmpty,
                let text = (specifier["FooterText"] as? String)?.nilIfEmpty
            else {
                return nil
            }
            return Entry(title: title, text: text)
        }
    }
}

final class TellomiAcknowledgementsViewController: OWSTableViewController2 {
    /// 页面最上面那一句：许可证 + 源代码在哪（owner 2026-09-25：「关于」里不再放 GitHub 那一行，改成这里一句指向官网的说明）
    static var sourceCodeNotice: String {
        OWSLocalizedString(
            "SETTINGS_ABOUT_TELLOMI_SOURCE_CODE_NOTICE",
            value: "Tellomi is released under the GNU AGPLv3. The source code is available at www.tellomi.app/source.",
            comment: "Tellomi: sentence at the top of the open source licenses page saying where to get the source code. Keep the web address as is.",
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let noticeSection = OWSTableSection()
        noticeSection.hasBackground = false
        noticeSection.add(OWSTableItem(customCellBlock: {
            let cell = OWSTableItem.newCell()
            cell.selectionStyle = .none
            let label = UILabel()
            label.text = Self.sourceCodeNotice
            label.font = .dynamicTypeFootnote
            label.textColor = .Signal.secondaryLabel
            label.numberOfLines = 0
            cell.contentView.addSubview(label)
            label.autoPinEdgesToSuperviewMargins()
            return cell
        }))

        let section = OWSTableSection()
        for entry in TellomiAcknowledgements.load() {
            // 有几条是几十个 Rust 包共用一份许可，标题是一长串包名：列表里最多三行，全文页开头列全
            section.add(.disclosureItem(
                withText: entry.title,
                maxNameLines: 3,
                actionBlock: { [weak self] in
                    self?.navigationController?.pushViewController(TellomiAcknowledgementTextViewController(entry: entry), animated: true)
                },
            ))
        }
        self.contents = OWSTableContents(
            title: OWSLocalizedString("SETTINGS_ABOUT_TELLOMI_OPEN_SOURCE_LICENSES", value: "Open source licenses", comment: "Tellomi: row in About Tellomi that lists third-party licenses."),
            sections: [noticeSection, section],
        )
    }
}

private final class TellomiAcknowledgementTextViewController: OWSViewController {
    private let entry: TellomiAcknowledgements.Entry

    init(entry: TellomiAcknowledgements.Entry) {
        self.entry = entry
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = entry.title
        view.backgroundColor = .Signal.background

        let textView = UITextView()
        textView.isEditable = false
        textView.text = "\(entry.title)\n\n\(entry.text)"
        textView.font = .dynamicTypeFootnote
        textView.textColor = .Signal.label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(hMargin: 16, vMargin: 16)
        view.addSubview(textView)
        textView.autoPinEdgesToSuperviewEdges()
    }
}
