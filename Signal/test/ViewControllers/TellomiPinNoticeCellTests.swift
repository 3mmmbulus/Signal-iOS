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

/// pinned-messages.md 3.7（ADR-0081 §4.2）：长按「××置顶了«…»」是回复、删除（没有选择），上面有表情条；回应在它下面居中。
/// 走会话页同一条渲染路径（`CVLoader.buildStandaloneRenderItem` + `CVCellView`，同 `TellomiLocationBubbleTests`），不连服务端。
final class TellomiPinNoticeCellTests: XCTestCase {

    private var oldContext: (any AppContext)!
    private let bob = Aci.randomForTesting()

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

    // MARK: - The long press

    @MainActor
    func testTheLongPressMenuOnAPinNoticeIsReplyAndDelete() throws {
        let (thread, notice) = try pinnedChat(keepsPinTime: true)
        let item = try itemViewModel(notice, thread: thread)
        let delegate = ActionsDelegate()

        XCTAssertEqual(MessageActions.infoMessageActions(itemViewModel: item, shouldAllowMessageSendActions: true, delegate: delegate).map(\.contextMenuTitle), ["Reply", "Delete"])
        XCTAssertEqual(MessageActions.infoMessageActions(itemViewModel: item, shouldAllowMessageSendActions: false, delegate: delegate).map(\.contextMenuTitle), ["Delete"], "can't send here")
    }

    @MainActor
    func testOtherSystemMessagesAndOldNoticesStayDeleteAndSelect() throws {
        let (thread, oldNotice) = try pinnedChat(keepsPinTime: false)
        let other = write { tx in
            let message = TSInfoMessage(
                thread: thread,
                timestamp: Date.ows_millisecondTimestamp(),
                serverGuid: nil,
                messageType: .userJoinedSignal,
                expireTimerVersion: nil,
                expiresInSeconds: 0,
                infoMessageUserInfo: nil,
            )
            message.anyInsert(transaction: tx)
            return message
        }

        for interaction in [oldNotice, other] {
            let item = try itemViewModel(interaction, thread: thread)
            XCTAssertEqual(MessageActions.infoMessageActions(itemViewModel: item, shouldAllowMessageSendActions: true, delegate: ActionsDelegate()).map(\.contextMenuTitle), ["Delete", "Select"])
        }
    }

    // MARK: - Reactions under it

    @MainActor
    func testReactionsSitCentredUnderThePinNotice() throws {
        let (thread, notice) = try pinnedChat(keepsPinTime: true)
        let bare = try host(notice, thread: thread)
        XCTAssertNil(Self.find(CVReactionCountsView.self, in: bare.cellView), "no reactions, no row")

        write { tx in
            _ = notice.recordReaction(for: self.bob, emoji: "👍", sentAtTimestamp: 3000, receivedAtTimestamp: 3000, tx: tx)
        }
        let reacted = try host(notice, thread: thread)
        let pills = try XCTUnwrap(Self.find(CVReactionCountsView.self, in: reacted.cellView))
        let text = try XCTUnwrap((reacted.cellView.componentView as? CVComponentSystemMessage.CVComponentViewSystemMessage)?.textLabel.view)

        let pillsFrame = pills.convert(pills.bounds, to: reacted.cellView)
        let textFrame = text.convert(text.bounds, to: reacted.cellView)
        XCTAssertGreaterThan(pillsFrame.size.width, 0)
        XCTAssertEqual(pillsFrame.midX, reacted.cellView.bounds.midX, accuracy: 1, "centred, as under a service message in both Telegram apps")
        XCTAssertGreaterThanOrEqual(pillsFrame.minY, textFrame.maxY, "under the notice")
        XCTAssertGreaterThan(reacted.cellView.bounds.size.height, bare.cellView.bounds.size.height)
    }

    // MARK: - Helpers

