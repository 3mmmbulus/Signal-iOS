//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

/// Tellomi（tellomi/tellomi#1522 E-3）：画笔菜单「形状」加的形状。
///
/// 照两端 Telegram：加出来就是选中的，颜色、粗细跟着色条和粗细滑杆走（iOS 改选中的那个、安卓改正在摆的那个）；
/// 按住它拖 = 挪，两指 = 缩放 / 旋转，拖到垃圾桶 = 删；点别处 = 放下，接着画。
extension ImageEditorViewController {

    func addShape(_ kind: ImageEditorShapeItem.Kind) {
        owsAssertDebug(mode == .draw)
        dismissEyedropper()

        let item = imageEditorView.createNewShapeItem(
            kind: kind,
            color: drawToolbar.colorPickerBar.uiColor,
            isFilled: drawToolbar.fillsShapes,
            unitLineWidth: shapeUnitLineWidth(scaling: 1 / model.currentTransform().scaling),
        )
        model.append(item: item)
        imageEditorView.selectedTransformableItemID = item.itemId
        ImpactHapticFeedback.impactOccurred(style: .light)
    }

    /// 线宽取笔的粗细滑杆（和笔一样粗）：看得见的线宽 = 笔的线宽，所以除掉形状自己的缩放和图的缩放。
    func shapeUnitLineWidth(scaling: CGFloat) -> CGFloat {
        let penWidth = ImageEditorStrokeItem.unitStrokeWidth(
            forStrokeType: .pen,
            widthAdjustmentFactor: CGFloat(strokeWidthSlider.value),
        )
        return penWidth / max(0.01, scaling * model.currentTransform().scaling)
    }

    /// 色条变了：选中的形状跟着变色。
    func applyColorToSelectedShape(_ color: UIColor) {
        guard mode == .draw, let shape = imageEditorView.selectedShapeItem, shape.color != color else { return }
        model.replace(item: shape.with(color: color))
    }

    /// 粗细滑杆动了：选中的形状跟着变粗细（填充的形状没有线，不用管）。
    func applyLineWidthToSelectedShape() {
        guard mode == .draw, let shape = imageEditorView.selectedShapeItem, !shape.isFilled || shape.kind == .arrow else { return }
        model.replace(item: shape.with(unitLineWidth: shapeUnitLineWidth(scaling: shape.scaling)))
    }

    /// 画笔模式里按在选中的形状上：这一下给形状（挪 / 缩放），不画线、不长按填满。
    func touchIsOnSelectedShape(_ touch: UITouch) -> Bool {
        guard mode == .draw else { return false }
        return imageEditorView.isOnSelectedShape(locationInView: touch.location(in: imageEditorView.gestureReferenceView))
    }
}
