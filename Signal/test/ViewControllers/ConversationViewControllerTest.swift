//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import XCTest

@testable import Signal

class ConversationViewControllerTest: SignalBaseTest {

    func testCVCBottomViewType() {
        XCTAssertEqual(CVCBottomViewType.none, CVCBottomViewType.none)
        XCTAssertNotEqual(CVCBottomViewType.none, CVCBottomViewType.inputToolbar)
        XCTAssertEqual(CVCBottomViewType.inputToolbar, CVCBottomViewType.inputToolbar)
        XCTAssertNotEqual(CVCBottomViewType.none, CVCBottomViewType.memberRequestView)
        XCTAssertNotEqual(
            CVCBottomViewType.memberRequestView,
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: true,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
        )
        XCTAssertEqual(
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: true,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: true,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
        )
        XCTAssertNotEqual(
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: true,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: false,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
        )
        XCTAssertEqual(
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: false,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: false,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
        )
        XCTAssertNotEqual(
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: true,
                    isThreadBlocked: true,
                    hasSentMessages: false,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
            CVCBottomViewType.messageRequestView(
                messageRequestType: MessageRequestType(
                    isGroupV1Thread: true,
                    isGroupV2Thread: false,
                    isThreadBlocked: true,
                    hasSentMessages: true,
                    isThreadFromHiddenRecipient: false,
                    hasReportedSpam: false,
                    isLocalUserInvitedMember: false,
                    showReviewRequestsCarefullyWarning: false,
                ),
            ),
        )
    }
}

/// Tellomi（tellomi/tellomi#1109，ADR-0058 §2）：滑动回复改成手指从右往左滑。
class TellomiSwipeToReplyTest: XCTestCase {

    func testThresholdIs45ForIncomingAnd60ForOutgoingAsInTelegram() {
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyThreshold(isIncoming: true), 45)
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyThreshold(isIncoming: false), 60)
    }

    func testBubbleFollowsTheFingerUpToTheThresholdThenRubberBands() {
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: 0, threshold: 45), 0)
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: -12, threshold: 45), 0)
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: 30, threshold: 45), 30)
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: 45, threshold: 45), 45)
        // 过阈值 100：(1 - 1 / (100 × 0.4 / 100 + 1)) × 100 ≈ 28.57
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: 145, threshold: 45), 73.571, accuracy: 0.01)
        let far = CVComponentMessage.tellomiSwipeToReplyBubbleOffset(fingerOffset: 10_000, threshold: 60)
        XCTAssertGreaterThan(far, 155)
        XCTAssertLessThanOrEqual(far, 180)
    }

    // 交互审计 A-10：松手用投射落点判定（位移 + 速度 × 0.1 s），回位弹簧从气泡速度起步。

    func testReleasingPastTheThresholdWithoutMovingStillReplies() {
        XCTAssertTrue(CVComponentMessage.tellomiSwipeToReplyShouldReply(fingerOffset: 50, fingerVelocity: 0, threshold: 45))
        XCTAssertFalse(CVComponentMessage.tellomiSwipeToReplyShouldReply(fingerOffset: 40, fingerVelocity: 0, threshold: 45))
    }

    func testAQuickFlickShortOfTheThresholdReplies() {
        // 30 + 800 × 0.1 = 110 > 45
        XCTAssertTrue(CVComponentMessage.tellomiSwipeToReplyShouldReply(fingerOffset: 30, fingerVelocity: 800, threshold: 45))
        // 12 + 200 × 0.1 = 32 < 45：轻微晃动不算
        XCTAssertFalse(CVComponentMessage.tellomiSwipeToReplyShouldReply(fingerOffset: 12, fingerVelocity: 200, threshold: 45))
    }

    func testFlickingBackFromPastTheThresholdCancels() {
        // 70 − 400 × 0.1 = 30 < 60
        XCTAssertFalse(CVComponentMessage.tellomiSwipeToReplyShouldReply(fingerOffset: 70, fingerVelocity: -400, threshold: 60))
    }

    func testBubbleSpeedFollowsTheFingerThenSlowsInTheRubberBand() {
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleVelocity(fingerOffset: 30, fingerVelocity: 500, threshold: 45), 500)
        // 过阈值 100：斜率 0.4 / (100 × 0.4 / 100 + 1)² = 0.4 / 1.96
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleVelocity(fingerOffset: 145, fingerVelocity: 500, threshold: 45), 500 * 0.4 / 1.96, accuracy: 0.01)
        XCTAssertLessThan(CVComponentMessage.tellomiSwipeToReplyBubbleVelocity(fingerOffset: 145, fingerVelocity: -500, threshold: 45), 0)
        // 还没出发：不动
        XCTAssertEqual(CVComponentMessage.tellomiSwipeToReplyBubbleVelocity(fingerOffset: -5, fingerVelocity: 500, threshold: 45), 0)
    }

    func testAnOutwardReleaseStartsTheReturnSpringAwayFromRest() {
        // 气泡在 60 pt、还以 300 pt/s 往外走：回到 0 的剩余路程是 −60，初速比例为负（先往外再回来）。
        let outward = TellomiMotion.relativeVelocity(CGPoint(x: 300, y: 0), remaining: CGVector(dx: -60, dy: 0))
        XCTAssertEqual(outward.dx, -5, accuracy: 0.001)
        // 往回甩着松手：比例为正，直接朝原位去。
        let inward = TellomiMotion.relativeVelocity(CGPoint(x: -300, y: 0), remaining: CGVector(dx: -60, dy: 0))
        XCTAssertEqual(inward.dx, 5, accuracy: 0.001)
    }

    func testOnlyRightToLeftHorizontalPansBeginOnMessagesExceptAudioScrubbing() {
        // 从右往左：回复
        XCTAssertTrue(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: -10, y: 2), isRTL: false, isScrubbingAudio: false))
        // 从左往右：不接，留给系统返回
        XCTAssertFalse(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: 10, y: 2), isRTL: false, isScrubbingAudio: false))
        // 拖语音进度两个方向都要
        XCTAssertTrue(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: 10, y: 2), isRTL: false, isScrubbingAudio: true))
        // 纵向让给滚动
        XCTAssertFalse(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: -3, y: 8), isRTL: false, isScrubbingAudio: false))
        // RTL 镜像
        XCTAssertTrue(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: 10, y: 2), isRTL: true, isScrubbingAudio: false))
        XCTAssertFalse(ConversationViewController.tellomiShouldBeginMessagePan(translation: CGPoint(x: -10, y: 2), isRTL: true, isScrubbingAudio: false))
    }
}
