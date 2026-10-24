//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

class ConversationViewTest: SignalBaseTest {
    func testConversationStyleComparison() throws {
        let thread = ContactThreadFactory().create()

        Theme.setIsDarkThemeEnabledForTests(false)
        XCTAssertFalse(Theme.isDarkThemeEnabled)

        let style1 = ConversationStyle(
            type: .`default`,
            thread: thread,
            viewWidth: 100,
            hasWallpaper: false,
            shouldDimWallpaperInDarkMode: false,
            chatColor: ChatColorSettingStore.Constants.defaultColor.colorSetting,
        )
        let style2 = ConversationStyle(
            type: .`default`,
            thread: thread,
            viewWidth: 100,
            hasWallpaper: false,
            shouldDimWallpaperInDarkMode: false,
            chatColor: ChatColorSettingStore.Constants.defaultColor.colorSetting,
        )
        let style3 = ConversationStyle(
            type: .`default`,
            thread: thread,
            viewWidth: 101,
            hasWallpaper: false,
            shouldDimWallpaperInDarkMode: false,
            chatColor: ChatColorSettingStore.Constants.defaultColor.colorSetting,
        )

        XCTAssertFalse(style1.isDarkThemeEnabled)
        XCTAssertFalse(style2.isDarkThemeEnabled)
        XCTAssertFalse(style3.isDarkThemeEnabled)

        XCTAssertTrue(style1 == style2)
        XCTAssertFalse(style1 == style3)
        XCTAssertFalse(style2 == style3)

        Theme.setIsDarkThemeEnabledForTests(true)
        XCTAssertTrue(Theme.isDarkThemeEnabled)

        let style4 = ConversationStyle(
            type: .`default`,
            thread: thread,
            viewWidth: 100,
            hasWallpaper: false,
            shouldDimWallpaperInDarkMode: false,
            chatColor: ChatColorSettingStore.Constants.defaultColor.colorSetting,
        )

        XCTAssertFalse(style1.isDarkThemeEnabled)
        XCTAssertFalse(style2.isDarkThemeEnabled)
        XCTAssertFalse(style3.isDarkThemeEnabled)
        XCTAssertTrue(style4.isDarkThemeEnabled)

        XCTAssertTrue(style1 == style2)
        XCTAssertFalse(style1 == style3)
        XCTAssertFalse(style2 == style3)

        XCTAssertFalse(style4 == style1)
        XCTAssertFalse(style4 == style2)
        XCTAssertFalse(style4 == style3)
    }
}

// MARK: - Tellomi（tellomi/tellomi#1184）

/// 两档勾、文字消息 2 秒规则、对等规则（需求 message-status-and-read-receipts §3.1–3.4）。
class TellomiMessageStatusTest: SignalBaseTest {

    override func setUp() {
        super.setUp()
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    private func textMessage(to aci: Aci, timestamp: UInt64, tx: DBWriteTransaction) -> TSOutgoingMessage {
        let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(aci), transaction: tx)
        let builder = TSOutgoingMessageBuilder.outgoingMessageBuilder(thread: thread, messageBody: nil)
        builder.timestamp = timestamp
        let message = builder.build(transaction: tx)
        message.anyInsert(transaction: tx)
        return message
    }

    private func readMessage(by aci: Aci, tx: DBWriteTransaction) -> TSOutgoingMessage {
        let message = textMessage(to: aci, timestamp: 100, tx: tx)
        message.updateWithSentRecipients([aci], wasSentByUD: false, tx: tx)
        message.update(withReadRecipient: SignalServiceAddress(aci), deviceId: DeviceId(validating: 1)!, readTimestamp: 300, tx: tx)
        return message
    }

    func testDeliveredIsOneCheckLikeSentAndOnlyReadIsTwoChecks() {
        write { tx in
            let aci = Aci.randomForTesting()
            let message = textMessage(to: aci, timestamp: 100, tx: tx)
            message.updateWithSentRecipients([aci], wasSentByUD: false, tx: tx)
            XCTAssertEqual(MessageRecipientStatusUtils.recipientStatus(outgoingMessage: message, hasBodyAttachments: false), .sent)

            message.update(
                withDeliveredRecipient: SignalServiceAddress(aci),
                deviceId: DeviceId(validating: 1)!,
                deliveryTimestamp: 200,
                context: PassthroughDeliveryReceiptContext(),
                tx: tx,
            )
            XCTAssertEqual(MessageRecipientStatusUtils.recipientStatus(outgoingMessage: message, hasBodyAttachments: false), .sent)

            message.update(withReadRecipient: SignalServiceAddress(aci), deviceId: DeviceId(validating: 1)!, readTimestamp: 300, tx: tx)
            XCTAssertEqual(MessageRecipientStatusUtils.recipientStatus(outgoingMessage: message, hasBodyAttachments: false), .read)
        }
    }

    func testWithMyReadReceiptsOffNobodysReadShowsIncludingEarlierOnes() {
        write { tx in
            let aci = Aci.randomForTesting()
            let message = readMessage(by: aci, tx: tx)
            let recipientState = message.recipientState(for: SignalServiceAddress(aci))!
            let receiptManager = SSKEnvironment.shared.receiptManagerRef

            receiptManager.setAreReadReceiptsEnabled(true, transaction: tx)
            XCTAssertEqual(MessageRecipientStatusUtils.recipientStatus(outgoingMessage: message, transaction: tx), .read)
            XCTAssertEqual(MessageRecipientStatusUtils.recipientStatusAndStatusMessage(outgoingMessage: message, recipientState: recipientState, transaction: tx).status, .read)

            receiptManager.setAreReadReceiptsEnabled(false, transaction: tx)
            XCTAssertEqual(MessageRecipientStatusUtils.recipientStatus(outgoingMessage: message, transaction: tx), .sent)
            XCTAssertEqual(MessageRecipientStatusUtils.recipientStatusAndStatusMessage(outgoingMessage: message, recipientState: recipientState, transaction: tx).status, .delivered)

            receiptManager.setAreReadReceiptsEnabled(true, transaction: tx)
            XCTAssertEqual(MessageRecipientStatusUtils.recipientStatus(outgoingMessage: message, transaction: tx), .read)
        }
    }

    func testTextWaitsTwoSecondsFromSendingBeforeTheSpinnerShows() {
        XCTAssertEqual(MessageRecipientStatusUtils.tellomiSendingIndicatorDelay(revealAtMs: 12_000, nowMs: 10_000), 2)
        XCTAssertEqual(MessageRecipientStatusUtils.tellomiSendingIndicatorDelay(revealAtMs: 12_000, nowMs: 11_500), 0.5)
        XCTAssertEqual(MessageRecipientStatusUtils.tellomiSendingIndicatorDelay(revealAtMs: 12_000, nowMs: 13_000), 0)
        XCTAssertEqual(MessageRecipientStatusUtils.tellomiSendingIndicatorDelay(revealAtMs: 12_000, nowMs: 9_000), 2)
        XCTAssertEqual(MessageRecipientStatusUtils.tellomiSendingIndicatorDelay(revealAtMs: nil, nowMs: 10_000), 0)

        write { tx in
            let message = textMessage(to: Aci.randomForTesting(), timestamp: 10_000, tx: tx)
            XCTAssertTrue(MessageRecipientStatusUtils.tellomiIsTextOnly(outgoingMessage: message, transaction: tx))
            XCTAssertEqual(MessageRecipientStatusUtils.tellomiSendingIndicatorRevealTimestamp(outgoingMessage: message, transaction: tx), 12_000)
        }
    }
}
