//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1522 E-3）：图片编辑器画笔菜单里的形状（照 Telegram 两端都有的那部分）。
final class TellomiImageEditorShapeTests: SignalBaseTest {

    // MARK: - Geometry

    /// 描边的形状往里收半个线宽，线不出框；填充的贴满；箭头整块在框里。
    func testShapesStayInsideTheirBox() {
        let size = CGSize(width: 200, height: 150)
        let lineWidth: CGFloat = 12
        for kind in ImageEditorShapeItem.Kind.allCases {
            for isFilled in [false, true] {
                let path = TellomiShapePath.path(kind: kind, size: size, lineWidth: lineWidth, isFilled: isFilled)
                let box = path.boundingBoxOfPath
                let outset = (isFilled || kind == .arrow) ? 0 : lineWidth / 2
                let drawn = box.insetBy(dx: -outset, dy: -outset)
                XCTAssertFalse(box.isEmpty, "\(kind)")
                XCTAssertGreaterThanOrEqual(drawn.minX, -0.001, "\(kind) filled=\(isFilled)")
                XCTAssertGreaterThanOrEqual(drawn.minY, -0.001, "\(kind) filled=\(isFilled)")
                XCTAssertLessThanOrEqual(drawn.maxX, size.width + 0.001, "\(kind) filled=\(isFilled)")
                XCTAssertLessThanOrEqual(drawn.maxY, size.height + 0.001, "\(kind) filled=\(isFilled)")
            }
        }
    }

    /// 星形五个尖，第一个朝上，内外半径之比 0.4；圆是正圆。
    func testStarAndCircle() {
        let star = TellomiShapePath.star(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(star.contains(CGPoint(x: 50, y: 50)))
        XCTAssertTrue(star.contains(CGPoint(x: 50, y: 3)), "top tip")
        let between: CGFloat = -CGFloat.pi / 2 + CGFloat.pi / 5
        let direction = CGPoint(x: cos(between), y: sin(between))
        XCTAssertFalse(star.contains(CGPoint(x: 50 + 22 * direction.x, y: 50 + 22 * direction.y)), "between two tips")
        XCTAssertTrue(star.contains(CGPoint(x: 50 + 18 * direction.x, y: 50 + 18 * direction.y)), "inner corner")

        let circle = TellomiShapePath.path(kind: .circle, size: CGSize(width: 100, height: 100), lineWidth: 10, isFilled: true).boundingBoxOfPath
        XCTAssertEqual(circle.size.width, circle.size.height, accuracy: 0.001)
    }

    /// 气泡的尾巴在左下，尖碰到框底；箭头的尖在最右、居中。
    func testBubbleTailAndArrowTip() {
        let size = CGSize(width: 200, height: 140)
        let bubble = TellomiShapePath.path(kind: .bubble, size: size, lineWidth: 10, isFilled: true)
        XCTAssertEqual(bubble.boundingBoxOfPath.maxY, size.height, accuracy: 0.001)
        XCTAssertTrue(bubble.contains(CGPoint(x: size.width * 0.2, y: size.height * 0.9)), "the tail is on the bottom left")
        XCTAssertFalse(bubble.contains(CGPoint(x: size.width * 0.8, y: size.height * 0.9)), "nothing on the bottom right")

        let arrow = TellomiShapePath.arrow(size: CGSize(width: 200, height: 60), lineWidth: 8)
        XCTAssertEqual(arrow.boundingBoxOfPath.maxX, 200, accuracy: 0.001)
        XCTAssertTrue(arrow.contains(CGPoint(x: 195, y: 30)))
        XCTAssertTrue(arrow.contains(CGPoint(x: 20, y: 30)), "the shaft")
        XCTAssertFalse(arrow.contains(CGPoint(x: 20, y: 40)), "the shaft is one line wide")
    }

    /// 箭头不填充（照 Telegram 安卓），别的形状听开关的。
    func testArrowIsNeverFilled() {
        XCTAssertFalse(ImageEditorShapeItem(kind: .arrow, color: .red, isFilled: true, unitLineWidth: 0.02, rotationRadians: 0, scaling: 1).isFilled)
        XCTAssertTrue(ImageEditorShapeItem(kind: .star, color: .red, isFilled: true, unitLineWidth: 0.02, rotationRadians: 0, scaling: 1).isFilled)
    }

    // MARK: - Menu

    /// 画笔菜单最后一项是「形状」：照 Telegram iOS 的次序五种形状，再一个「填充」开关；开了之后图标换实心的。
    @MainActor
    func testShapesMenu() throws {
        XCTAssertEqual(ImageEditorViewController.DrawToolbar.shapes, [.rectangle, .circle, .bubble, .star, .arrow])

        let editor = ImageEditorViewController(model: try Self.model(color: .gray), stickerSheetDelegate: nil)
        editor.loadViewIfNeeded()
        editor.mode = .draw

        let shapes = try Self.shapesMenu(editor)
        let actions = shapes.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), ImageEditorViewController.DrawToolbar.shapes.map { ImageEditorViewController.DrawToolbar.title(for: $0) })
        let fill = try XCTUnwrap((shapes.children.last as? UIMenu)?.children.first as? UIAction)
        XCTAssertEqual(fill.state, .off, "new shapes are outlined by default")

