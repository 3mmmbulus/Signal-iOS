//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（ADR-0081 §4.6，pinned-messages.md 3.1）：置顶时先问「给谁看」，最后一行是时长（默认永久）。与安卓 `TellomiPinChoice` 一致。
///
/// 照 Telegram iOS 长按菜单原地换成的几项（只读机制，没搬代码；`ChatControllerLoadDisplayNode.swift` 的 `pinMessage`）：
/// 单聊 `Conversation_PinMessagesFor`「为我和 ×× 置顶」/ `Conversation_PinMessagesForMe`「仅为我置顶」，没有默认项；
/// 群里 `Conversation_PinMessageAlert_PinAndNotifyMembers`「置顶并通知所有成员」/ `Conversation_PinMessageAlert_OnlyPin`（只置顶、不通知）。
/// Tellomi 在群里另加「仅为我置顶」，群里没有置顶权限的人只有这一项（spec 3.1）；我的收藏直接置顶，不问。
public enum TellomiPinChoice: Equatable {
    /// 单聊：为我和对方置顶（发给对方）。
    case forBoth
    /// 群：为所有人置顶并通知。
    case forEveryone
    /// 群：为所有人置顶，不通知（`TellomiDataMessage.pinSilent`）。
    case forEveryoneSilent
    /// 仅为我置顶：只同步给自己的设备（`TellomiDataMessage.pinForSelfOnly`），不发给对方。
    case forMe

    /// 要问的几项，按显示顺序；nil = 不问，直接置顶（我的收藏）。
    public static func choices(isNoteToSelf: Bool, isGroup: Bool, canPinForEveryone: Bool) -> [TellomiPinChoice]? {
        if isNoteToSelf {
            return nil
        }
        if !isGroup {
            return [.forBoth, .forMe]
        }
        if canPinForEveryone {
            return [.forEveryone, .forEveryoneSilent, .forMe]
        }
        return [.forMe]
    }

    /// 能不能取消这条置顶：仅为我置顶的随时能取消（只动我自己的设备，群没了也行）；
    /// 别的置顶照 Signal，要群里的置顶权限（`TSThread.canUserEditPinnedMessages`）且群还在。与安卓 `TellomiPinChoice.canUnpin` 一致。
    public static func canUnpin(isPinnedForMe: Bool, canPinForEveryone: Bool, isTerminatedGroup: Bool) -> Bool {
        return isPinnedForMe || (canPinForEveryone && !isTerminatedGroup)
    }

    /// 置顶列表底下是「取消所有置顶」还是「隐藏置顶消息」（pinned-messages.md 3.5）：每一条都能取消才是前者，否则只能在本机藏起置顶栏。
    /// 两端 Telegram 同样按能不能置顶分（安卓 `ChatActivity` `UnpinAllMessages` / `HidePinnedMessages`，iOS `ChatControllerLoadDisplayNode`
    /// `canManagePin()`）；Tellomi 多了「仅为我」的置顶，这几条总能取消。与安卓 `TellomiPinChoice.canUnpinAll` 一致。
    public static func canUnpinAll(pinnedForMe: [Bool], canPinForEveryone: Bool, isTerminatedGroup: Bool) -> Bool {
        return pinnedForMe.allSatisfy { canUnpin(isPinnedForMe: $0, canPinForEveryone: canPinForEveryone, isTerminatedGroup: isTerminatedGroup) }
    }
}
