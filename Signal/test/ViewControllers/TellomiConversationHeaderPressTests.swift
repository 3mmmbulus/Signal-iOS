//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalUI

/// 交互审计 A-09「顶栏标题没有按下态」（iOS）：按住名字那一列它变淡，按住头像头像变淡，松开淡回（照 Telegram iOS `ChatTitleView`）。
final class TellomiConversationHeaderPressTests: SignalBaseTest {

    @MainActor
    func testPressingTheTitleDimsItAndReleasingRestores() throws {
        let header = ConversationHeaderView(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        header.layoutIfNeeded()
        let rootStack = try XCTUnwrap(header.avatarView.superview)
        let textRows = try XCTUnwrap(header.tellomiTextRowsForTesting)
        let textPoint = CGPoint(x: textRows.frame.midX, y: textRows.frame.midY)

        header.tellomiPressBegan(at: textPoint, in: rootStack)
        XCTAssertEqual(textRows.alpha, ConversationHeaderView.tellomiPressedAlpha, accuracy: 0.001, "一按下名字那一列就淡")
        XCTAssertEqual(header.avatarView.alpha, 1, "头像不动")

        header.tellomiPressEnded()
        XCTAssertEqual(textRows.alpha, 1, accuracy: 0.001, "松开淡回（动画的终值已经写上）")
    }

    @MainActor
    func testPressingTheAvatarDimsTheAvatar() throws {
        let header = ConversationHeaderView(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        header.layoutIfNeeded()
        let rootStack = try XCTUnwrap(header.avatarView.superview)
        let avatarPoint = CGPoint(x: header.avatarView.frame.midX, y: header.avatarView.frame.midY)

        header.tellomiPressBegan(at: avatarPoint, in: rootStack)
        XCTAssertEqual(header.avatarView.alpha, ConversationHeaderView.tellomiPressedAlpha, accuracy: 0.001)
        XCTAssertEqual(header.tellomiTextRowsForTesting?.alpha, 1)

        header.tellomiPressEnded(animated: false)
        XCTAssertEqual(header.avatarView.alpha, 1)
    }
}
