//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（pinned-messages.md 3.4）：会话顶上的置顶栏显示哪一条、标题、左边的竖线。置顶按消息在会话里的先后排（最早的在前，`sortId`），
/// 不按什么时候置顶的排——两端 Telegram 都这样。与安卓 `TellomiPinnedBar` 一致。
///
/// 照 Telegram 两端（只读机制，没搬代码）：
/// - 显示哪一条：屏幕上最新那条消息之前（含）最新的一条置顶；都比它新就显示最早的。iOS `ChatController.swift` 的
///   置顶信号（按可见范围上界取 `id ≤` 的最新一条）；安卓 `ChatActivity.findClosest`（`maxVisibleId`）。
/// - 点一下：跳到正显示的这条，然后换成更早的一条，最早的之后回到最新的。iOS `scrolledToMessageIdValue` 之后取更早的一条、
///   最早的回到最新；安卓 `forceNextPinnedMessageId = currentPinned - 1`。
/// - 标题：只有一条「置顶消息」；两条时较早的那条是「上一条置顶」；多于两条时最新的不带编号，其余「置顶消息 #N」，最早的是 #1。
///   iOS `ChatPinnedMessageTitlePanelNode`（`Conversation_PinnedMessage` / `Conversation_PinnedPreviousMessage` / `#N`）；
///   安卓 `ChatActivity` 标题 + `NumberTextView` 计数。
/// - 竖线：最早的在上；多于 3 条只露 3 段，选中的尽量在中间，上下有更多时渐隐。安卓 `PinnedLineView`（最多 3 格、渐隐）；
///   iOS `AnimatedNavigationStripeNode` 多了也滚动、两端渐隐。
public enum TellomiPinnedBar {

    /// 竖线最多露几段。
    public static let visibleSegments = 3

    public enum Title: Equatable {
        case pinned
        case previous
        case numbered(Int)
    }

    /// 竖线露出来的那几段：从第 `first` 段起 `count` 段，上 / 下还有没露出来的就渐隐。
    public struct Segments: Equatable {
        public let first: Int
        public let count: Int
        public let fadeTop: Bool
        public let fadeBottom: Bool
    }

    /// 滚动时显示哪一条：`pinPositions`（最早的在前）里不晚于 `newestVisible` 的最新一条；都更晚就是最早的那条。
    public static func pinFor(_ pinPositions: [UInt64], newestVisible: UInt64) -> Int {
        return pinPositions.lastIndex(where: { $0 <= newestVisible }) ?? 0
    }

    /// 点了第 `index` 条（跳过去）之后显示的那条：更早的一条，最早的之后是最新的。
    public static func nextAfterTap(_ index: Int, count: Int) -> Int {
        return index <= 0 ? count - 1 : index - 1
    }

    public static func title(_ index: Int, count: Int) -> Title {
        if count <= 1 || index == count - 1 {
            return .pinned
        }
        if count == 2 {
            return .previous
        }
        return .numbered(index + 1)
    }

    public static func segments(_ index: Int, count: Int) -> Segments {
        if count <= visibleSegments {
            return Segments(first: 0, count: count, fadeTop: false, fadeBottom: false)
        }
        let first = min(max(index - 1, 0), count - visibleSegments)
        return Segments(first: first, count: visibleSegments, fadeTop: first > 0, fadeBottom: first + visibleSegments < count)
    }

    /// 点过之后定住的那一条什么时候放开，回到跟着滚动走：用户自己往新消息那边拖就放开；往旧消息那边拖，拖过了那一条才放开
    /// （安卓 `ChatActivity` 拖动时清掉 `forceNextPinnedMessageId` 的两种情况；iOS 同样）。跳转本身的滚动不算。
    public static func releasesForcedPin(
        userDragging: Bool,
        newestVisibleBefore: UInt64,
        newestVisibleNow: UInt64,
        forcedPinPosition: UInt64,
    ) -> Bool {
        guard userDragging else {
            return false
        }
        return newestVisibleNow > newestVisibleBefore || newestVisibleNow < forcedPinPosition
    }

    // MARK: - × without the permission to unpin

    private static let hiddenStore = NewKeyValueStore(collection: "TellomiPinnedBarHidden")

    /// 群里没有置顶权限的人点置顶栏的 ×，只在本机藏起置顶栏，直到又有新的置顶——记下藏的时候最新（会话里最靠后）那条置顶，
    /// 最新那条还是它就一直藏着（两端 Telegram 同样：iOS `closedPinnedMessageId`，安卓 `pin_<会话>`）。只在本机，不进备份。
    /// 与安卓 `TellomiPinnedBarValues` 一致。
    public static func isHidden(threadUniqueId: String, newestPinRowId: Int64, tx: DBReadTransaction) -> Bool {
        return hiddenStore.fetchValue(Int64.self, forKey: threadUniqueId, tx: tx) == newestPinRowId
    }

    public static func hide(threadUniqueId: String, newestPinRowId: Int64, tx: DBWriteTransaction) {
        hiddenStore.writeValue(newestPinRowId, forKey: threadUniqueId, tx: tx)
    }
}
