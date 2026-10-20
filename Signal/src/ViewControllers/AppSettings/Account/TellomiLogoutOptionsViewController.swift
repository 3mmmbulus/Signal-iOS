//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// 设置 → 账号 →「退出登录」（需求 §3.2，ADR-0072）。
///
/// 先给替代方案——很多人想退出其实是怕别人看到、空间不够或换了号码——每一行打开现有的设置页；
/// 最下面才是红色「退出登录」，点了弹确认：「退出登录」（保留聊天记录，默认）/「退出并删除本机数据」/「取消」。
/// 有已链接设备时多一个开关「同时让已链接的设备退出」（默认关）。
///
/// 做法参考了 Telegram 的「退出前先看看替代方案」（LogoutOptionsController / LogoutActivity），代码是独立写的：
/// 用 Signal 现有的设置列表（OWSTableViewController2）和弹层（ActionSheetController）。
final class TellomiLogoutOptionsViewController: OWSTableViewController2 {

    private let logout: TellomiAccountLogout
    /// 现在能不能换号码（上游在注册流程没走完时不让换）；不能就不显示那一行。
    private let changePhoneNumber: (() -> Void)?

    private var hasLinkedDevices: Bool
    private var alsoUnlinkLinkedDevices = false

    init(
        logout: TellomiAccountLogout = .fromGlobals(),
        changePhoneNumber: (() -> Void)?,
    ) {
        self.logout = logout
        self.changePhoneNumber = changePhoneNumber
        self.hasLinkedDevices = DependenciesBridge.shared.db.read { tx in
            logout.hasLinkedDevices(tx: tx)
        }
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = Strings.title

        updateTableContents()

        // 本机记着的设备列表可能是旧的（没打开过「已链接的设备」页）；刷新一次，决定开关显不显示。
        Task { [weak self, logout] in
            await logout.refreshLinkedDevicesBestEffort()
            let hasLinkedDevices = DependenciesBridge.shared.db.read { tx in
                logout.hasLinkedDevices(tx: tx)
            }
            await MainActor.run {
                guard let self, self.hasLinkedDevices != hasLinkedDevices else { return }
                self.hasLinkedDevices = hasLinkedDevices
                self.updateTableContents()
            }
        }
    }

    // MARK: - Contents

    private func updateTableContents() {
        let contents = OWSTableContents()

        let alternativesSection = OWSTableSection()
        alternativesSection.headerTitle = Strings.intro
        alternativesSection.add(.disclosureItem(
            icon: .settingsPrivacy,
            withText: Strings.screenLockTitle,
            subtitle: Strings.screenLockBody,
            actionBlock: { [weak self] in
                // 「屏幕锁定」开关在「隐私」页。
                self?.navigationController?.pushViewController(PrivacySettingsViewController(), animated: true)
            },
        ))
        alternativesSection.add(.disclosureItem(
            icon: .settingsChats,
            withText: Strings.storageTitle,
            subtitle: Strings.storageBody,
            actionBlock: { [weak self] in
                // iOS 上游没有单独的「管理存储空间」页；能清理聊天记录与附件的现有入口在「聊天」页（「清除聊天记录」）。
                self?.navigationController?.pushViewController(ChatsSettingsViewController(), animated: true)
            },
        ))
        if let changePhoneNumber {
            alternativesSection.add(.disclosureItem(
                icon: .phoneNumber,
                withText: Strings.changeNumberTitle,
                subtitle: Strings.changeNumberBody,
                actionBlock: changePhoneNumber,
            ))
        }
        contents.add(alternativesSection)

        if hasLinkedDevices {
            let linkedDevicesSection = OWSTableSection()
            linkedDevicesSection.add(.switch(
                withText: Strings.alsoUnlinkLinkedDevices,
                accessibilityIdentifier: "tellomi.logout.alsoUnlinkLinkedDevices",
                isOn: { [weak self] in self?.alsoUnlinkLinkedDevices ?? false },
                actionBlock: { [weak self] uiSwitch in
                    self?.alsoUnlinkLinkedDevices = uiSwitch.isOn
                },
            ))
            contents.add(linkedDevicesSection)
        }

        let logoutSection = OWSTableSection()
        logoutSection.add(.item(
            name: Strings.logOutButton,
            textColor: .Signal.red,
            accessibilityIdentifier: "tellomi.logout.logOut",
            actionBlock: { [weak self] in
                self?.didTapLogOut()
            },
        ))
        contents.add(logoutSection)

        self.contents = contents
    }

