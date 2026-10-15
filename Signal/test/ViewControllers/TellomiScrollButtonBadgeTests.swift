//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalUI

/// 交互审计 A-14（iOS 半边）：「滚到底」按钮的未读角标——一开始藏着；按钮看得见时数字变了滚动换上、0 ↔ 有数时弹出 / 缩回；
/// 按钮看不见时直接换。照 Telegram iOS `ChatHistoryNavigationButtonNode`。
final class TellomiScrollButtonBadgeTests: XCTestCase {

    @MainActor
    func testBadgeAnimatesOnlyWhileTheButtonIsOnScreen() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }

        let button = ConversationScrollButton(iconName: "chevron-down")
        XCTAssertFalse(button.isUnreadBadgeShownForTesting, "没有未读时角标藏着（不再等第一次设数）")

        // 按钮还不在窗口里：直接换，不做动画
        button.unreadCount = 2
        XCTAssertTrue(button.isUnreadBadgeShownForTesting)
        XCTAssertEqual(button.unreadBadgeAlphaForTesting, 1)
        XCTAssertFalse(button.isRollingUnreadCountForTesting)

        root.view.addSubview(button)
        button.frame = CGRect(x: 100, y: 600, width: 40, height: 40)

        button.unreadCount = 5
        XCTAssertEqual(button.unreadTextForTesting, "5")
        XCTAssertTrue(button.isRollingUnreadCountForTesting, "看得见时数字滚动换上")

        button.unreadCount = 0
        XCTAssertTrue(button.isUnreadBadgeShownForTesting, "缩回去的过程中还在")
        let hidden = await waitUntil { !button.isUnreadBadgeShownForTesting }
        XCTAssertTrue(hidden, "缩回完了藏起来")
        XCTAssertEqual(button.unreadBadgeAlphaForTesting, 1, "藏起来以后复原，下次直接从 0.5 倍弹出")

        button.unreadCount = 1
        XCTAssertTrue(button.isUnreadBadgeShownForTesting)
        XCTAssertEqual(button.unreadTextForTesting, "1")
        XCTAssertFalse(button.isRollingUnreadCountForTesting, "0 → 有数是弹出，不是滚数字")

        // 中途反向：刚开始缩回又有了新未读，角标不能被上一段的收尾藏掉
        button.unreadCount = 0
        button.unreadCount = 3
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(button.isUnreadBadgeShownForTesting)
        XCTAssertEqual(button.unreadTextForTesting, "3")
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}
