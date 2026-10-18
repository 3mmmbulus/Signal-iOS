//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalUI

/// pinned-messages.md 3.4：置顶栏左边的竖线——每条置顶一段、最早的在上、正显示的那段实色；多于 3 条只露 3 段，那头还有更多就渐隐。
/// 会话页在单测里建不起来（模拟器上的 App 没注册），这里直接排一次竖线本身。
final class TellomiPinnedLineViewTests: XCTestCase {

    private func laidOut(index: Int, count: Int) -> (line: TellomiPinnedLineView, segments: [UIView]) {
        let line = TellomiPinnedLineView(index: index, count: count)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.layoutIfNeeded()
        let stack = line.subviews.compactMap { $0 as? UIStackView }.first
        return (line, stack?.arrangedSubviews ?? [])
    }

    /// The shown segment is `UIColor.Signal.label` (opaque); the others `tertiaryLabel` (30 %).
    private func isSolid(_ segment: UIView) -> Bool {
        let light = UITraitCollection(userInterfaceStyle: .light)
        return segment.backgroundColor?.resolvedColor(with: light).cgColor.alpha == 1
    }

    private func endAlphas(_ line: TellomiPinnedLineView) throws -> (top: CGFloat, bottom: CGFloat) {
        let mask = try XCTUnwrap(line.layer.mask as? CAGradientLayer)
        XCTAssertEqual(mask.frame, line.bounds)
        let colors = try XCTUnwrap(mask.colors as? [CGColor])
        XCTAssertEqual(colors.count, 4)
        return (try XCTUnwrap(colors.first).alpha, try XCTUnwrap(colors.last).alpha)
    }

    func testTwoPinsAreTwoSegmentsTheShownOneSolidAndNothingFades() {
        let (line, segments) = laidOut(index: 1, count: 2)
        XCTAssertEqual(line.bounds.size, CGSize(width: 2, height: 34))
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(isSolid), [false, true], "the newer one is below")
        XCTAssertEqual(segments[0].frame.size.height, 15, accuracy: 0.5)
        XCTAssertLessThan(segments[0].frame.maxY, segments[1].frame.minY, "a gap between segments")
        XCTAssertNil(line.layer.mask)
    }

    func testSevenPinsShowThreeSegmentsAroundTheShownOneAndFadeWhereThereAreMore() throws {
        let (middle, middleSegments) = laidOut(index: 3, count: 7)
        XCTAssertEqual(middleSegments.count, 3)
        XCTAssertEqual(middleSegments.map(isSolid), [false, true, false], "the shown one in the middle")
        let bothEnds = try endAlphas(middle)
        XCTAssertEqual(bothEnds.top, 0, "fades at the top")
        XCTAssertEqual(bothEnds.bottom, 0, "fades at the bottom")

        let (oldest, oldestSegments) = laidOut(index: 0, count: 7)
        XCTAssertEqual(oldestSegments.map(isSolid), [true, false, false], "the oldest at the top")
        let bottomOnly = try endAlphas(oldest)
        XCTAssertEqual(bottomOnly.top, 1, "nothing older above it")
        XCTAssertEqual(bottomOnly.bottom, 0)

        let (newest, newestSegments) = laidOut(index: 6, count: 7)
        XCTAssertEqual(newestSegments.map(isSolid), [false, false, true], "the newest at the bottom")
        let topOnly = try endAlphas(newest)
        XCTAssertEqual(topOnly.top, 0)
        XCTAssertEqual(topOnly.bottom, 1, "nothing newer below it")
    }
}
