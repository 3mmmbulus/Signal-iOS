//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Tellomi（tellomi/tellomi#1522 E-2，照 Telegram 两端颜色面板里的吸管）：从画布上取一个颜色给画笔或文字。
///
/// 点吸管键：把画布现在的样子拍一张（写文字时只拍键盘上面露出来的那块；正在改的那段字本来就藏着，不会取到它自己），
/// 盖一层 `TellomiEyedropperView`；拖动放大镜、松手取色。画笔模式取到的颜色给画笔的色条，写文字时给文字的色条，
/// 色条的滑块停在原处、显示取到的颜色。再点一次吸管键、动色条、换工具、撤销都会收起吸管。
extension ImageEditorViewController {

    static func makeEyedropperButton() -> UIButton {
        let image = UIImage(systemName: "eyedropper", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)) ?? UIImage()
        let button = UIButton(configuration: .roundMedia(image: image, size: 44))
        button.accessibilityLabel = OWSLocalizedString(
            "IMAGE_EDITOR_TELLOMI_EYEDROPPER",
            comment: "Accessibility label of the eyedropper button in the image editor's draw and text tools; it lets the user pick a color from the photo.",
        )
        return button
    }

    func installTextEyedropperButton() {
        let button = textEyedropperButton
        guard button.superview == nil else { return }
        button.alpha = 0
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            button.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
        ])
    }

    func didTapEyedropperButton() {
        if let eyedropperView, !eyedropperView.isDismissing {
            dismissEyedropper()
            return
        }
        presentEyedropper()
    }

    /// 吸管盖住的区域（`view` 的坐标）：画布；写文字时截到键盘上沿。
    var eyedropperFrame: CGRect {
        var frame = imageEditorView.frame
        if mode == .text, textView.isFirstResponder {
            let keyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
            frame.size.height = max(0, min(frame.maxY, keyboardTop) - frame.minY)
        }
        return frame
    }

    func presentEyedropper() {
        guard mode == .draw || mode == .text else { return }
        view.layoutIfNeeded()
        let frame = eyedropperFrame
        let rectInCanvas = view.convert(frame, to: imageEditorView)
        guard let snapshot = Self.eyedropperSnapshot(of: imageEditorView, rect: rectInCanvas) else { return }

        let eyedropper = TellomiEyedropperView(snapshot: snapshot)
        eyedropper.frame = frame
        eyedropper.onPicked = { [weak self, weak eyedropper] color in
            eyedropper?.dismiss()
            self?.applyEyedropperColor(color)
        }
        if mode == .text, textUIInitialized {
            // 盖在压暗层上面，吸管键还在最上面，再点一次能收起。
            view.insertSubview(eyedropper, aboveSubview: textViewContainer)
            view.bringSubviewToFront(textEyedropperButton)
        } else {
            // 在工具条、粗细滑杆下面。
            view.insertSubview(eyedropper, aboveSubview: imageEditorView)
        }
        eyedropper.layoutIfNeeded()
        eyedropperView = eyedropper
        eyedropper.animateIn()
    }

    func dismissEyedropper(animated: Bool = true) {
        guard let eyedropperView else { return }
        eyedropperView.dismiss(animated: animated)
        if !animated {
            self.eyedropperView = nil
        }
    }

    /// 取到颜色：滑块位置不动（`palettePhase` 照旧），颜色换成取到的。
    func applyEyedropperColor(_ color: UIColor) {
        switch mode {
        case .draw:
            let picked = ColorPickerBarColor(color: color, palettePhase: drawToolbar.colorPickerBar.color.palettePhase)
            drawToolbar.colorPickerBar.color = picked
            colorPickerBarValueChanged(color: picked)
        case .text:
            let picked = ColorPickerBarColor(color: color, palettePhase: textViewAccessoryToolbar.currentColorPickerValue.palettePhase)
            textViewAccessoryToolbar.currentColorPickerValue = picked
            textColorDidChange(newColor: picked)
        case .blur, .sticker:
            break
        }
    }

    /// 拍 `view` 里 `rect` 这一块，1 点 1 像素（放大镜里一格就是一个像素），sRGB 8 位。
    /// 画布全是 CALayer（图片、笔画、文字图层），用 `layer.render(in:)` 拍，不用等下一帧。
    static func eyedropperSnapshot(of view: UIView, rect: CGRect) -> UIImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(bounds: rect, format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(rect)
            view.layer.render(in: context.cgContext)
        }
    }
}
