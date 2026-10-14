//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1522 E-2）：图片编辑器的吸管（照 Telegram iOS `EyedropperView`）。
final class TellomiImageEditorEyedropperTests: SignalBaseTest {

    /// 像素按行从上往下读：上半红、下半蓝，取上面得红、取下面得蓝，越界取边上的。
    func testPixelsReadTopToBottom() throws {
        let image = Self.image(size: CGSize(width: 10, height: 10)) { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 5))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 5, width: 10, height: 5))
        }
        let pixels = try XCTUnwrap(TellomiEyedropperPixels(image: image))
        XCTAssertEqual(pixels.width, 10)
        XCTAssertEqual(pixels.height, 10)
        Self.assertColor(pixels.color(atUnit: CGPoint(x: 0.5, y: 0.1)), .red)
        Self.assertColor(pixels.color(atUnit: CGPoint(x: 0.5, y: 0.9)), .blue)
        Self.assertColor(pixels.color(atUnit: CGPoint(x: -1, y: -1)), .red)
        Self.assertColor(pixels.color(atUnit: CGPoint(x: 2, y: 2)), .blue)
    }

    /// 放大镜从正中开始，按位移挪、不出边；松手交出中心那个像素的颜色，取过就不再响应。
    @MainActor
    func testMagnifierMovesByTranslationAndPicksOnRelease() {
        let size = CGSize(width: 300, height: 300)
        let snapshot = Self.image(size: size) { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 150, height: 300))
            UIColor.white.setFill()
            context.fill(CGRect(x: 150, y: 0, width: 150, height: 300))
        }
        let eyedropper = TellomiEyedropperView(snapshot: snapshot)
        eyedropper.frame = CGRect(origin: .zero, size: size)
        eyedropper.layoutIfNeeded()

        XCTAssertEqual(eyedropper.magnifierCenter, CGPoint(x: 150, y: 150))
        XCTAssertEqual(eyedropper.samplePoint, CGPoint(x: 150.5, y: 150.5))
        Self.assertColor(eyedropper.currentColor, .white)

        eyedropper.moveMagnifier(by: CGPoint(x: -100, y: 30))
        XCTAssertEqual(eyedropper.magnifierCenter, CGPoint(x: 50, y: 180))
        Self.assertColor(eyedropper.currentColor, .green)

        eyedropper.moveMagnifier(by: CGPoint(x: -1000, y: 1000))
        XCTAssertEqual(eyedropper.magnifierCenter, CGPoint(x: 0, y: 300), "放大镜中心不出边")
        XCTAssertEqual(eyedropper.samplePoint, CGPoint(x: 0.5, y: 299.5))

        var picked = [UIColor]()
        eyedropper.onPicked = { color in
            picked.append(color)
            eyedropper.dismiss(animated: false)
        }
        eyedropper.finishPicking()
        eyedropper.finishPicking()
        XCTAssertEqual(picked.count, 1)
        Self.assertColor(picked.first, .green)
        XCTAssertTrue(eyedropper.isDismissing)
    }

    /// 很浅的颜色（亮度 > 0.9）放大镜换深色格线、灰圈（照 Telegram）。
    func testLightnessThreshold() {
        XCTAssertGreaterThan(TellomiEyedropperView.lightness(of: .white), 0.9)
        XCTAssertGreaterThan(TellomiEyedropperView.lightness(of: UIColor(white: 0.95, alpha: 1)), 0.9)
        XCTAssertLessThan(TellomiEyedropperView.lightness(of: .yellow), 0.9)
        XCTAssertLessThan(TellomiEyedropperView.lightness(of: .black), 0.9)
    }

    /// 只换了颜色、滑块位置没动，也算改了（不然写文字时吸管取的颜色会被当成“没改”丢掉）。
    func testColorPickerBarColorComparesTheColorToo() {
        let palette = ColorPickerBarColor(color: .red, palettePhase: 0.5)
        XCTAssertTrue(palette == ColorPickerBarColor(color: .red, palettePhase: 0.5))
        XCTAssertFalse(palette == ColorPickerBarColor(color: .green, palettePhase: 0.5))
        XCTAssertFalse(palette == ColorPickerBarColor(color: .red, palettePhase: 0.6))

        let textItem = ImageEditorTextItem(
            text: "Hi",
            color: palette,
            fontSize: ImageEditorTextItem.defaultFontSize,
            decorationStyle: .none,
            textAlignment: .center,
            fontReferenceImageWidth: 400,
        )
        XCTAssertNotEqual(textItem, textItem.with(color: ColorPickerBarColor(color: .green, palettePhase: 0.5)))
    }

    /// 画笔模式：点吸管键盖一层在画布上，取到的颜色给画笔色条（滑块不动），再点一次收起。
    @MainActor
    func testDrawModeEyedropperFeedsTheBrushColor() throws {
        let (window, editor) = try Self.hostEditor(imageColor: UIColor(rgbHex: 0x3a7bd5))
        defer { window.isHidden = true }
        XCTAssertEqual(editor.mode, .draw)
        let phaseBefore = editor.drawToolbar.colorPickerBar.color.palettePhase
        XCTAssertTrue(editor.drawToolbar.eyedropperButton.isDescendant(of: editor.drawToolbar))
        XCTAssertNotNil(editor.drawToolbar.eyedropperButton.accessibilityLabel)

        editor.didTapEyedropperButton()
        let eyedropper = try XCTUnwrap(editor.eyedropperView)
        XCTAssertEqual(eyedropper.frame, editor.imageEditorView.frame)
        XCTAssertTrue(eyedropper.superview === editor.view)
        let subviews = editor.view.subviews
        XCTAssertLessThan(
            try XCTUnwrap(subviews.firstIndex(of: eyedropper)),
            try XCTUnwrap(subviews.firstIndex(of: editor.drawToolbar)),
            "吸管在工具条下面，工具条还能点",
        )

        // 画布正中是图片。
        eyedropper.finishPicking()
        Self.assertColor(editor.drawToolbar.colorPickerBar.uiColor, UIColor(rgbHex: 0x3a7bd5), tolerance: 0.02)
        Self.assertColor(editor.model.color.color, UIColor(rgbHex: 0x3a7bd5), tolerance: 0.02)
        XCTAssertEqual(editor.drawToolbar.colorPickerBar.color.palettePhase, phaseBefore, accuracy: 0.0001)
        XCTAssertTrue(eyedropper.isDismissing)

        // 再点一次打开，再点一次收起。
        editor.didTapEyedropperButton()
        let second = try XCTUnwrap(editor.eyedropperView)
        XCTAssertFalse(second.isDismissing)
        editor.didTapEyedropperButton()
        XCTAssertTrue(second.isDismissing)

        // 换工具时收起。
        editor.didTapEyedropperButton()
        let third = try XCTUnwrap(editor.eyedropperView)
        editor.mode = .blur
        XCTAssertTrue(third.isDismissing)
        XCTAssertNil(editor.eyedropperView)
    }

    /// 截图（TELLOMI_SHOTS=1）：画笔工具条多了吸管键、吸管打开时的放大镜。
    @MainActor
    func testScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let directory = URL(fileURLWithPath: environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 编辑器出现前工具条是隐藏的（等出现动画），工具条单独拍。
        let toolbarWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 160))
        toolbarWindow.overrideUserInterfaceStyle = .dark
        let host = UIViewController()
        host.view.backgroundColor = .black
        toolbarWindow.rootViewController = host
        toolbarWindow.isHidden = false
        let toolbar = ImageEditorViewController.DrawToolbar(currentColor: .defaultColor)
        toolbar.frame = host.view.bounds
        host.view.addSubview(toolbar)
        toolbarWindow.layoutIfNeeded()
        let toolbarShot = UIGraphicsImageRenderer(bounds: toolbarWindow.bounds).image { _ in
            toolbarWindow.drawHierarchy(in: toolbarWindow.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(toolbarShot.pngData()).write(to: directory.appendingPathComponent("editor-eyedropper-toolbar.png"))
        toolbarWindow.isHidden = true

        let (window, editor) = try Self.hostEditor(imageColor: nil)
        defer { window.isHidden = true }

        editor.didTapEyedropperButton()
        let eyedropper = try XCTUnwrap(editor.eyedropperView)
        eyedropper.moveMagnifier(by: CGPoint(x: -40, y: -60))
        UIView.performWithoutAnimation { window.layoutIfNeeded() }
        // 跳过出现的弹簧动画，直接看停下来的样子。
        eyedropper.layer.removeAllAnimations()
        eyedropper.subviews.forEach {
            $0.layer.removeAllAnimations()
            $0.transform = .identity
            $0.alpha = 1
        }
        let pickingShot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(pickingShot.pngData()).write(to: directory.appendingPathComponent("editor-eyedropper-picking.png"))
    }

    // MARK: - Helpers

    @MainActor
    private static func hostEditor(imageColor: UIColor?) throws -> (UIWindow, ImageEditorViewController) {
        let size = CGSize(width: 900, height: 1200)
        let image = Self.image(size: size, scale: 1) { context in
            if let imageColor {
                imageColor.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                return
            }
            // 截图用：几块颜色加一道斜线，看得出放大镜里的像素格。
            let colors: [UIColor] = [UIColor(rgbHex: 0x3a7bd5), UIColor(rgbHex: 0xf5d76e), UIColor(rgbHex: 0xe74c3c), UIColor(rgbHex: 0x2ecc71)]
            for (index, color) in colors.enumerated() {
                color.setFill()
                context.fill(CGRect(x: CGFloat(index % 2) * 450, y: CGFloat(index / 2) * 600, width: 450, height: 600))
            }
            UIColor.white.setStroke()
            context.cgContext.setLineWidth(6)
            context.cgContext.move(to: CGPoint(x: 0, y: 0))
            context.cgContext.addLine(to: CGPoint(x: 900, y: 1200))
            context.cgContext.strokePath()
        }
        let model = try ImageEditorModel(normalizedImage: NormalizedImage.forImage(image))
        let editor = ImageEditorViewController(model: model, stickerSheetDelegate: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = editor
        window.isHidden = false
        editor.mode = .draw
        UIView.performWithoutAnimation {
            window.layoutIfNeeded()
        }
        XCTAssertGreaterThan(editor.imageEditorView.frame.size.width, CGFloat(0))
        return (window, editor)
    }

    private static func image(size: CGSize, scale: CGFloat = 1, draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
    }

    private static func assertColor(
        _ actual: UIColor?,
        _ expected: UIColor,
        tolerance: CGFloat = 0.01,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        guard let actual else {
            XCTFail("没有颜色", file: file, line: line)
            return
        }
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        actual.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        expected.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        XCTAssertEqual(r1, r2, accuracy: tolerance, "red", file: file, line: line)
        XCTAssertEqual(g1, g2, accuracy: tolerance, "green", file: file, line: line)
        XCTAssertEqual(b1, b2, accuracy: tolerance, "blue", file: file, line: line)
    }
}