        editor.drawToolbar.fillsShapes = true
        let filledMenu = try Self.shapesMenu(editor)
        let filledFill = try XCTUnwrap((filledMenu.children.last as? UIMenu)?.children.first as? UIAction)
        XCTAssertEqual(filledFill.state, .on)
        XCTAssertEqual(
            (filledMenu.children.first as? UIAction)?.image?.pngData(),
            UIImage(systemName: "rectangle.fill")?.pngData(),
        )
    }

    // MARK: - Adding and editing

    /// 加形状：放在图中间、摆正、选中，颜色和线宽取当前的笔，一步撤销。
    @MainActor
    func testAddShapeCentersAndSelectsIt() throws {
        let model = try Self.model(color: .gray)
        let editor = ImageEditorViewController(model: model, stickerSheetDelegate: nil)
        let window = try Self.window(showing: editor)
        defer { window.isHidden = true }
        editor.mode = .draw
        let red = ColorPickerBarColor(color: .red, palettePhase: 0)
        editor.drawToolbar.colorPickerBar.color = red
        editor.colorPickerBarValueChanged(color: red)

        editor.addShape(.star)
        let shape = try XCTUnwrap(editor.imageEditorView.selectedShapeItem)
        XCTAssertEqual(shape.kind, .star)
        XCTAssertEqual(shape.color, .red)
        XCTAssertFalse(shape.isFilled)
        XCTAssertEqual(shape.unitCenter.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(shape.unitCenter.y, 0.5, accuracy: 0.01)
        XCTAssertEqual(shape.rotationRadians, 0, accuracy: 0.001)
        XCTAssertEqual(shape.unitLineWidth, ImageEditorStrokeItem.unitStrokeWidth(forStrokeType: .pen, widthAdjustmentFactor: CGFloat(editor.strokeWidthSlider.value)), accuracy: 0.0001)

        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertFalse(model.items.contains { $0 is ImageEditorShapeItem })
    }

    /// 选中的形状跟着色条变色、跟着粗细滑杆变粗细；换笔就把它放下，之后色条不动形状。
    @MainActor
    func testColorAndWidthFollowTheSelectedShape() throws {
        let model = try Self.model(color: .gray)
        let editor = ImageEditorViewController(model: model, stickerSheetDelegate: nil)
        let window = try Self.window(showing: editor)
        defer { window.isHidden = true }
        editor.mode = .draw
        editor.addShape(.rectangle)
        let before = try XCTUnwrap(editor.imageEditorView.selectedShapeItem)

        let blue = ColorPickerBarColor(color: .blue, palettePhase: 5 / 8)
        editor.drawToolbar.colorPickerBar.color = blue
        editor.colorPickerBarValueChanged(color: blue)
        XCTAssertEqual(editor.imageEditorView.selectedShapeItem?.color, .blue)

        editor.strokeWidthSlider.value = 2
        editor.handleSliderValueChanged(value: 2)
        let wider = try XCTUnwrap(editor.imageEditorView.selectedShapeItem)
        XCTAssertGreaterThan(wider.unitLineWidth, before.unitLineWidth)
        XCTAssertEqual(wider.itemId, before.itemId)

        // 换笔就把形状放下：换上箭头的默认橙色，形状还是蓝的。
        editor.drawToolbar.select(strokeType: .arrow)
        XCTAssertNil(editor.imageEditorView.selectedShapeItem)
        XCTAssertEqual((model.item(forId: before.itemId) as? ImageEditorShapeItem)?.color, .blue)

        let green = ColorPickerBarColor(color: .green, palettePhase: 0.375)
        editor.colorPickerBarValueChanged(color: green)
        XCTAssertEqual((model.item(forId: before.itemId) as? ImageEditorShapeItem)?.color, .blue, "nothing selected, the color bar leaves the shape alone")
    }

    /// 画笔模式里：按在选中的形状上是挪它（画线、长按填满都不接这一下），别处照旧画；别的模式不受影响。
    @MainActor
    func testDrawModeTouchesOnTheSelectedShapeMoveIt() throws {
        let model = try Self.model(color: .gray)
        let editor = ImageEditorViewController(model: model, stickerSheetDelegate: nil)
        let window = try Self.window(showing: editor)
        defer { window.isHidden = true }
        editor.mode = .draw
        XCTAssertTrue(editor.imageEditorView.selectedShapeTakesTouches)
        editor.addShape(.circle)
        window.layoutIfNeeded()

        let view = editor.imageEditorView.gestureReferenceView
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        XCTAssertTrue(editor.imageEditorView.isOnSelectedShape(locationInView: center))
        XCTAssertFalse(editor.imageEditorView.isOnSelectedShape(locationInView: CGPoint(x: view.bounds.minX + 4, y: view.bounds.minY + 4)))

        editor.imageEditorView.selectedTransformableItemID = nil
        XCTAssertFalse(editor.imageEditorView.isOnSelectedShape(locationInView: center), "a shape that is not selected does not take the touch")

        // 别的模式里（这里用打码）不接；文字 / 贴纸模式本来就能挪所有东西。
        editor.mode = .blur
        XCTAssertFalse(editor.imageEditorView.selectedShapeTakesTouches)
    }

    // MARK: - Output

    /// 发出去的图：填充的矩形中间是它的颜色；描边的圆只有一圈，中间露出照片；橡皮不擦形状（和贴纸一样）。
    @MainActor
    func testOutputDrawsShapesAndTheEraserLeavesThem() throws {
        let model = try Self.model(color: .gray)
        model.append(item: ImageEditorShapeItem(
            kind: .rectangle,
            color: .red,
            isFilled: true,
            unitLineWidth: 0.02,
            unitCenter: CGPoint(x: 0.3, y: 0.3),
            rotationRadians: 0,
            scaling: 0.5,
        ))
        model.append(item: ImageEditorShapeItem(
            kind: .circle,
            color: .blue,
            isFilled: false,
            unitLineWidth: 0.02,
            unitCenter: CGPoint(x: 0.5, y: 0.7),
            rotationRadians: 0,
            scaling: 1,
        ))
        model.append(item: ImageEditorStrokeItem(
            color: .white,
            strokeType: .eraser,
            unitSamples: [CGPoint(x: 0, y: 0.3), CGPoint(x: 1, y: 0.3)],
            unitStrokeWidth: 0.1,
        ))

        let output = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: model, transform: model.currentTransform()))
        let pixels = try XCTUnwrap(TellomiEyedropperPixels(image: output))
        Self.assertColor(pixels.color(atUnit: CGPoint(x: 0.3, y: 0.3)), .red, "filled rectangle, under the eraser")
        Self.assertColor(pixels.color(atUnit: CGPoint(x: 0.5, y: 0.7)), .gray, "the outlined circle is hollow")
        // 圆：直径 = 短边的一半（200），线宽 8，线在半径 96 处。
        Self.assertColor(pixels.color(atUnit: CGPoint(x: 0.5 + 96.0 / 400, y: 0.7)), .blue, "the circle's outline")
    }

    // MARK: - Screenshots

    /// 截图（TELLOMI_SHOTS=1）：① 发出去的图——上排五种描边、下排五种填充（箭头没有填充）；② 编辑器里刚加的星形（选中框）。
    @MainActor
    func testScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let directory = URL(fileURLWithPath: environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = try ImageEditorModel(normalizedImage: NormalizedImage.forImage(UIImage.image(color: UIColor(rgbHex: 0x2b3a55), size: CGSize(width: 900, height: 600))))
        let colors: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal]
        for (row, isFilled) in [false, true].enumerated() {
            for (column, kind) in ImageEditorViewController.DrawToolbar.shapes.enumerated() {
                model.append(item: ImageEditorShapeItem(
                    kind: kind,
                    color: colors[column],
                    isFilled: isFilled,
                    unitLineWidth: 0.02,
                    unitCenter: CGPoint(x: 0.1 + 0.2 * CGFloat(column), y: 0.28 + 0.44 * CGFloat(row)),
                    rotationRadians: kind == .arrow ? -0.4 : 0,
                    scaling: 0.55,
                ))
            }
        }
        let output = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: model, transform: model.currentTransform()))
        try XCTUnwrap(output.pngData()).write(to: directory.appendingPathComponent("editor-shapes-output.png"))

        let editor = ImageEditorViewController(model: try Self.model(color: UIColor(rgbHex: 0x2b3a55)), stickerSheetDelegate: nil)
        let window = try Self.window(showing: editor)
        defer { window.isHidden = true }
        editor.mode = .draw
        editor.addShape(.star)
        window.layoutIfNeeded()
        let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(shot.pngData()).write(to: directory.appendingPathComponent("editor-shapes-selected.png"))
    }

    // MARK: - Helpers

    @MainActor
    private static func shapesMenu(_ editor: ImageEditorViewController) throws -> UIMenu {
        let menu = try XCTUnwrap(editor.drawToolbar.strokeTypeButton.menu)
        let shapes = try XCTUnwrap(menu.children.last as? UIMenu)
        XCTAssertEqual(shapes.title, OWSLocalizedString("IMAGE_EDITOR_TELLOMI_SHAPES", comment: ""))
        return shapes
    }

    /// 窗口挂在测试宿主的场景上（应用用 UIScene，`UIWindow(frame:)` 不排版），画布才有大小。
    @MainActor
    private static func window(showing viewController: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = viewController
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    @MainActor
    private static func model(color: UIColor) throws -> ImageEditorModel {
        try ImageEditorModel(normalizedImage: NormalizedImage.forImage(UIImage.image(color: color, size: CGSize(square: 400))))
    }

    private static func assertColor(_ actual: UIColor, _ expected: UIColor, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        actual.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        expected.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        XCTAssertEqual(r1, r2, accuracy: 0.06, "\(message) (red)", file: file, line: line)
        XCTAssertEqual(g1, g2, accuracy: 0.06, "\(message) (green)", file: file, line: line)
        XCTAssertEqual(b1, b2, accuracy: 0.06, "\(message) (blue)", file: file, line: line)
    }
}
