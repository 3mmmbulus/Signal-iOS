//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（2026-10-16，owner 发来的《附件面板里位置 / 投票 / 联系人在面板内换页》方案）：附件 Sheet 里由会话页提供的页。
/// 放在自己的文件里，不往上游那几个大文件里塞（合并上游时冲突少）。
extension ConversationViewController {

    /// dock 的这一格能不能在同一个 Sheet 里换页；能就换（联系人先问通讯录权限，允许了才换），返回 true；
    /// 不能（GIF、联系人走另一种选择器时）返回 false，调用方照旧先收起 Sheet 再走上游的流程。
    func tellomiOpenInSheet(_ item: TellomiAttachmentDockItem, container: TellomiAttachmentSheetController) -> Bool {
        guard let page = TellomiAttachmentSheetController.page(for: item) else { return false }
        switch page {
        case .contact:
            // BuildFlags.accountIdentifierSharing 打开时上游换成另一种选择器（RecipientPicker），那条路还没搬进 Sheet。
            guard !BuildFlags.accountIdentifierSharing else { return false }
            SUIEnvironment.shared.contactsViewHelperRef.checkReadAuthorization(
                purpose: .share,
                performWhenAllowed: { [weak container] in container?.show(.contact) },
                presentErrorFrom: container,
            )
        case .gallery, .files, .poll, .location:
            container.show(page)
        }
        return true
    }

    /// 「投票」页：上游的 `NewPollViewController2`，发出走会话页现有的 `sendPoll`（`PollSendDelegate`），✕ / 发完收起整个 Sheet。
    func makeTellomiPollPage() -> UIViewController {
        let poll = NewPollViewController2(maxOptionCount: RemoteConfig.current.maxPollOptionSendCount)
        poll.sendDelegate = self
        poll.onClose = { [weak self] in
            self?.dismiss(animated: true)
        }
        let page = TellomiAttachmentPollPage(poll: poll, dockItems: TellomiAttachmentDockItem.attachmentSheetItems)
        page.delegate = self
        return page
    }

    /// 「联系人」页：上游的 `ContactPickerViewController`（同 `chooseContactForSending` 不开 accountIdentifierSharing 那条），
    /// 选了一个人在同一个导航栈里推上游的联系人卡片审核页（`ContactShareViewController`）；审核页「取消」回到列表，
    /// 「发送」收起整个 Sheet 再发（同上游先收再发的顺序）；列表的「取消」收起整个 Sheet。同 Telegram iOS `.contact`。
    func makeTellomiContactPage() -> UIViewController? {
        guard !BuildFlags.accountIdentifierSharing else { return nil }
        let adapter = TellomiAttachmentContactsAdapter(conversation: self)
        let picker = ContactPickerViewController(allowsMultipleSelection: false, subtitleCellType: .none)
        picker.delegate = adapter
        picker.title = OWSLocalizedString(
            "CONTACT_PICKER_TITLE",
            comment: "navbar title for contact picker when sharing a contact",
        )
        let page = TellomiAttachmentNavigationPage(root: picker, dockItem: .contact, dockItems: TellomiAttachmentDockItem.attachmentSheetItems)
        page.retainedObjects.append(adapter)
        page.delegate = self
        return page
    }
}

extension ConversationViewController {

    /// 「位置」页：上游的 `LocationPicker`（Apple 地图、搜索、长按选点、当前位置），发出走会话页现有的 `didPickLocation`；
    /// 发完、✕ 都收起整个 Sheet。同 Telegram iOS `.location`。
    /// 地图要拖，Sheet 不许下拉关（✕ 照样能关），进来就展开到全屏。
    func makeTellomiLocationPage() -> UIViewController {
        let adapter = TellomiAttachmentLocationAdapter(conversation: self)
        let picker = LocationPicker()
        picker.delegate = adapter
        picker.onFinish = { [weak self] in
            self?.dismiss(animated: true)
        }
        let page = TellomiAttachmentNavigationPage(root: picker, dockItem: .location, dockItems: TellomiAttachmentDockItem.attachmentSheetItems)
        page.retainedObjects.append(adapter)
        page.isModalInPresentation = true
        page.delegate = self
        return page
    }
}

/// 位置页的代理：上游 `LocationPicker` 只弱引用代理，由页面持有它。
final class TellomiAttachmentLocationAdapter: LocationPickerDelegate {

