//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 交互审计 A-09（iOS）：正文里的链接一按下就高亮（原来点完才闪 0.25 s），松开稍后收回；长按拿起时也收回。
final class TellomiLinkPressTests: SignalBaseTest {

    @MainActor
    private func makeLabel() throws -> (CVTextLabel, CVTextLabel.Item, NSRange) {
        let text = NSAttributedString(string: "see https://example.com now", attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.black])
        let items = CVComponentBodyText.detectItems(
            text: DisplayableText.testOnlyInit(fullContent: .attributedText(text), truncatedContent: nil),
            hasPendingMessageRequest: false,
            shouldAllowLinkification: true,
            textWasTruncated: false,
            revealedSpoilerIds: Set(),
            interactionUniqueId: UUID().uuidString,
            interactionIdentifier: InteractionSnapshotIdentifier(timestamp: 0, authorAci: nil),
        )
        let item = try XCTUnwrap(items.first, "认出链接")
        let label = CVTextLabel()
        label.configureForRendering(
            config: CVTextLabel.Config(
                text: .attributedText(text),
                displayConfig: .forUnstyledText(font: .systemFont(ofSize: 17), textColor: .black),
                font: .systemFont(ofSize: 17),
                textColor: .black,
                selectionStyling: [.foregroundColor: UIColor.orange],
                textAlignment: .natural,
                lineBreakMode: .byWordWrapping,
                numberOfLines: 0,
                cacheKey: UUID().uuidString,
                items: items,
                linkifyStyle: .linkAttribute,
            ),
            spoilerAnimationManager: SpoilerAnimationManager(),
        )
        return (label, item, item.range)
    }

    @MainActor
    private func color(_ label: CVTextLabel, at location: Int) -> UIColor? {
        label.tellomiRenderedTextForTesting.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor
    }

    @MainActor
    func testPressingALinkHighlightsItRightAwayAndReleaseClearsIt() throws {
        let (label, item, range) = try makeLabel()
        XCTAssertTrue(CVTextLabel.tellomiHighlightsOnPress(item))
        XCTAssertNotEqual(color(label, at: range.location), .orange)

        let feedback = TellomiPressFeedback()
        feedback.pressText(label: label, item: item, pointInWindow: .zero)
        XCTAssertEqual(color(label, at: range.location), .orange, "一按下就高亮")
        XCTAssertNotEqual(color(label, at: 0), .orange, "只高亮链接那一段")

        feedback.release()
        XCTAssertNil(feedback.pressedTextLabel)
        let cleared = expectation(description: "稍后收回")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertNotEqual(self.color(label, at: range.location), .orange)
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 2)
    }

    @MainActor
    func testScrollingAwayFromALinkLetsGo() throws {
        let (label, item, _) = try makeLabel()
        let feedback = TellomiPressFeedback()
        feedback.pressText(label: label, item: item, pointInWindow: CGPoint(x: 100, y: 100))

        feedback.moved(toWindowPoint: CGPoint(x: 104, y: 103))
        XCTAssertNotNil(feedback.pressedTextLabel, "抖一下不算")
        feedback.moved(toWindowPoint: CGPoint(x: 100, y: 130))
        XCTAssertNil(feedback.pressedTextLabel, "挪出 10 pt 是在滚动：收回")
    }
}
