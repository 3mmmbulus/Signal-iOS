//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import SignalServiceKit

/// Tellomi (ADR-0081 §4.4, pinned-messages.md 3.2): "×× pinned «the first 15 characters…»" — in the chat, the chat list and
/// notifications — when it is pushed, and that someone else's pin counts as unread and brings the chat up.
class TellomiPinNoticeTest: SSKBaseTest {

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

    // MARK: - The preview

    func testShortTextIsQuotedWholeOnOneLine() {
        XCTAssertEqual(TellomiPinNotice.clip("Lunch at noon"), "Lunch at noon")
        XCTAssertEqual(TellomiPinNotice.clip("Line\n\ntwo"), "Line two")
        XCTAssertEqual(TellomiPinNotice.clip("Lunch at noon\ntomorrow"), "Lunch at noon t…")
    }

    func testMoreThan15CharactersAreCutTo15WithAnEllipsis() {
        XCTAssertEqual(TellomiPinNotice.clip("123456789012345"), "123456789012345")
        XCTAssertEqual(TellomiPinNotice.clip("1234567890123456"), "123456789012345…")
        XCTAssertEqual(TellomiPinNotice.clip("明天中午十二点在公司楼下的餐厅一起吃饭"), "明天中午十二点在公司楼下的餐厅…")
    }

    func testAnEmojiIsOneCharacterAndNeverSplit() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(TellomiPinNotice.clip("12345678901234\(family)tail"), "12345678901234\(family)…")
    }

    // MARK: - The sentence

    func testSomeoneElsePinningText() {
        let (_, message) = insertFromBob("Hello pinned world, this is long")

        read { tx in
            XCTAssertEqual(TellomiPinNotice.describe(pinnerIsLocalUser: false, pinnerName: "Bob", target: message, tx: tx), "Bob pinned “Hello pinned wo…”")
        }
    }

    func testMyOwnPin() {
        let (_, message) = insertFromBob("See you there")

        read { tx in
            XCTAssertEqual(TellomiPinNotice.describe(pinnerIsLocalUser: true, pinnerName: "", target: message, tx: tx), "You pinned “See you there”")
        }
    }

    func testAPinWhoseMessageIsGone() {
        read { tx in
            XCTAssertEqual(TellomiPinNotice.describe(pinnerIsLocalUser: false, pinnerName: "Bob", target: nil, tx: tx), "Bob pinned a message")
        }
    }

    func testMediaIsNamedByWhatItIs() {
        XCTAssertEqual(TellomiPinNotice.mediaSubject(mimeType: "image/jpeg", renderingFlag: .default), "a photo")
        XCTAssertEqual(TellomiPinNotice.mediaSubject(mimeType: "video/mp4", renderingFlag: .default), "a video")
        XCTAssertEqual(TellomiPinNotice.mediaSubject(mimeType: "video/mp4", renderingFlag: .shouldLoop), "a GIF")
        XCTAssertEqual(TellomiPinNotice.mediaSubject(mimeType: "audio/aac", renderingFlag: .voiceMessage), "a voice message")
        XCTAssertEqual(TellomiPinNotice.mediaSubject(mimeType: "audio/mpeg", renderingFlag: .default), "an audio file")
        XCTAssertEqual(TellomiPinNotice.mediaSubject(mimeType: "application/pdf", renderingFlag: .default), "a file")
    }

    // MARK: - Pushed, unread, brought up

    func testOnlyAGroupPinWithNotifyingIsPushed() {
        XCTAssertTrue(TellomiPinNotice.notifies(silent: false, isGroup: true))
        XCTAssertFalse(TellomiPinNotice.notifies(silent: true, isGroup: true), "pinned without notifying")
        XCTAssertFalse(TellomiPinNotice.notifies(silent: false, isGroup: false), "a 1:1 pin is never pushed")
    }

    func testSomeoneElsesPinIsUnreadAndBringsTheChatUp() {
        let (thread, _) = insertFromBob("Pin me")

        let pin = write { tx in self.insertPin(in: thread, by: self.bob, tx: tx) }

        read { tx in
            XCTAssertEqual(InteractionFinder(threadUniqueId: thread.uniqueId).unreadCount(transaction: tx), 2, "his message and his pin")
            XCTAssertTrue(pin.shouldBumpThreadToTopOfChatList(transaction: tx))
            XCTAssertTrue(pin.infoMessagePreviewText(with: tx).hasSuffix("pinned “Pin me”"), pin.infoMessagePreviewText(with: tx))
        }
    }

    func testMyOwnPinIsReadAlready() {
        let (thread, _) = insertFromBob("Pin me")

        let pin = write { tx in self.insertPin(in: thread, by: LocalIdentifiers.forUnitTests.aci, tx: tx) }

        read { tx in
            XCTAssertEqual(InteractionFinder(threadUniqueId: thread.uniqueId).unreadCount(transaction: tx), 1, "only his message")
            XCTAssertEqual(pin.infoMessagePreviewText(with: tx), "You pinned “Pin me”")
        }
    }

    // MARK: - Helpers

    private func insertFromBob(_ text: String) -> (TSThread, TSMessage) {
        write { tx in
            let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(self.bob), transaction: tx)
            let message = TSIncomingMessageBuilder.withDefaultValues(
                thread: thread,
                timestamp: 1000,
                authorAci: self.bob,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody(text),
            ).build()
            message.anyInsert(transaction: tx)
            return (thread, message)
        }
    }

    private func insertPin(in thread: TSThread, by pinner: Aci, tx: DBWriteTransaction) -> TSInfoMessage {
        return pinnedMessageManager.insertInfoMessageForPinnedMessage(
            timestamp: 2000,
            thread: thread,
            targetMessageTimestamp: 1000,
            targetMessageAuthor: bob,
            pinAuthor: pinner,
            expireTimer: 0,
            expireTimerVersion: 0,
            tx: tx,
        )
    }
}
