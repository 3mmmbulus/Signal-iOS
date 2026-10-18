//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// pinned-messages.md 3.5：置顶列表——「N 条置顶消息」、按消息在会话里的先后（不按置顶的先后）、「仅为我」的下面「仅自己可见」、
/// 底下是「取消所有置顶」还是「隐藏置顶消息」。会话页在单测里建不起来，置顶列表可以：真的数据库、真的渲染
/// （`CVLoader.buildStandaloneRenderItem`，同 `TellomiAsFileCellTests`），不连服务端。
final class TellomiPinnedMessagesListTests: XCTestCase {

    private var oldContext: (any AppContext)!

    @MainActor
    override func setUp() {
        super.setUp()
        let setupExpectation = expectation(description: "mock ssk environment setup completed")
        self.oldContext = CurrentAppContext()
        Task {
            let appReadiness = AppReadinessImpl()
            await MockSSKEnvironment.activate(
                appReadiness: appReadiness,
                testDependencies: AppSetup.TestDependencies(
                    groupV2Updates: MockGroupV2Updates(),
                    groupsV2: MockGroupsV2(),
                    messageSender: FakeMessageSender(),
                    networkManager: OWSFakeNetworkManager(appReadiness: appReadiness, netProvider: nil),
                    paymentsCurrencies: MockPaymentsCurrencies(),
                    paymentsHelper: MockPaymentsHelper(),
                    pendingReceiptRecorder: NoopPendingReceiptRecorder(),
                    reachabilityManager: MockSSKReachabilityManager(),
                    remoteConfigManager: StubbableRemoteConfigManager(),
                    signalService: OWSSignalServiceMock(),
                    storageServiceManager: FakeStorageServiceManager(),
                    syncManager: OWSMockSyncManager(),
                    systemStoryManager: SystemStoryManagerMock(),
                    versionedProfiles: MockVersionedProfiles(),
                    webSocketFactory: WebSocketFactoryMock(),
                ),
            )
            setupExpectation.fulfill()
        }
        waitForExpectations(timeout: 30)

        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    @MainActor
    override func tearDown() {
        UIWindow.tellomiDetachTestWindows()
        MockSSKEnvironment.deactivate(oldContext: self.oldContext)
        super.tearDown()
    }

    private func read<T>(block: (DBReadTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.read(block: block)
    }

    private func write<T>(block: (DBWriteTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.write(block: block)
    }

    private final class Delegate: PinnedMessageInteractionManagerDelegate {
        var wentTo: [String] = []
        var unpinnedAll = 0
        var hid = 0

        func goToMessage(message: TSMessage?) { wentTo.append(message?.uniqueId ?? "") }
        func unpinMessage(message: TSMessage?, modalDelegate: UIViewController?) {}
        func presentSeeAllMessages() {}
        func unpinAllMessages() { unpinnedAll += 1 }
        func tellomiClosePinnedBar() {}
        func tellomiHidePinnedMessages() { hid += 1 }
    }

    /// 三条收到的消息（最早的在前），按 `pinOrder` 里的先后置顶；`forMe` 里的「仅为我」。没加白名单的会话还是消息请求，不能为双方取消置顶。
    private func pinnedChat(whitelisted: Bool, pinOrder: [Int], forMe: Set<Int>) throws -> (TSContactThread, [TSIncomingMessage]) {
        return try write { tx in
            let thread = ContactThreadFactory().create(transaction: tx)
            let authorAci = try XCTUnwrap(thread.contactAddress.aci)
            if whitelisted {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: authorAci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            let now = Date.ows_millisecondTimestamp()
            let messages = ["Lunch at noon", "Bring the slides", "Room 4B"].enumerated().map { index, text in
                let message = TSIncomingMessageBuilder.withDefaultValues(
                    thread: thread,
                    timestamp: now - 60_000 + UInt64(index) * 1000,
                    authorAci: authorAci,
                    messageBody: DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                        MessageBody(text: text, ranges: .empty),
                        tx: tx,
                    ),
                ).build()
                message.anyInsert(transaction: tx)
                return message
            }
            for (step, index) in pinOrder.enumerated() {
                let interactionId = try XCTUnwrap(messages[index].sqliteRowId)
                _ = try PinnedMessageRecord.insertRecord(
                    interactionId: interactionId,
                    threadId: try XCTUnwrap(thread.sqliteRowId),
                    sentTimestamp: now + UInt64(step),
                    receivedTimestamp: now + UInt64(step),
                    tx: tx,
                )
                if forMe.contains(index) {
                    TellomiPinsForMe.remember(interactionId: interactionId, tx: tx)
                }
            }
            return (thread, messages)
        }
    }

    @MainActor
    private func present(_ thread: TSThread, delegate: Delegate) -> PinnedMessagesDetailsViewController {
        let threadViewModel = read { tx in ThreadViewModel(threadUniqueId: thread.uniqueId, forChatList: false, transaction: tx) }
        let list = PinnedMessagesDetailsViewController(
            pinnedMessages: threadViewModel.pinnedMessages,
            threadViewModel: threadViewModel,
            database: DependenciesBridge.shared.db,
            delegate: delegate,
            databaseChangeObserver: DependenciesBridge.shared.databaseChangeObserver,
            pinnedMessageManager: DependenciesBridge.shared.pinnedMessageManager,
            spoilerState: SpoilerRenderState(),
        )
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: list)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return list
    }

    private func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        return view.subviews.flatMap { subview -> [T] in
            if let match = subview as? T {
                return [match]
            }
            return all(type, in: subview)
        }
    }

    private func y(_ view: UIView) -> CGFloat {
        return view.convert(view.bounds, to: nil).minY
    }

    @MainActor
    func testTitleChatOrderAndOnlyVisibleToYou() throws {
        // Pinned newest first, then the oldest, then the middle one; the middle one is mine only.
        let (thread, messages) = try pinnedChat(whitelisted: true, pinOrder: [2, 0, 1], forMe: [1])
        let delegate = Delegate()
        let list = present(thread, delegate: delegate)

        let title = try XCTUnwrap((list.navigationItem.titleView as? UIStackView)?.arrangedSubviews.first as? UILabel)
        XCTAssertEqual(title.text, "3 pinned messages")

        let goTo = all(UIButton.self, in: list.view)
            .filter { $0.bounds.size == CGSize(width: PinnedMessagesDetailsViewController.goToMessageButtonSize, height: PinnedMessagesDetailsViewController.goToMessageButtonSize) }
            .sorted { y($0) < y($1) }
        XCTAssertEqual(goTo.count, 3)
        goTo.forEach { $0.sendActions(for: .primaryActionTriggered) }
        XCTAssertEqual(delegate.wentTo, messages.map(\.uniqueId), "top to bottom in chat order, not pin order")

        let onlyYou = all(UILabel.self, in: list.view).filter { $0.text == "Only visible to you" }
        XCTAssertEqual(onlyYou.count, 1)
        let label = try XCTUnwrap(onlyYou.first)
        XCTAssertGreaterThan(y(label), y(goTo[1]), "under the second message…")
        XCTAssertLessThan(y(label), y(goTo[2]), "…before the third")

        let bottom = try XCTUnwrap(all(UIButton.self, in: list.view).first { $0.configuration?.title == "Unpin all messages" })
        bottom.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(delegate.unpinnedAll, 1)
        XCTAssertEqual(delegate.hid, 0)
    }

    @MainActor
    func testWithoutPermissionTheButtonHidesThemUnlessAllAreMineOnly() throws {
        let (someoneElses, _) = try pinnedChat(whitelisted: false, pinOrder: [0, 1], forMe: [0])
        let delegate = Delegate()
        let list = present(someoneElses, delegate: delegate)
        XCTAssertNil(all(UIButton.self, in: list.view).first { $0.configuration?.title == "Unpin all messages" })
        let hide = try XCTUnwrap(all(UIButton.self, in: list.view).first { $0.configuration?.title == "Hide pinned messages" })
        hide.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(delegate.hid, 1)
        XCTAssertEqual(delegate.unpinnedAll, 0)

        let (allMine, _) = try pinnedChat(whitelisted: false, pinOrder: [0, 1], forMe: [0, 1])
        let mine = present(allMine, delegate: Delegate())
        XCTAssertNotNil(all(UIButton.self, in: mine.view).first { $0.configuration?.title == "Unpin all messages" }, "pins for me only can always be unpinned")
    }
}
