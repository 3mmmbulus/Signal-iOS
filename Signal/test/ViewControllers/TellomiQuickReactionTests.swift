//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（owner 2026-09-24 C-01）：双击别人的消息 = 用回应条上第一个表情快速回应，再双击撤回（照 Telegram 两端）；
/// 双击自己的消息照旧是编辑。
@MainActor
final class TellomiQuickReactionTests: SignalBaseTest {

    /// 只有别人的消息双击回应；自己的消息双击照旧是上游的编辑（C-01「保留 Signal」）。
    func testOnlySomeoneElsesMessageReactsOnDoubleTap() {
        let (incoming, outgoing) = SSKEnvironment.shared.databaseStorageRef.write { tx in
            (IncomingMessageFactory().create(transaction: tx), OutgoingMessageFactory().create(transaction: tx))
        }
        XCTAssertTrue(ConversationViewController.tellomiDoubleTapReacts(to: incoming))
        XCTAssertFalse(ConversationViewController.tellomiDoubleTapReacts(to: outgoing))
    }

    func testDoubleTapAddsTheQuickReaction() {
        let result = ConversationViewController.tellomiQuickReaction(quickEmoji: "❤️", myEmoji: nil)
        XCTAssertEqual(result.emoji, "❤️")
        XCTAssertFalse(result.isRemoving)
    }

    /// 已经用它回应过：再双击撤回（Telegram 同样）。
    func testDoubleTapAgainTakesItBack() {
        let result = ConversationViewController.tellomiQuickReaction(quickEmoji: "❤️", myEmoji: "❤️")
        XCTAssertTrue(result.isRemoving)
    }

    /// 回应过别的：换成快速回应（一个人一条消息只有一个回应）。
    func testDoubleTapOverAnotherReactionReplacesIt() {
        let result = ConversationViewController.tellomiQuickReaction(quickEmoji: "❤️", myEmoji: "👍")
        XCTAssertEqual(result.emoji, "❤️")
        XCTAssertFalse(result.isRemoving)
    }

    /// 条上的表情是规范化过的写法；我的回应要换成同一种写法再比（带肤色的同一个手势算同一个）。
    func testMyReactionIsComparedInTheBarsNormalForm() throws {
        let raised = try XCTUnwrap(EmojiWithSkinTones(rawValue: "👍🏽")?.rawValue)
        let result = ConversationViewController.tellomiQuickReaction(quickEmoji: raised, myEmoji: "👍🏽")
        XCTAssertTrue(result.isRemoving)
    }

    /// 快速回应的表情是条上第一个：没改过就是 Signal 默认的第一个（❤️），改过就是用户的第一个。
    func testTheQuickReactionIsTheFirstEmojiOnTheBar() {
        XCTAssertEqual(ContextMenuReactionBarAccessory.quickReactionEmoji(), EmojiWithSkinTones(rawValue: ReactionManager.defaultEmojiSet[0])?.rawValue)

        SSKEnvironment.shared.databaseStorageRef.write { tx in
            ReactionManager.setCustomEmojiSet(["🔥", "👍", "👎", "😂", "😮", "😢"], transaction: tx)
        }
        XCTAssertEqual(ContextMenuReactionBarAccessory.quickReactionEmoji(), "🔥")
    }
}
