//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（2026-10-16，owner 发来的《附件面板里位置 / 投票 / 联系人在面板内换页》方案）：附件 Sheet 里由会话页提供的页。
/// 放在自己的文件里，不往上游那几个大文件里塞（合并上游时冲突少）。
extension ConversationViewController {

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
}

extension ConversationViewController: TellomiAttachmentPollPageDelegate {

    /// 投票页 dock：「相册」「文件」就地换页；「位置 / 联系人 / GIF」同另外两页，先收起 Sheet 再走上游的流程。
    func pollPage(_ page: TellomiAttachmentPollPage, didSelectDockItem item: TellomiAttachmentDockItem) {
        if let container = page.parent as? TellomiAttachmentSheetController, let target = TellomiAttachmentSheetController.page(for: item) {
            container.show(target)
            return
        }
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            switch item {
            case .location: self.locationButtonPressed()
            case .contact: self.contactButtonPressed()
            case .gif: self.gifButtonPressed()
            case .gallery, .file, .poll: break
            }
        }
    }
}
