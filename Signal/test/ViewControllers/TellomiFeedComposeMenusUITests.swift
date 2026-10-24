//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 发布页底栏「话题」「回复」两个菜单的界面检查（UIKit，只在 Mac 上跑）：真的点菜单里的项（`UIAction.performWithSender`），
/// 看草稿、按钮上的字和菜单项的可用状态。规则本身（最多 3 个话题、回复选项默认值）在 `TellomiFeedComposeCompletionTests`。
final class TellomiFeedComposeMenusUITests: XCTestCase {

    @MainActor
    private func show(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = OWSNavigationController(rootViewController: controller)
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    @MainActor
    private func makeCompose() -> (FeedComposeViewController, UIWindow) {
        let compose = FeedComposeViewController(source: SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)) { _ in }
        let window = show(compose)
        return (compose, window)
    }

    /// 菜单（含内嵌子菜单）里所有的 `UIAction`，按显示顺序。
    private func actions(in menu: UIMenu?) -> [UIAction] {
        return (menu?.children ?? []).flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let submenu = element as? UIMenu { return actions(in: submenu) }
            return []
        }
    }

    @MainActor
    private func action(_ title: String, in button: UIButton) throws -> UIAction {
        return try XCTUnwrap(actions(in: button.menu).first { $0.title == title }, "菜单里没有「\(title)」")
    }

    // MARK: - 话题

    @MainActor
    func testTopicMenuPicksUpToThreeAndTheRestAreDisabledUntilOneIsRemoved() throws {
        guard #available(iOS 16, *) else { throw XCTSkip("UIAction.performWithSender 要 iOS 16") }
        let (compose, window) = makeCompose()
        defer { window.isHidden = true }
        let button = compose.topicButtonForTesting
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        XCTAssertEqual(button.configuration?.title, FeedComposeViewController.topicButtonTitle([]))

        let slugs = FeedTopicCatalog.slugs
        XCTAssertGreaterThan(slugs.count, FeedDraft.maxTopics)
        XCTAssertEqual(actions(in: button.menu).map(\.title), slugs.map { "#" + FeedComposeViewController.topicName($0) })
        XCTAssertTrue(actions(in: button.menu).allSatisfy { !$0.attributes.contains(.disabled) && $0.state == .off })

        let first = "#" + FeedComposeViewController.topicName(slugs[0])
        try action(first, in: button).performWithSender(nil, target: nil)
        XCTAssertEqual(compose.draft.topics, [slugs[0]])
        XCTAssertEqual(button.configuration?.title, first, "选了一个：按钮写 #名字")
        XCTAssertEqual(try action(first, in: button).state, .on)

        for slug in slugs[1..<FeedDraft.maxTopics] {
            try action("#" + FeedComposeViewController.topicName(slug), in: button).performWithSender(nil, target: nil)
        }
        XCTAssertEqual(compose.draft.topics, Array(slugs.prefix(FeedDraft.maxTopics)))
        XCTAssertEqual(button.configuration?.title, FeedComposeViewController.topicButtonTitle(Array(slugs.prefix(FeedDraft.maxTopics))))

        // 满 3 个：没选的都灰掉，选上的还能点掉
        let menuActions = actions(in: button.menu)
        for (index, item) in menuActions.enumerated() {
            if index < FeedDraft.maxTopics {
                XCTAssertEqual(item.state, .on)
                XCTAssertFalse(item.attributes.contains(.disabled))
            } else {
                XCTAssertEqual(item.state, .off)
                XCTAssertTrue(item.attributes.contains(.disabled), "\(item.title) 应该灰掉")
            }
        }
        // 菜单里点一下不关菜单，方便连选
        XCTAssertTrue(menuActions.allSatisfy { $0.attributes.contains(.keepsMenuPresented) })

        try action(first, in: button).performWithSender(nil, target: nil)
        XCTAssertEqual(compose.draft.topics, Array(slugs[1..<FeedDraft.maxTopics]))
        XCTAssertTrue(actions(in: button.menu).allSatisfy { !$0.attributes.contains(.disabled) }, "少了一个：又都能选")
    }

    // MARK: - 回复设置

    @MainActor
    func testReplyMenuChangesWhoCanReplyAndClosingCommentsDisablesTheOtherOptions() throws {
        guard #available(iOS 16, *) else { throw XCTSkip("UIAction.performWithSender 要 iOS 16") }
        let (compose, window) = makeCompose()
        defer { window.isHidden = true }
        let button = compose.replyButtonForTesting
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(compose.draft.replies, FeedReplySettings())
        XCTAssertEqual(button.configuration?.title, OWSLocalizedString("TELLOMI_FEED_COMPOSE_REPLIES", comment: ""))

        let everyone = FeedComposeViewController.replyPolicyName(.everyone)
        let friends = FeedComposeViewController.replyPolicyName(.friends)
        let following = FeedComposeViewController.replyPolicyName(.following)
        let closed = OWSLocalizedString("TELLOMI_FEED_COMPOSE_REPLIES_CLOSED", comment: "")
        let moderation = OWSLocalizedString("TELLOMI_FEED_COMPOSE_REPLIES_MODERATION", comment: "")
        XCTAssertEqual(actions(in: button.menu).map(\.title), [everyone, friends, following, closed, moderation])
        XCTAssertEqual(try action(everyone, in: button).state, .on, "默认所有人都能回复")

        try action(friends, in: button).performWithSender(nil, target: nil)
        XCTAssertEqual(compose.draft.replies.policy, .friends)
        XCTAssertEqual(button.configuration?.title, friends)
        XCTAssertEqual(try action(friends, in: button).state, .on)
        XCTAssertEqual(try action(everyone, in: button).state, .off)

        try action(moderation, in: button).performWithSender(nil, target: nil)
        XCTAssertTrue(compose.draft.replies.moderation)
        XCTAssertEqual(try action(moderation, in: button).state, .on)

        // 关闭评论：按钮写「关闭评论」，谁能回复和审核都灰掉，「关闭评论」本身还能点回来
        try action(closed, in: button).performWithSender(nil, target: nil)
        XCTAssertTrue(compose.draft.replies.commentsClosed)
        XCTAssertEqual(button.configuration?.title, closed)
        for title in [everyone, friends, following, moderation] {
            XCTAssertTrue(try action(title, in: button).attributes.contains(.disabled), "\(title) 应该灰掉")
        }
        XCTAssertFalse(try action(closed, in: button).attributes.contains(.disabled))

        try action(closed, in: button).performWithSender(nil, target: nil)
        XCTAssertFalse(compose.draft.replies.commentsClosed)
        XCTAssertEqual(compose.draft.replies.policy, .friends, "重新打开评论：之前选的还在")
        XCTAssertTrue(compose.draft.replies.moderation)
        XCTAssertEqual(button.configuration?.title, friends)
    }

    /// 编辑已发出的帖子时没有话题 / 回复入口（引擎编辑只收正文和标题）。
    @MainActor
    func testEditingHidesTheTopicAndReplyButtons() {
        let sample = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let target = FeedEditTarget(id: "mine-seed-p1", kind: "post", title: nil, text: "x", publishedAt: nil)
        let compose = FeedComposeViewController(source: sample, editTarget: target, articleDrafts: InMemoryFeedArticleDrafts(), extrasEnabled: true) { _ in }
        let window = show(compose)
        defer { window.isHidden = true }
        XCTAssertTrue(compose.topicButtonForTesting.isHidden)
        XCTAssertTrue(compose.replyButtonForTesting.isHidden)
    }
}
