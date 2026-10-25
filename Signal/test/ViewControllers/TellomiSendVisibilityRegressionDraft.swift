//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit
import XCTest

@testable import Signal

// ---- DRAFT regression (tellomi测试, not pushed) — P0 TF43: 5 quick sends must all be visible ----
// Uses only API that exists at 70a52004, mirrors CVC's reveal rule (row stays hidden while any flight holds it).
@MainActor
final class TellomiSendVisibilityRegressionDraft: XCTestCase {
    func testFiveQuickSendsAreAllRevealedWhenTheirFlightsEnd() {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        defer { window.isHidden = true }
        var flights = [TellomiSendFlight]()
        var hiddenAfterReveal = [String: Bool]()
        for n in 1...5 {
            let flight = TellomiSendFlight(
                messageTimestamp: UInt64(n),
                source: TellomiSendFlight.Source(textSnapshot: UIView(), textSnapshotFrame: .zero, textOrigin: .zero, fontSize: 17, box: CGRect(x: 60, y: 792, width: 280, height: 38)),
                window: window,
                findTarget: { _ in nil },
                makeContent: { _ in nil },
                onChange: { _ in },
                // Same rule as ConversationViewController.tellomiRevealSendFlightRow at 70a52004.
                onReveal: { _, id in hiddenAfterReveal[id] = flights.contains { $0.isHoldingRow(interactionUniqueId: id) } },
                onFinish: { f in flights.removeAll { $0 === f } },
            )
            flights.append(flight)
            flight.claim(interactionUniqueId: "m\(n)")
        }
        for flight in flights { flight.cancelImmediately() }
        XCTAssertEqual(hiddenAfterReveal, ["m1": false, "m2": false, "m3": false, "m4": false, "m5": false], "every sent row must be visible once its flight ends")
    }
}
