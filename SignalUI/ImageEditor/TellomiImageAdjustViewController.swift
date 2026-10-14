//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Tellomi（tellomi/tellomi#1593 E5-3，Epic #1523）：调色页。
///
/// 照 Telegram iOS 的「调整」页（`TGPhotoToolsController` 的工具页签，只读机制，代码自己写）：
/// - 上面是照片，下面是工具列表，每行一个工具：左边名字、右边数值（不在 0 时才有，名字变强调色），下面一条滑杆
///   （`TGPhotoToolCell` 里放的就是 `TGPhotoEditorGenericToolView`，行高 46）；
/// - 拖滑杆时这一行的字藏起来、面板底淡掉，顶上的提示条显示「名字 数值」；松手恢复；
/// - 按住照片看原图，提示条显示「原图」；
/// - 下面取消 / 完成：取消回到打开时的样子，完成算一步撤销。
///
/// 只列已经能画出来的工具（`availableTools`），后面的子 Issue 做好一项加一项；色调 / 模糊 / 曲线是 Telegram 的单独页签，
/// 等那几项做了再加页签。数值的写法照 Telegram iOS：值 ÷ 最大值，两位小数，带正负号（+0.35）。
public final class TellomiImageAdjustViewController: OWSViewController {

    /// 入口按钮的图标：Signal 的图标里没有调色这一类，用系统的 SF Symbol（Telegram 的图标不能拿）。
    public static var toolIcon: UIImage {
        UIImage(systemName: "slider.horizontal.3", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))!
    }

    /// 照 Telegram iOS `PGPhotoEditor.availableTools` 的顺序，只放已经能画的。
    static let availableTools: [TellomiImageAdjustments.Tool] = [.exposure, .contrast, .saturation, .warmth, .fade, .highlights, .shadows]

    private let model: ImageEditorModel
    private let initialAdjustments: TellomiImageAdjustments
    private var adjustments: TellomiImageAdjustments

    private let imageEditorView: ImageEditorView
    private let panelView = UIView()
    private let panelBackgroundView = UIView()
    private let rowsStack = UIStackView()
    /// 照 Telegram iOS：工具列表区高度固定（约四行半），工具多了在里面上下滚，不往上盖住照片。
    private let rowsScrollView = UIScrollView()
    private static let maxRowsHeight: CGFloat = 52 * 4.5
    /// 页签：工具、色调（照 Telegram iOS 调整页的 Tools / Tint 页签；模糊、曲线做了再加）。
    private let bottomBar = ImageEditorToolbar(tools: [.tellomiAdjustTools, .tellomiAdjustTint])
    private let tintPanel = TintPanelView()
    private let hudLabel = HUDLabel()
    private var rows: [TellomiImageAdjustments.Tool: RowView] = [:]

    /// 结束时调（完成 / 取消都调）；传 true = 完成。
    var onFinish: ((Bool) -> Void)?

    init(model: ImageEditorModel) {
        self.model = model
        self.initialAdjustments = model.adjustments
        self.adjustments = model.adjustments
        self.imageEditorView = ImageEditorView(model: model, delegate: nil)
        super.init()
        overrideUserInterfaceStyle = .dark
    }

    // MARK: - View

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.mediaBackground

        imageEditorView.configureSubviews()
        imageEditorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageEditorView)

        let holdGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        holdGesture.minimumPressDuration = 0
        imageEditorView.addGestureRecognizer(holdGesture)

        panelBackgroundView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        panelBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(panelBackgroundView)

        rowsStack.axis = .vertical
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsScrollView.translatesAutoresizingMaskIntoConstraints = false
        rowsScrollView.showsVerticalScrollIndicator = false
        // 按在滑杆上立刻开始拖（不等滚动判断）；上下滚从每行的文字那一条拖。
        rowsScrollView.delaysContentTouches = false
        rowsScrollView.addSubview(rowsStack)
        panelView.addSubview(rowsScrollView)
        for tool in Self.availableTools {
            let row = RowView(tool: tool, value: adjustments[tool])
            row.slider.addAction(UIAction { [weak self, weak row] _ in
                guard let self, let row else { return }
                self.sliderChanged(tool: tool, value: row.slider.value)
            }, for: .valueChanged)
            row.slider.interactionBegan = { [weak self, weak row] in
                guard let self, let row else { return }
                self.setDragging(true, row: row)
            }
            row.slider.interactionEnded = { [weak self, weak row] in
                guard let self, let row else { return }
                self.setDragging(false, row: row)
            }
            rows[tool] = row
            rowsStack.addArrangedSubview(row)
        }

        panelView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panelView)

        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)
        bottomBar.cancelButton.addAction(UIAction { [weak self] _ in self?.finish(done: false) }, for: .primaryActionTriggered)
        bottomBar.selectedToolButton = .tellomiAdjustTools
        bottomBar.setAccessibilityLabel(
            OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST", comment: "Image editor: name of the tool that adjusts exposure, contrast, colour and so on. Also its button's accessibility label."),
            for: .tellomiAdjustTools,
        )
        bottomBar.setAccessibilityLabel(
            OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_TINT", comment: "Image editor, adjustments: the tint tab (colours for shadows and highlights)."),
            for: .tellomiAdjustTint,
        )
        bottomBar.addAction(UIAction { [weak self] _ in self?.showTintTab(false) }, for: .tellomiAdjustTools)
        bottomBar.addAction(UIAction { [weak self] _ in self?.showTintTab(true) }, for: .tellomiAdjustTint)

        tintPanel.translatesAutoresizingMaskIntoConstraints = false
        tintPanel.isHidden = true
        tintPanel.update(shadows: adjustments.tintShadows, highlights: adjustments.tintHighlights)
        tintPanel.onSelect = { [weak self] shadows, color in
            self?.tintSelected(shadows: shadows, color: color)
        }
        panelView.addSubview(tintPanel)
        bottomBar.doneButton.addAction(UIAction { [weak self] _ in self?.finish(done: true) }, for: .primaryActionTriggered)

        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        hudLabel.isHidden = true
        view.addSubview(hudLabel)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            panelView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            panelView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),

            panelBackgroundView.topAnchor.constraint(equalTo: panelView.topAnchor),
            panelBackgroundView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            panelBackgroundView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            panelBackgroundView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),

            rowsScrollView.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 4),
            rowsScrollView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 16),
            rowsScrollView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -16),
            rowsScrollView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -4),
            rowsScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxRowsHeight),
            {
                let fitsContent = rowsScrollView.heightAnchor.constraint(equalTo: rowsStack.heightAnchor)
                fitsContent.priority = .defaultHigh
                return fitsContent
            }(),

            rowsStack.topAnchor.constraint(equalTo: rowsScrollView.contentLayoutGuide.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: rowsScrollView.contentLayoutGuide.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: rowsScrollView.contentLayoutGuide.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: rowsScrollView.contentLayoutGuide.bottomAnchor),
            rowsStack.widthAnchor.constraint(equalTo: rowsScrollView.frameLayoutGuide.widthAnchor),

            // 色调页签和工具列表占同一块地方，面板高度不跟着页签变（照 Telegram iOS 面板固定高度）。
            tintPanel.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 16),
            tintPanel.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -16),
            tintPanel.centerYAnchor.constraint(equalTo: panelView.centerYAnchor),
            tintPanel.topAnchor.constraint(greaterThanOrEqualTo: panelView.topAnchor, constant: 4),

            imageEditorView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            imageEditorView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            imageEditorView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            imageEditorView.bottomAnchor.constraint(equalTo: panelView.topAnchor, constant: -8),

            hudLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hudLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
    }

    // MARK: - Editing

    private func sliderChanged(tool: TellomiImageAdjustments.Tool, value: Float) {
        adjustments[tool] = value
        // 拖动中只改预览，不记撤销；完成时整段算一步（见 `finish`）。
        model.replace(adjustments: adjustments, suppressUndo: true)
        rows[tool]?.update(value: adjustments[tool])
        showHUD(Self.hudText(tool: tool, value: adjustments[tool]))
    }

    private func showTintTab(_ showsTint: Bool) {
        bottomBar.selectedToolButton = showsTint ? .tellomiAdjustTint : .tellomiAdjustTools
        rowsScrollView.isHidden = showsTint
        tintPanel.isHidden = !showsTint
    }

    /// 点色块：和拖滑杆一样只改预览，完成时整段算一步撤销。
    private func tintSelected(shadows: Bool, color: TellomiImageAdjustments.TintColor?) {
        if shadows {
            adjustments.tintShadows = color
        } else {
            adjustments.tintHighlights = color
        }
        model.replace(adjustments: adjustments, suppressUndo: true)
        tintPanel.update(shadows: adjustments.tintShadows, highlights: adjustments.tintHighlights)
    }

    private func setDragging(_ dragging: Bool, row: RowView) {
        row.setLabelsHidden(dragging)
        UIView.animate(withDuration: dragging ? 0 : 0.15) {
            self.panelBackgroundView.alpha = dragging ? 0 : 1
        }
        if dragging {
            showHUD(Self.hudText(tool: row.tool, value: row.slider.value))
        } else {
            showHUD(nil)
        }
    }

    @objc
    private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            setShowsOriginal(true)
        case .ended, .cancelled, .failed:
            setShowsOriginal(false)
        default:
            break
        }
    }

    func setShowsOriginal(_ showsOriginal: Bool) {
        imageEditorView.canvasView.tellomiShowsOriginal = showsOriginal
        showHUD(showsOriginal ? OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_ORIGINAL", comment: "Image editor, adjustments: label shown while the user presses and holds the photo to compare it with the original.") : nil)
    }

    private func showHUD(_ text: String?) {
        hudLabel.text = text
        hudLabel.isHidden = text == nil
    }

    /// 完成：调色整段在撤销栈里只占一步（先悄悄回到打开时的样子，再记一步换成最终的）；取消：回到打开时的样子，不留撤销。
    func finish(done: Bool) {
        let final = adjustments
        model.replace(adjustments: initialAdjustments, suppressUndo: true)
        if done {
            model.replace(adjustments: final)
        }
        onFinish?(done)
        dismiss(animated: false)
    }

    // MARK: - Text

    /// 行右边的数值：0 时没有；否则 值 ÷ 最大值，两位小数，带正负号（照 Telegram iOS `PGPhotoTool.stringValue`）。
    static func valueText(_ value: Float, range: ClosedRange<Float>) -> String? {
        guard value.rounded() != 0 else { return nil }
        let fraction = value / max(abs(range.upperBound), abs(range.lowerBound))
        return String(format: fraction > 0 ? "+%.2f" : "%.2f", fraction)
    }

    /// 拖动时顶上的提示：名字 + 数值（0 时写 0.00）。
    static func hudText(tool: TellomiImageAdjustments.Tool, value: Float) -> String {
        "\(title(for: tool)) \(valueText(value, range: tool.range) ?? "0.00")"
    }

    static func title(for tool: TellomiImageAdjustments.Tool) -> String {
        switch tool {
        case .skin:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_SKIN", comment: "Image editor, adjustments: name of the tool that smooths skin.")
        case .enhance:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_ENHANCE", comment: "Image editor, adjustments: name of the tool that automatically enhances the photo.")
        case .exposure:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_EXPOSURE", comment: "Image editor, adjustments: name of the exposure (brightness) tool.")
        case .contrast:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_CONTRAST", comment: "Image editor, adjustments: name of the contrast tool.")
        case .saturation:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_SATURATION", comment: "Image editor, adjustments: name of the saturation tool.")
        case .warmth:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_WARMTH", comment: "Image editor, adjustments: name of the warmth (colour temperature) tool.")
        case .fade:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_FADE", comment: "Image editor, adjustments: name of the fade tool.")
        case .highlights:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_HIGHLIGHTS", comment: "Image editor, adjustments: name of the highlights tool.")
        case .shadows:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_SHADOWS", comment: "Image editor, adjustments: name of the shadows tool.")
        case .vignette:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_VIGNETTE", comment: "Image editor, adjustments: name of the vignette tool.")
        case .grain:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_GRAIN", comment: "Image editor, adjustments: name of the film grain tool.")
        case .sharpen:
            return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_SHARPEN", comment: "Image editor, adjustments: name of the sharpen tool.")
        }
    }

    // MARK: - Testing

    var rowToolsForTesting: [TellomiImageAdjustments.Tool] {
        rowsStack.arrangedSubviews.compactMap { ($0 as? RowView)?.tool }
    }

    func sliderForTesting(_ tool: TellomiImageAdjustments.Tool) -> TellomiAdjustmentSlider? {
        rows[tool]?.slider
    }

    func valueTextForTesting(_ tool: TellomiImageAdjustments.Tool) -> String? {
        rows[tool]?.valueLabel.text
    }

    func showTintTabForTesting(_ showsTint: Bool) {
        showTintTab(showsTint)
    }

    var isTintTabShownForTesting: Bool {
        !tintPanel.isHidden && rowsScrollView.isHidden
    }

    var tintPanelForTesting: TintPanelView {
        tintPanel
    }

    var hudTextForTesting: String? {
        hudLabel.isHidden ? nil : hudLabel.text
    }

    var canvasViewForTesting: ImageEditorCanvasView {
        imageEditorView.canvasView
    }

    // MARK: - Row

    private final class RowView: UIView {
        let tool: TellomiImageAdjustments.Tool
        let titleLabel = UILabel()
        let valueLabel = UILabel()
        let slider: TellomiAdjustmentSlider

        init(tool: TellomiImageAdjustments.Tool, value: Float) {
            self.tool = tool
            self.slider = TellomiAdjustmentSlider(range: tool.range, value: value)
            super.init(frame: .zero)

            titleLabel.font = .dynamicTypeSubheadlineClamped
            titleLabel.text = TellomiImageAdjustViewController.title(for: tool)
            valueLabel.font = .dynamicTypeSubheadlineClamped.monospaced()
            valueLabel.textColor = .Signal.accent
            valueLabel.textAlignment = .right
            slider.accessibilityLabel = titleLabel.text

            for subview in [titleLabel, valueLabel, slider] {
                subview.translatesAutoresizingMaskIntoConstraints = false
                addSubview(subview)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 52),
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                valueLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
                valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
                slider.leadingAnchor.constraint(equalTo: leadingAnchor),
                slider.trailingAnchor.constraint(equalTo: trailingAnchor),
                slider.bottomAnchor.constraint(equalTo: bottomAnchor),
                slider.heightAnchor.constraint(equalToConstant: 32),
            ])
            update(value: value)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(value: Float) {
            let text = TellomiImageAdjustViewController.valueText(value, range: tool.range)
            valueLabel.text = text
            titleLabel.textColor = text == nil ? .Signal.label : .Signal.accent
            if slider.value != value {
                slider.setValue(value)
            }
        }

        func setLabelsHidden(_ hidden: Bool) {
            UIView.animate(withDuration: hidden ? 0 : 0.2) {
                self.titleLabel.alpha = hidden ? 0 : 1
                self.valueLabel.alpha = hidden ? 0 : 1
            }
        }
    }

    // MARK: - Tint

    /// 色调页签（照 Telegram iOS `TGPhotoEditorTintToolView`）：上面「阴影」「高光」两个切换，下面一排 8 个色块（第一个是「不加」），
    /// 均匀铺开。色值是自己挑的，个数和 Telegram 一样；没有强度滑杆（O8：只有 Telegram iOS 能调强度）。
    final class TintPanelView: UIView {

        /// (是不是暗部, 选的颜色；nil = 不加)
        var onSelect: ((Bool, TellomiImageAdjustments.TintColor?) -> Void)?

        private(set) var editsShadows = true
        private var shadowsColor: TellomiImageAdjustments.TintColor?
        private var highlightsColor: TellomiImageAdjustments.TintColor?

        private let shadowsButton = UIButton(type: .custom)
        private let highlightsButton = UIButton(type: .custom)
        private let swatchesStack = UIStackView()
        private(set) var swatches: [SwatchView] = []

        override init(frame: CGRect) {
            super.init(frame: frame)

            for (button, title) in [
                (shadowsButton, TellomiImageAdjustViewController.title(for: .shadows)),
                (highlightsButton, TellomiImageAdjustViewController.title(for: .highlights)),
            ] {
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = .dynamicTypeSubheadlineClamped
                button.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .normal)
                button.setTitleColor(.white, for: .selected)
            }
            shadowsButton.addAction(UIAction { [weak self] _ in self?.setEditsShadows(true) }, for: .touchDown)
            highlightsButton.addAction(UIAction { [weak self] _ in self?.setEditsShadows(false) }, for: .touchDown)

            let modes = UIStackView(arrangedSubviews: [shadowsButton, highlightsButton])
            modes.distribution = .fillEqually

            swatchesStack.distribution = .equalSpacing
            swatchesStack.alignment = .center

            let column = UIStackView(arrangedSubviews: [modes, swatchesStack])
            column.axis = .vertical
            column.spacing = 12
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: topAnchor),
                column.leadingAnchor.constraint(equalTo: leadingAnchor),
                column.trailingAnchor.constraint(equalTo: trailingAnchor),
                column.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            rebuildSwatches()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(shadows: TellomiImageAdjustments.TintColor?, highlights: TellomiImageAdjustments.TintColor?) {
            shadowsColor = shadows
            highlightsColor = highlights
            refreshSelection()
        }

        func setEditsShadows(_ editsShadows: Bool) {
            self.editsShadows = editsShadows
            rebuildSwatches()
        }

        private var palette: [TellomiImageAdjustments.TintColor?] {
            editsShadows ? TellomiImageAdjustments.TintColor.shadowsPalette : TellomiImageAdjustments.TintColor.highlightsPalette
        }

        private func rebuildSwatches() {
            shadowsButton.isSelected = editsShadows
            highlightsButton.isSelected = !editsShadows
            swatches.forEach { $0.removeFromSuperview() }
            let modeTitle = TellomiImageAdjustViewController.title(for: editsShadows ? .shadows : .highlights)
            swatches = palette.enumerated().map { index, color in
                let swatch = SwatchView(color: color)
                swatch.accessibilityLabel = color == nil
                    ? OWSLocalizedString("IMAGE_EDITOR_TELLOMI_ADJUST_TINT_NONE", comment: "Image editor, adjustments, tint: the swatch that removes the tint.")
                    : "\(modeTitle) \(index)"
                swatch.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    self.onSelect?(self.editsShadows, color)
                }, for: .touchUpInside)
                swatchesStack.addArrangedSubview(swatch)
                return swatch
            }
            refreshSelection()
        }

        private func refreshSelection() {
            let current = editsShadows ? shadowsColor : highlightsColor
            for swatch in swatches {
                swatch.isSelected = swatch.color == current
            }
        }
    }

    /// 一个色块：彩色的是实心圆，「不加」是白圈；选中的外面多一圈白环。
    final class SwatchView: UIControl {
        let color: TellomiImageAdjustments.TintColor?
        private let fill = CAShapeLayer()
        private let ring = CAShapeLayer()

        init(color: TellomiImageAdjustments.TintColor?) {
            self.color = color
            super.init(frame: .zero)
            isAccessibilityElement = true
            accessibilityTraits = .button
            if let color {
                fill.fillColor = UIColor(red: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: 1).cgColor
            } else {
                fill.fillColor = UIColor.clear.cgColor
                fill.strokeColor = UIColor.white.cgColor
                fill.lineWidth = 2
            }
            ring.fillColor = UIColor.clear.cgColor
            ring.strokeColor = UIColor.white.cgColor
            ring.lineWidth = 2
            layer.addSublayer(fill)
            layer.addSublayer(ring)
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 32),
                heightAnchor.constraint(equalToConstant: 32),
            ])
            updateSelection()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isSelected: Bool {
            didSet { updateSelection() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            fill.path = UIBezierPath(arcCenter: center, radius: 10, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
            ring.path = UIBezierPath(arcCenter: center, radius: 14.5, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        }

        private func updateSelection() {
            ring.isHidden = !isSelected
            accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    // MARK: - HUD

    private final class HUDLabel: UILabel {
        override init(frame: CGRect) {
            super.init(frame: frame)
            font = .dynamicTypeSubheadlineClamped.semibold()
            textColor = .white
            backgroundColor = UIColor.black.withAlphaComponent(0.6)
            textAlignment = .center
            layer.cornerRadius = 14
            layer.masksToBounds = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: size.width + 28, height: max(28, size.height + 8))
        }
    }
}
