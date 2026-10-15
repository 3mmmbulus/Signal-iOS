//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit

// MARK: - ImageEditorItemBackground

struct ImageEditorItemBackground {
    enum CornerRadius: CGFloat {
        case small = 8
        case large = 18
    }

    let color: CGColor
    let corners: CornerRadius
    let scaleFactor: CGFloat

    init(color: CGColor, corners: CornerRadius, scaleFactor: CGFloat) {
        self.color = color
        self.corners = corners
        self.scaleFactor = scaleFactor
    }

    init(color: UIColor, corners: CornerRadius, scaleFactor: CGFloat) {
        self.init(color: color.cgColor, corners: corners, scaleFactor: scaleFactor)
    }

    // Margins between text and edges of the colored background.
    var horizontalMargin: CGFloat {
        6 * scaleFactor
    }

    var verticalMargin: CGFloat {
        2 * scaleFactor
    }

    var cornerRadius: CGFloat {
        corners.rawValue * scaleFactor
    }
}

// MARK: - EditorTextLayer

class EditorTextLayer: CATextLayer {

    let itemId: String

    private var contentLayer: EditorTextLayer?

    init(itemId: String) {
        self.itemId = itemId
        super.init()
        self.name = itemId
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Creates a new layer that is larger than `self` by amount specified in `Margins`.
    // The resulting layer has background color and rounded corners set.
    // `self` is added as a sublayer and is centered vertically and horizontally.
    fileprivate func withRoundedRectBackground(_ background: ImageEditorItemBackground) -> EditorTextLayer {
        guard background.color.alpha > 0 else { return self }

        let rootLayer = EditorTextLayer(itemId: itemId)
        rootLayer.frame = frame.inset(
            by: UIEdgeInsets(
                hMargin: background.horizontalMargin,
                vMargin: background.verticalMargin,
            )
            .inverted(),
        )
        rootLayer.backgroundColor = background.color
        rootLayer.cornerRadius = background.cornerRadius
        rootLayer.addSublayer(self)
        rootLayer.contentLayer = self
        position = rootLayer.bounds.center
        return rootLayer
    }

    override var contentsScale: CGFloat {
        get { super.contentsScale }
        set {
            super.contentsScale = newValue
            if let contentLayer {
                contentLayer.contentsScale = newValue
            }
        }
    }
}

// MARK: - TextFrameLayer

private class TextFrameLayer: CAShapeLayer {

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var bounds: CGRect {
        didSet {
            updatePath()
        }
    }

    override var frame: CGRect {
        didSet {
            updatePath()
        }
    }

    private static let circleRadius: CGFloat = 5

    // Visible frame is a little smaller than layer's bounds in order
    // to make room for little circles in the middle of left and right frame sides.
    private var frameRect: CGRect {
        bounds.insetBy(dx: TextFrameLayer.circleRadius, dy: 0)
    }

    private lazy var leftCircleLayer = TextFrameLayer.createCircleLayer()
    private lazy var rightCircleLayer = TextFrameLayer.createCircleLayer()
    private static func createCircleLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.bounds = CGRect(origin: .zero, size: CGSize(square: circleRadius * 2))
        layer.fillColor = UIColor.white.cgColor
        layer.path = UIBezierPath(ovalIn: layer.bounds).cgPath
        return layer
    }

    private func commonInit() {
        fillColor = UIColor.clear.cgColor
        lineWidth = UITraitCollection.current.hairlineWidthFraction(3)
        strokeColor = UIColor.white.cgColor

        addSublayer(leftCircleLayer)
        addSublayer(rightCircleLayer)
    }

    private func updatePath() {
        path = UIBezierPath(rect: frameRect).cgPath
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        let frameRect = frameRect
        leftCircleLayer.position = CGPoint(x: frameRect.minX, y: frameRect.midY)
        rightCircleLayer.position = CGPoint(x: frameRect.maxX, y: frameRect.midY)
    }
}

// MARK: - ImageEditorCanvasView

// A view for previewing an image editor model.
class ImageEditorCanvasView: UIView, ImageEditorModelObserver {

    private let model: ImageEditorModel

    var hiddenItemId: String? {
        didSet {
            if let itemId = oldValue, let layer = contentLayerMap[itemId] {
                layer.isHidden = false
                // Show text object's frame if current text object is selected.
                if itemId == selectedTransformableItemID {
                    selectedTextFrameLayer?.isHidden = false
                }
            }
            if let hiddenItemId, let layer = contentLayerMap[hiddenItemId] {
                layer.isHidden = true
                // Hide text object's frame when hiding selected text object.
                if hiddenItemId == selectedTransformableItemID {
                    selectedTextFrameLayer?.isHidden = true
                }
            }
        }
    }

    var selectedTransformableItemID: String? {
        didSet {
            updateSelectedTransformableItemFrame()
        }
    }

    /// We want blurs to be rendered above the image and behind strokes and text.
    private static let blurLayerZ: CGFloat = +1
    /// We want strokes to be rendered above the image and blurs and behind text.
    private static let brushLayerZ: CGFloat = +2
    /// We want text to be rendered above the image, blurs, and strokes.
    private static let textLayerZ: CGFloat = +3
    /// Selection frame is rendered above all content.
    private static let selectionFrameLayerZ: CGFloat = +4
    /// Trash is rendered above all content.
    static let trashLayerZ: CGFloat = +5
    /// We leave space for 10k items/layers of each type.
    private static let zPositionSpacing: CGFloat = 0.0001

