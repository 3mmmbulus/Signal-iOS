//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import XCTest

@testable import SignalUI

/// Tellomi（tellomi/tellomi#1522 E-1）：裁剪的比例预设与锁住比例时拖边 / 拖角（照 Telegram `TGPhotoCropController`、`TGPhotoCropAreaView`）。
final class TellomiImageEditorCropAspectTests: XCTestCase {

    typealias AspectRatio = ImageEditorCropViewController.AspectRatio

    /// 8 项，顺序同 Telegram：原始、正方形、3:2、5:3、4:3、5:4、7:5、16:9；竖的框倒过来写。
    func testPresetsMatchTelegramAndFollowTheCropOrientation() {
        XCTAssertEqual(AspectRatio.allCases.count, 8)
        let landscape = AspectRatio.allCases.dropFirst(2).map { $0.localizedTitle(isPortrait: false) }
        let portrait = AspectRatio.allCases.dropFirst(2).map { $0.localizedTitle(isPortrait: true) }
        let format = OWSLocalizedString("ASPECT_RATIO_X_BY_Y", comment: "")
        func title(_ width: Int, _ height: Int) -> String {
            String.nonPluralLocalizedStringWithFormat(format, OWSFormat.formatInt(width), OWSFormat.formatInt(height))
        }
        XCTAssertEqual(landscape, [title(3, 2), title(5, 3), title(4, 3), title(5, 4), title(7, 5), title(16, 9)])
        XCTAssertEqual(portrait, [title(2, 3), title(3, 5), title(3, 4), title(4, 5), title(5, 7), title(9, 16)])

        XCTAssertEqual(AspectRatio.threeByTwo.widthToHeight(originalWidthToHeight: 0.5, isPortrait: false), 1.5, accuracy: 0.0001)
        XCTAssertEqual(AspectRatio.threeByTwo.widthToHeight(originalWidthToHeight: 0.5, isPortrait: true), 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(AspectRatio.square.widthToHeight(originalWidthToHeight: 0.5, isPortrait: true), 1)
        XCTAssertEqual(AspectRatio.original.widthToHeight(originalWidthToHeight: 0.75, isPortrait: false), 0.75)
    }

    private let start = CGRect(x: 0, y: 0, width: 300, height: 200)
    private let minimumSize = CGSize(width: 40, height: 40)

    private func locked(_ region: CropRegion, proposed: CGRect, translation: CGPoint) -> CGRect {
        ImageEditorCropViewController.lockedCropRect(
            start: start,
            proposed: proposed,
            region: region,
            translation: translation,
            widthToHeight: 1.5,
            minimumSize: minimumSize,
        )
    }

    /// 拖角：挪得多的那个方向说了算，另一边按比例跟着收，对角不动。
    func testLockedCornerDragKeepsTheRatioAndTheOppositeCorner() {
        // 右下角往左上拖 60 / 10：横向多，按宽算高。
        let bottomRight = locked(.bottomRight, proposed: CGRect(x: 0, y: 0, width: 240, height: 190), translation: CGPoint(x: -60, y: -10))
        XCTAssertEqual(bottomRight, CGRect(x: 0, y: 0, width: 240, height: 160))

        // 左上角往右下拖 10 / 50：竖向多，按高算宽，右下角不动。
        let topLeft = locked(.topLeft, proposed: CGRect(x: 10, y: 50, width: 290, height: 150), translation: CGPoint(x: 10, y: 50))
        XCTAssertEqual(topLeft, CGRect(x: 75, y: 50, width: 225, height: 150))
    }

    /// 拖边：拖左右边按宽算高、上下以原来的中线为准；拖上下边按高算宽、左右以中线为准。
    func testLockedEdgeDragKeepsTheRatioAroundTheMiddle() {
        let right = locked(.right, proposed: CGRect(x: 0, y: 0, width: 150, height: 200), translation: CGPoint(x: -150, y: 0))
        XCTAssertEqual(right, CGRect(x: 0, y: 50, width: 150, height: 100))

        let top = locked(.top, proposed: CGRect(x: 0, y: 80, width: 300, height: 120), translation: CGPoint(x: 0, y: 80))
        XCTAssertEqual(top, CGRect(x: 60, y: 80, width: 180, height: 120))
    }

    /// 不小于最小尺寸，也不超出原来的框。
    func testLockedDragStaysWithinLimits() {
        let tiny = locked(.bottomRight, proposed: CGRect(x: 0, y: 0, width: 45, height: 190), translation: CGPoint(x: -255, y: -10))
        XCTAssertEqual(tiny.height, 40, accuracy: 0.0001, "高到了下限，宽按比例 60")
        XCTAssertEqual(tiny.width, 60, accuracy: 0.0001)

        let untouched = locked(.left, proposed: start, translation: .zero)
        XCTAssertEqual(untouched, start)
    }
}
