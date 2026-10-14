//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1593 E5-3）：调色页——行、数值写法、拖动 / 完成 / 取消和撤销、按住看原图。
@MainActor
final class TellomiImageAdjustViewControllerTests: SignalBaseTest {

    /// 数值照 Telegram iOS：值 ÷ 最大值、两位小数、带正负号；0 时不显示。
    func testValueText() {
        let bipolar: ClosedRange<Float> = -100...100
        XCTAssertNil(TellomiImageAdjustViewController.valueText(0, range: bipolar))
        XCTAssertEqual(TellomiImageAdjustViewController.valueText(35, range: bipolar), "+0.35")
        XCTAssertEqual(TellomiImageAdjustViewController.valueText(-35, range: bipolar), "-0.35")
        XCTAssertEqual(TellomiImageAdjustViewController.valueText(100, range: bipolar), "+1.00")
        XCTAssertEqual(TellomiImageAdjustViewController.valueText(50, range: 0...100), "+0.50")
        XCTAssertEqual(TellomiImageAdjustViewController.hudText(tool: .exposure, value: 35), "Exposure +0.35")
        XCTAssertEqual(TellomiImageAdjustViewController.hudText(tool: .warmth, value: 0), "Warmth 0.00")
    }

    /// 行是已经能画的那几项，顺序照 Telegram iOS（曝光、对比度、饱和度、色温、褪色、高光、阴影）；每行的滑杆范围对。
    func testRowsAreTheRenderedToolsInTelegramOrder() throws {
        let (viewController, _) = try makeViewController()
        XCTAssertEqual(viewController.rowToolsForTesting, [.exposure, .contrast, .saturation, .warmth, .fade, .highlights, .shadows])
        XCTAssertEqual(try XCTUnwrap(viewController.sliderForTesting(.fade)).range, 0...100, "褪色是单极的")
        XCTAssertEqual(try XCTUnwrap(viewController.sliderForTesting(.exposure)).range, -100...100)
    }

    /// 拖动中改的是预览、不记撤销；完成后整段只占一步撤销。
    func testDoneIsOneUndoStep() throws {
        let (viewController, model) = try makeViewController()
        let slider = try XCTUnwrap(viewController.sliderForTesting(.exposure))

        slider.updateValue(20)
        slider.updateValue(40)
        XCTAssertEqual(model.adjustments.exposure, 40, "预览跟着变")
        XCTAssertFalse(model.canUndo, "拖动中不记撤销")
        XCTAssertEqual(viewController.valueTextForTesting(.exposure), "+0.40")

        try XCTUnwrap(viewController.sliderForTesting(.warmth)).updateValue(-25)
        viewController.finish(done: true)

        XCTAssertEqual(model.adjustments.exposure, 40)
        XCTAssertEqual(model.adjustments.warmth, -25)
        XCTAssertTrue(model.isDirty)
        model.undo()
        XCTAssertTrue(model.adjustments.isDefault, "一步撤销回到打开前")
        XCTAssertFalse(model.canUndo)
    }

    /// 取消：回到打开时的样子，不留撤销。
    func testCancelRestoresTheAdjustmentsFromBefore() throws {
        let model = try makeModel()
        var before = TellomiImageAdjustments.default
        before.contrast = 30
        model.replace(adjustments: before)
        let viewController = TellomiImageAdjustViewController(model: model)
        viewController.loadViewIfNeeded()
        XCTAssertEqual(try XCTUnwrap(viewController.sliderForTesting(.contrast)).value, 30, "滑杆从现在的值开始")

        try XCTUnwrap(viewController.sliderForTesting(.contrast)).updateValue(-60)
        try XCTUnwrap(viewController.sliderForTesting(.saturation)).updateValue(50)
        viewController.finish(done: false)

        XCTAssertEqual(model.adjustments, before)
        model.undo()
        XCTAssertTrue(model.adjustments.isDefault, "撤销栈里只有打开前那一步")
        XCTAssertFalse(model.canUndo)
    }

