//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

extension AttachmentApprovalViewController {
    /// tellomi/tellomi#1261 P-10：打开时停在第 `index` 张。上游总从第一张开始；
    /// 选图面板里点的是哪张（网格里的照片、「只看已选」里的卡片），进来就先看到哪张（同 Telegram）。
    public func tellomiShowItem(at index: Int) {
        loadViewIfNeeded()
        let items = attachmentApprovalItems
        guard items.indices.contains(index), !items[index].isIdenticalTo(currentItem) else { return }
        setCurrentItem(items[index], direction: .forward, animated: false)
    }

    public func tellomiActivateTool(_ tool: TellomiApprovalEditTool) {
        switch tool {
        case .pen:
            currentPageViewController?.activatePenTool()
        case .crop:
            currentPageViewController?.activateCropTool()
        }
    }
}

public enum TellomiApprovalEditTool {
    case pen
    case crop
}