    init(model: ImageEditorModel, hiddenItemId: String? = nil) {
        self.model = model
        self.hiddenItemId = hiddenItemId

        super.init(frame: .zero)

        contentMode = .scaleAspectFit

        model.add(observer: self)

        prepareBlurredImage()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var contentMode: UIView.ContentMode {
        didSet {
            updateLayout()
        }
    }

    // MARK: - Views

    /// Hosts the layers used to render the content. The transform for the content is applied to this view.
    let imageLayerView = OWSLayerView()

    /// Used to clip the content. It reflects the actual visible bounds of the "canvas" content.
    private let clipView = UIView()

    private var contentViewConstraints: [NSLayoutConstraint]?

    private var imageLayer = CALayer()

    /// Tellomi（tellomi/tellomi#1592 E5-2）：原图；调色调回默认时换回它。
    private var tellomiOriginalImage: CGImage?

    func setCornerRadius(_ cornerRadius: CGFloat, animationDuration: TimeInterval = 0) {
        guard cornerRadius != clipView.layer.cornerRadius else { return }

        if animationDuration > 0 {
            let animation = CABasicAnimation(keyPath: #keyPath(CALayer.cornerRadius))
            animation.fromValue = clipView.layer.cornerRadius
            animation.toValue = cornerRadius
            animation.duration = animationDuration
            clipView.layer.add(animation, forKey: "cornerRadius")
        }
        clipView.layer.cornerRadius = cornerRadius
    }

    func configureSubviews() {
        backgroundColor = .clear
        isOpaque = false

        clipView.clipsToBounds = true
        clipView.isOpaque = false
        clipView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clipView)
        // Constraints added in `updateLayout()`.

        if let srcImage = loadSrcImage() {
            imageLayer.contents = srcImage.cgImage
            imageLayer.contentsScale = srcImage.scale
            tellomiOriginalImage = srcImage.cgImage
        }
        tellomiUpdateBaseImage()
        imageLayerView.isOpaque = false
        imageLayerView.layer.addSublayer(imageLayer)
        imageLayerView.layoutCallback = { [weak self] _ in
            guard let self else { return }
            self.updateAllContent()
        }
        imageLayerView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(imageLayerView)
        NSLayoutConstraint.activate([
            imageLayerView.topAnchor.constraint(equalTo: clipView.topAnchor),
            imageLayerView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            imageLayerView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            imageLayerView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
        ])

        updateLayout()
    }

    var gestureReferenceView: UIView {
        return clipView
    }

    private func updateLayout() {
        // Skip update during init.
        guard clipView.superview != nil else { return }

        if let contentViewConstraints {
            NSLayoutConstraint.deactivate(contentViewConstraints)
            self.contentViewConstraints = nil
        }

        let transform = model.currentTransform()
        let aspectRatio = transform.outputSizePixels

        // Always centered in the superview.
        var constraints = [
            clipView.centerYAnchor.constraint(equalTo: centerYAnchor),
            clipView.centerXAnchor.constraint(equalTo: centerXAnchor),
        ]

        // We only need two modes: `scaleAspectFit` and `scaleToFill`.
        let sizingConstraints: [NSLayoutConstraint] = switch contentMode {
        case .scaleAspectFit:
            [
                // `clipView` doesn't exceed superview's bounds while keeping set aspect ratio.
                clipView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
                clipView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
                clipView.widthAnchor.constraint(
                    equalTo: clipView.heightAnchor,
                    multiplier: aspectRatio.width / aspectRatio.height,
                ),
            ]
        case .scaleToFill:
            [
                // `clipView` is always resized to fill superview's bounds.
                clipView.widthAnchor.constraint(equalTo: widthAnchor),
                clipView.heightAnchor.constraint(equalTo: heightAnchor),
            ]
        default:
            owsFail("Invalid content mode")
        }
        constraints += sizingConstraints

        // Intrinsic content size.
        constraints += {
            let c = [
                clipView.widthAnchor.constraint(equalToConstant: aspectRatio.width),
                clipView.heightAnchor.constraint(equalToConstant: aspectRatio.height),
            ]
            c.forEach { $0.priority = .defaultLow }
            return c
        }()

        NSLayoutConstraint.activate(constraints)
        contentViewConstraints = constraints
    }

    private func loadSrcImage() -> UIImage? {
        return Self.loadSrcImage(model: model)
    }

    /// Tellomi（tellomi/tellomi#1592 E5-2）：画布底图跟着调色换（调过色是调色后的预览图，没调色是原图）。
    private func tellomiUpdateBaseImage() {
        if !tellomiShowsOriginal, let adjusted = Self.tellomiPreviewBaseImage(model: model) {
            imageLayer.contents = adjusted
        } else if let tellomiOriginalImage {
            imageLayer.contents = tellomiOriginalImage
        }
    }

    /// Tellomi（tellomi/tellomi#1593 E5-3）：按住看原图——底图临时换回原图，模型不动（照 Telegram 两端调整页按住画面）。
    var tellomiShowsOriginal = false {
        didSet {
            guard tellomiShowsOriginal != oldValue else { return }
            tellomiUpdateBaseImage()
        }
    }

    var tellomiDisplayedBaseImageForTesting: CGImage? {
        imageLayer.contents.map { $0 as! CGImage }
    }

    class func loadSrcImage(model: ImageEditorModel) -> UIImage? {
        let srcImageData: Data
        do {
            srcImageData = try model.srcImage.dataSource.readData()
        } catch {
            owsFailDebug("Couldn't parse srcImageUrl")
            return nil
        }
        // We use this constructor so that we can specify the scale.
        //
        // UIImage(contentsOfFile:) will sometimes use device scale.
        guard let srcImage = UIImage(data: srcImageData, scale: 1.0) else {
            owsFailDebug("Couldn't load background image.")
            return nil
        }
        // We normalize the image orientation here for the sake
        // of code simplicity.  We could modify the image layer's
        // transform to handle the normalization, which would
        // have perf benefits.
        return srcImage.normalized()
    }

    // MARK: - Text Selection Frame

    private var selectedTextFrameLayer: TextFrameLayer?
    private lazy var tooltipView: UIView = {
        let hMargin: CGFloat = 9
        let vMargin: CGFloat = 5
        let label = UILabel()
        let text = NSAttributedString(
            string: OWSLocalizedString(
                "MEDIA_EDITOR_TAP_FOR_MORE",
                comment: "Tooltip to display above a clock sticker in the media editor saying to tap for more clock styles",
            ),
            attributes: [
                .font: UIFont.dynamicTypeBody,
                .foregroundColor: UIColor.white,
            ],
        )
        label.attributedText = text
        label.frame = .init(
            origin: .init(
                x: hMargin,
                y: vMargin,
            ),
            size: text.boundingRect(
                with: .init(
                    width: self.width,
                    height: .greatestFiniteMagnitude,
                ),
                options: [.usesLineFragmentOrigin],
                context: nil,
            )
            .size,
        )
        let background = UIView()
        background.backgroundColor = .ows_blackAlpha40
        background.layer.cornerRadius = 8
        background.addSubview(label)
        background.frame.size = label.frame.size.plus(.init(width: hMargin * 2, height: vMargin * 2))
        label.frame.origin = .init(x: 9, y: 5)
        return background
    }()

    private var tooltipTimer: Timer?

    // Negative insets because text object frame is larger than object itself.
    private static let textFrameInsets = UIEdgeInsets(hMargin: -16, vMargin: -4)

    private func updateSelectedTransformableItemFrame() {
        guard
            let selectedItemID = selectedTransformableItemID,
            let textLayer = contentLayerMap[selectedItemID]
        else {
            selectedTextFrameLayer?.removeFromSuperlayer()
            selectedTextFrameLayer = nil
            tellomiUpdateShapeHandles()
            return
        }

        let selectedTextFrameLayer = selectedTextFrameLayer ?? TextFrameLayer()
        if selectedTextFrameLayer.superlayer == nil {
            imageLayerView.layer.addSublayer(selectedTextFrameLayer)
            selectedTextFrameLayer.zPosition = ImageEditorCanvasView.selectionFrameLayerZ
            self.selectedTextFrameLayer = selectedTextFrameLayer
        }

        // Disable implicit animations that make little circles not move smoothly with the frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let transform = textLayer.affineTransform()
        let rotationAngle = atan2(transform.b, transform.a)
        let scaleX = sqrt(pow(transform.a, 2) + pow(transform.c, 2))
        let scaleY = sqrt(pow(transform.b, 2) + pow(transform.d, 2))

        selectedTextFrameLayer.bounds = textLayer.bounds
            .inset(by: ImageEditorCanvasView.textFrameInsets)
            .applying(CGAffineTransform(scaleX: scaleX, y: scaleY))
        selectedTextFrameLayer.position = textLayer.position
        selectedTextFrameLayer.setAffineTransform(CGAffineTransform(rotationAngle: rotationAngle))
        selectedTextFrameLayer.layoutSublayers()

        selectedTextFrameLayer.opacity = shouldFadeTransformableItem ? 0.5 : 1
        // Tellomi（tellomi/tellomi#1522 E-3b）：形状不用文字的选中框，画自己的框和拉柄。
        if model.item(forId: selectedItemID) is ImageEditorShapeItem {
            selectedTextFrameLayer.opacity = 0
        }
        tellomiUpdateShapeHandles()

        CATransaction.commit()
    }

    // MARK: - Tellomi shape handles (tellomi/tellomi#1522 E-3b)

    private static let shapeHandleRadius: CGFloat = 7

    private var shapeHandlesLayer: CALayer?

    /// 选中的形状、它的图层、形状单位（图短边 = 1）在画布上合多少点。
    func selectedShapeGeometry() -> (item: ImageEditorShapeItem, layer: CALayer, unit: CGFloat)? {
        guard
            let selectedTransformableItemID,
            let item = model.item(forId: selectedTransformableItemID) as? ImageEditorShapeItem,
            let layer = contentLayerMap[selectedTransformableItemID],
            item.unitWidth > 0
        else {
            return nil
        }
        return (item, layer, layer.bounds.size.width / item.unitWidth)
    }

    /// 选中形状的每个拉柄在画布上的位置。
    func selectedShapeHandlePositions() -> [(handle: TellomiShapeHandles.Handle, point: CGPoint)] {
        guard let geometry = selectedShapeGeometry() else { return [] }
        let shape = geometry.item.shape
        return TellomiShapeHandles.handles(for: geometry.item.kind).map { handle in
            (handle, Self.canvasPoint(TellomiShapeHandles.position(of: handle, in: shape), layer: geometry.layer, unit: geometry.unit))
        }
    }

    /// 形状自己的坐标（中心在原点、图短边 = 1）→ 画布。
    static func canvasPoint(_ point: CGPoint, layer: CALayer, unit: CGFloat) -> CGPoint {
        let offset = CGPoint(x: point.x * unit, y: point.y * unit).applying(layer.affineTransform())
        return CGPoint(x: layer.position.x + offset.x, y: layer.position.y + offset.y)
    }

    /// 画布 → 形状自己的坐标。
    static func shapePoint(fromCanvas point: CGPoint, position: CGPoint, transform: CGAffineTransform, unit: CGFloat) -> CGPoint {
        let offset = CGPoint(x: point.x - position.x, y: point.y - position.y).applying(transform.inverted())
        return CGPoint(x: offset.x / max(unit, 0.0001), y: offset.y / max(unit, 0.0001))
    }

    /// 选中的形状画一圈细框（箭头不画）和拉柄；拉柄在屏幕上大小不变（除掉画布的缩放）。
    private func tellomiUpdateShapeHandles() {
        guard let geometry = selectedShapeGeometry() else {
            shapeHandlesLayer?.removeFromSuperlayer()
            shapeHandlesLayer = nil
            return
        }
        let container: CALayer
        if let shapeHandlesLayer {
            container = shapeHandlesLayer
        } else {
            container = CALayer()
            let outline = CAShapeLayer()
            outline.fillColor = nil
            outline.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
            let dots = CAShapeLayer()
            dots.fillColor = UIColor.white.cgColor
            dots.strokeColor = UIColor.black.withAlphaComponent(0.3).cgColor
            container.addSublayer(outline)
            container.addSublayer(dots)
            container.zPosition = ImageEditorCanvasView.selectionFrameLayerZ
            imageLayerView.layer.addSublayer(container)
            shapeHandlesLayer = container
        }
        guard let outline = container.sublayers?.first as? CAShapeLayer, let dots = container.sublayers?.last as? CAShapeLayer else { return }
        container.frame = imageLayerView.layer.bounds
        let zoom = max(model.currentTransform().scaling, 0.0001)

        let outlinePath = CGMutablePath()
        let shape = geometry.item.shape
        if geometry.item.kind != .arrow {
            let halfWidth = shape.width / 2
            let halfHeight = shape.height / 2
            let corners = [CGPoint(x: -halfWidth, y: -halfHeight), CGPoint(x: halfWidth, y: -halfHeight), CGPoint(x: halfWidth, y: halfHeight), CGPoint(x: -halfWidth, y: halfHeight)]
            outlinePath.addLines(between: corners.map { Self.canvasPoint($0, layer: geometry.layer, unit: geometry.unit) })
            outlinePath.closeSubpath()
        }
        outline.path = outlinePath
        outline.lineWidth = 1 / zoom

        let radius = Self.shapeHandleRadius / zoom
        let dotsPath = CGMutablePath()
        for (_, point) in selectedShapeHandlePositions() {
            dotsPath.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        dots.path = dotsPath
        dots.lineWidth = 1 / zoom
        container.opacity = shouldFadeTransformableItem ? 0.5 : 1
    }

    func hideTooltip() {
        guard tooltipView.superview != nil else { return }
        UIView.animate(withDuration: 0.2) {
            self.tooltipView.layer.opacity = 0
        } completion: { _ in
            self.tooltipView.removeFromSuperview()
        }
        tooltipTimer?.invalidate()
        tooltipTimer = nil
    }

    func updateTooltip() {
        guard
            let selectedItemID = selectedTransformableItemID,
            let stickerItem = model.item(forId: selectedItemID) as? ImageEditorStickerItem,
            case .story = stickerItem.sticker,
            let stickerLayer = contentLayerMap[selectedItemID],
            let selectedTextFrameLayer
        else {
            hideTooltip()
            return
        }

        if tooltipView.superview == nil {
            imageLayerView.addSubview(tooltipView)
            tooltipView.layer.zPosition = ImageEditorCanvasView.selectionFrameLayerZ
        }

        if tooltipView.layer.opacity < 1 {
            // Fade in the tooltip if it wasn't already showing
            UIView.animate(withDuration: 0.2) {
                self.tooltipView.layer.opacity = 1
            }
        }
        tooltipTimer?.invalidate()
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] timer in
            UIView.animate(withDuration: 0.2) {
                self?.tooltipView.layer.opacity = 0
            }
        }

        tooltipView.layer.position = stickerLayer.position.offsetBy(
            dx: 0,
            dy: -(selectedTextFrameLayer.bounds.height / 2 + tooltipView.frame.height / 2 + 8),
        )
    }

