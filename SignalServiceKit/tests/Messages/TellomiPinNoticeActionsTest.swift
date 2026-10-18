//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import SignalServiceKit

/// Tellomi (ADR-0081 §4.2, pinned-messages.md 3.7): "×× pinned «…»" can be reacted to, replied to and deleted, as in both
/// Telegram apps. A quote, a reaction or a delete names it by who pinned and when the pin was sent; iOS keeps that time on the
/// notice. The same cases as Android's `TellomiPinNoticeActionsTest`. Real `PinnedMessageManager` and database.
class TellomiPinNoticeActionsTest: SSKBaseTest {

    private let bob = Aci.randomForTesting()

    private var pinnedMessageManager: PinnedMessageManager {
        DependenciesBridge.shared.pinnedMessageManager
    }

    override func setUp() {
        super.setUp()
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    // MARK: - Named by who pinned and when

    func testHisPinsNoticeIsNamedByHimAndThePinsSentTime() throws {
        let (thread, _) = insertFromBob("Lunch at noon", timestamp: 1000)

        let notice = try XCTUnwrap(try write { tx in
            try self.pinnedMessageManager.pinMessage(
                pinMessageProto: self.pin(target: 1000),
                pinAuthor: self.bob,
                thread: thread,
                pinSentAtTimestamp: 2000,
                expireTimer: 0,
                expireTimerVersion: 0,
                transaction: tx,
            )
        })

        read { tx in
            let finder = InteractionFinder(threadUniqueId: thread.uniqueId)
            let identity = notice.tellomiPinNoticeIdentity
            XCTAssertEqual(identity?.pinner, self.bob)
            XCTAssertEqual(identity?.pinSentTimestamp, 2000)
            XCTAssertEqual(finder.tellomiPinNotice(pinner: self.bob, pinSentTimestamp: 2000, tx: tx)?.uniqueId, notice.uniqueId)
            XCTAssertNil(finder.tellomiPinNotice(pinner: self.bob, pinSentTimestamp: 2001, tx: tx))
            XCTAssertNil(finder.tellomiPinNotice(pinner: LocalIdentifiers.forUnitTests.aci, pinSentTimestamp: 2000, tx: tx))
        }
    }

    func testMyPinsNoticeIsNamedByMeAndThePinMessagesSentTime() throws {
        let (thread, _) = insertFromBob("See you there", timestamp: 1000)

        write { tx in
            self.pinnedMessageManager.applyPinMessageChangeToLocalState(
                targetTimestamp: 1000,
                targetAuthorAci: self.bob,
                expiresAt: nil,
                isPin: true,
                sentTimestamp: 3000,
                threadUniqueId: thread.uniqueId,
                tx: tx,
            )
        }

        read { tx in
            let notice = InteractionFinder(threadUniqueId: thread.uniqueId).tellomiPinNotice(pinner: LocalIdentifiers.forUnitTests.aci, pinSentTimestamp: 3000, tx: tx)
            XCTAssertNotNil(notice)
            XCTAssertEqual(notice?.tellomiPinNoticeIdentity?.pinner, LocalIdentifiers.forUnitTests.aci)
        }
    }

    func testANoticeFromBeforeTheTimeWasKeptCantBeNamed() {
        let (thread, _) = insertFromBob("Old pin", timestamp: 1000)

        let notice = write { tx in
            self.pinnedMessageManager.insertInfoMessageForPinnedMessage(
                timestamp: 5000,
                thread: thread,
                targetMessageTimestamp: 1000,
                targetMessageAuthor: self.bob,
                pinAuthor: self.bob,
                tellomiPinSentTimestamp: nil,
                expireTimer: 0,
                expireTimerVersion: 0,
                tx: tx,
            )
        }

        read { tx in
            let stored = TSInteraction.anyFetch(uniqueId: notice.uniqueId, transaction: tx) as? TSInfoMessage
            XCTAssertNotNil(stored)
            XCTAssertNil(stored?.tellomiPinNoticeIdentity)
            XCTAssertNil(InteractionFinder(threadUniqueId: thread.uniqueId).tellomiPinNotice(pinner: self.bob, pinSentTimestamp: 5000, tx: tx))
        }
    }

    // MARK: - Reactions

    func testAReactionNamingThePinnerAndThePinsSentTimeLandsOnHisNotice() throws {
        let (thread, notice) = try receiveBobsPin()

        let result = try write { tx in
            ReactionManager.processIncomingReaction(
                try self.reaction("👍", to: self.bob, at: 2000),
                thread: thread,
                reactor: self.bob,
                timestamp: 3000,
                serverTimestamp: 3000,
                expiresInSeconds: 0,
                expireTimerVersion: 0,
                sentTranscript: nil,
                transaction: tx,
            )
        }

        XCTAssertEqual(result, .success)
        read { tx in
            XCTAssertEqual(notice.reaction(for: self.bob, tx: tx)?.emoji, "👍")
        }
    }

    func testHisReactionToMyNoticeLandsAndCountsAsUnseenLikeOneToMyMessage() throws {
        let (thread, _) = insertFromBob("See you there", timestamp: 1000)
        let me = LocalIdentifiers.forUnitTests.aci
        write { tx in
            self.pinnedMessageManager.applyPinMessageChangeToLocalState(
                targetTimestamp: 1000,
                targetAuthorAci: self.bob,
                expiresAt: nil,
                isPin: true,
                sentTimestamp: 3000,
                threadUniqueId: thread.uniqueId,
                tx: tx,
            )
        }
        let myNotice = try XCTUnwrap(readValue { tx in
            InteractionFinder(threadUniqueId: thread.uniqueId).tellomiPinNotice(pinner: me, pinSentTimestamp: 3000, tx: tx)
        })

        let result = try write { tx in
            ReactionManager.processIncomingReaction(
                try self.reaction("🔥", to: me, at: 3000),
                thread: thread,
                reactor: self.bob,
                timestamp: 4000,
                serverTimestamp: 4000,
                expiresInSeconds: 0,
                expireTimerVersion: 0,
                sentTranscript: nil,
                transaction: tx,
            )
        }

        XCTAssertEqual(result, .success)
        read { tx in
            XCTAssertEqual(myNotice.reaction(for: self.bob, tx: tx)?.emoji, "🔥")
            XCTAssertEqual(TellomiUnseenReactions.unseenMessageIds(threadUniqueId: thread.uniqueId, tx: tx), [myNotice.uniqueId])
        }
    }

    func testMyReactionToHisNoticeNamesHimAndThePinsSentTime() throws {
        let (thread, notice) = try receiveBobsPin()

        let proto = try XCTUnwrap(try readValue { tx in
            try OutgoingReactionMessage(
                timestamp: 4000,
                emoji: "❤️",
                isRemoving: false,
                inThread: thread,
                onMessage: notice,
                newReaction: nil,
                oldReaction: nil,
                expiresInSeconds: 0,
                expireTimerVersion: 1,
                tx: tx,
            ).dataMessageBuilder(with: thread, transaction: tx)?.build().reaction
        })

        XCTAssertEqual(proto.timestamp, 2000, "when the pin was sent, not when the notice was made here")
        XCTAssertEqual(proto.targetAuthorAciBinary, bob.serviceIdBinary)
    }

    // MARK: - Replies

    func testMyReplyQuotesHisNoticeAsHisPinInTheThirdPerson() throws {
        let (_, notice) = try receiveBobsPin()

        let draft = try XCTUnwrap(readValue { tx in
            DependenciesBridge.shared.quotedReplyManager.buildDraftQuotedReply(
                originalMessage: notice,
                loadNormalizedImage: { _, _ in nil },
                tx: tx,
            )
        })

        XCTAssertEqual(draft.originalMessageTimestamp, 2000)
        XCTAssertEqual(draft.originalMessageAuthorAddress.aci, bob)
        let body = try XCTUnwrap(draft.bodyForSending?.text)
        XCTAssertTrue(body.hasSuffix("pinned “Lunch at noon”"), body)
    }

    func testMyReplyToMyOwnNoticeIsInTheThirdPersonToo() throws {
        let (thread, _) = insertFromBob("See you there", timestamp: 1000)
        write { tx in
            self.pinnedMessageManager.applyPinMessageChangeToLocalState(
                targetTimestamp: 1000,
                targetAuthorAci: self.bob,
                expiresAt: nil,
                isPin: true,
                sentTimestamp: 3000,
                threadUniqueId: thread.uniqueId,
                tx: tx,
            )
        }

        let body = try XCTUnwrap(readValue { tx -> String? in
            let notice = InteractionFinder(threadUniqueId: thread.uniqueId).tellomiPinNotice(pinner: LocalIdentifiers.forUnitTests.aci, pinSentTimestamp: 3000, tx: tx)
            XCTAssertEqual(notice?.pinnedMessageDescription(transaction: tx), "You pinned “See you there”", "in the chat it says You")
            return notice?.tellomiPinNoticeQuoteText(tx: tx)
        })

        XCTAssertFalse(body.hasPrefix("You"), body)
        XCTAssertTrue(body.hasSuffix(" pinned “See you there”"), body)
    }

    func testAReceivedReplyToHisNoticeQuotesThisAppsOwnLine() throws {
        let (thread, notice) = try receiveBobsPin()

        let quote = SSKProtoDataMessageQuote.builder(id: 2000)
        quote.setAuthorAciBinary(bob.serviceIdBinary)
        quote.setText("Bob hat «Lunch at noon» angeheftet")

        let quotedReply = try readValue { tx in
            try DependenciesBridge.shared.quotedReplyManager.validateAndBuildQuotedReply(
                from: try quote.build(),
                threadUniqueId: thread.uniqueId,
                tx: tx,
            ).quotedReply
        }

        XCTAssertEqual(quotedReply.bodySource, TSQuotedMessageContentSource.local, "found here, so tapping it goes to the notice")
        read { tx in
            XCTAssertEqual(quotedReply.body, notice.pinnedMessageDescription(transaction: tx))
        }
        XCTAssertEqual(quotedReply.timestampValue?.uint64Value, 2000)
    }

    // MARK: - Deleted for everyone

    func testHisDeleteForEveryoneTakesHisNoticeAwayAndThePinStays() throws {
        let (thread, notice) = try receiveBobsPin()

        try write { tx in
            try TSMessage.tryToRemotelyDeleteMessageAsNonAdmin(
                fromAuthor: self.bob,
                sentAtTimestamp: 2000,
                threadUniqueId: thread.uniqueId,
                serverTimestamp: 2500,
                transaction: tx,
            )
        }

        read { tx in
            XCTAssertNil(TSInteraction.anyFetch(uniqueId: notice.uniqueId, transaction: tx), "the notice is gone")
            XCTAssertEqual(self.pinnedMessageManager.fetchPinnedMessagesForThread(threadId: thread.sqliteRowId!, tx: tx).count, 1, "the message is still pinned")
        }
    }

    func testOnlyWhoeverPinnedCanDeleteTheNoticeAndOnlyInTime() throws {
        let (thread, notice) = try receiveBobsPin()
        let someoneElse = Aci.randomForTesting()

        try write { tx in
            XCTAssertThrowsError(try TSMessage.tryToRemotelyDeleteMessageAsNonAdmin(
                fromAuthor: someoneElse,
                sentAtTimestamp: 2000,
                threadUniqueId: thread.uniqueId,
                serverTimestamp: 2500,
                transaction: tx,
            ))
            XCTAssertThrowsError(try TSMessage.tryToRemotelyDeleteMessageAsNonAdmin(
                fromAuthor: self.bob,
                sentAtTimestamp: 2000,
                threadUniqueId: thread.uniqueId,
                serverTimestamp: 2000 + 3 * UInt64.dayInMs,
                transaction: tx,
            ), "too late")
        }

        read { tx in
            XCTAssertNotNil(TSInteraction.anyFetch(uniqueId: notice.uniqueId, transaction: tx))
        }
    }

    func testICanDeleteMyOwnNoticeForEveryoneInTimeAndItGoesAtOnce() throws {
        let (thread, hisNotice) = try receiveBobsPin()
        write { tx in
            self.pinnedMessageManager.applyPinMessageChangeToLocalState(
                targetTimestamp: 1000,
                targetAuthorAci: self.bob,
                expiresAt: nil,
                isPin: true,
                sentTimestamp: 3000,
                threadUniqueId: thread.uniqueId,
                tx: tx,
            )
        }
        let me = LocalIdentifiers.forUnitTests.aci
        let myNotice = try XCTUnwrap(readValue { tx in
            InteractionFinder(threadUniqueId: thread.uniqueId).tellomiPinNotice(pinner: me, pinSentTimestamp: 3000, tx: tx)
        })

        XCTAssertTrue(TellomiPinNotice.canDeleteForEveryone(myNotice, localAci: me, nowMs: 3000 + 1000))
        XCTAssertFalse(TellomiPinNotice.canDeleteForEveryone(myNotice, localAci: me, nowMs: 3000 + 2 * UInt64.dayInMs), "after the limit")
        XCTAssertFalse(TellomiPinNotice.canDeleteForEveryone(hisNotice, localAci: me, nowMs: 2000 + 1000), "not his")

        write { tx in
            TellomiPinNotice.deleteForEveryone(myNotice, thread: thread, tx: tx)
        }

        read { tx in
            XCTAssertNil(TSInteraction.anyFetch(uniqueId: myNotice.uniqueId, transaction: tx), "gone before the delete is out")
            XCTAssertNotNil(TSInteraction.anyFetch(uniqueId: hisNotice.uniqueId, transaction: tx))
            XCTAssertEqual(self.pinnedMessageManager.fetchPinnedMessagesForThread(threadId: thread.sqliteRowId!, tx: tx).count, 1, "the message is still pinned")
        }
    }

    // MARK: - Helpers

    /// Bob's "Lunch at noon" (sent at 1000) and his pin of it (sent at 2000), with its notice.
    private func receiveBobsPin() throws -> (TSThread, TSInfoMessage) {
        let (thread, _) = insertFromBob("Lunch at noon", timestamp: 1000)
        let notice = try XCTUnwrap(try write { tx in
            try self.pinnedMessageManager.pinMessage(
                pinMessageProto: self.pin(target: 1000),
                pinAuthor: self.bob,
                thread: thread,
                pinSentAtTimestamp: 2000,
                expireTimer: 0,
                expireTimerVersion: 0,
                transaction: tx,
            )
        })
        return (thread, notice)
    }

    private func reaction(_ emoji: String, to author: Aci, at timestamp: UInt64) throws -> SSKProtoDataMessageReaction {
        let reaction = SSKProtoDataMessageReaction.builder(emoji: emoji, timestamp: timestamp)
        reaction.setTargetAuthorAciBinary(author.serviceIdBinary)
        return try reaction.build()
    }

    private func readValue<T>(_ block: (DBReadTransaction) throws -> T) rethrows -> T {
        try SSKEnvironment.shared.databaseStorageRef.read(block: block)
    }

    private func insertFromBob(_ text: String, timestamp: UInt64) -> (TSThread, TSIncomingMessage) {
        write { tx in
            let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(self.bob), transaction: tx)
            let message = TSIncomingMessageBuilder.withDefaultValues(
                thread: thread,
                timestamp: timestamp,
                authorAci: self.bob,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody(text),
            ).build()
            message.anyInsert(transaction: tx)
            return (thread, message)
        }
    }

    private func pin(target: UInt64) -> SSKProtoDataMessagePinMessage {
        let pin = SSKProtoDataMessagePinMessage.builder()
        pin.setTargetAuthorAciBinary(bob.serviceIdBinary)
        pin.setTargetSentTimestamp(target)
        pin.setPinDurationForever(true)
        return pin.buildInfallibly()
    }
}