    /// Bob's message and his pin of it; `keepsPinTime: false` is a notice from before iOS kept when the pin was sent.
    private func pinnedChat(keepsPinTime: Bool) throws -> (TSThread, TSInfoMessage) {
        return write { tx in
            let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(self.bob), transaction: tx)
            var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: self.bob, tx: tx)
            SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            let message = TSIncomingMessageBuilder.withDefaultValues(
                thread: thread,
                timestamp: 1000,
                authorAci: self.bob,
                messageBody: DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                    MessageBody(text: "Lunch at noon", ranges: .empty),
                    tx: tx,
                ),
            ).build()
            message.anyInsert(transaction: tx)
            let notice = DependenciesBridge.shared.pinnedMessageManager.insertInfoMessageForPinnedMessage(
                timestamp: Date.ows_millisecondTimestamp(),
                thread: thread,
                targetMessageTimestamp: 1000,
                targetMessageAuthor: self.bob,
                pinAuthor: self.bob,
                tellomiPinSentTimestamp: keepsPinTime ? 2000 : nil,
                expireTimer: 0,
                expireTimerVersion: 0,
                tx: tx,
            )
            return (thread, notice)
        }
    }

    private func renderItem(_ interaction: TSInteraction, thread: TSThread, width: CGFloat = 402) throws -> CVRenderItem {
        return try read { tx in
            let conversationStyle = ConversationStyle(
                type: .`default`,
                thread: thread,
                viewWidth: width,
                hasWallpaper: false,
                shouldDimWallpaperInDarkMode: false,
                chatColor: DependenciesBridge.shared.chatColorSettingStore.resolvedChatColor(for: thread, tx: tx),
            )
            let latest = try XCTUnwrap(TSInteraction.anyFetch(uniqueId: interaction.uniqueId, transaction: tx))
            return try XCTUnwrap(CVLoader.buildStandaloneRenderItem(
                interaction: latest,
                thread: thread,
                conversationStyle: conversationStyle,
                spoilerState: SpoilerRenderState(),
                groupNameColors: GroupNameColors.forThread(thread),
                transaction: tx,
            ))
        }
    }

    @MainActor
    private func itemViewModel(_ interaction: TSInteraction, thread: TSThread) throws -> CVItemViewModelImpl {
        return CVItemViewModelImpl(renderItem: try renderItem(interaction, thread: thread))
    }

    private struct Hosted {
        let cellView: CVCellView
        let delegate: MockConversationView
    }

    @MainActor
    private func host(_ interaction: TSInteraction, thread: TSThread, width: CGFloat = 402) throws -> Hosted {
        let renderItem = try renderItem(interaction, thread: thread, width: width)
        let delegate = MockConversationView(model: .init(items: []), hasWallpaper: false, customChatColor: nil)
        let height = renderItem.cellMeasurement.cellSize.height
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 150, width: width, height: height + 24))
        let cellView = CVCellView()
        cellView.configure(renderItem: renderItem, componentDelegate: delegate)
        cellView.frame = CGRect(x: 0, y: 12, width: width, height: height)
        window.addSubview(cellView)
        window.isHidden = false
        cellView.isCellVisible = true
        window.layoutIfNeeded()
        return Hosted(cellView: cellView, delegate: delegate)
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        for subview in view.subviews {
            if let match = subview as? T, match.superview != nil, !match.isHidden {
                return match
            }
            if let match = find(type, in: subview) {
                return match
            }
        }
        return nil
    }

    private final class ActionsDelegate: MessageActionsDelegate {
        func messageActionsShowDetailsForItem(_ itemViewModel: CVItemViewModelImpl) {}
        func messageActionsReplyToItem(_ itemViewModel: CVItemViewModelImpl) {}
        func messageActionsForwardItem(_ itemViewModel: CVItemViewModelImpl) {}
        func messageActionsStartedSelect(initialItem itemViewModel: CVItemViewModelImpl) {}
        func messageActionsDeleteItem(_ itemViewModel: CVItemViewModelImpl) {}
        func messageActionsSpeakItem(_ itemViewModel: CVItemViewModelImpl) {}
        func messageActionsStopSpeakingItem(_ itemViewModel: CVItemViewModelImpl) {}
        func messageActionsEditItem(_ itemViewModel: CVItemViewModelImpl) {}
        func messageActionsShowPaymentDetails(_ itemViewModel: CVItemViewModelImpl) {}
        func messageActionsEndPoll(_ itemViewModel: CVItemViewModelImpl) {}
        func messageActionsChangePinStatus(_ itemViewModel: CVItemViewModelImpl, pin: Bool) {}
        func messageActionsTellomiSaveToSavedMessages(_ itemViewModel: CVItemViewModelImpl) {}
    }
}
