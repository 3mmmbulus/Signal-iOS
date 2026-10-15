//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

extension ImageEditorViewController {

    private func initializeDrawToolUIIfNecessary() {
        guard !drawToolUIInitialized else { return }

        drawToolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drawToolbar)
        NSLayoutConstraint.activate([
            drawToolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            drawToolbar.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
        ])

        view.addGestureRecognizer(drawToolGestureRecognizer)
        view.addGestureRecognizer(fillGestureRecognizer)

        drawToolUIInitialized = true
    }

    func updateDrawToolControlsVisibility() {
        drawToolbar.alpha = topBar.alpha
        strokeWidthSliderContainer.alpha = topBar.alpha
    }

    func updateDrawToolUIVisibility() {
        let visible = mode == .draw

        if visible {
            initializeDrawToolUIIfNecessary()
        } else {
            guard drawToolUIInitialized else { return }
        }

        drawToolbar.isHidden = !visible
        drawToolGestureRecognizer.isEnabled = visible

        if visible {
            currentStrokeType = drawToolbar.strokeType
        }
    }

    static var highligherStrokeOpacity: CGFloat = 0.5

    @objc
    func handleDrawToolGesture(_ gestureRecognizer: ImageEditorPanGestureRecognizer) {
        AssertIsOnMainThread()

        owsAssertDebug(mode == .draw, "Incorrect mode [\(mode)]")

        let removeCurrentStroke = {
            if let stroke = self.currentStroke {
                self.model.remove(item: stroke)
            }
            self.currentStroke = nil
            self.currentStrokeSamples.removeAll()
        }
        let tryToAppendStrokeSample = { (locationInView: CGPoint) in
            let view = self.imageEditorView.gestureReferenceView
            let viewBounds = view.bounds
            let newSample = ImageEditorCanvasView.locationImageUnit(
                forLocationInView: locationInView,
                viewBounds: viewBounds,
                model: self.model,
                transform: self.model.currentTransform(),
            )

            if
                let prevSample = self.currentStrokeSamples.last,
                prevSample == newSample
            {
                // Ignore duplicate samples.
                return
            }
            self.currentStrokeSamples.append(newSample)
        }

        var strokeColor = drawToolbar.colorPickerBar.uiColor
        if currentStrokeType == .highlighter {
            strokeColor = strokeColor.withAlphaComponent(Self.highligherStrokeOpacity)
        }
        let unitStrokeWidth = currentStrokeUnitWidth()

        switch gestureRecognizer.state {
        case .began:
            setStrokeWidthSlider(revealed: false)

            // Tellomi（tellomi/tellomi#1522 E-3）：在别处画就是把选中的形状放下。
            if imageEditorView.selectedShapeItem != nil {
                imageEditorView.selectedTransformableItemID = nil
            }

            removeCurrentStroke()

            // Apply the location history of the gesture so that the stroke reflects
            // the touch's movement before the gesture recognized.
            for location in gestureRecognizer.locationHistory {
                tryToAppendStrokeSample(location)
            }

            let locationInView = gestureRecognizer.location(in: imageEditorView.gestureReferenceView)
            tryToAppendStrokeSample(locationInView)

            let stroke = ImageEditorStrokeItem(
                color: strokeColor,
                strokeType: currentStrokeType,
                unitSamples: currentStrokeSamples,
                unitStrokeWidth: unitStrokeWidth,
                isFinished: false,
            )
            model.append(item: stroke)
            currentStroke = stroke

        case .changed, .ended:
            let locationInView = gestureRecognizer.location(in: imageEditorView.gestureReferenceView)
            tryToAppendStrokeSample(locationInView)

            guard let lastStroke = self.currentStroke else {
                owsFailDebug("Missing last stroke.")
                removeCurrentStroke()
                return
            }

            // Model items are immutable; we _replace_ the
            // stroke item rather than modify it.
            let stroke = ImageEditorStrokeItem(
                itemId: lastStroke.itemId,
                color: strokeColor,
                strokeType: currentStrokeType,
                unitSamples: currentStrokeSamples,
                unitStrokeWidth: unitStrokeWidth,
                isFinished: gestureRecognizer.state == .ended,
            )
            model.replace(item: stroke, suppressUndo: true)

            if gestureRecognizer.state == .ended {
                // Tellomi（tellomi/tellomi#1522 E-2）：抬手了，箭头长出来。
                if stroke.strokeType == .arrow {
                    imageEditorView.canvasView.animateArrowHead(itemId: stroke.itemId)
                }
                currentStroke = nil
                currentStrokeSamples.removeAll()
            } else {
                currentStroke = stroke
            }

        default:
            removeCurrentStroke()
        }
    }

    class DrawToolbar: UIView {

        var strokeType: ImageEditorStrokeItem.StrokeType = .pen {
            didSet {
                updateStrokeTypeButtonImage()
                updateStrokeTypeMenu()
            }
        }

        /// Tellomi（tellomi/tellomi#1522 E-2，照 Telegram 两端一排可选的笔）：画笔键点开是笔的菜单，按 Telegram 的顺序——
        /// 笔、箭头、荧光笔（Telegram 的「马克笔」）、霓虹、橡皮。上游这里是笔 / 荧光笔来回切。
        static let brushes: [ImageEditorStrokeItem.StrokeType] = [.pen, .arrow, .highlighter, .neon, .eraser]

        var onStrokeTypeSelected: ((ImageEditorStrokeItem.StrokeType) -> Void)?

        /// Tellomi（tellomi/tellomi#1522 E-3，照 Telegram 两端画笔一排最后的「+」→ 形状）：菜单最后一项「形状」，点开是五种形状和「填充」开关。
        var onShapeSelected: ((ImageEditorShapeItem.Kind) -> Void)?

        /// 新形状填充还是描边（默认描边，照两端 Telegram）；只管之后加的形状，这次编辑里记着（照 Telegram 安卓的全局开关，不存盘，D9）。
        var fillsShapes = false {
            didSet {
                updateStrokeTypeMenu()
            }
        }

        func select(strokeType: ImageEditorStrokeItem.StrokeType) {
            self.strokeType = strokeType
            onStrokeTypeSelected?(strokeType)
        }

        static func title(for strokeType: ImageEditorStrokeItem.StrokeType) -> String {
            switch strokeType {
            case .pen, .blur:
                return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_BRUSH_PEN", comment: "Image editor brush menu: the regular pen.")
            case .highlighter:
                return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_BRUSH_HIGHLIGHTER", comment: "Image editor brush menu: the translucent highlighter.")
            case .arrow:
                return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_BRUSH_ARROW", comment: "Image editor brush menu: a pen that ends in an arrow head.")
            case .neon:
                return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_BRUSH_NEON", comment: "Image editor brush menu: a glowing neon pen.")
            case .eraser:
                return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_BRUSH_ERASER", comment: "Image editor brush menu: the eraser, which removes earlier drawing.")
            }
        }

        static func image(for strokeType: ImageEditorStrokeItem.StrokeType) -> UIImage {
            let symbol = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            switch strokeType {
            case .pen, .blur:
                return UIImage(imageLiteralResourceName: "brush-pen")
            case .highlighter:
                return UIImage(imageLiteralResourceName: "brush-highlighter")
            case .arrow:
                return UIImage(systemName: "arrow.up.right", withConfiguration: symbol) ?? UIImage()
            case .neon:
                return UIImage(systemName: "scribble.variable", withConfiguration: symbol) ?? UIImage()
            case .eraser:
                return UIImage(systemName: "eraser", withConfiguration: symbol) ?? UIImage()
            }
        }

        private func updateStrokeTypeMenu() {
            let brushActions: [UIMenuElement] = Self.brushes.map { brush in
                UIAction(
                    title: Self.title(for: brush),
                    image: Self.image(for: brush),
                    state: brush == strokeType ? .on : .off,
                ) { [weak self] _ in
                    self?.select(strokeType: brush)
                }
            }
            strokeTypeButton.menu = UIMenu(children: brushActions + [shapesMenu()])
        }

        /// 形状的次序照 Telegram iOS 的形状菜单：矩形、圆、气泡、星形、箭头。
        static let shapes: [ImageEditorShapeItem.Kind] = [.rectangle, .circle, .bubble, .star, .arrow]

        private func shapesMenu() -> UIMenu {
            let shapeActions: [UIMenuElement] = Self.shapes.map { kind in
                UIAction(
                    title: Self.title(for: kind),
                    image: Self.image(for: kind, filled: fillsShapes),
                ) { [weak self] _ in
                    self?.onShapeSelected?(kind)
                }
            }
            let fillToggle = UIAction(
                title: OWSLocalizedString("IMAGE_EDITOR_TELLOMI_SHAPE_FILL", comment: "Image editor shapes menu: toggle that makes new shapes filled instead of outlined."),
                image: UIImage(systemName: "circle.lefthalf.filled"),
                state: fillsShapes ? .on : .off,
            ) { [weak self] _ in
                guard let self else { return }
                self.fillsShapes.toggle()
            }
            return UIMenu(
                title: OWSLocalizedString("IMAGE_EDITOR_TELLOMI_SHAPES", comment: "Image editor brush menu: submenu that adds a shape (rectangle, circle, bubble, star, arrow) to the image."),
                image: UIImage(systemName: "square.on.circle"),
                children: shapeActions + [UIMenu(options: .displayInline, children: [fillToggle])],
            )
        }

        static func title(for kind: ImageEditorShapeItem.Kind) -> String {
            switch kind {
            case .rectangle:
                return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_SHAPE_RECTANGLE", comment: "Image editor shapes menu: a rectangle.")
            case .circle:
                return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_SHAPE_CIRCLE", comment: "Image editor shapes menu: a circle.")
            case .star:
                return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_SHAPE_STAR", comment: "Image editor shapes menu: a five-pointed star.")
            case .bubble:
                return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_SHAPE_BUBBLE", comment: "Image editor shapes menu: a speech bubble.")
            case .arrow:
                return OWSLocalizedString("IMAGE_EDITOR_TELLOMI_SHAPE_ARROW", comment: "Image editor shapes menu: a straight arrow shape.")
            }
        }

        static func image(for kind: ImageEditorShapeItem.Kind, filled: Bool) -> UIImage? {
            let name: String
            switch kind {
            case .rectangle: name = "rectangle"
            case .circle: name = "circle"
            case .star: name = "star"
            case .bubble: name = "bubble.left"
            case .arrow: return UIImage(systemName: "arrow.right")
            }
            return UIImage(systemName: filled ? name + ".fill" : name)
        }

        let colorPickerBar: ColorPickerBar

        let strokeTypeButton = UIButton(configuration: .roundMedia(
            image: UIImage(imageLiteralResourceName: "brush-pen"),
            size: 44,
        ))

        /// Tellomi（tellomi/tellomi#1522 E-2）：吸管键，在色条和画笔键之间（和安卓一样）。
        let eyedropperButton = ImageEditorViewController.makeEyedropperButton()

        private func updateStrokeTypeButtonImage() {
            guard strokeType != .blur else {
                owsFailDebug("Invalid stroke type")
                return
            }
            strokeTypeButton.configuration?.image = Self.image(for: strokeType)
        }

        init(currentColor: ColorPickerBarColor) {
            colorPickerBar = ColorPickerBar(color: currentColor)

            super.init(frame: .zero)

            preservesSuperviewLayoutMargins = true
            directionalLayoutMargins.top = 0
            directionalLayoutMargins.bottom = 2

            strokeTypeButton.setCompressionResistanceHorizontalHigh()
            eyedropperButton.setCompressionResistanceHorizontalHigh()
            updateStrokeTypeButtonImage() // just in case
            strokeTypeButton.showsMenuAsPrimaryAction = true
            strokeTypeButton.accessibilityLabel = OWSLocalizedString(
                "IMAGE_EDITOR_TELLOMI_BRUSH_MENU",
                comment: "Accessibility label of the image editor's brush button, which opens a menu of brushes (pen, arrow, highlighter, neon, eraser).",
            )
            updateStrokeTypeMenu()

            // I had to use a custom layout guide because stack view isn't centered
            // but instead has slight offset towards the trailing edge.
            let stackView = UIStackView(arrangedSubviews: [colorPickerBar, eyedropperButton, strokeTypeButton])
            stackView.translatesAutoresizingMaskIntoConstraints = false
            stackView.alignment = .center
            stackView.spacing = 8
            addSubview(stackView)
            NSLayoutConstraint.activate([
                stackView.centerXAnchor.constraint(equalTo: layoutMarginsGuide.centerXAnchor),
                stackView.leadingAnchor.constraint(greaterThanOrEqualTo: layoutMarginsGuide.leadingAnchor),
                stackView.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
                stackView.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
                {
                    let constraint = stackView.widthAnchor.constraint(
                        equalToConstant: ImageEditorViewController.preferredToolbarContentWidth,
                    )
                    constraint.priority = .defaultHigh
                    return constraint
                }(),
            ])
        }

        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
