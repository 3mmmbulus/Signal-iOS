//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（pinned-messages.md 3.5 / 3.6）：取消了置顶、还没真的生效的那几条（单条取消，或置顶列表里的「取消所有置顶」）。
///
/// - 「撤销」的 5 秒里：置顶栏上已经没有它们，还能撤销；
/// - 5 秒过了：发出去。发出去以后、置顶真的没了以前，栏上仍然没有它们（不会先跳回来再消失）；发不出去就放回栏上；
/// - 置顶真的没了就不再记着：以后再被置顶要回到栏上。
///
/// 两端 Telegram 都是这样延后发的（安卓 `BulletinFactory.createUnpinAllMessagesBulletin`、iOS `ChatController.performRequestedUnpinAllMessages`）。
/// 与安卓 `TellomiHeldUnpins` 同一套。
public struct TellomiHeldUnpins<ID: Hashable> {

    /// 栏上不显示的：还在等撤销的，和已经发出去、置顶还没真没了的。
    public private(set) var held = Set<ID>()

    private var undoable = Set<ID>()

    public init() {}

    public mutating func hold(_ ids: [ID]) {
        held.formUnion(ids)
        undoable.formUnion(ids)
    }

    /// 撤销：还能撤销的放回栏上；返回放回去的。
    @discardableResult
    public mutating func undo(_ ids: [ID]) -> Set<ID> {
        let back = undoable.intersection(ids)
        undoable.subtract(back)
        held.subtract(back)
        return back
    }

    /// 撤销的时间过了：还没撤销的就要发出去（栏上仍然不显示）；返回要发的。
    public mutating func commit(_ ids: [ID]) -> Set<ID> {
        let send = undoable.intersection(ids)
        undoable.subtract(send)
        return send
    }

    /// 发不出去：放回栏上。
    public mutating func failed(_ ids: [ID]) {
        held.subtract(ids)
    }

    /// 置顶的消息有变化时：发出去、置顶也真没了的不再记着。
    public mutating func prune(pinned: Set<ID>) {
        held = held.filter { undoable.contains($0) || pinned.contains($0) }
    }
}