    private weak var conversation: ConversationViewController?

    init(conversation: ConversationViewController) {
        self.conversation = conversation
    }

    func didPickLocation(_ locationPicker: LocationPicker, location: Location) {
        conversation?.didPickLocation(locationPicker, location: location)
    }

    func locationPickerDidCancel() {
        conversation?.dismiss(animated: true)
    }
}

extension ConversationViewController: TellomiAttachmentNavigationPageDelegate {

    /// 投票 / 联系人页的 dock：Sheet 里的页就地换；「位置 / GIF」同另外两页，先收起 Sheet 再走上游的流程。
    func navigationPage(_ page: TellomiAttachmentNavigationPage, didSelectDockItem item: TellomiAttachmentDockItem) {
        if let container = page.parent as? TellomiAttachmentSheetController, tellomiOpenInSheet(item, container: container) {
            return
        }
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            switch item {
            // accountIdentifierSharing 打开时的联系人（上游 RecipientPicker，还没搬进 Sheet）
            case .contact: self.contactButtonPressed()
            case .gif: self.gifButtonPressed()
            // 都在 Sheet 里换页，走不到这里（清单 C-6）
            case .gallery, .file, .poll, .location: break
            }
        }
    }
}

/// 联系人页的代理：上游的 `ContactPickerViewController`、`ContactShareViewController` 只弱引用代理，由页面持有它。
final class TellomiAttachmentContactsAdapter: ContactPickerDelegate, ContactShareViewControllerDelegate {

    private weak var conversation: ConversationViewController?

    init(conversation: ConversationViewController) {
        self.conversation = conversation
    }

    // MARK: ContactPickerDelegate

    func contactPickerDidCancel(_: ContactPickerViewController) {
        conversation?.dismiss(animated: true)
    }

    func contactPicker(_ contactPicker: ContactPickerViewController, didSelect systemContact: SystemContact) {
        AssertIsOnMainThread()

        guard let cnContact = SSKEnvironment.shared.contactManagerRef.cnContact(withId: systemContact.cnContactId) else {
            owsFailDebug("Could not load system contact.")
            return
        }

        // 同上游 `ConversationViewController.contactPicker(_:didSelect:)`
        let contactShareDraft = SSKEnvironment.shared.databaseStorageRef.read { tx in
            return ContactShareDraft.load(
                cnContact: cnContact,
                signalContact: systemContact,
                contactManager: SSKEnvironment.shared.contactManagerRef,
                phoneNumberUtil: SSKEnvironment.shared.phoneNumberUtilRef,
                profileManager: SSKEnvironment.shared.profileManagerRef,
                recipientManager: DependenciesBridge.shared.recipientManager,
                tsAccountManager: DependenciesBridge.shared.tsAccountManager,
                tx: tx,
            )
        }

        let approveContactShare = ContactShareViewController(contactShareDraft: contactShareDraft)
        approveContactShare.shareDelegate = self
        contactPicker.navigationController?.pushViewController(approveContactShare, animated: true)
    }

    func contactPicker(_: ContactPickerViewController, didSelectMultiple systemContacts: [SystemContact]) {
        owsFailDebug("Multiple selection not allowed.")
    }

    func contactPicker(_: ContactPickerViewController, shouldSelect systemContact: SystemContact) -> Bool {
        return true
    }

    // MARK: ContactShareViewControllerDelegate

    func contactShareViewController(_ viewController: ContactShareViewController, didApproveContactShare contactShare: ContactShareDraft) {
        guard let conversation else { return }
        conversation.dismiss(animated: true) {
            conversation.send(contactShareDraft: contactShare)
        }
    }

    /// 审核页「取消」回到联系人列表（上游是整个收起）。
    func contactShareViewControllerDidCancel(_ viewController: ContactShareViewController) {
        viewController.navigationController?.popViewController(animated: true)
    }

    func titleForContactShareViewController(_ viewController: ContactShareViewController) -> String? {
        return conversation?.titleForContactShareViewController(viewController)
    }

    func recipientsDescriptionForContactShareViewController(_ viewController: ContactShareViewController) -> String? {
        return conversation?.recipientsDescriptionForContactShareViewController(viewController)
    }

    func approvalModeForContactShareViewController(_ viewController: ContactShareViewController) -> ApprovalMode {
        return conversation?.approvalModeForContactShareViewController(viewController) ?? .send
    }
}
