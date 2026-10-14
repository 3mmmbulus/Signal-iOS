//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1591 E5-1）：调色参数的数据模型——默认值、范围、序列化，以及放进图片编辑器模型后的撤销 / 重做与「编辑过」。
final class TellomiImageAdjustmentsTests: SignalBaseTest {

    // MARK: - Value type

    /// 默认值照 TG iOS：曲线 5 点 0 / 25 / 50 / 75 / 100，模糊中心 (0.5, 0.5)、大小 0.24、过渡 0.12、角度 0，色调强度 50。
    func testDefaultsFollowTelegramIOS() {
        let adjustments = TellomiImageAdjustments.default
        XCTAssertTrue(adjustments.isDefault)
        XCTAssertEqual(adjustments.scalars, Array(repeating: 0, count: 12))
        XCTAssertNil(adjustments.tintShadows)
        XCTAssertNil(adjustments.tintHighlights)
        for curve in [adjustments.curves.all, adjustments.curves.red, adjustments.curves.green, adjustments.curves.blue] {
            XCTAssertEqual(curve.values, [0, 25, 50, 75, 100])
        }
        XCTAssertEqual(adjustments.blur.kind, .off)
        XCTAssertEqual(adjustments.blur.centerX, 0.5)
        XCTAssertEqual(adjustments.blur.centerY, 0.5)
        XCTAssertEqual(adjustments.blur.size, 0.24)
        XCTAssertEqual(adjustments.blur.falloff, 0.12)
        XCTAssertEqual(adjustments.blur.angle, 0)
        XCTAssertEqual(TellomiImageAdjustments.tintIntensity, 50)
    }

    /// 任何一项离开默认值都算调过；模糊关着时只挪中心、大小不算。
    func testIsDefault() {
        for tool in TellomiImageAdjustments.Tool.allCases {
            var adjustments = TellomiImageAdjustments.default
            adjustments[tool] = 10
            XCTAssertFalse(adjustments.isDefault, "\(tool)")
            adjustments[tool] = 0
            XCTAssertTrue(adjustments.isDefault, "\(tool) 调回 0")
        }

        var tinted = TellomiImageAdjustments.default
        tinted.tintShadows = .init(red: 1, green: 0, blue: 0)
        XCTAssertFalse(tinted.isDefault)
        tinted.tintShadows = nil
        tinted.tintHighlights = .init(red: 0, green: 0, blue: 1)
        XCTAssertFalse(tinted.isDefault)

        var curved = TellomiImageAdjustments.default
        curved.curves.green.midtones = 60
        XCTAssertFalse(curved.isDefault)

        var blurred = TellomiImageAdjustments.default
        blurred.blur.centerX = 0.3
        blurred.blur.size = 0.5
        XCTAssertTrue(blurred.isDefault, "模糊关着，挪过的中心、大小不算")
        blurred.blur.kind = .linear
        XCTAssertFalse(blurred.isDefault)
    }

    /// 6 个双极（−100…100）、6 个单极（0…100）；写进去超范围的值夹到边上。
    func testToolRangesAndClamping() {
        let bipolar = TellomiImageAdjustments.Tool.allCases.filter(\.isBipolar)
        XCTAssertEqual(bipolar, [.exposure, .contrast, .saturation, .warmth, .highlights, .shadows])
        XCTAssertEqual(TellomiImageAdjustments.Tool.allCases.count, 12)

        var adjustments = TellomiImageAdjustments.default
        adjustments[.exposure] = 150
        XCTAssertEqual(adjustments.exposure, 100)
        adjustments[.shadows] = -150
        XCTAssertEqual(adjustments.shadows, -100)
        adjustments[.fade] = -20
        XCTAssertEqual(adjustments.fade, 0)
        adjustments[.grain] = 101
        XCTAssertEqual(adjustments.grain, 100)
        adjustments[.contrast] = -35
        XCTAssertEqual(adjustments[.contrast], -35)
    }

