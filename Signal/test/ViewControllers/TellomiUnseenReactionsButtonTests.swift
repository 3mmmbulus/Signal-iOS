//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal

/// chat-telegram-parity F01 / F02（iOS）：回应按钮、提及按钮什么时候出现、怎么叠；回应那一行露出来才算看到。
final class TellomiUnseenReactionsButtonTests: XCTestCase {

    private typealias Layout = ConversationViewController.TellomiScrollButtonsLayout

    func testAtTheBottomTheMentionAndReactionButtonsStillShowAndCloseUp() {
        let layout = ConversationViewController.tellomiScrollButtonsLayout(
            shouldScrollDownAppear: false,
            isSuppressed: false,
            unreadMentionCount: 1,
            unseenReactionCount: 2,
        )

        XCTAssertEqual(layout, Layout(scrollDownHidden: true, mentionHidden: false, reactionHidden: false, mentionStack: 0, reactionStack: -70))
    }

    func testScrolledUpEverythingStacksAboveScrollDown() {
        let layout = ConversationViewController.tellomiScrollButtonsLayout(
            shouldScrollDownAppear: true,
            isSuppressed: false,
            unreadMentionCount: 1,
            unseenReactionCount: 1,
        )

        XCTAssertEqual(layout, Layout(scrollDownHidden: false, mentionHidden: false, reactionHidden: false, mentionStack: -70, reactionStack: -70))
    }

    func testWithoutMentionsTheReactionButtonTakesTheMentionSlot() {
        let layout = ConversationViewController.tellomiScrollButtonsLayout(
            shouldScrollDownAppear: true,
            isSuppressed: false,
            unreadMentionCount: 0,
            unseenReactionCount: 3,
        )

        XCTAssertTrue(layout.mentionHidden)
        XCTAssertFalse(layout.reactionHidden)
        XCTAssertEqual(layout.mentionStack, -70, "the hidden mention slot sits above scroll down")
        XCTAssertEqual(layout.reactionStack, 0, "so the reaction button lands right above scroll down")
    }

    func testRecordingOrPreviewHidesAllThree() {
        let layout = ConversationViewController.tellomiScrollButtonsLayout(
            shouldScrollDownAppear: true,
            isSuppressed: true,
            unreadMentionCount: 1,
            unseenReactionCount: 1,
        )

        XCTAssertTrue(layout.scrollDownHidden && layout.mentionHidden && layout.reactionHidden)
    }

    func testReactionRowCountsAsSeenOnlyWhenOnScreen() {
        let visible = CGRect(x: 0, y: 100, width: 390, height: 600)
        func onScreen(_ minY: CGFloat, height: CGFloat = 30) -> Bool {
            ConversationViewController.tellomiReactionRowIsOnScreen(CGRect(x: 0, y: minY, width: 100, height: height), visible: visible)
        }

        XCTAssertTrue(onScreen(300))
        XCTAssertFalse(onScreen(90), "top edge still under the navigation bar")
        XCTAssertTrue(onScreen(700 - 30 + 15), "bottom 15 pt under the input bar is allowed")
        XCTAssertFalse(onScreen(700 - 30 + 17), "more than 16 pt under the input bar is not")
    }
}
