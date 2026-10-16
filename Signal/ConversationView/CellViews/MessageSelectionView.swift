//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// ManualLayoutView wrapper around SelectionIndicatorView.
class MessageSelectionView: ManualLayoutView {

    private let selectionIndicatorView = SelectionIndicatorView(style: .list)

    var isSelected: Bool {
        get {
            selectionIndicatorView.isSelected
        }
        set {
            selectionIndicatorView.isSelected = newValue
        }
    }

    /// Tellomi（交互审计 A-15）：点一下 / 拖选改了选中状态时，勾那个圈弹一下（`TellomiCheckPop`，照 Telegram）、淡入淡出；
    /// 画面重画时照旧用 `isSelected`，不弹。减弱动态效果时只淡入淡出。
    func tellomiSetSelected(_ isSelected: Bool, animated: Bool) {
        guard isSelected != selectionIndicatorView.isSelected else {
            return
        }
        selectionIndicatorView.setIsSelected(isSelected, animated: animated)
        guard animated, !TellomiMotion.isReduceMotionEnabled else {
            return
        }
        selectionIndicatorView.layer.add(TellomiCheckPop.animation(selected: isSelected), forKey: TellomiCheckPop.animationKey)
    }

    init() {
        super.init(name: "MessageSelectionView")

        addSubviewToFillSuperviewEdges(selectionIndicatorView)
    }

    static var preferredSize: CGSize {
        CGSize(square: SelectionIndicatorView.preferredSize)
    }

    func updateStyle(conversationStyle: ConversationStyle) {
        selectionIndicatorView.fillColor = conversationStyle.chatColorValue.asChatUIElementTintColor()
        // Less transparent empty circle when there's a wallpaper and we're in light theme
        // to improve legibility over darker wallpapers.
        if
            conversationStyle.isDarkThemeEnabled == false,
            conversationStyle.hasWallpaper
        {
            selectionIndicatorView.unselectedListIndicatorColor = UIColor(rgbHex: 0x808080, alpha: 0.5)
        } else {
            selectionIndicatorView.unselectedListIndicatorColor = nil // reset to default
        }
    }
}