    // MARK: - Content

    private var contentLayerMap = [String: CALayer]()

    var shouldFadeTransformableItem = false
    private var fadedItemID: String? {
        shouldFadeTransformableItem ? selectedTransformableItemID : nil
    }

    private func updateAllContent() {
        AssertIsOnMainThread()

        // Don't animate changes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for layer in contentLayerMap.values {
            layer.removeFromSuperlayer()
        }
        contentLayerMap.removeAll()

        let viewSize = clipView.bounds.size
        let transform = model.currentTransform()
        if viewSize.isNonEmpty {
            applyTransform()
            updateImageLayer()

            model.items.forEach { item in
                guard
                    let layer = ImageEditorCanvasView.layerForItem(
                        item: item,
                        model: model,
                        shouldFadeTransformableItemWithID: fadedItemID,
                        transform: transform,
                        viewSize: viewSize,
                    )
                else {
                    return
                }

                if item.itemId == hiddenItemId {
                    layer.isHidden = true
                }
                imageLayerView.layer.addSublayer(layer)
                contentLayerMap[item.itemId] = layer
            }
        }

        updateSelectedTransformableItemFrame()

        // Force layout now.
        setNeedsLayout()
        layoutIfNeeded()

        CATransaction.commit()
    }

    private func updateContent(changedItemIds: [String]) {
        AssertIsOnMainThread()

        let changedItemIds = itemIdsIncludingAffectedErasers(changedItemIds)

        // Don't animate changes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Remove all changed items.
        for itemId in changedItemIds {
            if let layer = contentLayerMap[itemId] {
                layer.removeFromSuperlayer()
            }
            contentLayerMap.removeValue(forKey: itemId)
        }

        let viewSize = clipView.bounds.size
        let transform = model.currentTransform()
        if viewSize.isNonEmpty {
            applyTransform()
            updateImageLayer()

            // Create layers for inserted and updated items.
            for itemId in changedItemIds {
                guard let item = model.item(forId: itemId) else {
                    // Item was deleted.
                    continue
                }

                // Item was inserted or updated.
                guard
                    let layer = ImageEditorCanvasView.layerForItem(
                        item: item,
                        model: model,
                        shouldFadeTransformableItemWithID: fadedItemID,
                        transform: transform,
                        viewSize: viewSize,
                    )
                else {
                    continue
                }

                if item.itemId == hiddenItemId {
                    layer.isHidden = true
                }
                imageLayerView.layer.addSublayer(layer)
                contentLayerMap[item.itemId] = layer
            }
        }

        updateSelectedTransformableItemFrame()

        CATransaction.commit()
    }

    private func applyTransform() {
        let viewSize = clipView.bounds.size
        imageLayerView.layer.setAffineTransform(model.currentTransform().affineTransform(viewSize: viewSize))
    }

    private func updateImageLayer() {
        let viewSize = clipView.bounds.size
        ImageEditorCanvasView.updateImageLayer(
            imageLayer: imageLayer,
            viewSize: viewSize,
            imageSize: model.srcImageSizePixels,
            transform: model.currentTransform(),
        )
    }

    class func updateImageLayer(imageLayer: CALayer, viewSize: CGSize, imageSize: CGSize, transform: ImageEditorTransform) {
        imageLayer.frame = imageFrame(forViewSize: viewSize, imageSize: imageSize, transform: transform)

        // This is the only place the isFlipped flag is consulted.
        // We deliberately do _not_ use it in the affine transforms, etc.
        // so that:
        //
        // * It doesn't affect text content & brush strokes.
        // * To not complicate the other "coordinate system math".
        let transform = CGAffineTransform.identity.scaledBy(x: transform.isFlipped ? -1 : +1, y: 1)
        imageLayer.setAffineTransform(transform)
    }

    class func imageFrame(forViewSize viewSize: CGSize, imageSize: CGSize, transform: ImageEditorTransform) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else {
            owsFailDebug("Invalid viewSize")
            return .zero
        }
        guard imageSize.width > 0, imageSize.height > 0 else {
            owsFailDebug("Invalid imageSize")
            return .zero
        }

        // The image content's default size (at scaling = 1) is to fill the output/canvas bounds.
        // This makes it easier to clamp the scaling to safe values.
        // The downside is that rotation has the side effect of changing the render size of the
        // image, which complicates the crop view logic.
        //
        // Find the smallest possible image size that will completely fill the output size.
        //
        // NOTE: The "bounding box" of the output size that we need to fill needs to
        //       reflect the rotation.
        let sinValue = abs(sin(transform.rotationRadians))
        let cosValue = abs(cos(transform.rotationRadians))
        let outputSize = CGSize(
            width: viewSize.width * cosValue + viewSize.height * sinValue,
            height: viewSize.width * sinValue + viewSize.height * cosValue,
        )

        var width = outputSize.width
        var height = outputSize.width * imageSize.height / imageSize.width
        if height < outputSize.height {
            width = outputSize.height * imageSize.width / imageSize.height
            height = outputSize.height
        }
        let imageFrame = CGRect(
            x: (width - viewSize.width) * -0.5,
            y: (height - viewSize.height) * -0.5,
            width: width,
            height: height,
        )

        return imageFrame
    }

    private class func imageLayerForItem(
        model: ImageEditorModel,
        transform: ImageEditorTransform,
        viewSize: CGSize,
    ) -> CALayer? {
        guard let srcImage = loadSrcImage(model: model) else {
            owsFailDebug("Could not load src image.")
            return nil
        }
        let imageLayer = CALayer()
        // Tellomi（tellomi/tellomi#1592 E5-2）：调过色就画原尺寸的调色图。
        imageLayer.contents = tellomiFullBaseImage(model: model, srcImage: srcImage, transform: transform) ?? srcImage.cgImage
        imageLayer.contentsScale = srcImage.scale
        updateImageLayer(
            imageLayer: imageLayer,
            viewSize: viewSize,
            imageSize: model.srcImageSizePixels,
            transform: transform,
        )
        return imageLayer
    }

    private class func layerForItem(
        item: ImageEditorItem,
        model: ImageEditorModel,
        shouldFadeTransformableItemWithID fadedItemID: String?,
        transform: ImageEditorTransform,
        viewSize: CGSize,
    ) -> CALayer? {
        AssertIsOnMainThread()

        switch item.itemType {
        case .test:
            owsFailDebug("Unexpected test item.")
            return nil
        case .stroke:
            guard let strokeItem = item as? ImageEditorStrokeItem else {
                owsFailDebug("Item has unexpected type: \(type(of: item)).")
                return nil
            }
            return strokeLayerForItem(
                item: strokeItem,
                model: model,
                transform: transform,
                viewSize: viewSize,
            )
        case .text:
            guard let textItem = item as? ImageEditorTextItem else {
                owsFailDebug("Item has unexpected type: \(type(of: item)).")
                return nil
            }
            let isFaded = item.itemId == fadedItemID
            return textLayerForItem(
                item: textItem,
                model: model,
                isFaded: isFaded,
                transform: transform,
                viewSize: viewSize,
            )
        case .sticker:
            guard let stickerItem = item as? ImageEditorStickerItem else {
                owsFailDebug("Item has unexpected type: \(type(of: item)).")
                return nil
            }
            let isFaded = item.itemId == fadedItemID
            return stickerLayerForItem(
                item: stickerItem,
                model: model,
                isFaded: isFaded,
                transform: transform,
                viewSize: viewSize,
            )
        case .blurRegions:
            guard let blurRegionsItem = item as? ImageEditorBlurRegionsItem else {
                owsFailDebug("Item has unexpected type: \(type(of: item)).")
                return nil
            }
            return blurRegionsLayerForItem(
                item: blurRegionsItem,
                model: model,
                transform: transform,
                viewSize: viewSize,
            )
        case .shape:
            guard let shapeItem = item as? ImageEditorShapeItem else {
                owsFailDebug("Item has unexpected type: \(type(of: item)).")
                return nil
            }
            return shapeLayerForItem(
                item: shapeItem,
                model: model,
                isFaded: item.itemId == fadedItemID,
                transform: transform,
                viewSize: viewSize,
            )
        }
    }

    /// Tellomi（tellomi/tellomi#1522 E-3）：形状是一个矢量图层，摆法和贴纸一样（中心、缩放、旋转），和贴纸、文字在同一层。
    private class func shapeLayerForItem(
        item: ImageEditorShapeItem,
        model: ImageEditorModel,
        isFaded: Bool,
        transform: ImageEditorTransform,
        viewSize: CGSize,
    ) -> CALayer {
        AssertIsOnMainThread()

        let imageFrame = ImageEditorCanvasView.imageFrame(
            forViewSize: viewSize,
            imageSize: model.srcImageSizePixels,
            transform: transform,
        )
        let shortSide = min(imageFrame.width, imageFrame.height)
        let size = item.size(shortSide: shortSide)
        let lineWidth = item.lineWidth(shortSide: shortSide)
        let center = item.unitCenter.fromUnitCoordinates(viewBounds: imageFrame)

        let layer = CAShapeLayer()
        layer.frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        layer.path = TellomiShapePath.path(
            kind: item.kind,
            size: size,
            parameters: TellomiShapePath.Parameters(
                lineWidth: lineWidth,
                isFilled: item.isFilled,
                tailX: item.tailX,
                bodyFraction: item.bodyFraction,
                bend: item.bend,
            ),
        )
        if item.kind == .arrow || item.isFilled {
            layer.fillColor = item.color.cgColor
            layer.strokeColor = nil
        } else {
            layer.fillColor = nil
            layer.strokeColor = item.color.cgColor
            layer.lineWidth = lineWidth
            layer.lineJoin = .round
        }
        layer.contentsScale = UITraitCollection.current.displayScale * item.scaling * transform.scaling
        layer.setAffineTransform(CGAffineTransform.scale(item.scaling).rotated(by: item.rotationRadians))
        layer.zPosition = zPositionForItem(item: item, model: model, zPositionBase: textLayerZ)
        layer.name = item.itemId
        layer.opacity = isFaded ? 0.5 : 1
        return layer
    }

    private class func strokeLayerForItem(
        item: ImageEditorStrokeItem,
        model: ImageEditorModel,
        transform: ImageEditorTransform,
        viewSize: CGSize,
    ) -> CALayer? {
        AssertIsOnMainThread()

        let optionalBlurredImageLayer: CALayer?
        if item.strokeType == .blur {
            guard let blurredImageLayer = blurredImageLayerForItem(model: model, transform: transform, viewSize: viewSize) else {
                owsFailDebug("Failed to retrieve blurredImageLayer")
                return nil
            }

            blurredImageLayer.zPosition = zPositionForItem(item: item, model: model, zPositionBase: blurLayerZ)
            optionalBlurredImageLayer = blurredImageLayer
        } else {
            optionalBlurredImageLayer = nil
        }

        let strokeWidth = item.strokeWidth(forDstSize: viewSize)
        let unitSamples = item.unitSamples
        guard unitSamples.count > 0 else {
            // Not an error; the stroke doesn't have enough samples to render yet.
            return nil
        }

        let shapeLayer = CAShapeLayer()
        shapeLayer.lineWidth = strokeWidth
        shapeLayer.strokeColor = item.color?.cgColor
        shapeLayer.frame = CGRect(origin: .zero, size: viewSize)

        // Tellomi（tellomi/tellomi#1522 E-2）：长按填满——整块画布涂满（笔、荧光笔），或作橡皮 / 模糊的遮罩盖满整块画布。
        if item.isFill {
            shapeLayer.path = UIBezierPath(rect: shapeLayer.bounds).cgPath
            shapeLayer.lineWidth = 0
            shapeLayer.strokeColor = nil
            switch item.strokeType {
            case .eraser:
                shapeLayer.fillColor = UIColor.black.cgColor
                return eraserLayerForItem(item: item, model: model, transform: transform, viewSize: viewSize, mask: shapeLayer)
            case .blur:
                guard let blurredImageLayer = optionalBlurredImageLayer else { return nil }
                shapeLayer.fillColor = UIColor.black.cgColor
                blurredImageLayer.mask = shapeLayer
                return blurredImageLayer
            case .pen, .highlighter, .arrow, .neon:
                shapeLayer.fillColor = item.color?.cgColor
                shapeLayer.zPosition = zPositionForItem(item: item, model: model, zPositionBase: brushLayerZ)
                return shapeLayer
            }
        }

        // Blur region origins are specified in "image unit" coordinates,
        // but need to be rendered in "canvas" coordinates. The imageFrame
        // is the bounds of the image specified in "canvas" coordinates,
        // so to transform we can simply convert from image frame units.
        let imageFrame = ImageEditorCanvasView.imageFrame(forViewSize: viewSize, imageSize: model.srcImageSizePixels, transform: transform)
        let transformSampleToPoint = { (unitSample: CGPoint) -> CGPoint in
            return unitSample.fromUnitCoordinates(viewBounds: imageFrame)
        }

        // Use bezier curves to smooth stroke.
        let bezierPath = UIBezierPath()

        let points = applySmoothing(to: unitSamples.map { unitSample in
            transformSampleToPoint(unitSample)
        })
        var previousForwardVector = CGPoint.zero
        for index in 0..<points.count {
            let point = points[index]

            let forwardVector: CGPoint
            if points.count <= 1 {
                // Skip forward vectors.
                forwardVector = .zero
            } else if index == 0 {
                // First sample.
                let nextPoint = points[index + 1]
                forwardVector = CGPoint.subtract(nextPoint, point)
            } else if index == points.count - 1 {
                // Last sample.
                let previousPoint = points[index - 1]
                forwardVector = CGPoint.subtract(point, previousPoint)
            } else {
                // Middle samples.
                let previousPoint = points[index - 1]
                let previousPointForwardVector = CGPoint.subtract(point, previousPoint)
                let nextPoint = points[index + 1]
                let nextPointForwardVector = CGPoint.subtract(nextPoint, point)
                forwardVector = CGPoint.scale(CGPoint.add(previousPointForwardVector, nextPointForwardVector), factor: 0.5)
            }

            if index == 0 {
                // First sample.
                bezierPath.move(to: point)

                if points.count == 1 {
                    bezierPath.addLine(to: point)
                }
            } else {
                let previousPoint = points[index - 1]
                // We apply more than one kind of smoothing.
                // This smoothing avoids rendering "angled segments"
                // by drawing the stroke as a series of curves.
                // We use bezier curves and infer the control points
                // from the "next" and "prev" points.
                //
                // This factor controls how much we're smoothing.
                //
                // * 0.0 = No smoothing.
                //
                // TODO: Tune this variable once we have stroke input.
                let controlPointFactor: CGFloat = 0.25
                let controlPoint1 = CGPoint.add(previousPoint, CGPoint.scale(previousForwardVector, factor: +controlPointFactor))
                let controlPoint2 = CGPoint.add(point, CGPoint.scale(forwardVector, factor: -controlPointFactor))
                // We're using Cubic curves.
                bezierPath.addCurve(to: point, controlPoint1: controlPoint1, controlPoint2: controlPoint2)
            }
            previousForwardVector = forwardVector
        }

        shapeLayer.path = bezierPath.cgPath
        shapeLayer.fillColor = nil

        // Tellomi（tellomi/tellomi#1522 E-2，照 Telegram 两端的画笔）：箭头、霓虹、橡皮。
        switch item.strokeType {
        case .neon:
            let neon = neonLayer(path: bezierPath.cgPath, strokeWidth: strokeWidth, color: item.color ?? .white, viewSize: viewSize)
            neon.zPosition = zPositionForItem(item: item, model: model, zPositionBase: brushLayerZ)
            return neon
        case .eraser:
            shapeLayer.strokeColor = UIColor.black.cgColor
            shapeLayer.lineCap = .round
            shapeLayer.lineJoin = .round
            return eraserLayerForItem(item: item, model: model, transform: transform, viewSize: viewSize, mask: shapeLayer)
        case .arrow:
            if
                item.isFinished,
                let head = ImageEditorStrokeItem.arrowHead(
                    points: points,
                    strokeWidth: strokeWidth,
                    imageLongSide: max(imageFrame.width, imageFrame.height),
                )
            {
                for arm in [head.arm1, head.arm2] {
                    let armPath = UIBezierPath()
                    armPath.move(to: head.tip)
                    armPath.addLine(to: arm)
                    let armLayer = CAShapeLayer()
                    armLayer.name = arrowHeadLayerName
                    armLayer.frame = shapeLayer.bounds
                    armLayer.path = armPath.cgPath
                    armLayer.lineWidth = strokeWidth
                    armLayer.strokeColor = shapeLayer.strokeColor
                    armLayer.fillColor = nil
                    armLayer.lineCap = .round
                    shapeLayer.addSublayer(armLayer)
                }
            }
        case .pen, .highlighter, .blur:
            break
        }

        if item.strokeType == .highlighter {
            shapeLayer.lineCap = CAShapeLayerLineCap.square
            shapeLayer.lineJoin = CAShapeLayerLineJoin.bevel
        } else {
            shapeLayer.lineCap = CAShapeLayerLineCap.round
            shapeLayer.lineJoin = CAShapeLayerLineJoin.round
        }

        if item.strokeType == .blur {
            guard let blurredImageLayer = optionalBlurredImageLayer else {
                owsFailDebug("Unexpectedly missing blurredImageLayer")
                return nil
            }

            shapeLayer.strokeColor = UIColor.black.cgColor
            blurredImageLayer.mask = shapeLayer

            return blurredImageLayer
        } else {
            shapeLayer.zPosition = zPositionForItem(item: item, model: model, zPositionBase: brushLayerZ)

            return shapeLayer
        }
    }

    // MARK: - Tellomi brushes (tellomi/tellomi#1522 E-2)

    static let arrowHeadLayerName = "TellomiArrowHead"

    /// 箭头抬手后长出来（照 Telegram 两端：0.2 s）。只在画布上动，发出去的图直接是完整的箭头。
    func animateArrowHead(itemId: String) {
        guard let layer = contentLayerMap[itemId] else { return }
        for arm in layer.sublayers ?? [] where arm.name == Self.arrowHeadLayerName {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = 0.2
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            arm.add(animation, forKey: "TellomiArrowHead")
        }
    }

    /// 霓虹的三层颜色（照 Telegram 两端）：外面一圈笔色的光，中间笔色的浅色，芯是白的；几乎是黑色时芯是黑的、光是紫的（照 Telegram iOS）。
    static func neonColors(for color: UIColor) -> (glow: UIColor, body: UIColor, core: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let lightness = 0.299 * red + 0.587 * green + 0.114 * blue
        if lightness < 0.07 {
            let purple = UIColor(rgbHex: 0x440881)
            return (purple, purple, .black)
        }
        return (color, color.blended(with: .white, alpha: 0.8), .white)
    }

    private class func neonLayer(path: CGPath, strokeWidth: CGFloat, color: UIColor, viewSize: CGSize) -> CALayer {
        let colors = neonColors(for: color)
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: viewSize)

        func strokeLayer(width: CGFloat, color: UIColor) -> CAShapeLayer {
            let layer = CAShapeLayer()
            layer.frame = container.bounds
            layer.path = path
            layer.lineWidth = width
            layer.strokeColor = color.cgColor
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            return layer
        }

        let glow = strokeLayer(width: strokeWidth * 2, color: colors.glow.withAlphaComponent(0.5))
        glow.shadowColor = colors.glow.cgColor
        glow.shadowOpacity = 1
        glow.shadowRadius = strokeWidth
        glow.shadowOffset = .zero
        container.addSublayer(glow)
        container.addSublayer(strokeLayer(width: strokeWidth, color: colors.body))
        container.addSublayer(strokeLayer(width: strokeWidth * 0.5, color: colors.core))
        return container
    }

    /// 橡皮（照 Telegram 两端：只擦涂鸦层）：Signal 的笔画在“画笔层”，在模糊之上、文字贴纸之下，所以橡皮就是画笔层里一层
    /// “底图”，按橡皮的线露出来——底图是照片、人脸模糊，加上在这块橡皮之后才画的模糊（之前画的模糊被它擦掉，照 Telegram）。
    /// 它在之前的笔画上面、之后的笔画下面，文字贴纸始终在上面，所以只擦得掉之前的笔画。
    private class func eraserLayerForItem(
        item: ImageEditorStrokeItem,
        model: ImageEditorModel,
        transform: ImageEditorTransform,
        viewSize: CGSize,
        mask: CAShapeLayer,
    ) -> CALayer? {
        guard let baseImageLayer = eraserBaseImageLayer(model: model, transform: transform, viewSize: viewSize) else {
            return nil
        }
        baseImageLayer.zPosition = 0
        var baseLayers: [CALayer] = [baseImageLayer]
        let eraserIndex = model.itemIds.firstIndex(of: item.itemId) ?? Int.max
        for other in model.items {
            if let blurRegions = other as? ImageEditorBlurRegionsItem {
                if let layer = blurRegionsLayerForItem(item: blurRegions, model: model, transform: transform, viewSize: viewSize) {
                    baseLayers.append(layer)
                }
            } else if
                let stroke = other as? ImageEditorStrokeItem,
                stroke.strokeType == .blur,
                let index = model.itemIds.firstIndex(of: stroke.itemId),
                index > eraserIndex,
                let layer = strokeLayerForItem(item: stroke, model: model, transform: transform, viewSize: viewSize)
            {
                baseLayers.append(layer)
            }
        }

        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: viewSize)
        for layer in baseLayers.sorted(by: { $0.zPosition < $1.zPosition }) {
            container.addSublayer(layer)
        }
        mask.frame = container.bounds
        container.mask = mask
        container.zPosition = zPositionForItem(item: item, model: model, zPositionBase: brushLayerZ)
        return container
    }

    private class func eraserBaseImageLayer(model: ImageEditorModel, transform: ImageEditorTransform, viewSize: CGSize) -> CALayer? {
        let srcImage: UIImage
        if let cached = model.tellomiDecodedSrcImage {
            srcImage = cached
        } else {
            guard let loaded = loadSrcImage(model: model) else { return nil }
            model.tellomiDecodedSrcImage = loaded
            srcImage = loaded
        }
        let imageLayer = CALayer()
        // Tellomi（tellomi/tellomi#1592 E5-2）：橡皮露出来的是调色后的照片。
        imageLayer.contents = tellomiEraserBaseImage(model: model, transform: transform) ?? srcImage.cgImage
        imageLayer.contentsScale = srcImage.scale
        updateImageLayer(imageLayer: imageLayer, viewSize: viewSize, imageSize: model.srcImageSizePixels, transform: transform)
        return imageLayer
    }

    /// 橡皮的底图里有模糊：模糊一变，橡皮也要重画。
    private func itemIdsIncludingAffectedErasers(_ changedItemIds: [String]) -> [String] {
        let eraserIds = model.items.compactMap { ($0 as? ImageEditorStrokeItem)?.strokeType == .eraser ? $0.itemId : nil }
        guard !eraserIds.isEmpty else { return changedItemIds }
        let touchesBase = changedItemIds.contains { itemId in
            guard let item = model.item(forId: itemId) else { return true }
            return item.itemType == .blurRegions || (item as? ImageEditorStrokeItem)?.strokeType == .blur
        }
        guard touchesBase else { return changedItemIds }
        return changedItemIds + eraserIds.filter { !changedItemIds.contains($0) }
    }

    private class func blurRegionsLayerForItem(
        item: ImageEditorBlurRegionsItem,
        model: ImageEditorModel,
        transform: ImageEditorTransform,
        viewSize: CGSize,
    ) -> CALayer? {
        AssertIsOnMainThread()

        guard !item.unitBoundingBoxes.isEmpty else { return nil }

        guard let blurredImageLayer = blurredImageLayerForItem(model: model, transform: transform, viewSize: viewSize) else {
            owsFailDebug("Failed to retrieve blurredImageLayer")
            return nil
        }

        blurredImageLayer.zPosition = zPositionForItem(item: item, model: model, zPositionBase: blurLayerZ)

        // Stroke samples are specified in "image unit" coordinates, but
        // need to be rendered in "canvas" coordinates.  The imageFrame
        // is the bounds of the image specified in "canvas" coordinates,
        // so to transform we can simply convert from image frame units.
        let imageFrame = ImageEditorCanvasView.imageFrame(forViewSize: viewSize, imageSize: model.srcImageSizePixels, transform: transform)
        func transformSampleToPoint(_ unitSample: CGPoint) -> CGPoint {
            return unitSample.fromUnitCoordinates(viewBounds: imageFrame)
        }

        let maskingShapeLayer = CAShapeLayer()
        maskingShapeLayer.frame = CGRect(origin: .zero, size: viewSize)

        let maskingPath = UIBezierPath()

        for unitRect in item.unitBoundingBoxes {
            var rect = unitRect

            rect.origin = transformSampleToPoint(rect.origin)

            // Rescale normalized coordinates.
            rect.size.width *= imageFrame.width
            rect.size.height *= imageFrame.height

            let bezierPath = UIBezierPath(rect: rect)
            maskingPath.append(bezierPath)
        }

        maskingShapeLayer.path = maskingPath.cgPath
        blurredImageLayer.mask = maskingShapeLayer

        return blurredImageLayer
    }

    private class func zPositionForItem(
        item: ImageEditorItem,
        model: ImageEditorModel,
        zPositionBase: CGFloat,
    ) -> CGFloat {
        guard let itemIndex = model.itemIds.firstIndex(of: item.itemId) else {
            owsFailDebug("Couldn't find index of item.")
            return zPositionBase
        }
        return zPositionBase + CGFloat(itemIndex) * zPositionSpacing
    }

    #if TESTABLE_BUILD
    /// Tellomi（tellomi/tellomi#1522 E-2）：测试里看某一项的图层（橡皮、霓虹、箭头）。
    class func layerForTesting(item: ImageEditorItem, model: ImageEditorModel, viewSize: CGSize) -> CALayer? {
        layerForItem(item: item, model: model, shouldFadeTransformableItemWithID: nil, transform: model.currentTransform(), viewSize: viewSize)
    }

    /// Tellomi（tellomi/tellomi#1522 E-4）：测试里看文字图层（有底色时是外面那层，文字在 `contentLayer` 里）。
    class func textLayerForTesting(item: ImageEditorTextItem, model: ImageEditorModel, viewSize: CGSize) -> CATextLayer? {
        let layer = textLayerForItem(item: item, model: model, isFaded: false, transform: model.currentTransform(), viewSize: viewSize)
        return (layer?.sublayers?.first as? CATextLayer) ?? (layer as? CATextLayer)
    }
    #endif

    private class func textLayerForItem(
        item: ImageEditorTextItem,
        model: ImageEditorModel,
        isFaded: Bool,
        transform: ImageEditorTransform,
        viewSize: CGSize,
    ) -> CALayer? {
        AssertIsOnMainThread()

        let imageFrame = ImageEditorCanvasView.imageFrame(forViewSize: viewSize, imageSize: model.srcImageSizePixels, transform: transform)

        let scaleFactor = imageFrame.size.width / item.fontReferenceImageWidth

        // We need to adjust the font size to reflect the current output scale,
        // using the image width as reference.
        let fontSize = item.fontSize * scaleFactor
        let font = MediaTextView.font(for: item.textStyle, withPointSize: fontSize)

        let text = item.text.filterForDisplay
        let textStorage = NSTextStorage(
            string: text,
            attributes: [.font: font, .foregroundColor: item.textForegroundColor],
        )

        if let textDecorationColor = item.textDecorationColor {
            switch item.decorationStyle {
            case .underline:
                textStorage.addAttributes(
                    [
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: textDecorationColor,
                    ],
                    range: textStorage.entireRange,
                )

            case .outline:
                textStorage.addAttributes(
                    [
                        .strokeWidth: -3,
                        .strokeColor: textDecorationColor,
                    ],
                    range: textStorage.entireRange,
                )

            default:
                break
            }
        }

        let background = item.textBackgroundColor.map { color in
            ImageEditorItemBackground(color: color, corners: .small, scaleFactor: scaleFactor)
        }

        return textLayer(
            for: textStorage.attributedString(),
            imageFrame: imageFrame,
            unitWidth: item.unitWidth,
            background: background,
            alignment: item.textAlignment,
            item: item,
            model: model,
            isFaded: isFaded,
            transform: transform,
            viewSize: viewSize,
        )
    }

    private class func textLayer(
        for attributedString: NSAttributedString,
        imageFrame: CGRect,
        unitWidth: CGFloat = 1,
        background: ImageEditorItemBackground?,
        alignment: NSTextAlignment = .center,
        item: any ImageEditorTransformable,
        model: ImageEditorModel,
        isFaded: Bool,
        transform: ImageEditorTransform,
        viewSize: CGSize,
    ) -> CALayer? {
        let textLayer = EditorTextLayer(itemId: item.itemId)
        textLayer.string = attributedString
        textLayer.isWrapped = true
        // Tellomi（tellomi/tellomi#1522 E-4）：照文字的对齐。
        textLayer.alignmentMode = switch alignment {
        case .left: .left
        case .right: .right
        default: .center
        }
        // I don't think we need to enable allowsFontSubpixelQuantization
        // or set truncationMode.

        // This text needs to be rendered at a scale that reflects:
        //
        // * The screen scaling (so that text looks sharp on Retina devices.
        // * The item's scaling (so that text doesn't become blurry as you make it larger).
        // * Model transform (so that text doesn't become blurry as you zoom the content).
        textLayer.contentsScale = UITraitCollection.current.displayScale * item.scaling * transform.scaling

        let maxWidth = imageFrame.size.width * unitWidth
        let textSize = attributedString.boundingRect(
            with: CGSize(
                width: maxWidth,
                height: .greatestFiniteMagnitude,
            ),
            options: [.usesLineFragmentOrigin],
            context: nil,
        ).size.ceil

        // The text item's center is specified in "image unit" coordinates, but
        // needs to be rendered in "canvas" coordinates.  The imageFrame
        // is the bounds of the image specified in "canvas" coordinates,
        // so to transform we can simply convert from image frame units.
        let centerInCanvas = item.unitCenter.fromUnitCoordinates(viewBounds: imageFrame)
        textLayer.frame = CGRect(
            origin: CGPoint(
                x: centerInCanvas.x - textSize.width * 0.5,
                y: centerInCanvas.y - textSize.height * 0.5,
            ),
            size: textSize,
        )

        // Enlarge the layer slightly when setting the background color to add some horizontal padding around the text.
        let layer: EditorTextLayer
        if let background {
            layer = textLayer.withRoundedRectBackground(background)
        } else {
            layer = textLayer
        }

        let transform = CGAffineTransform.scale(item.scaling).rotated(by: item.rotationRadians)
        layer.setAffineTransform(transform)
        layer.zPosition = zPositionForItem(item: item, model: model, zPositionBase: textLayerZ)

        layer.opacity = isFaded ? 0.5 : 1

        return layer
    }

    private class func stickerLayerForItem(
        item: ImageEditorStickerItem,
        model: ImageEditorModel,
        isFaded: Bool,
        transform: ImageEditorTransform,
        viewSize: CGSize,
    ) -> CALayer? {
        AssertIsOnMainThread()

        let imageFrame = ImageEditorCanvasView.imageFrame(
            forViewSize: viewSize,
            imageSize: model.srcImageSizePixels,
            transform: transform,
        )

        let image: UIImage
        switch (model.stickerViewCache.object(forKey: item.itemId)?.value, item.sticker) {
        case (.some(let cachedImage), _):
            // Cached image exists. Use that
            image = cachedImage
        case (.none, .regular(let stickerInfo)):
            // Regular sticker. Fetch its image
            guard
                let metadata = StickerManager.installedStickerMetadataWithSneakyTransaction(stickerInfo: stickerInfo),
                let imageData = try? metadata.readStickerData(),
                let stickerImage = UIImage(data: imageData)
            else {
                owsFailDebug("Failed to retrieve sticker image")
                return nil
            }
            model.stickerViewCache.setObject(ThreadSafeCacheHandle(stickerImage), forKey: item.itemId)
            image = stickerImage
        case (.none, .story(let storySticker)):
            // Story sticker. Return early with special rendering
            return storyStickerLayer(
                for: storySticker,
                imageFrame: imageFrame,
                item: item,
                model: model,
                isFaded: isFaded,
                transform: transform,
                viewSize: viewSize,
            )
        }

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit

        return makeLayerTransformable(
            imageView.layer,
            imageFrame: imageFrame,
            item: item,
            model: model,
            isFaded: isFaded,
            transform: transform,
            viewSize: viewSize,
        )
    }

    private class func makeLayerTransformable(
        _ imageLayer: CALayer,
        imageFrame: CGRect,
        item: ImageEditorStickerItem,
        model: ImageEditorModel,
        isFaded: Bool,
        transform: ImageEditorTransform,
        viewSize: CGSize,
    ) -> CALayer {
        imageLayer.contentsScale = UITraitCollection.current.displayScale * item.scaling * transform.scaling
        let stickerSize = CGSize(square: 175 * imageFrame.size.width / item.referenceImageWidth)
        let centerInCanvas = item.unitCenter.fromUnitCoordinates(viewBounds: imageFrame)
        imageLayer.frame = imageFrame

        imageLayer.frame = CGRect(
            origin: CGPoint(
                x: centerInCanvas.x - stickerSize.width * 0.5,
                y: centerInCanvas.y - stickerSize.height * 0.5,
            ),
            size: stickerSize,
        )

        let transform = CGAffineTransform.scale(item.scaling).rotated(by: item.rotationRadians)
        imageLayer.setAffineTransform(transform)
        imageLayer.zPosition = zPositionForItem(item: item, model: model, zPositionBase: textLayerZ)
        imageLayer.name = item.itemId

        imageLayer.opacity = isFaded ? 0.5 : 1

        return imageLayer
    }

    private class func storyStickerLayer(
        for storySticker: EditorSticker.StorySticker,
        imageFrame: CGRect,
        item: ImageEditorStickerItem,
        model: ImageEditorModel,
        isFaded: Bool,
        transform: ImageEditorTransform,
        viewSize: CGSize,
    ) -> CALayer? {
        switch storySticker {
        case .clockDigital(let digitalClockStyle):
            let scaleFactor = imageFrame.size.width / item.referenceImageWidth

            let attributedString = digitalClockStyle.attributedString(
                date: item.date,
                scaleFactor: scaleFactor,
            )

            let background = digitalClockStyle.backgroundColor.map { color in
                ImageEditorItemBackground(color: color, corners: .large, scaleFactor: scaleFactor)
            }

            return textLayer(
                for: attributedString,
                imageFrame: imageFrame,
                background: background,
                item: item,
                model: model,
                isFaded: isFaded,
                transform: transform,
                viewSize: viewSize,
            )
        case .clockAnalog(let clockStyle):
            let clockLayer = clockStyle.drawClock(date: item.date)

            return makeLayerTransformable(
                clockLayer,
                imageFrame: imageFrame,
                item: item,
                model: model,
                isFaded: isFaded,
                transform: transform,
                viewSize: viewSize,
            )
        }
    }

    // We apply more than one kind of smoothing.
    //
    // This (simple) smoothing reduces jitter from the touch sensor.
    private class func applySmoothing(to points: [CGPoint]) -> [CGPoint] {
        AssertIsOnMainThread()

        var result = [CGPoint]()

        for index in 0..<points.count {
            let point = points[index]

            if index == 0 {
                // First sample.
                result.append(point)
            } else if index == points.count - 1 {
                // Last sample.
                result.append(point)
            } else {
                // Middle samples.
                let lastPoint = points[index - 1]
                let nextPoint = points[index + 1]
                let alpha: CGFloat = 0.1
                let smoothedPoint = CGPoint.add(
                    CGPoint.scale(point, factor: 1.0 - 2.0 * alpha),
                    CGPoint.add(
                        CGPoint.scale(lastPoint, factor: alpha),
                        CGPoint.scale(nextPoint, factor: alpha),
                    ),
                )
                result.append(smoothedPoint)
            }
        }

        return result
    }

    // MARK: - Blur

    private func prepareBlurredImage() {
        guard let srcImage = loadSrcImage() else {
            return owsFailDebug("Could not load src image.")
        }

        Task { @MainActor [weak self] in
            do {
                // we use a very strong blur radius to ensure adequate coverage of large and small faces
                let blurredImage = try await srcImage.cgImageWithGaussianBlurAsync(
                    radius: 25,
                    resizeToMaxPixelDimension: 300,
                )
                guard let self else { return }
                self.model.blurredSourceImage = blurredImage

                // Once the blur is ready, update any content in case the user already blurred
                if self.window != nil {
                    self.updateAllContent()
                }
            } catch {
                owsFailDebug("Failed to blur src image")
            }
        }
    }

    private class func blurredImageLayerForItem(
        model: ImageEditorModel,
        transform: ImageEditorTransform,
        viewSize: CGSize,
    ) -> CALayer? {
        // Tellomi（tellomi/tellomi#1592 E5-2）：打码从调色后的底图取样。
        guard let blurredSourceImage = tellomiBlurredBaseImage(model: model, transform: transform) else {
            // If we fail to generate the blur image, or it's not ready yet, use a black mask
            let layer = CALayer()
            layer.frame = imageFrame(forViewSize: viewSize, imageSize: model.srcImageSizePixels, transform: transform)
            layer.backgroundColor = UIColor.black.cgColor
            return layer
        }

        // The image layer renders the blurred image in canvas coordinates
        let blurredImageLayer = CALayer()
        blurredImageLayer.contents = blurredSourceImage
        updateImageLayer(
            imageLayer: blurredImageLayer,
            viewSize: viewSize,
            imageSize: model.srcImageSizePixels,
            transform: transform,
        )

        // The container holds the blurred image, and can be masked using canvas
        // coordinates to partially blur the image.
        let blurredImageContainer = CALayer()
        blurredImageContainer.addSublayer(blurredImageLayer)
        blurredImageContainer.frame = CGRect(origin: .zero, size: viewSize)

        return blurredImageContainer
    }

    // MARK: - Actions

    // Returns nil on error.
    //
    // We render using the transform parameter, not the transform from the model.
    // This allows this same method to be used for rendering "previews" for the
    // crop tool and the final output.
    class func renderForOutput(model: ImageEditorModel, transform: ImageEditorTransform) -> UIImage? {
        // TODO: Do we want to render off the main thread?
        AssertIsOnMainThread()

        // Tellomi（tellomi/tellomi#1592 E5-2）：原尺寸调色图只在这一次渲染里留着（底图、橡皮共用），渲染完放掉。
        defer { model.tellomiAdjustedImages.full = nil }

        // Render output at same size as source image.
        let dstSizePixels = transform.outputSizePixels
        let dstScale: CGFloat = 1.0 // The size is specified in pixels, not in points.
        let viewSize = dstSizePixels

        // We use an UIImageView + UIView.renderAsImage() instead of a CGGraphicsContext
        // Because CALayer.renderInContext() doesn't honor CALayer properties like frame,
        // transform, etc.
        let view = UIView()
        view.backgroundColor = UIColor.clear
        view.isOpaque = false
        view.frame = CGRect(origin: .zero, size: viewSize)

        // Rendering a UIView to an image will not honor the root image's layer transform.
        // We therefore use a subview.
        let contentView = UIView()
        contentView.backgroundColor = UIColor.clear
        contentView.isOpaque = false
        contentView.frame = CGRect(origin: .zero, size: viewSize)
        view.addSubview(contentView)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        contentView.layer.setAffineTransform(transform.affineTransform(viewSize: viewSize))

        guard
            let imageLayer = imageLayerForItem(
                model: model,
                transform: transform,
                viewSize: viewSize,
            )
        else {
            owsFailDebug("Could not load src image.")
            return nil
        }
        imageLayer.contentsScale = dstScale * transform.scaling
        contentView.layer.addSublayer(imageLayer)

        let layers: [CALayer] = model.items.compactMap { item in
            guard
                let layer = layerForItem(
                    item: item,
                    model: model,
                    shouldFadeTransformableItemWithID: nil,
                    transform: transform,
                    viewSize: viewSize,
                )
            else {
                owsFailDebug("Couldn't create layer for item.")
                return nil
            }
            layer.contentsScale = dstScale * transform.scaling * item.outputScale
            return layer
        }
        // UIView.renderAsImage() doesn't honor zPosition of layers,
        // so sort the item layers to ensure they are added in the
        // correct order.
        let sortedLayers = layers.sorted(by: { left, right -> Bool in
            return left.zPosition < right.zPosition
        })
        for layer in sortedLayers {
            contentView.layer.addSublayer(layer)
        }

        CATransaction.commit()

        let image = view.renderAsImage(opaque: !model.srcImageMetadata.hasAlpha, scale: dstScale)
        return image
    }

    // MARK: -

    func transformableLayer(forLocation point: CGPoint) -> CALayer? {
        guard let sublayers = imageLayerView.layer.sublayers else {
            return nil
        }

        // Allow to interact with selected text layer when user taps within
        // selection frame (which is larger than text itself).
        if
            let selectedTextFrameLayer,
            let selectedTextItemId = selectedTransformableItemID,
            let selectedTextLayer = contentLayerMap[selectedTextItemId] as? EditorTextLayer,
            selectedTextFrameLayer.hitTest(point) != nil
        {
            return selectedTextLayer
        }

        // First we build a map of all named layers.
        let layerMap = sublayers.reduce(into: [String: CALayer]()) { partialResult, layer in
            guard let layerName = layer.name else { return }
            partialResult[layerName] = layer
        }

        // The layer ordering in the model is authoritative.
        // Iterate over the layers in _reverse_ order of which they appear
        // in the model, so that layers "on top" are hit first.
        return model.items
            .lazy
            .reversed()
            .filter { $0 is ImageEditorTransformable }
            .compactMap { item in layerMap[item.itemId] }
            .first { layer in layer.hitTest(point) != nil }
    }

    // MARK: - Coordinates

    class func locationImageUnit(
        forLocationInView locationInView: CGPoint,
        viewBounds: CGRect,
        model: ImageEditorModel,
        transform: ImageEditorTransform,
    ) -> CGPoint {
        let imageFrame = self.imageFrame(forViewSize: viewBounds.size, imageSize: model.srcImageSizePixels, transform: transform)
        let affineTransformStart = transform.affineTransform(viewSize: viewBounds.size)
        let locationInContent = locationInView.minus(viewBounds.center).applyingInverse(affineTransformStart).plus(viewBounds.center)
        let locationImageUnit = locationInContent.toUnitCoordinates(viewBounds: imageFrame, shouldClamp: false)
        return locationImageUnit
    }

    // MARK: - ImageEditorModelObserver

    func imageEditorModelDidChange(before: ImageEditorContents, after: ImageEditorContents) {
        // 调色变了要重画底图；裁剪变了（这里 before == after）而暗角不是 0 也要，暗角跟着画框。没变时走缓存，不重画。
        tellomiUpdateBaseImage()
        updateAllContent()
        updateLayout()
    }

    func imageEditorModelDidChange(changedItemIds: [String]) {
        updateContent(changedItemIds: changedItemIds)
    }
}