    /// 编码再解码，每个字段都原样回来（默认值和全调过的都试）。
    func testCodableRoundTrip() throws {
        var adjustments = TellomiImageAdjustments.default
        for (index, tool) in TellomiImageAdjustments.Tool.allCases.enumerated() {
            adjustments[tool] = Float(index + 1) * (tool.isBipolar ? -7 : 7)
        }
        adjustments.tintShadows = .init(red: 0.1, green: 0.2, blue: 0.3)
        adjustments.tintHighlights = .init(red: 0.9, green: 0.8, blue: 0.7)
        adjustments.curves.all.blacks = 5
        adjustments.curves.red.shadows = 30
        adjustments.curves.green.midtones = 45
        adjustments.curves.blue.highlights = 80
        adjustments.curves.blue.whites = 95
        adjustments.blur = {
            var blur = TellomiImageAdjustments.Blur()
            blur.kind = .radial
            blur.centerX = 0.25
            blur.centerY = 0.75
            blur.size = 0.4
            blur.falloff = 0.2
            blur.angle = .pi / 3
            return blur
        }()
        XCTAssertFalse(adjustments.isDefault)

        for value in [adjustments, .default] {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(TellomiImageAdjustments.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    // MARK: - Editor model

    /// 调色进撤销 / 重做；调过色算「编辑过」（高清项、按文件发时发编辑后的图），撤回到默认就不算。
    @MainActor
    func testReplaceAdjustmentsUndoRedoAndDirty() throws {
        let model = try makeModel()
        XCTAssertFalse(model.isDirty, "不调色：发出时走原图，和现在一样")
        XCTAssertTrue(model.adjustments.isDefault)

        var warmer = TellomiImageAdjustments.default
        warmer.warmth = 40
        model.replace(adjustments: warmer)
        XCTAssertEqual(model.adjustments, warmer)
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.canUndo)

        model.undo()
        XCTAssertTrue(model.adjustments.isDefault)
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(model.canRedo)

        model.redo()
        XCTAssertEqual(model.adjustments, warmer)
        XCTAssertTrue(model.isDirty)
    }

    /// 拖一次滑杆（第一下记撤销，后面 suppressUndo）只占一步撤销，撤回到拖之前。
    @MainActor
    func testOneDragIsOneUndoStep() throws {
        let model = try makeModel()
        for (step, exposure) in [10, 20, 30].enumerated() {
            var adjustments = model.adjustments
            adjustments.exposure = Float(exposure)
            model.replace(adjustments: adjustments, suppressUndo: step > 0)
        }
        XCTAssertEqual(model.adjustments.exposure, 30)

        model.undo()
        XCTAssertTrue(model.adjustments.isDefault)
        XCTAssertFalse(model.canUndo)
    }

    /// 换成一样的调色：不记撤销，也不通知重绘。
    @MainActor
    func testReplacingWithTheSameAdjustmentsDoesNothing() throws {
        let model = try makeModel()
        let observer = RecordingObserver()
        model.add(observer: observer)

        model.replace(adjustments: .default)
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(observer.fullReloads, 0)
    }

    /// 调色改的是底图：通知整份重载（before / after 里能看到调色变了）。
    @MainActor
    func testAdjustmentChangeReloadsTheWholeCanvas() throws {
        let model = try makeModel()
        let observer = RecordingObserver()
        model.add(observer: observer)

        var adjustments = TellomiImageAdjustments.default
        adjustments.vignette = 50
        model.replace(adjustments: adjustments)

        XCTAssertEqual(observer.fullReloads, 1)
        XCTAssertEqual(observer.itemChanges, 0)
        XCTAssertEqual(observer.lastBefore?.adjustments, .default)
        XCTAssertEqual(observer.lastAfter?.adjustments, adjustments)
    }

    /// 调色和画上去的元素在同一份快照里：撤销一个元素时调色不丢。
    @MainActor
    func testUndoingAnItemKeepsTheAdjustments() throws {
        let model = try makeModel()
        var adjustments = TellomiImageAdjustments.default
        adjustments.contrast = -20
        model.replace(adjustments: adjustments)

        model.append(item: ImageEditorStrokeItem(
            color: .white,
            strokeType: .pen,
            unitSamples: [ImageEditorSample(x: 0.1, y: 0.1), ImageEditorSample(x: 0.9, y: 0.9)],
            unitStrokeWidth: 0.05,
        ))
        XCTAssertEqual(model.itemCount, 1)

        model.undo()
        XCTAssertEqual(model.itemCount, 0)
        XCTAssertEqual(model.adjustments, adjustments)
        XCTAssertTrue(model.isDirty, "还调着色")

        model.undo()
        XCTAssertTrue(model.adjustments.isDefault)
        XCTAssertFalse(model.isDirty)
    }

    // MARK: - Helpers

    @MainActor
    private func makeModel() throws -> ImageEditorModel {
        try ImageEditorModel(normalizedImage: NormalizedImage.forImage(UIImage.image(color: .gray, size: CGSize(square: 400))))
    }

    private final class RecordingObserver: ImageEditorModelObserver {
        var fullReloads = 0
        var itemChanges = 0
        var lastBefore: ImageEditorContents?
        var lastAfter: ImageEditorContents?

        func imageEditorModelDidChange(before: ImageEditorContents, after: ImageEditorContents) {
            fullReloads += 1
            lastBefore = before
            lastAfter = after
        }

        func imageEditorModelDidChange(changedItemIds: [String]) {
            itemChanges += 1
        }
    }
}
