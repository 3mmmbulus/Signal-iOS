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
        XCTAssertEqual(viewController.rowToolsForTesting, [.enhance, .exposure, .contrast, .saturation, .warmth, .fade, .highlights, .shadows, .vignette, .grain, .sharpen])
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

    /// 曲线页签（E5-7）：照片上盖曲线层、面板换成「全部 / 红 / 绿 / 蓝」；在哪一段拖就改哪个点（点跟着手指，拖过整个高度 = 100），
    /// 换通道改的是那条；完成算一步撤销，取消回到打开时的样子。
    func testCurvesTab() throws {
        let (viewController, model) = try makeViewController()
        let window = try makeWindow()
        window.rootViewController = viewController
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        let overlay = viewController.curvesOverlayForTesting
        XCTAssertTrue(overlay.isHidden)
        viewController.showTabForTesting(.curves)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertFalse(viewController.curvesPanelForTesting.isHidden)
        XCTAssertTrue(try XCTUnwrap(viewController.curvesPanelForTesting.buttons[.all]).isSelected)
        XCTAssertEqual(overlay.frame.size, viewController.canvasViewForTesting.gestureReferenceView.bounds.size, "曲线层和照片一样大")

        XCTAssertEqual(TellomiCurvesOverlayView.segment(at: 0, width: 500), 0)
        XCTAssertEqual(TellomiCurvesOverlayView.segment(at: 250, width: 500), 2)
        XCTAssertEqual(TellomiCurvesOverlayView.segment(at: 499, width: 500), 4)
        XCTAssertEqual(TellomiCurvesOverlayView.segment(at: 600, width: 500), 4)

        overlay.drag(segment: 2, by: 20)
        XCTAssertEqual(model.adjustments.curves.all.midtones, 70)
        overlay.drag(segment: 4, by: 30)
        XCTAssertEqual(model.adjustments.curves.all.whites, 100, "夹在 0…100")

        try XCTUnwrap(viewController.curvesPanelForTesting.buttons[.red]).sendActions(for: .touchUpInside)
        XCTAssertEqual(overlay.channel, .red)
        overlay.drag(segment: 0, by: 12)
        XCTAssertEqual(model.adjustments.curves.red.blacks, 12)
        XCTAssertEqual(model.adjustments.curves.all.midtones, 70, "别的通道不动")
        XCTAssertEqual(TellomiCurvesOverlayView.valueText(model.adjustments.curves.red.blacks), "0.12")

        XCTAssertFalse(model.canUndo, "拖的时候不记撤销")
        viewController.finish(done: true)
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertTrue(model.adjustments.curves.isDefault, "一步撤销回到打开前")
    }

    /// 模糊页签（E5-8）：选径向 / 线性 / 关；照片上按中心拖挪中心、按外圈拖改外半径、两指捏一起缩放、线性时在外面拖转角度；
    /// 完成算一步撤销。
    func testBlurTab() throws {
        let (viewController, model) = try makeViewController()
        let window = try makeWindow()
        window.rootViewController = viewController
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        viewController.showTabForTesting(.blur)
        let overlay = viewController.blurOverlayForTesting
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(try XCTUnwrap(viewController.blurPanelForTesting.buttons[.off]).isSelected)
        try XCTUnwrap(viewController.blurPanelForTesting.buttons[.radial]).sendActions(for: .touchUpInside)
        XCTAssertEqual(model.adjustments.blur.kind, .radial)
        XCTAssertTrue(try XCTUnwrap(viewController.blurPanelForTesting.buttons[.radial]).isSelected)

        let mapping = try XCTUnwrap(overlay.mappingProvider?(overlay.bounds.size))
        let center = mapping.view(fromUnit: SIMD2(0.5, 0.5))
        XCTAssertEqual(overlay.control(at: center), .center)
        let outerPoint = CGPoint(x: center.x + CGFloat(model.adjustments.blur.size) * mapping.shortSideInView, y: center.y)
        XCTAssertEqual(overlay.control(at: outerPoint), .outer)
        XCTAssertNil(overlay.control(at: CGPoint(x: 2, y: 2)), "径向时别处不动")

        overlay.drag(.center, from: center, to: CGPoint(x: center.x + 40, y: center.y), startBlur: model.adjustments.blur, mapping: mapping)
        XCTAssertGreaterThan(model.adjustments.blur.centerX, 0.5)
        XCTAssertEqual(model.adjustments.blur.centerY, 0.5, accuracy: 1e-4)

        let before = model.adjustments.blur
        overlay.drag(.outer, from: outerPoint, to: CGPoint(x: outerPoint.x + 30, y: outerPoint.y), startBlur: before, mapping: mapping)
        XCTAssertGreaterThan(model.adjustments.blur.size, before.size)
        XCTAssertEqual(model.adjustments.blur.falloff, before.falloff)

        let pinched = model.adjustments.blur
        overlay.pinch(scale: 0.5, startBlur: pinched)
        XCTAssertEqual(model.adjustments.blur.falloff, pinched.falloff * 0.5, accuracy: 1e-5)
        XCTAssertEqual(model.adjustments.blur.size, pinched.size * 0.5, accuracy: 1e-5)

        try XCTUnwrap(viewController.blurPanelForTesting.buttons[.linear]).sendActions(for: .touchUpInside)
        let linear = model.adjustments.blur
        XCTAssertEqual(linear.kind, .linear)
        let linearCenter = mapping.view(fromUnit: SIMD2(linear.centerX, linear.centerY))
        // 横带：正下方离那条线远（在外圈外面）的地方按住拖 = 转。
        let far = CGPoint(x: linearCenter.x, y: linearCenter.y + 200)
        XCTAssertEqual(overlay.control(at: far), .rotation)
        overlay.drag(.rotation, from: far, to: CGPoint(x: linearCenter.x + 200, y: linearCenter.y + 50), startBlur: linear, mapping: mapping)
        XCTAssertNotEqual(model.adjustments.blur.angle, linear.angle)

        XCTAssertFalse(model.canUndo, "拖的时候不记撤销")
        viewController.finish(done: true)
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertEqual(model.adjustments.blur.kind, .off, "一步撤销回到打开前")
    }

    /// 美肤（E5-9）：没认出人脸时没有这一行；认出了加在最上面；已经磨过的照片再打开直接有。
    func testSkinRowAppearsWithFaces() throws {
        let (viewController, _) = try makeViewController()
        XCTAssertFalse(viewController.rowToolsForTesting.contains(.skin), "灰图没有人脸")
        viewController.showSkinRow()
        XCTAssertEqual(viewController.rowToolsForTesting.first, .skin)
        viewController.showSkinRow()
        XCTAssertEqual(viewController.rowToolsForTesting.filter { $0 == .skin }.count, 1)

        let model = try makeModel()
        var adjustments = TellomiImageAdjustments.default
        adjustments.skin = 30
        model.replace(adjustments: adjustments)
        let reopened = TellomiImageAdjustViewController(model: model)
        reopened.loadViewIfNeeded()
        XCTAssertEqual(reopened.rowToolsForTesting.first, .skin)
    }

    /// 截图（TELLOMI_SHOTS=1）：调色页（曝光 +0.35、色温 −0.20），按住看原图，色调页，暗角 / 颗粒 / 锐化和发出的图，曲线页签，模糊页签。
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

        // E5-5：暗角、颗粒、锐化（列表滚到底看新加的三行），再存一张发出的原尺寸图看效果。
        viewController.showTintTabForTesting(false)
        let vignetteSlider = try XCTUnwrap(viewController.sliderForTesting(.vignette))
        vignetteSlider.updateValue(100)
        try XCTUnwrap(viewController.sliderForTesting(.grain)).updateValue(60)
        try XCTUnwrap(viewController.sliderForTesting(.sharpen)).updateValue(60)
        var ancestor: UIView? = vignetteSlider
        while let view = ancestor, !(view is UIScrollView) {
            ancestor = view.superview
        }
        if let scrollView = ancestor as? UIScrollView {
            scrollView.setContentOffset(CGPoint(x: 0, y: max(0, scrollView.contentSize.height - scrollView.bounds.size.height)), animated: false)
        }
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        try save(window, as: "adjust-detail", in: directory)
        let output = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: model, transform: model.currentTransform()))
        try XCTUnwrap(output.pngData()).write(to: directory.appendingPathComponent("\(Int(window.bounds.size.width))/adjust-detail-output.png"))

        // E5-7：曲线页签，「全部」拉成 S 形，再切到红色抬一点暗部。
        viewController.showTabForTesting(.curves)
        let overlay = viewController.curvesOverlayForTesting
        overlay.drag(segment: 1, by: -10)
        overlay.drag(segment: 3, by: 10)
        try XCTUnwrap(viewController.curvesPanelForTesting.buttons[.red]).sendActions(for: .touchUpInside)
        overlay.drag(segment: 1, by: 12)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        try save(window, as: "adjust-curves", in: directory)

        // E5-8：模糊页签，径向挪到红太阳上，再存一张线性的。
        viewController.showTabForTesting(.blur)
        try XCTUnwrap(viewController.blurPanelForTesting.buttons[.radial]).sendActions(for: .touchUpInside)
        let blurOverlay = viewController.blurOverlayForTesting
        window.layoutIfNeeded()
        let mapping = try XCTUnwrap(blurOverlay.mappingProvider?(blurOverlay.bounds.size))
        blurOverlay.drag(
            .center,
            from: mapping.view(fromUnit: SIMD2(0.5, 0.5)),
            to: mapping.view(fromUnit: SIMD2(890 / 1200, 550 / 900)),
            startBlur: model.adjustments.blur,
            mapping: mapping,
        )
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        try save(window, as: "adjust-blur-radial", in: directory)
        try XCTUnwrap(viewController.blurPanelForTesting.buttons[.linear]).sendActions(for: .touchUpInside)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        try save(window, as: "adjust-blur-linear", in: directory)

        // E5-9：只开增强 100 的发出图，和原图并排看程度。
        let enhanceModel = try ImageEditorModel(normalizedImage: NormalizedImage.forImage(Self.samplePhoto()))
        var enhanced = TellomiImageAdjustments.default
        enhanced.enhance = 100
        enhanceModel.replace(adjustments: enhanced)
        let enhancedOutput = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: enhanceModel, transform: enhanceModel.currentTransform()))
        try XCTUnwrap(enhancedOutput.pngData()).write(to: directory.appendingPathComponent("\(Int(window.bounds.size.width))/adjust-enhance-output.png"))
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
