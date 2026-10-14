//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

extension ImageEditorViewController {

    func updateStrokeWidthSliderValue() {
        strokeWidthSlider.value = strokeWidthValues[currentStrokeType] ?? 1
        updateStrokeWidthPreviewSize()
    }

    private func setupStrokeWidthPreviewIfNecessary() {
        guard strokeWidthSliderIsTrackingObservation == nil else { return }

        strokeWidthPreviewDot.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(strokeWidthPreviewDot)
        NSLayoutConstraint.activate([
            strokeWidthPreviewDot.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            strokeWidthPreviewDot.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        strokeWidthSliderIsTrackingObservation = strokeWidthSlider.observe(\.isTracking, options: [.new]) { [weak self] _, _ in
            self?.updateStrokeWidthPreviewVisibility()
        }
        updateStrokeWidthPreviewVisibility()
    }

    private func updateStrokeWidthPreviewVisibility() {
        strokeWidthPreviewDot.alpha = strokeWidthSlider.isTracking ? 1 : 0
    }

    func updateStrokeWidthPreviewSize() {
        guard let strokeWidthPreviewDotSize else { return }

        let unitStrokeWidth = currentStrokeUnitWidth()
        let viewSize = imageEditorView.gestureReferenceView.bounds.size
        let strokeWidth = ImageEditorStrokeItem.strokeWidth(
            forUnitStrokeWidth: unitStrokeWidth,
            dstSize: viewSize,
        )
        var dotSize = max(strokeWidth, 1)
        if currentStrokeType != .blur {
            dotSize += 2 * strokeWidthPreviewDot.layer.borderWidth
        }
        strokeWidthPreviewDotSize.constant = dotSize
    }

    func updateStrokeWidthPreviewColor() {
        switch currentStrokeType {
        case .pen, .arrow, .neon: strokeWidthPreviewDot.backgroundColor = model.color.color
        case .highlighter: strokeWidthPreviewDot.backgroundColor = model.color.color.withAlphaComponent(Self.highligherStrokeOpacity)
        case .blur, .eraser: strokeWidthPreviewDot.backgroundColor = .white
        }
    }

    /// Tellomi（tellomi/tellomi#1522 E-2）：从画笔菜单选了一支笔。
    func didSelectStrokeType(_ strokeType: ImageEditorStrokeItem.StrokeType) {
        owsAssertDebug(currentStroke == nil)
        let previous = currentStrokeType
        if previous != strokeType {
            swapBrushColor(from: previous, to: strokeType)
        }
        currentStrokeType = strokeType
    }

    /// Tellomi（tellomi/tellomi#1522 E-2，照 Telegram 两端每支笔各记颜色）：没用过的笔从 Telegram 的默认色开始——
    /// 箭头橙、荧光笔（Telegram 的马克笔）黄、霓虹绿；笔从上游色条的默认色开始，橡皮没有颜色。
    static func defaultBrushColor(for strokeType: ImageEditorStrokeItem.StrokeType) -> ColorPickerBarColor? {
        switch strokeType {
        case .arrow: return ColorPickerBarColor(color: UIColor(rgbHex: 0xff8a00), palettePhase: 0.164)
        case .highlighter: return ColorPickerBarColor(color: UIColor(rgbHex: 0xffd60a), palettePhase: 0.22)
        case .neon: return ColorPickerBarColor(color: UIColor(rgbHex: 0x34c759), palettePhase: 0.375)
        case .pen, .blur, .eraser: return nil
        }
    }

    /// 换笔：色条记下离开的这支笔的颜色，换上下一支笔上次的颜色（没用过就用默认色）；橡皮没有颜色，色条不动。
    private func swapBrushColor(from: ImageEditorStrokeItem.StrokeType, to: ImageEditorStrokeItem.StrokeType) {
        if from != .eraser {
            brushColors[from] = drawToolbar.colorPickerBar.color
        }
        guard to != .eraser, let color = brushColors[to] ?? Self.defaultBrushColor(for: to) else { return }
        drawToolbar.colorPickerBar.color = color
        colorPickerBarValueChanged(color: color)
    }

    @objc
    func handleSliderContainerTap(_ gesture: UITapGestureRecognizer) {
        setStrokeWidthSlider(revealed: !strokeWidthSliderRevealed)

        // Hide slider after delay if user doesn't interact with it.
        if strokeWidthSliderRevealed {
            owsAssertDebug(hideStrokeWidthSliderTimer == nil)

            hideStrokeWidthSliderTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                guard let self else { return }

                self.setStrokeWidthSlider(revealed: false)
            }
        }
    }

    func handleSliderTouchEvents(_ slider: UISlider) {
        guard slider.isTracking != strokeWidthSliderRevealed else { return }

        setStrokeWidthSlider(revealed: slider.isTracking)
    }

    func handleSliderValueChanged(value: Float) {
        strokeWidthValues[currentStrokeType] = value
        updateStrokeWidthPreviewSize()
    }

    func setStrokeWidthSlider(revealed: Bool) {
        guard strokeWidthSliderRevealed != revealed else { return }

        strokeWidthSliderRevealed = revealed
        updateStrokeWidthSliderPosition()

        if strokeWidthSliderRevealed {
            setupStrokeWidthPreviewIfNecessary()
        }

        if let timer = hideStrokeWidthSliderTimer {
            timer.invalidate()
            hideStrokeWidthSliderTimer = nil
        }
    }

    private func updateStrokeWidthSliderPosition() {
        strokeWidthSliderPosition?.constant = strokeWidthSliderRevealed
            ? strokeWidthSliderContainer.bounds.height / 2 - 12
            : 0
        UIView.animate(withDuration: 0.2) {
            if !self.strokeWidthSliderRevealed {
                self.strokeWidthPreviewDot.alpha = 0
            }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }
}
