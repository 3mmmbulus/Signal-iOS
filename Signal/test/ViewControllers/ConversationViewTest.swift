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

    /// 付款消息另走一条路算状态（付款状态 + 消息状态），同样守关回执规则：关着时已读 / 已查看降为「已送达」（同普通消息），重新打开恢复。
    func testPaymentMessageStatusHidesReadWhenMyReadReceiptsAreOff() {
        write { tx in
            let aci = Aci.randomForTesting()
            let message = readMessage(by: aci, tx: tx)

            for paymentState: TSPaymentState in [.outgoingSent, .outgoingVerified, .outgoingComplete] {
                XCTAssertEqual(paymentState.combinedMessageReceiptStatus(with: message, showsReadStates: true), .read, "\(paymentState)")
                XCTAssertEqual(paymentState.combinedMessageReceiptStatus(with: message, showsReadStates: false), .delivered, "\(paymentState)")
            }
            // 失败 / 发送中不受开关影响。
            XCTAssertEqual(TSPaymentState.outgoingFailed.combinedMessageReceiptStatus(with: message, showsReadStates: false), .failed)

            message.update(withViewedRecipient: SignalServiceAddress(aci), deviceId: DeviceId(validating: 1)!, viewedTimestamp: 400, tx: tx)
            XCTAssertEqual(TSPaymentState.outgoingComplete.combinedMessageReceiptStatus(with: message, showsReadStates: true), .viewed)
            XCTAssertEqual(TSPaymentState.outgoingComplete.combinedMessageReceiptStatus(with: message, showsReadStates: false), .delivered)
        }
    }

    /// 付款消息遇到「已送达」时照旧是已送达（页脚 / 列表画成一个勾），关回执不会把它变成别的。
    func testPaymentMessageDeliveredStaysDeliveredWithReadReceiptsOff() {
        write { tx in
            let aci = Aci.randomForTesting()
            let message = textMessage(to: aci, timestamp: 100, tx: tx)
            message.updateWithSentRecipients([aci], wasSentByUD: false, tx: tx)
            message.update(
                withDeliveredRecipient: SignalServiceAddress(aci),
                deviceId: DeviceId(validating: 1)!,
                deliveryTimestamp: 200,
                context: PassthroughDeliveryReceiptContext(),
                tx: tx,
            )
            XCTAssertEqual(TSPaymentState.outgoingComplete.combinedMessageReceiptStatus(with: message, showsReadStates: false), .delivered)
            XCTAssertEqual(TSPaymentState.outgoingComplete.combinedMessageReceiptStatus(with: message, showsReadStates: true), .delivered)
        }
    }

    func testDowngradedReadShowsDeliveredWithoutLeakingReadTime() {
        write { tx in
            let aci = Aci.randomForTesting()
            let message = readMessage(by: aci, tx: tx)
            let recipientState = message.recipientState(for: SignalServiceAddress(aci))!
            let deliveredLabel = OWSLocalizedString("MESSAGE_STATUS_DELIVERED", comment: "")

            let hidden = MessageRecipientStatusUtils.recipientStatusAndStatusMessage(
                outgoingMessage: message,
                recipientState: recipientState,
                hasBodyAttachments: false,
                showsReadStates: false,
            )
            XCTAssertEqual(hidden.status, .delivered)
            XCTAssertEqual(hidden.shortStatusMessage, "")
            XCTAssertEqual(hidden.longStatusMessage, deliveredLabel)

            let shown = MessageRecipientStatusUtils.recipientStatusAndStatusMessage(
                outgoingMessage: message,
                recipientState: recipientState,
                hasBodyAttachments: false,
                showsReadStates: true,
            )
            XCTAssertEqual(shown.status, .read)
            XCTAssertFalse(shown.shortStatusMessage.isEmpty)
        }
    }

    func testRealDeliveredStillShowsItsTime() {
        write { tx in
            let aci = Aci.randomForTesting()
            let message = textMessage(to: aci, timestamp: 100, tx: tx)
            message.updateWithSentRecipients([aci], wasSentByUD: false, tx: tx)
            message.update(
                withDeliveredRecipient: SignalServiceAddress(aci),
                deviceId: DeviceId(validating: 1)!,
                deliveryTimestamp: 200,
                context: PassthroughDeliveryReceiptContext(),
                tx: tx,
            )
            let recipientState = message.recipientState(for: SignalServiceAddress(aci))!
            let result = MessageRecipientStatusUtils.recipientStatusAndStatusMessage(
                outgoingMessage: message,
                recipientState: recipientState,
                hasBodyAttachments: false,
                showsReadStates: false,
            )
            XCTAssertEqual(result.status, .delivered)
            XCTAssertEqual(result.shortStatusMessage, DateUtil.formatPastTimestampRelativeToNow(200))
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

    // MARK: - Tellomi（#1186）：品牌勾、动画、新手提示

    func testChecksAnimateOnlyForAChangeSeenOnScreen() {
        typealias U = MessageRecipientStatusUtils
        XCTAssertEqual(U.tellomiCheckAnimation(previous: .sending, next: .oneCheck, reduceMotion: false), .fadeInOneCheck)
        XCTAssertEqual(U.tellomiCheckAnimation(previous: .oneCheck, next: .twoChecks, reduceMotion: false), .growSecondCheck)
        XCTAssertEqual(U.tellomiCheckAnimation(previous: .sending, next: .twoChecks, reduceMotion: false), .growSecondCheck)
        // 刚画出来（打开会话、回翻历史）不动；没变不动；倒退不动。
        XCTAssertNil(U.tellomiCheckAnimation(previous: nil, next: .oneCheck, reduceMotion: false))
        XCTAssertNil(U.tellomiCheckAnimation(previous: nil, next: .twoChecks, reduceMotion: false))
        XCTAssertNil(U.tellomiCheckAnimation(previous: .oneCheck, next: .oneCheck, reduceMotion: false))
        XCTAssertNil(U.tellomiCheckAnimation(previous: .twoChecks, next: .oneCheck, reduceMotion: false))
        XCTAssertNil(U.tellomiCheckAnimation(previous: .oneCheck, next: .sending, reduceMotion: false))
        XCTAssertNil(U.tellomiCheckAnimation(previous: .oneCheck, next: nil, reduceMotion: false))
        // 减少动态时什么都不动。
        XCTAssertNil(U.tellomiCheckAnimation(previous: .sending, next: .oneCheck, reduceMotion: true))
        XCTAssertNil(U.tellomiCheckAnimation(previous: .oneCheck, next: .twoChecks, reduceMotion: true))
    }

    func testCheckAnimationDurationsMatchDesktop() {
        XCTAssertEqual(TellomiCheckAnimation.fadeInOneCheck.duration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(TellomiCheckAnimation.growSecondCheck.duration, 0.22, accuracy: 0.0001)
        XCTAssertEqual(MessageRecipientStatusUtils.tellomiGrowStartVisibleFraction, 0.62, accuracy: 0.0001)
        XCTAssertEqual(MessageRecipientStatusUtils.tellomiChecksHintSeconds, 8)
    }

    func testShownChecksRememberUntilTheMessageLeavesTheScreen() {
        var shown = TellomiShownChecks()
        XCTAssertNil(shown.record(.sending, for: "a"))
        XCTAssertEqual(shown.record(.oneCheck, for: "a"), .sending)
        XCTAssertEqual(shown.record(.twoChecks, for: "a"), .oneCheck)
        XCTAssertNil(shown.record(.oneCheck, for: "b"))
        // 失败（没画勾）记成 nil，重发时从「发送中」开始比。
        XCTAssertEqual(shown.record(nil, for: "b"), .oneCheck)
        XCTAssertNil(shown.record(.sending, for: "b"))
        shown.forget("a")
        XCTAssertNil(shown.record(.twoChecks, for: "a"))
        shown.forgetAll()
        XCTAssertEqual(shown.count, 0)
    }

    func testSeenSentIsOnlySendingToChecks() {
        typealias U = MessageRecipientStatusUtils
        XCTAssertTrue(U.tellomiIsSeenSent(previous: .sending, next: .oneCheck))
        XCTAssertTrue(U.tellomiIsSeenSent(previous: .sending, next: .twoChecks))
        XCTAssertFalse(U.tellomiIsSeenSent(previous: nil, next: .oneCheck))
        XCTAssertFalse(U.tellomiIsSeenSent(previous: .oneCheck, next: .twoChecks))
        XCTAssertFalse(U.tellomiIsSeenSent(previous: .sending, next: nil))
    }

    func testChecksHintOnceAndNotForNoteToSelfEditsOrStoryReplies() {
        typealias U = MessageRecipientStatusUtils
        XCTAssertTrue(U.tellomiShouldShowChecksHint(alreadyShown: false, isNoteToSelf: false, isEdit: false, isStoryReply: false))
        XCTAssertFalse(U.tellomiShouldShowChecksHint(alreadyShown: true, isNoteToSelf: false, isEdit: false, isStoryReply: false))
        XCTAssertFalse(U.tellomiShouldShowChecksHint(alreadyShown: false, isNoteToSelf: true, isEdit: false, isStoryReply: false))
        XCTAssertFalse(U.tellomiShouldShowChecksHint(alreadyShown: false, isNoteToSelf: false, isEdit: true, isStoryReply: false))
        XCTAssertFalse(U.tellomiShouldShowChecksHint(alreadyShown: false, isNoteToSelf: false, isEdit: false, isStoryReply: true))
    }

    func testTellomiCheckIconsAreBundledWithoutCircles() {
        let one = UIImage(named: MessageRecipientStatusUtils.tellomiOneCheckImageName)
        let two = UIImage(named: MessageRecipientStatusUtils.tellomiTwoChecksImageName)
        XCTAssertNotNil(one)
        XCTAssertNotNil(two)
        // 气泡上的状态位是 18×12：高度必须是 12，宽度不超过 18。
        XCTAssertEqual(one?.size.height, 12)
        XCTAssertEqual(two?.size.height, 12)
        XCTAssertLessThanOrEqual(one?.size.width ?? 99, 18)
        XCTAssertLessThanOrEqual(two?.size.width ?? 99, 18)
    }

    func testStatusSlotIsFixedSoTimeDoesNotMoveWhenRead() {
        typealias U = MessageRecipientStatusUtils
        // 产品经理裁定：三端 18×12 画布 + 固定状态位，一勾、两勾、发送中同宽。
        XCTAssertEqual(U.tellomiStatusSlotSize, CGSize(width: 18, height: 12))
        let one = UIImage(named: U.tellomiOneCheckImageName)
        let two = UIImage(named: U.tellomiTwoChecksImageName)
        XCTAssertEqual(one?.size, U.tellomiStatusSlotSize)
        XCTAssertEqual(two?.size, U.tellomiStatusSlotSize)
        XCTAssertEqual(one?.size.width, two?.size.width)

        // 会话列表：发送中的转圈（12×12）居中放进同样大小的位里；本来就是 18×12 的图原样返回。
        let sending = try! XCTUnwrap(UIImage(named: "message_status_sending"))
        let paddedSending = U.tellomiImageFittingStatusSlot(sending)
        XCTAssertEqual(paddedSending.size, U.tellomiStatusSlotSize)
        XCTAssertEqual(paddedSending.renderingMode, .alwaysTemplate)
        XCTAssertEqual(U.tellomiImageFittingStatusSlot(two!).size, U.tellomiStatusSlotSize)
    }

    func testSendingSpinnerIsOneAndAHalfSecondsPerTurn() {
        XCTAssertEqual(MessageRecipientStatusUtils.tellomiSendingSpinSeconds, 1.5, accuracy: 0.0001)
    }

    func testFirstSendHintCountsStraightToReadButNotOffScreen() {
        typealias U = MessageRecipientStatusUtils
        // 在屏上：发送中 → 一勾、发送中 → 直接两勾都算「第一次在屏上变成已发出」。
        XCTAssertTrue(U.tellomiIsSeenSent(previous: .sending, next: .oneCheck))
        XCTAssertTrue(U.tellomiIsSeenSent(previous: .sending, next: .twoChecks))
        // 不在屏上时变的（回来时第一次画出来，上次没记）不算；已经是勾再变两勾也不算。
        var shown = TellomiShownChecks()
        XCTAssertNil(shown.record(.sending, for: "m"))
        shown.forget("m")
        let previous = shown.record(.twoChecks, for: "m")
        XCTAssertFalse(U.tellomiIsSeenSent(previous: previous, next: .twoChecks))
        XCTAssertFalse(U.tellomiIsSeenSent(previous: .oneCheck, next: .twoChecks))
    }

    func testChecksHintIsRememberedOnThisDevice() {
        read { tx in XCTAssertFalse(TellomiChecksHint.hasShown(tx: tx)) }
        write { tx in TellomiChecksHint.markShown(tx: tx) }
        read { tx in XCTAssertTrue(TellomiChecksHint.hasShown(tx: tx)) }
    }

    func testMessageDetailSectionIconsUseTellomiChecks() {
        typealias V = MessageDetailViewController
        typealias U = MessageRecipientStatusUtils
        XCTAssertEqual(V.tellomiSectionIconName(for: .sent), U.tellomiOneCheckImageName)
        XCTAssertEqual(V.tellomiSectionIconName(for: .delivered), U.tellomiOneCheckImageName)
        XCTAssertEqual(V.tellomiSectionIconName(for: .read), U.tellomiTwoChecksImageName)
        XCTAssertEqual(V.tellomiSectionIconName(for: .viewed), U.tellomiTwoChecksImageName)
        XCTAssertEqual(V.tellomiSectionIconName(for: .sending), "message_status_sending")
        XCTAssertNil(V.tellomiSectionIconName(for: .failed))
        XCTAssertNil(V.tellomiSectionIconName(for: .skipped))

        let fallback = UIColor.ows_gray90
        let light = UITraitCollection(userInterfaceStyle: .light)
        func assertSameColor(_ a: UIColor, _ b: UIColor, line: UInt = #line) {
            XCTAssertEqual(a.resolvedColor(with: light), b.resolvedColor(with: light), line: line)
        }
        assertSameColor(V.tellomiSectionIconTintColor(for: .sent, defaultColor: fallback), UIColor.Signal.secondaryLabel)
        assertSameColor(V.tellomiSectionIconTintColor(for: .delivered, defaultColor: fallback), UIColor.Signal.secondaryLabel)
        assertSameColor(V.tellomiSectionIconTintColor(for: .read, defaultColor: fallback), UIColor.Signal.accent)
        assertSameColor(V.tellomiSectionIconTintColor(for: .viewed, defaultColor: fallback), UIColor.Signal.accent)
        assertSameColor(V.tellomiSectionIconTintColor(for: .sending, defaultColor: fallback), fallback)
    }
}