    // MARK: - Actions

    private func didTapLogOut() {
        let actionSheet = ActionSheetController(title: Strings.confirmTitle, message: Strings.confirmBody)
        actionSheet.addAction(ActionSheetAction(
            title: Strings.confirmKeepData,
            style: .default,
            handler: { [weak self] _ in
                self?.logOutKeepingData()
            },
        ))
        actionSheet.addAction(ActionSheetAction(
            title: Strings.confirmDeleteData,
            style: .destructive,
            handler: { [weak self] _ in
                self?.confirmLogOutAndDeleteData()
            },
        ))
        actionSheet.addAction(OWSActionSheets.cancelAction)
        presentActionSheet(actionSheet)
    }

    /// ADR-0072 §4.1：已链接设备（勾了才做）→ 注销推送令牌 → 本机标记 → 回欢迎页。失败就不退出。
    private func logOutKeepingData() {
        let alsoUnlinkLinkedDevices = self.alsoUnlinkLinkedDevices
        Task { @MainActor in
            do {
                try await ModalActivityIndicatorViewController.presentAndPropagateResult(from: self) { [logout] in
                    try await logout.logOut(alsoUnlinkLinkedDevices: alsoUnlinkLinkedDevices)
                }
            } catch {
                let message: String
                switch error as? TellomiAccountLogout.LogoutError {
                case .networkUnavailable:
                    message = Strings.networkError
                case .failed, nil:
                    message = CommonStrings.somethingWentWrongTryAgainLaterError
                }
                OWSActionSheets.showActionSheet(message: message, fromViewController: self)
                return
            }
            // 动态的 capabilities 是按账号存的：退出登录就清掉
            FeedEngineCapabilities.clearOnLogout()
            SignalApp.shared.tellomiDidLogOut()
        }
    }

    /// ADR-0072 §4.3：再确认一次；尽量注销推送令牌（没网也继续），然后走现有的「删除所有数据」（App 会退出）。
    private func confirmLogOutAndDeleteData() {
        let alsoUnlinkLinkedDevices = self.alsoUnlinkLinkedDevices
        OWSActionSheets.showConfirmationAlert(
            title: Strings.deleteConfirmTitle,
            message: Strings.deleteConfirmBody,
            proceedTitle: Strings.deleteConfirmButton,
            proceedStyle: .destructive,
            proceedAction: { [weak self, logout] _ in
                guard let self else { return }
                ModalActivityIndicatorViewController.present(
                    fromViewController: self,
                    title: CommonStrings.deletingModal,
                ) { _ in
                    await logout.signOffBestEffortBeforeDeletingLocalData(alsoUnlinkLinkedDevices: alsoUnlinkLinkedDevices)
                    FeedEngineCapabilities.clearOnLogout()
                    SignalApp.shared.resetAppDataAndExit(keyFetcher: SSKEnvironment.shared.databaseStorageRef.keyFetcher)
                }
            },
            fromViewController: self,
        )
    }

    // MARK: - Strings

    enum Strings {
        static var settingsRow: String {
            OWSLocalizedString("TELLOMI_LOGOUT_SETTINGS_ROW", comment: "Tellomi: Red row at the bottom of Settings > Account (above 'Delete Account') that opens the log out page. Logging out keeps the account; it is not account deletion.")
        }

        static var title: String {
            OWSLocalizedString("TELLOMI_LOGOUT_OPTIONS_TITLE", comment: "Tellomi: Title of the page shown before logging out, listing alternatives (screen lock, storage, change number).")
        }

        static var intro: String {
            OWSLocalizedString("TELLOMI_LOGOUT_OPTIONS_INTRO", comment: "Tellomi: Heading above the alternatives on the log out page, suggesting the user check whether one of them helps before logging out.")
        }

