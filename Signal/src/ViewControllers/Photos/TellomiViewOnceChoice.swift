//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1714，ADR-0079 §4.4）：选图查看器里这一张的计时——一次性查看，或打开后看 3 / 10 / 30 秒。
/// 「不删除」= 没有（nil）。照 Telegram 两端说明框右侧计时键的五项菜单（iOS `MessageInputPanelComponent` 的 timeoutButton、
/// 安卓 `CaptionPhotoViewer`），只取机制。
enum TellomiViewOnceChoice: Equatable {
    case viewOnce
    case seconds(UInt32)

    /// 菜单里的次序（最后一项「不删除」是 nil）。
    static let menuOrder: [TellomiViewOnceChoice?] = [.viewOnce, .seconds(3), .seconds(10), .seconds(30), nil]

    /// 发出去的 `viewOnceSeconds`；一次性查看是 nil（只有 `isViewOnce`）。
    var seconds: UInt32? {
        switch self {
        case .viewOnce: return nil
        case .seconds(let seconds): return seconds
        }
    }

    /// 计时键上显示的：一次性查看「1」，计时「3」「10」「30」。
    var badgeText: String {
        switch self {
        case .viewOnce: return OWSFormat.formatInt(1)
        case .seconds(let seconds): return OWSFormat.formatUInt32(seconds)
        }
    }

    static func menuTitle(for choice: TellomiViewOnceChoice?) -> String {
        switch choice {
        case .viewOnce:
            return OWSLocalizedString("IMAGE_PICKER_TELLOMI_TIMER_VIEW_ONCE", comment: "Item in the photo picker's self-destruct timer menu: the photo or video can be opened once.")
        case .seconds(let seconds):
            return String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString("IMAGE_PICKER_TELLOMI_TIMER_SECONDS_FORMAT", comment: "Item in the photo picker's self-destruct timer menu: the photo or video stays open this many seconds after it is opened. Embeds {{ number of seconds }}."),
                OWSFormat.formatUInt32(seconds),
            )
        case nil:
            return OWSLocalizedString("IMAGE_PICKER_TELLOMI_TIMER_DO_NOT_DELETE", comment: "Item in the photo picker's self-destruct timer menu: the photo or video is sent normally and stays in the chat.")
        }
    }

    static var menuHeader: String {
        OWSLocalizedString("IMAGE_PICKER_TELLOMI_TIMER_MENU_TITLE", comment: "Explanation at the top of the photo picker's self-destruct timer menu.")
    }

    static var buttonAccessibilityLabel: String {
        OWSLocalizedString("IMAGE_PICKER_TELLOMI_TIMER_BUTTON", comment: "Accessibility label of the self-destruct timer button in the photo picker's album viewer.")
    }

    /// 选了值变了之后的提示（ADR-0079 §4.4 第 1 条），照片、视频分开说。
    static func toastText(for choice: TellomiViewOnceChoice?, isVideo: Bool) -> String {
        switch (choice, isVideo) {
        case (.viewOnce, false):
            return OWSLocalizedString("IMAGE_PICKER_TELLOMI_TIMER_TOAST_PHOTO_VIEW_ONCE", comment: "Toast after setting a photo in the photo picker to view once.")
        case (.viewOnce, true):
            return OWSLocalizedString("IMAGE_PICKER_TELLOMI_TIMER_TOAST_VIDEO_VIEW_ONCE", comment: "Toast after setting a video in the photo picker to view once.")
        case (.seconds(let seconds), false):
            return String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString("IMAGE_PICKER_TELLOMI_TIMER_TOAST_PHOTO_SECONDS_FORMAT", comment: "Toast after setting a self-destruct timer on a photo in the photo picker. Embeds {{ number of seconds }}."),
                OWSFormat.formatUInt32(seconds),
            )
        case (.seconds(let seconds), true):
            return String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString("IMAGE_PICKER_TELLOMI_TIMER_TOAST_VIDEO_SECONDS_FORMAT", comment: "Toast after setting a self-destruct timer on a video in the photo picker. Embeds {{ number of seconds }}."),
                OWSFormat.formatUInt32(seconds),
            )
        case (nil, false):
            return OWSLocalizedString("IMAGE_PICKER_TELLOMI_TIMER_TOAST_PHOTO_KEEP", comment: "Toast after turning the self-destruct timer off for a photo in the photo picker: it stays in the chat.")
        case (nil, true):
            return OWSLocalizedString("IMAGE_PICKER_TELLOMI_TIMER_TOAST_VIDEO_KEEP", comment: "Toast after turning the self-destruct timer off for a video in the photo picker: it stays in the chat.")
        }
    }
}
