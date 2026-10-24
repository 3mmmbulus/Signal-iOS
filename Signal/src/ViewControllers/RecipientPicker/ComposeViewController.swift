//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

class ComposeViewController: RecipientPickerContainerViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        title = OWSLocalizedString("MESSAGE_COMPOSEVIEW_TITLE", comment: "Title for the compose view.")

        view.backgroundColor = Theme.backgroundColor

        recipientPicker.shouldShowInvites = true
        recipientPicker.shouldShowNewGroup = true
        recipientPicker.groupsToShow = .groupsThatUserIsMemberOfWhenSearching
        recipientPicker.shouldHideLocalRecipient = false
        configureRecipientPicker()
        recipientPicker.delegate = self

        addRecipientPicker()

        navigationItem.rightBarButtonItem = .cancelButton(dismissingFrom: self)
    }

    /// Tellomi：子类（底栏「好友」）在选人控件加进来之前改它的配置。新建会话本身什么都不改。
    func configureRecipientPicker() {}

    /// Presents the conversation for the given address and dismisses this
    /// controller such that the conversation is visible.
    func newConversation(address: SignalServiceAddress) {
        AssertIsOnMainThread()
        owsAssertDebug(address.isValid)

        let thread = SSKEnvironment.shared.databaseStorageRef.write { transaction in
            TSContactThread.getOrCreateThread(
                withContactAddress: address,
                transaction: transaction,
            )
        }
        self.newConversation(thread: thread)
    }

    /// Presents the conversation for the given thread and dismisses this
    /// controller such that the conversation is visible.
    func newConversation(thread: TSThread) {
        presentingViewController?.dismiss(animated: true)
        if let transitionCoordinator = presentingViewController?.transitionCoordinator {
            // When transitionCoordinator is present, coordinate the immediate presentation of
            // the conversationVC with the animated dismissal of the compose VC
            transitionCoordinator.animate { _ in
                UIView.performWithoutAnimation {
                    SignalApp.shared.presentConversationForThread(
                        threadUniqueId: thread.uniqueId,
                        action: .compose,
                        animated: false,
                    )
                }
            }
        } else {
            // There isn't a transition coordinator present for some reason, revert to displaying
            // the conversation VC in parallel with the animated dismissal of the compose VC
            SignalApp.shared.presentConversationForThread(
                threadUniqueId: thread.uniqueId,
                action: .compose,
                animated: false,
            )
        }
    }

    func showNewGroupUI() {
        navigationController?.pushViewController(NewGroupMembersViewController(), animated: true)
    }
}

extension ComposeViewController: RecipientPickerDelegate, UsernameLinkScanDelegate {

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        selectionStyleForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> UITableViewCell.SelectionStyle {
        return .default
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        didSelectRecipient recipient: PickedRecipient,
    ) {
        switch recipient.identifier {
        case .address(let address):
            newConversation(address: address)
        case .group(let groupThread):
            newConversation(thread: groupThread)
        }
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        accessoryMessageForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> String? {
        switch recipient.identifier {
        case .address:
            return nil
        case .group(let thread):
            guard SSKEnvironment.shared.blockingManagerRef.isThreadBlocked(thread, transaction: transaction) else { return nil }
            return MessageStrings.conversationIsBlocked
        }
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        attributedSubtitleForRecipient recipient: PickedRecipient,
        transaction: DBReadTransaction,
    ) -> NSAttributedString? {
        switch recipient.identifier {
        case .address(let address):
            guard !address.isLocalAddress else {
                return nil
            }
            if let bioForDisplay = SSKEnvironment.shared.profileManagerRef.userProfile(for: address, tx: transaction)?.bioForDisplay {
                return NSAttributedString(string: bioForDisplay)
            }
            return nil
        case .group:
            return nil
        }
    }

    func recipientPickerNewGroupButtonWasPressed() {
        showNewGroupUI()
    }
}

/// Tellomi：底栏「好友」的根页面（tellomi/tellomi#1355、#1360；补 #1108 的页面细节）。
/// 复用新建会话的选人控件，作为标签页常驻：标题叫「好友」，没有「取消」按钮。
/// - 列表只列个人：不列群、不列自己，没有「新建群组」；保留「按用户名查找」。
/// - 顶部（不在搜索时）：扫描二维码、邀请好友（系统分享面板发下载链接，不走要读通讯录的上游邀请流程）。
/// - 没有 CDSI 的构建里不提通讯录权限；一个好友都没有时只说一句，不换整页大图。
/// - iPhone 上点一个人，会话压在「好友」自己的导航栈上，返回回到「好友」。
/// 放在这个文件里，免得改 Xcode 工程文件。
final class TellomiFriendsViewController: ComposeViewController {

    /// 和邀请短信里的链接一样。
    static let installUrl = "https://tellomi.app/download/"

    override func viewDidLoad() {
        super.viewDidLoad()

        title = HomeTabBarController.Tabs.friends.title
        navigationItem.rightBarButtonItem = nil
    }

    override func configureRecipientPicker() {
        Self.configure(recipientPicker)
        recipientPicker.tellomiExtraStaticItems = [
            OWSTableItem.disclosureItem(
                icon: .qrCode,
                withText: CommonStrings.scanQRCodeTitle,
                actionBlock: { [weak self] in
                    self?.presentUsernameQRCodeScanner()
                },
            ),
            OWSTableItem.disclosureItem(
                icon: .settingsInvite,
                withText: OWSLocalizedString(
                    "TELLOMI_FRIENDS_INVITE_ROW",
                    comment: "Tellomi: row at the top of the Friends tab that shares the app download link.",
                ),
                actionBlock: { [weak self] in
                    self?.shareInvite()
                },
            ),
        ]
    }

    static func configure(_ recipientPicker: RecipientPickerViewController) {
        recipientPicker.shouldShowInvites = false
        recipientPicker.shouldShowNewGroup = false
        recipientPicker.groupsToShow = .noGroups
        recipientPicker.shouldHideLocalRecipient = true
        recipientPicker.allowsAddByAddress = true
        recipientPicker.tellomiSkipsNoContactsView = true
        recipientPicker.tellomiNoContactsText = OWSLocalizedString(
            "TELLOMI_FRIENDS_EMPTY",
            comment: "Tellomi: shown in the Friends tab when the user has no friends on Tellomi yet.",
        )
        // 通讯录权限只在有 CDSI 时才提（#1240 的用途说明照旧）；没有 CDSI 时整块提醒都不放
        recipientPicker.tellomiHidesContactAccessReminder = !TSConstants.cdsiAvailable
    }

    static func inviteText() -> String {
        return OWSLocalizedString("SMS_INVITE_BODY", comment: "body sent to contacts when inviting to Install Signal") + " " + installUrl
    }

    private func shareInvite() {
        let activityViewController = UIActivityViewController(activityItems: [Self.inviteText()], applicationActivities: nil)
        activityViewController.popoverPresentationController?.sourceView = view
        present(activityViewController, animated: true)
    }

    /// 不像新建会话那样关弹窗、切到「聊天」：在「好友」里打开，返回回到「好友」。
    override func newConversation(thread: TSThread) {
        guard let splitViewController = SignalApp.shared.conversationSplitViewController else {
            SignalApp.shared.presentConversationForThread(threadUniqueId: thread.uniqueId, action: .compose, animated: true)
            return
        }
        splitViewController.presentThreadFromFriendsTab(threadUniqueId: thread.uniqueId, animated: true)
    }
}
