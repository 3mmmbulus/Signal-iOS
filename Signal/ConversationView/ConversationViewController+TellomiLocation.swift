//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

/// Tellomi（spec attachment-files-location L-11）：点了聊天里的位置消息 → 位置详情（Telegram 点地图消息打开 `LocationViewController`）。
extension ConversationViewController {

    public func tellomiDidTapLocation(_ location: TellomiLocationMessage, itemViewModel: CVItemViewModelImpl) {
        AssertIsOnMainThread()

        dismissKeyBoard()
        present(TellomiLocationViewController(location: location), animated: true)
    }
}
