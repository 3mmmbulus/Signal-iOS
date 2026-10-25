//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import Signal
@testable import SignalServiceKit

/// Tellomi（清单 5.4）：转发时隐藏说明文字的规则。
final class TellomiForwardCaptionPolicyTests: XCTestCase {

    private func body(_ text: String) -> MessageBody {
        MessageBody(text: text, ranges: .empty)
    }

    func testSenderIsAlwaysHidden() {
        XCTAssertTrue(TellomiForwardCaptionPolicy.senderAlwaysHidden)
    }

    func testCaptionOnAttachmentCanBeHidden() {
        XCTAssertTrue(TellomiForwardCaptionPolicy.canHideCaption(body: body("海边"), hasAttachments: true))
        XCTAssertNil(TellomiForwardCaptionPolicy.outgoingBody(body("海边"), hasAttachments: true, hideCaption: true))
    }

    func testCaptionKeptWhenToggleOff() {
        let out = TellomiForwardCaptionPolicy.outgoingBody(body("海边"), hasAttachments: true, hideCaption: false)
        XCTAssertEqual(out?.text, "海边")
    }

    func testTextOnlyMessageNeverLosesText() {
        XCTAssertFalse(TellomiForwardCaptionPolicy.canHideCaption(body: body("你好"), hasAttachments: false))
        let out = TellomiForwardCaptionPolicy.outgoingBody(body("你好"), hasAttachments: false, hideCaption: true)
        XCTAssertEqual(out?.text, "你好")
    }

    func testWhitespaceCaptionCountsAsNone() {
        XCTAssertFalse(TellomiForwardCaptionPolicy.canHideCaption(body: body(" \n "), hasAttachments: true))
        XCTAssertFalse(TellomiForwardCaptionPolicy.canHideCaption(body: nil, hasAttachments: true))
    }

    func testToggleShownIfAnyItemHasCaption() {
        XCTAssertTrue(TellomiForwardCaptionPolicy.showsHideCaptionToggle([
            (body: body("纯文字"), hasAttachments: false),
            (body: body("图片说明"), hasAttachments: true),
        ]))
        XCTAssertFalse(TellomiForwardCaptionPolicy.showsHideCaptionToggle([
            (body: body("纯文字"), hasAttachments: false),
            (body: nil, hasAttachments: true),
        ]))
        XCTAssertFalse(TellomiForwardCaptionPolicy.showsHideCaptionToggle([]))
    }
}
