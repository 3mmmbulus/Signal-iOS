//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1522 E-2）：图片编辑器的箭头、霓虹、橡皮（照 Telegram 两端的画笔）。
final class TellomiImageEditorBrushTests: SignalBaseTest {

    // MARK: - Arrow

    /// 箭头从尖端往回，两臂 ±0.45 rad；长度取线宽 3 倍和图片长边 2% 里大的那个。
    func testArrowHeadGeometry() throws {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 300, y: 0)]
        let head = try XCTUnwrap(ImageEditorStrokeItem.arrowHead(points: points, strokeWidth: 20, imageLongSide: 1000))
        let length: CGFloat = 60
        XCTAssertEqual(head.tip, CGPoint(x: 300, y: 0))
        XCTAssertEqual(head.arm1.x, 300 + length * cos(.pi + ImageEditorStrokeItem.arrowArmAngle), accuracy: 0.001)
        XCTAssertEqual(head.arm1.y, length * sin(.pi + ImageEditorStrokeItem.arrowArmAngle), accuracy: 0.001)
        XCTAssertEqual(head.arm2.y, -head.arm1.y, accuracy: 0.001)

        // 线很细时，箭头至少是长边的 2%。
        let thin = try XCTUnwrap(ImageEditorStrokeItem.arrowHead(points: points, strokeWidth: 1, imageLongSide: 1000))
        XCTAssertEqual(hypot(thin.arm1.x - 300, thin.arm1.y), 20, accuracy: 0.001)
    }

    /// 抬手时的一点抖动不会把箭头带歪；没有方向时没有箭头。
    func testArrowHeadIgnoresAWobbleAndNeedsADirection() throws {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 303, y: 6)]
        let head = try XCTUnwrap(ImageEditorStrokeItem.arrowHead(points: points, strokeWidth: 20, imageLongSide: 1000))
        let middle = CGPoint(x: (head.arm1.x + head.arm2.x) / 2 - head.tip.x, y: (head.arm1.y + head.arm2.y) / 2 - head.tip.y)
        XCTAssertEqual(abs(atan2(middle.y, middle.x)), .pi, accuracy: 5 * .pi / 180)

        XCTAssertNil(ImageEditorStrokeItem.arrowHead(points: [CGPoint(x: 1, y: 1)], strokeWidth: 20, imageLongSide: 1000))
        XCTAssertNil(ImageEditorStrokeItem.arrowHead(points: [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 1)], strokeWidth: 20, imageLongSide: 1000))
    }

    /// 没抬手的箭头没有箭头，抬手后两臂是笔画图层的子图层。
    @MainActor
    func testArrowHeadAppearsOnlyWhenFinished() throws {
        let model = try Self.model(color: .gray)
        let drawing = Self.stroke(.arrow, color: .red, from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5), isFinished: false)
        model.append(item: drawing)
        let drawingLayer = try XCTUnwrap(ImageEditorCanvasView.layerForTesting(item: drawing, model: model, viewSize: CGSize(square: 400)))
        XCTAssertEqual(Self.arrowArms(in: drawingLayer), 0)

        let finished = Self.stroke(.arrow, color: .red, from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5), isFinished: true, itemId: drawing.itemId)
        model.replace(item: finished)
        let finishedLayer = try XCTUnwrap(ImageEditorCanvasView.layerForTesting(item: finished, model: model, viewSize: CGSize(square: 400)))
        XCTAssertEqual(Self.arrowArms(in: finishedLayer), 2)
    }

    // MARK: - Neon

    /// 霓虹：白芯、浅色身、笔色的光；几乎是黑色时黑芯紫光。
    func testNeonColors() {
        let green = ImageEditorCanvasView.neonColors(for: .green)
        XCTAssertEqual(green.core, .white)
        XCTAssertEqual(green.glow, .green)
        let black = ImageEditorCanvasView.neonColors(for: .black)
        XCTAssertEqual(black.core, .black)
        XCTAssertEqual(black.glow, UIColor(rgbHex: 0x440881))
    }

    // MARK: - Eraser

    /// 橡皮擦掉之前的笔画，露出照片；之后的笔画不擦。
    @MainActor
    func testEraserClearsEarlierStrokesOnlyInTheOutput() throws {
        let model = try Self.model(color: .blue)
        model.append(item: Self.stroke(.pen, color: .red, from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5)))
        model.append(item: Self.stroke(.eraser, color: .red, from: CGPoint(x: 0.5, y: 0.1), to: CGPoint(x: 0.5, y: 0.9)))
        model.append(item: Self.stroke(.pen, color: .yellow, from: CGPoint(x: 0.1, y: 0.25), to: CGPoint(x: 0.9, y: 0.25)))

        let output = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: model, transform: model.currentTransform()))
        let pixels = try XCTUnwrap(TellomiEyedropperPixels(image: output))

        Self.assertColor(pixels.color(atUnit: CGPoint(x: 0.3, y: 0.5)), .red, "red stroke away from the eraser")
        Self.assertColor(pixels.color(atUnit: CGPoint(x: 0.5, y: 0.5)), .blue, "red stroke under the eraser is gone, the photo shows")
        Self.assertColor(pixels.color(atUnit: CGPoint(x: 0.5, y: 0.25)), .yellow, "the stroke after the eraser stays")
        Self.assertColor(pixels.color(atUnit: CGPoint(x: 0.5, y: 0.75)), .blue, "the eraser on bare photo leaves the photo")
    }

    /// 橡皮在画笔那一层：之前的笔画下面压着，文字贴纸始终在它上面，所以擦不到文字。
    @MainActor
    func testEraserSitsBetweenEarlierStrokesAndText() throws {
        let model = try Self.model(color: .blue)
        let text = ImageEditorTextItem(
            text: "Hi",
            color: .white,
            fontSize: ImageEditorTextItem.defaultFontSize,
            decorationStyle: .none,
            textAlignment: .center,
            fontReferenceImageWidth: 400,
        )
        model.append(item: text)
        let pen = Self.stroke(.pen, color: .red, from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5))
        model.append(item: pen)
        let eraser = Self.stroke(.eraser, color: .red, from: CGPoint(x: 0.5, y: 0.1), to: CGPoint(x: 0.5, y: 0.9))
        model.append(item: eraser)
        let viewSize = CGSize(square: 400)

        let penLayer = try XCTUnwrap(ImageEditorCanvasView.layerForTesting(item: pen, model: model, viewSize: viewSize))
        let eraserLayer = try XCTUnwrap(ImageEditorCanvasView.layerForTesting(item: eraser, model: model, viewSize: viewSize))
        let textLayer = try XCTUnwrap(ImageEditorCanvasView.layerForTesting(item: text, model: model, viewSize: viewSize))
        XCTAssertGreaterThan(eraserLayer.zPosition, penLayer.zPosition)
        XCTAssertLessThan(eraserLayer.zPosition, textLayer.zPosition)
        XCTAssertNotNil(eraserLayer.mask, "the eraser shows the photo only along its own line")
    }

    // MARK: - Brush menu

    /// 菜单是 Telegram 的顺序；选了哪支笔，编辑器就用哪支笔、记它自己的粗细。
    @MainActor
    func testBrushMenuPicksTheStrokeType() throws {
        XCTAssertEqual(ImageEditorViewController.DrawToolbar.brushes, [.pen, .arrow, .highlighter, .neon, .eraser])

        let model = try Self.model(color: .gray)
        let editor = ImageEditorViewController(model: model, stickerSheetDelegate: nil)
        editor.loadViewIfNeeded()
        editor.mode = .draw

        let menu = try XCTUnwrap(editor.drawToolbar.strokeTypeButton.menu)
        XCTAssertEqual(menu.children.count, 6, "five brushes, then the shapes submenu (E-3)")
        XCTAssertTrue(editor.drawToolbar.strokeTypeButton.showsMenuAsPrimaryAction)

        editor.drawToolbar.select(strokeType: .neon)
        XCTAssertEqual(editor.currentStrokeType, .neon)
        XCTAssertEqual(editor.drawToolbar.strokeType, .neon)
        let neonMenu = try XCTUnwrap(editor.drawToolbar.strokeTypeButton.menu)
        let checked = neonMenu.children.compactMap { ($0 as? UIAction)?.state == .on ? ($0 as? UIAction)?.title : nil }
        XCTAssertEqual(checked, [ImageEditorViewController.DrawToolbar.title(for: .neon)])

        editor.handleSliderValueChanged(value: 1.5)
        editor.drawToolbar.select(strokeType: .eraser)
        XCTAssertEqual(editor.currentStrokeType, .eraser)
        editor.drawToolbar.select(strokeType: .neon)
        XCTAssertEqual(editor.strokeWidthSlider.value, 1.5, "each brush keeps its own width")
    }

    /// 每支笔各记各的颜色：没用过的从 Telegram 的默认色开始，橡皮不动色条，换回来还是上次的颜色。
    @MainActor
    func testEachBrushKeepsItsOwnColor() throws {
        let editor = ImageEditorViewController(model: try Self.model(color: .gray), stickerSheetDelegate: nil)
        editor.loadViewIfNeeded()
        editor.mode = .draw
        let penColor = editor.drawToolbar.colorPickerBar.uiColor

        editor.drawToolbar.select(strokeType: .arrow)
        XCTAssertEqual(editor.drawToolbar.colorPickerBar.uiColor, UIColor(rgbHex: 0xff8a00))
        XCTAssertEqual(editor.model.color.color, UIColor(rgbHex: 0xff8a00))

        let blue = ColorPickerBarColor(color: .blue, palettePhase: 5 / 8)
        editor.drawToolbar.colorPickerBar.color = blue
        editor.colorPickerBarValueChanged(color: blue)

        editor.drawToolbar.select(strokeType: .neon)
        XCTAssertEqual(editor.drawToolbar.colorPickerBar.uiColor, UIColor(rgbHex: 0x34c759))
        editor.drawToolbar.select(strokeType: .highlighter)
        XCTAssertEqual(editor.drawToolbar.colorPickerBar.uiColor, UIColor(rgbHex: 0xffd60a))

        editor.drawToolbar.select(strokeType: .eraser)
        XCTAssertEqual(editor.drawToolbar.colorPickerBar.uiColor, UIColor(rgbHex: 0xffd60a), "the eraser has no color")

        editor.drawToolbar.select(strokeType: .arrow)
        XCTAssertEqual(editor.drawToolbar.colorPickerBar.uiColor, .blue)
        editor.drawToolbar.select(strokeType: .pen)
        XCTAssertEqual(editor.drawToolbar.colorPickerBar.uiColor, penColor)
    }

    // MARK: - Long-press fill

    /// 长按填满（照两端 TG）：笔涂满整张（发出去的四角都是笔的颜色），一步撤销；荧光笔半透明。
    @MainActor
    func testFillCoversTheWholeCanvasAndIsOneUndoStep() throws {
        let model = try Self.model(color: .blue)
        let editor = ImageEditorViewController(model: model, stickerSheetDelegate: nil)
        let window = try Self.window(showing: editor)
        defer { window.isHidden = true }
        editor.mode = .draw
        XCTAssertTrue(editor.fillGestureRecognizer.isEnabled)
        let red = ColorPickerBarColor(color: .red, palettePhase: 0)
        editor.drawToolbar.colorPickerBar.color = red
        editor.colorPickerBarValueChanged(color: red)

        let fill = editor.fill(atLocationInView: .zero)
        XCTAssertTrue(fill.isFill)
        XCTAssertEqual(fill.strokeType, .pen)
        let output = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: model, transform: model.currentTransform()))
        let pixels = try XCTUnwrap(TellomiEyedropperPixels(image: output))
        for unit in [CGPoint(x: 0.02, y: 0.02), CGPoint(x: 0.98, y: 0.98), CGPoint(x: 0.5, y: 0.5)] {
            Self.assertColor(pixels.color(atUnit: unit), .red, "filled at \(unit)")
        }
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertFalse(model.items.contains { ($0 as? ImageEditorStrokeItem)?.isFill == true })

        editor.drawToolbar.select(strokeType: .neon)
        XCTAssertEqual(editor.fill(atLocationInView: .zero).strokeType, .pen, "neon fills like the pen (Telegram Android)")
        editor.drawToolbar.select(strokeType: .highlighter)
        let highlight = editor.fill(atLocationInView: .zero)
        XCTAssertEqual(highlight.strokeType, .highlighter)
        XCTAssertEqual(highlight.color?.cgColor.alpha ?? 1, ImageEditorViewController.highligherStrokeOpacity, accuracy: 0.01)
    }

    /// 橡皮长按：擦掉之前画的所有笔画，照片露出来；之后画的不受影响。打码模式长按是整张打码。
    @MainActor
    func testEraserFillClearsEarlierStrokesAndBlurFillBlursEverything() throws {
        let model = try Self.model(color: .blue)
        model.append(item: Self.stroke(.pen, color: .red, from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.9, y: 0.5)))
        let editor = ImageEditorViewController(model: model, stickerSheetDelegate: nil)
        let window = try Self.window(showing: editor)
        defer { window.isHidden = true }
        editor.mode = .draw
        editor.drawToolbar.select(strokeType: .eraser)
        XCTAssertEqual(editor.fill(atLocationInView: .zero).strokeType, .eraser)
        model.append(item: Self.stroke(.pen, color: .yellow, from: CGPoint(x: 0.1, y: 0.25), to: CGPoint(x: 0.9, y: 0.25)))

        let output = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: model, transform: model.currentTransform()))
        let pixels = try XCTUnwrap(TellomiEyedropperPixels(image: output))
        Self.assertColor(pixels.color(atUnit: CGPoint(x: 0.3, y: 0.5)), .blue, "the earlier stroke is gone")
        Self.assertColor(pixels.color(atUnit: CGPoint(x: 0.5, y: 0.25)), .yellow, "the later stroke stays")

        editor.mode = .blur
        XCTAssertTrue(editor.fillGestureRecognizer.isEnabled)
        XCTAssertEqual(editor.fill(atLocationInView: .zero).strokeType, .blur)
    }

    // MARK: - Screenshots

    /// 截图（TELLOMI_SHOTS=1）：发出去的图——笔、箭头、霓虹，一道橡皮竖着擦过；模糊一道在橡皮之前（被擦开）、一道在之后（留着）。
    @MainActor
    func testScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let directory = URL(fileURLWithPath: environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let size = CGSize(width: 600, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let checker = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for x in stride(from: 0, to: 600, by: 30) {
                for y in stride(from: 0, to: 800, by: 30) {
                    (((x + y) / 30) % 2 == 0 ? UIColor(rgbHex: 0xff8a00) : UIColor(rgbHex: 0x14142a)).setFill()
                    context.fill(CGRect(x: x, y: y, width: 30, height: 30))
                }
            }
        }
        let model = try ImageEditorModel(normalizedImage: NormalizedImage.forImage(checker))
        model.append(item: Self.stroke(.blur, color: .white, from: CGPoint(x: 0.1, y: 0.82), to: CGPoint(x: 0.9, y: 0.82)))
        model.append(item: Self.stroke(.pen, color: .red, from: CGPoint(x: 0.1, y: 0.2), to: CGPoint(x: 0.9, y: 0.2)))
        model.append(item: Self.stroke(.arrow, color: .red, from: CGPoint(x: 0.15, y: 0.45), to: CGPoint(x: 0.85, y: 0.32)))
        model.append(item: Self.stroke(.neon, color: .cyan, from: CGPoint(x: 0.1, y: 0.62), to: CGPoint(x: 0.9, y: 0.62)))
        model.append(item: Self.stroke(.eraser, color: .white, from: CGPoint(x: 0.5, y: 0.1), to: CGPoint(x: 0.5, y: 0.9)))
        model.append(item: Self.stroke(.blur, color: .white, from: CGPoint(x: 0.1, y: 0.92), to: CGPoint(x: 0.9, y: 0.92)))

        let output = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: model, transform: model.currentTransform()))
        try XCTUnwrap(output.pngData()).write(to: directory.appendingPathComponent("editor-brushes-output.png"))
    }

    // MARK: - Helpers

    /// 窗口挂在测试宿主的场景上（应用用 UIScene，`UIWindow(frame:)` 不排版），画布才有大小。
    @MainActor
    private static func window(showing viewController: UIViewController) throws -> UIWindow {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = viewController
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    @MainActor
    private static func model(color: UIColor) throws -> ImageEditorModel {
        try ImageEditorModel(normalizedImage: NormalizedImage.forImage(UIImage.image(color: color, size: CGSize(square: 400))))
    }

    private static func stroke(
        _ type: ImageEditorStrokeItem.StrokeType,
        color: UIColor,
        from start: CGPoint,
        to end: CGPoint,
        isFinished: Bool = true,
        itemId: String? = nil,
    ) -> ImageEditorStrokeItem {
        let samples = (0...8).map { step -> ImageEditorStrokeItem.StrokeSample in
            let t = CGFloat(step) / 8
            return ImageEditorSample(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
        let width = ImageEditorStrokeItem.unitStrokeWidth(forStrokeType: type, widthAdjustmentFactor: 1)
        if let itemId {
            return ImageEditorStrokeItem(itemId: itemId, color: color, strokeType: type, unitSamples: samples, unitStrokeWidth: width, isFinished: isFinished)
        }
        return ImageEditorStrokeItem(color: color, strokeType: type, unitSamples: samples, unitStrokeWidth: width, isFinished: isFinished)
    }

    private static func arrowArms(in layer: CALayer) -> Int {
        (layer.sublayers ?? []).filter { $0.name == ImageEditorCanvasView.arrowHeadLayerName }.count
    }

    private static func assertColor(_ actual: UIColor, _ expected: UIColor, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        actual.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        expected.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        XCTAssertEqual(r1, r2, accuracy: 0.05, "\(message) (red)", file: file, line: line)
        XCTAssertEqual(g1, g2, accuracy: 0.05, "\(message) (green)", file: file, line: line)
        XCTAssertEqual(b1, b2, accuracy: 0.05, "\(message) (blue)", file: file, line: line)
    }
}
