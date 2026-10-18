//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest
@testable import SignalServiceKit

/// Tellomi（chat-telegram-parity F01）：我的消息上别人的回应，在聊天里看到之前一直记着。
class TellomiUnseenReactionsTest: SSKBaseTest {
    override func setUp() {
        super.setUp()
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    private func makeMessages(count: Int) -> (TSThread, [TSOutgoingMessage]) {
        write { tx in
            let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(phoneNumber: "+12345678900"), transaction: tx)
            let messages = (0..<count).map { index -> TSOutgoingMessage in
                let builder: TSOutgoingMessageBuilder = .withDefaultValues(
                    thread: thread,
                    messageBody: AttachmentContentValidatorMock.mockValidatedBody("message \(index)"),
                )
                let message = TSOutgoingMessage(outgoingMessageWith: builder, recipientAddressStates: [:])
                message.anyInsert(transaction: tx)
                return message
            }
            return (thread, messages)
        }
    }

    private func react(_ message: TSOutgoingMessage, by reactor: Aci, emoji: String = "👍") {
        write { tx in
            _ = message.recordReaction(for: reactor, emoji: emoji, sentAtTimestamp: 1, receivedAtTimestamp: 1, tx: tx)
        }
    }

    private func unseen(_ thread: TSThread) -> [String] {
        var ids = [String]()
        read { tx in ids = TellomiUnseenReactions.unseenMessageIds(threadUniqueId: thread.uniqueId, tx: tx) }
        return ids
    }

    func testSomeoneElsesReactionIsRememberedOldestFirst() {
        let (thread, messages) = makeMessages(count: 3)
        let bob = Aci.randomForTesting()

        react(messages[2], by: bob)
        react(messages[0], by: bob)

        XCTAssertEqual(unseen(thread), [messages[0].uniqueId, messages[2].uniqueId])
    }

    func testMyOwnReactionIsNotRemembered() {
        let (thread, messages) = makeMessages(count: 1)

        react(messages[0], by: LocalIdentifiers.forUnitTests.aci)

        XCTAssertEqual(unseen(thread), [])
    }

    func testSeenOnesAreCrossedOff() {
        let (thread, messages) = makeMessages(count: 2)
        let bob = Aci.randomForTesting()
        react(messages[0], by: bob)
        react(messages[1], by: bob)

        write { tx in TellomiUnseenReactions.markSeen(messageUniqueIds: [messages[0].uniqueId], threadUniqueId: thread.uniqueId, tx: tx) }
        XCTAssertEqual(unseen(thread), [messages[1].uniqueId])

        write { tx in TellomiUnseenReactions.markAllSeen(threadUniqueId: thread.uniqueId, tx: tx) }
        XCTAssertEqual(unseen(thread), [])
    }

    func testTakingTheOnlyReactionBackForgetsIt() {
        let (thread, messages) = makeMessages(count: 1)
        let bob = Aci.randomForTesting()
        react(messages[0], by: bob)

        write { tx in _ = messages[0].removeReaction(for: bob, tx: tx) }

        XCTAssertEqual(unseen(thread), [])
    }

    func testChangingTheEmojiKeepsItUnseen() {
        let (thread, messages) = makeMessages(count: 1)
        let bob = Aci.randomForTesting()
        react(messages[0], by: bob, emoji: "👍")

        react(messages[0], by: bob, emoji: "❤️")

        XCTAssertEqual(unseen(thread), [messages[0].uniqueId])
        var latest: String?
        read { tx in latest = TellomiUnseenReactions.latestEmojiFromOthers(messageUniqueId: messages[0].uniqueId, tx: tx) }
        XCTAssertEqual(latest, "❤️")
    }

    func testOverTheCapDropsTheEarliestRecorded() {
        XCTAssertEqual(TellomiUnseenReactions.adding("d", to: ["a", "b", "c"], max: 3), ["b", "c", "d"])
        XCTAssertEqual(TellomiUnseenReactions.adding("b", to: ["a", "b"], max: 3), ["a", "b"])
    }
}