        static var screenLockTitle: String {
            OWSLocalizedString("TELLOMI_LOGOUT_OPTION_SCREEN_LOCK_TITLE", comment: "Tellomi: Log out alternatives: title of the row that opens the Screen Lock setting.")
        }

        static var screenLockBody: String {
            OWSLocalizedString("TELLOMI_LOGOUT_OPTION_SCREEN_LOCK_BODY", comment: "Tellomi: Log out alternatives: explanation under 'Screen Lock' — worried others will see your chats? Turn it on and the app must be unlocked first.")
        }

        static var storageTitle: String {
            OWSLocalizedString("TELLOMI_LOGOUT_OPTION_STORAGE_TITLE", comment: "Tellomi: Log out alternatives: title of the row that opens storage management.")
        }

        static var storageBody: String {
            OWSLocalizedString("TELLOMI_LOGOUT_OPTION_STORAGE_BODY", comment: "Tellomi: Log out alternatives: explanation under 'Manage Storage' — running out of space? Clean up images and files you don't need.")
        }

        static var changeNumberTitle: String {
            OWSLocalizedString("TELLOMI_LOGOUT_OPTION_CHANGE_NUMBER_TITLE", comment: "Tellomi: Log out alternatives: title of the row that starts changing the phone number.")
        }

        static var changeNumberBody: String {
            OWSLocalizedString("TELLOMI_LOGOUT_OPTION_CHANGE_NUMBER_BODY", comment: "Tellomi: Log out alternatives: explanation under 'Change Phone Number' — got a new number? Chats and contacts are kept.")
        }

        static var alsoUnlinkLinkedDevices: String {
            OWSLocalizedString("TELLOMI_LOGOUT_UNLINK_DEVICES_SWITCH", comment: "Tellomi: Switch on the log out page (off by default, shown only when there are linked devices): also log out the linked devices such as computers.")
        }

        static var logOutButton: String {
            OWSLocalizedString("TELLOMI_LOGOUT_OPTIONS_BUTTON", comment: "Tellomi: Red button at the bottom of the log out page.")
        }

        static var confirmTitle: String {
            OWSLocalizedString("TELLOMI_LOGOUT_CONFIRM_TITLE", comment: "Tellomi: Title of the confirmation sheet for logging out.")
        }

        static var confirmBody: String {
            OWSLocalizedString("TELLOMI_LOGOUT_CONFIRM_BODY", comment: "Tellomi: Body of the log out confirmation: chats stay on this phone and come back after logging in with the same number; messages sent meanwhile wait on the server for up to 30 days.")
        }

        static var confirmKeepData: String {
            OWSLocalizedString("TELLOMI_LOGOUT_CONFIRM_KEEP_DATA", comment: "Tellomi: Default action in the log out confirmation: log out and keep the chats on this phone.")
        }

        static var confirmDeleteData: String {
            OWSLocalizedString("TELLOMI_LOGOUT_CONFIRM_DELETE_DATA", comment: "Tellomi: Destructive action in the log out confirmation: log out and delete all data on this phone.")
        }

        static var deleteConfirmTitle: String {
            OWSLocalizedString("TELLOMI_LOGOUT_DELETE_CONFIRM_TITLE", comment: "Tellomi: Title of the second confirmation before logging out and deleting this phone's data.")
        }

        static var deleteConfirmBody: String {
            OWSLocalizedString("TELLOMI_LOGOUT_DELETE_CONFIRM_BODY", comment: "Tellomi: Body of the second confirmation: all chats and files on this phone are deleted for good; the account itself is not affected and can log in on any device.")
        }

        static var deleteConfirmButton: String {
            OWSLocalizedString("TELLOMI_LOGOUT_DELETE_CONFIRM_BUTTON", comment: "Tellomi: Destructive button in the second confirmation: delete this phone's data and log out.")
        }

        static var networkError: String {
            OWSLocalizedString("TELLOMI_LOGOUT_NETWORK_ERROR", comment: "Tellomi: Shown when logging out fails because there is no network connection; the app stays logged in.")
        }
    }
}