    /// 色调页签：切过去显示阴影 / 高光两组色块；点色块改预览，完成时整段算一步撤销；「不加」把色调去掉。
    func testTintTab() throws {
        let (viewController, model) = try makeViewController()
        XCTAssertFalse(viewController.isTintTabShownForTesting)
        viewController.showTintTabForTesting(true)
        XCTAssertTrue(viewController.isTintTabShownForTesting)

        let panel = viewController.tintPanelForTesting
        XCTAssertTrue(panel.editsShadows)
        XCTAssertEqual(panel.swatches.count, 8)
        XCTAssertTrue(panel.swatches[0].isSelected, "一开始是「不加」")
        panel.swatches[2].sendActions(for: .touchUpInside)
        XCTAssertEqual(model.adjustments.tintShadows, TellomiImageAdjustments.TintColor.shadowsPalette[2])
        XCTAssertTrue(panel.swatches[2].isSelected)

        panel.setEditsShadows(false)
        XCTAssertTrue(panel.swatches[0].isSelected, "高光还没选")
        panel.swatches[6].sendActions(for: .touchUpInside)
        XCTAssertEqual(model.adjustments.tintHighlights, TellomiImageAdjustments.TintColor.highlightsPalette[6])
        XCTAssertFalse(model.canUndo, "选色块时不记撤销")

        viewController.finish(done: true)
        model.undo()
        XCTAssertTrue(model.adjustments.isDefault)
    }

    /// 按住照片：画布临时换回原图、提示「原图」；松手回到调色后的样子。模型一直不动。
    func testHoldingShowsTheOriginal() throws {
        let (viewController, model) = try makeViewController()
        let window = try makeWindow()
        window.rootViewController = viewController
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        try XCTUnwrap(viewController.sliderForTesting(.exposure)).updateValue(60)
        let canvas = viewController.canvasViewForTesting
        let adjusted = try XCTUnwrap(canvas.tellomiDisplayedBaseImageForTesting)

        viewController.setShowsOriginal(true)
        let original = try XCTUnwrap(canvas.tellomiDisplayedBaseImageForTesting)
        XCTAssertFalse(original === adjusted)
        XCTAssertEqual(viewController.hudTextForTesting, "Original")
        XCTAssertEqual(model.adjustments.exposure, 60, "模型不动")

        viewController.setShowsOriginal(false)
        XCTAssertTrue(try XCTUnwrap(canvas.tellomiDisplayedBaseImageForTesting) === adjusted)
        XCTAssertNil(viewController.hudTextForTesting)
    }

    /// 截图（TELLOMI_SHOTS=1）：调色页（曝光 +0.35、色温 −0.20），以及按住看原图。
    func testScreenshots() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let directory = URL(fileURLWithPath: environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = try ImageEditorModel(normalizedImage: NormalizedImage.forImage(Self.samplePhoto()))
        let viewController = TellomiImageAdjustViewController(model: model)
        let window = try makeWindow()
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = viewController
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        try XCTUnwrap(viewController.sliderForTesting(.exposure)).updateValue(35)
        try XCTUnwrap(viewController.sliderForTesting(.warmth)).updateValue(-20)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        try save(window, as: "adjust-panel", in: directory)

        viewController.setShowsOriginal(true)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        try save(window, as: "adjust-hold-original", in: directory)
        viewController.setShowsOriginal(false)

        viewController.showTintTabForTesting(true)
        viewController.tintPanelForTesting.swatches[5].sendActions(for: .touchUpInside)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        try save(window, as: "adjust-tint", in: directory)
    }

    // MARK: - Helpers

    /// 窗口要挂在测试宿主的场景上（应用用 UIScene 之后，`UIWindow(frame:)` 不上屏，截出来是白的）。
    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        return window
    }

    private func makeModel() throws -> ImageEditorModel {
        try ImageEditorModel(normalizedImage: NormalizedImage.forImage(UIImage.image(color: .gray, size: CGSize(square: 400))))
    }

    private func makeViewController() throws -> (TellomiImageAdjustViewController, ImageEditorModel) {
        let model = try makeModel()
        let viewController = TellomiImageAdjustViewController(model: model)
        viewController.loadViewIfNeeded()
        return (viewController, model)
    }

    /// 一张有天空、地面和渐变的假照片，看得出调色。
    private static func samplePhoto() -> UIImage {
        let size = CGSize(width: 1200, height: 900)
        return UIGraphicsImageRenderer(size: size, format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }()).image { context in
            let colors = [UIColor(red: 0.35, green: 0.6, blue: 0.9, alpha: 1).cgColor, UIColor(red: 0.95, green: 0.8, blue: 0.6, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height * 0.6), options: [])
            UIColor(red: 0.25, green: 0.45, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.6, width: size.width, height: size.height * 0.4))
            UIColor(red: 0.9, green: 0.3, blue: 0.25, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 760, y: 420, width: 260, height: 260))
        }
    }

    private func save(_ window: UIWindow, as name: String, in directory: URL) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let folder = directory.appendingPathComponent("\(Int(window.bounds.size.width))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent("\(name).png"))
    }
}
