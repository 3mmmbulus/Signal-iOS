//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1115）：附件 Sheet 底部的 dock——相册 · 文件 · 位置 · 投票 · 联系人（owner 2026-09-23 定），
/// 最后临时加回一格 GIF（owner 2026-09-26 定：「+」改成 Sheet 后原来附件面板打不开了，面板上的 GIF 键是 iPhone 上唯一的 GIF 入口；
/// GIF 以后挪到表情面板 #1012，那边做好之前先放在这里）。
/// 图标、文案用 Signal 自己原来附件面板那一套（只有「相册」是新词），不用 Telegram 的任何图标（Telegram 的附件菜单里本来就没有 GIF）。
enum TellomiAttachmentDockItem: CaseIterable {
    case gallery
    case file
    case location
    case poll
    case contact
    case gif

    /// 附件 Sheet 的 dock 实际列出哪几格（会话页用）：GIF 只在这个部署能用 GIF 时列（#1078 `isGifAvailable`，同原来的上游附件面板
    /// `AttachmentFormatPickerView`，2026-10-16 已删）——大陆包 provider = none，入口一起关，包里才没有连境外内容代理的地方。
    static var attachmentSheetItems: [TellomiAttachmentDockItem] {
        let isGifAvailable = RemoteConfig.current.isGifAvailable
        return allCases.filter { $0 != .gif || isGifAvailable }
    }

    var title: String {
        switch self {
        case .gallery:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_TELLOMI_GALLERY", value: "Gallery", comment: "Tellomi: dock button in the attachment sheet that shows the photo grid.")
        case .file:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_FILE", comment: "A button to select a file from the Attachment Keyboard")
        case .location:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_LOCATION", comment: "A button to select a location from the Attachment Keyboard")
        case .poll:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_POLL", comment: "A button to select a poll from the Attachment Keyboard")
        case .contact:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_CONTACT", comment: "A button to select a contact from the Attachment Keyboard")
        case .gif:
            return OWSLocalizedString("ATTACHMENT_KEYBOARD_GIF", comment: "A button to select a GIF from the Attachment Keyboard")
        }
    }

    var imageName: String {
        switch self {
        case .gallery: return "album-tilt-28"
        case .file: return "file-28"
        case .location: return "location-28"
        case .poll: return "poll-28"
        case .contact: return "person-circle-28"
        case .gif: return "gif-28"
        }
    }
}

/// 尺寸照 Telegram iOS 的 glass tab bar（`AttachmentPanel`：高 62、胶囊、左右各让 20、离底部安全区 8；格子里图标在上、10 pt 中等字重的字在下）。
///
/// 2026-10-17（TestFlight 0.1.0 (16) 反馈「「+」菜单没有液态玻璃效果」）：照 Telegram iOS 的机制重做外观与手感——
/// - iOS 26：整条是系统的 `UIGlassEffect`（带 Signal 的 glass 底色、可交互，同会话输入栏），选中那格底下是一块小一圈的玻璃「镜片」
///   （Telegram 在 iOS 26 用私有的 `_UILiquidLensView`；这里只用公开的 `UIGlassEffect(style: .clear)`，规格内「只用系统自带的玻璃」）；
/// - iOS 26 之前：系统材质模糊 + 很淡的阴影，镜片是一块中性色的胶囊（Telegram `LegacyGlassView` 的做法）；
/// - 换选中项时镜片用弹簧滑过去（`AttachmentPanel.updateLiquidLens`，0.4 s spring）；按住在 dock 上左右拖，镜片跟手、
///   松手落在手指下那一格（`AttachmentPanel.onTabSelectionGesture` / `TabSelectionRecognizer`）。
/// 只读了 Telegram 的源码弄清机制，代码是独立写的（GPLv2 与 AGPLv3 不兼容，`docs/reference/TELEGRAM_SOURCE.md`）。
final class TellomiCustomAttachmentDock: UIView {

    static let height: CGFloat = 62
    static let sideMargin: CGFloat = 20
    static let bottomMargin: CGFloat = 8
    /// 镜片离胶囊边的距离（Telegram：3 pt）。
    static let lensInset: CGFloat = 3

    var onSelect: ((TellomiAttachmentDockItem) -> Void)?

    let items: [TellomiAttachmentDockItem]
    private(set) var selectedItem: TellomiAttachmentDockItem
    private var buttons: [TellomiAttachmentDockItem: UIButton] = [:]
    private let stack = UIStackView()
    private let background: UIVisualEffectView
    private let barEffect: UIVisualEffect
    private let lens: UIView
    private let lensEffect: UIVisualEffect?
    /// 拖动中：镜片中心跟着的 x（dock 坐标）；nil = 镜片停在选中那格。
    private var dragX: CGFloat?
    /// 拖动中手指下的那一格（字和图标先变成选中色，松手才真正选）。
    private var highlightedItem: TellomiAttachmentDockItem?

    init(items: [TellomiAttachmentDockItem], selectedItem: TellomiAttachmentDockItem) {
        self.items = items
        self.selectedItem = selectedItem
        if #available(iOS 26, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.tintColor = .Signal.glassBackgroundTint
            glass.isInteractive = true
            barEffect = glass
            let lensGlass = UIGlassEffect(style: .clear)
            lensGlass.tintColor = Self.lensTint
            lensEffect = lensGlass
            lens = UIVisualEffectView(effect: lensGlass)
        } else {
            barEffect = UIBlurEffect(style: .systemChromeMaterial)
            lensEffect = nil
            lens = UIView()
            lens.backgroundColor = Self.lensTint
        }
        background = UIVisualEffectView(effect: barEffect)
        super.init(frame: .zero)

        if #available(iOS 26, *) {
            background.cornerConfiguration = .capsule()
            lens.cornerConfiguration = .capsule()
        } else {
            background.clipsToBounds = true
            background.layer.cornerRadius = Self.height / 2
            background.layer.cornerCurve = .continuous
            lens.layer.cornerCurve = .continuous
            // 胶囊浮在内容上：很淡的一圈阴影（阴影画在不裁剪的 self 上）
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.08
            layer.shadowRadius = 20
            layer.shadowOffset = CGSize(width: 0, height: 1)
        }
        addSubview(background)
        background.autoPinEdgesToSuperviewEdges()

        background.contentView.addSubview(lens)

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        background.contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(hMargin: Self.lensInset, vMargin: 0))

        for item in items {
            let button = makeButton(for: item)
            buttons[item] = button
            stack.addArrangedSubview(button)
        }

        let drag = UIPanGestureRecognizer(target: self, action: #selector(didDrag(_:)))
        drag.cancelsTouchesInView = true
        addGestureRecognizer(drag)

        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 镜片的底色：iOS 26 是给玻璃镜片的一点点色，之前是整块胶囊的颜色（Telegram：浅色黑 7.5%、深色白 10%）。
    private static var lensTint: UIColor {
        UIColor(
            light: UIColor(white: 0, alpha: 0.075),
            dark: UIColor(white: 1, alpha: 0.1),
        )
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    func select(_ item: TellomiAttachmentDockItem) {
        select(item, animated: false)
    }

    /// 换选中项；animated 时镜片弹簧滑过去。
    func select(_ item: TellomiAttachmentDockItem, animated: Bool) {
        let animated = animated && window != nil
        if animated {
            // 先把镜片放在它现在该在的地方，再换选中项、滑过去
            layoutIfNeeded()
        }
        selectedItem = item
        updateColors()
        guard animated else {
            setNeedsLayout()
            return
        }
        animateLens { self.layoutLens() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutLens()
    }

    private func layoutLens() {
        guard let frame = lensTargetFrame() else { return }
        lens.bounds = CGRect(origin: .zero, size: frame.size)
        lens.center = CGPoint(x: frame.midX, y: frame.midY)
        if #unavailable(iOS 26) {
            lens.layer.cornerRadius = frame.height / 2
        }
        // 拖动时镜片「提起来」：放大一点（Telegram 提起时镜片升高、变大）
        lens.transform = dragX == nil ? .identity : CGAffineTransform(scaleX: 1.08, y: 1.08)
    }

    /// 镜片该在的位置（background.contentView 坐标）：拖动时跟手，否则在选中那格。
    private func lensTargetFrame() -> CGRect? {
        guard let button = buttons[selectedItem] else { return nil }
        // background 的 contentView（stack 在里面）要先排好，不然第一次排版时格子的位置还是零宽时的
        background.layoutIfNeeded()
        var frame = button.convert(button.bounds, to: background.contentView)
        frame = frame.insetBy(dx: 0, dy: Self.lensInset)
        if let dragX {
            let x = convert(CGPoint(x: dragX, y: 0), to: background.contentView).x
            let minX = Self.lensInset
            let maxX = background.contentView.bounds.width - Self.lensInset - frame.width
            frame.origin.x = min(max(x - frame.width / 2, minX), max(minX, maxX))
        }
        return frame
    }

    private func animateLens(_ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes) { _ in completion?() }
        } else {
            UIView.animate(
                withDuration: 0.4,
                delay: 0,
                usingSpringWithDamping: 0.82,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: changes,
            ) { _ in completion?() }
        }
    }

    // MARK: - 出现

    /// 出现动画的起点：玻璃先「化开」（effect = nil）、图标和字透明。之后在动画块里调 `finishAppearing()`。
    /// 不动 dock 的 alpha：`UIVisualEffectView`（玻璃、模糊）自己或上层的透明度一不是 1 就画不对，淡入到最后会一下子「跳」成玻璃
    /// （TestFlight (16)「画面闪动」）。动 effect 是系统给玻璃做出现 / 消失动画的办法。
    func prepareToAppear() {
        background.effect = nil
        (lens as? UIVisualEffectView)?.effect = nil
        if lensEffect == nil {
            lens.alpha = 0
        }
        stack.alpha = 0
    }

    func finishAppearing() {
        background.effect = barEffect
        (lens as? UIVisualEffectView)?.effect = lensEffect
        lens.alpha = 1
        stack.alpha = 1
    }

    // MARK: - 拖动换格

    /// 只接横着拖：竖着拖留给 Sheet 自己（下拉关闭 / 上拉展开）。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.view === self else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc
    private func didDrag(_ gesture: UIPanGestureRecognizer) {
        let x = gesture.location(in: self).x
        switch gesture.state {
        case .began:
            dragX = x
            highlightedItem = item(atX: x)
            updateColors()
            animateLens { self.layoutLens() }
        case .changed:
            dragX = x
            let item = item(atX: x)
            if item != highlightedItem {
                highlightedItem = item
                updateColors()
            }
            layoutLens()
        case .ended:
            let item = item(atX: x)
            endDrag()
            if let item {
                onSelect?(item)
            }
        case .cancelled, .failed:
            endDrag()
        default:
            break
        }
    }

    private func endDrag() {
        dragX = nil
        highlightedItem = nil
        updateColors()
        animateLens { self.layoutLens() }
    }

    /// dock 坐标 x 下面是哪一格（超出两头算最边上那格）。
    private func item(atX x: CGFloat) -> TellomiAttachmentDockItem? {
        guard !items.isEmpty else { return nil }
        background.layoutIfNeeded()
        let local = convert(CGPoint(x: x, y: bounds.midY), to: stack)
        let width = stack.bounds.width / CGFloat(items.count)
        guard width > 0 else { return nil }
        let index = min(max(Int(local.x / width), 0), items.count - 1)
        return items[index]
    }

    // MARK: - 按钮

    private func makeButton(for item: TellomiAttachmentDockItem) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(imageLiteralResourceName: item.imageName)
        configuration.imagePlacement = .top
        configuration.imagePadding = 2
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.attributedTitle = AttributedString(item.title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 10, weight: .medium)]))
        // 按下不要按钮自己的灰底：按下的反馈是玻璃本身（可交互的 glass）和镜片
        configuration.background.backgroundColor = .clear
        let button = UIButton(configuration: configuration)
        button.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = .clear
        }
        button.accessibilityLabel = item.title
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onSelect?(item)
        }, for: .primaryActionTriggered)
        return button
    }

    private func updateColors() {
        let accentItem = highlightedItem ?? selectedItem
        for (item, button) in buttons {
            let color: UIColor = item == accentItem ? .Signal.accent : .Signal.secondaryLabel
            button.tintColor = color
            button.configuration?.baseForegroundColor = color
            button.accessibilityTraits = item == selectedItem ? [.button, .selected] : .button
        }
    }
}

/// 附件 Sheet 底部的 dock（2026-10-17 第二版，owner 在 TestFlight 18 上：「换 tab 时动效是从第一个 tab 瞬间切过去的，不是真实的 iOS 液态玻璃」）。
///
/// - **iOS 26 起就是系统的 `UITabBar`**：浮起来的玻璃胶囊、选中项那块会随手指和换选中项拉伸着滑过去的镜片、按住拖动换格，
///   全是系统自己画的（Apple 的 liquid lens）。Telegram iOS 在 `AttachmentPanel` 里用的就是这个镜片（私有的 `_UILiquidLensView`，
///   `LiquidLensView.swift` 按类名取）；公开 API 拿到同一个东西的办法是直接用 `UITabBar`。第一版自己用 `UIGlassEffect` 拼的镜片看起来像一块灰片，
///   也没有系统那种拉伸。
/// - iOS 26 之前：第一版的自绘 dock（`TellomiCustomAttachmentDock`：模糊胶囊 + 会滑的选中块）。
///
/// 选中项由页面 / Sheet 定（`select(_:animated:)`）：点了一格只交给 `onSelect`；系统 tab 栏点下去自己已经换了选中项，
/// 页面没换页（GIF 收起 Sheet、置灰的格子……）时由 Sheet 换回来。
/// 摆放用 `install(in:)`：系统 tab 栏贴满宽度、贴着底边（安全区它自己让），自绘的照旧左右各让 20、离安全区底 8、高 62。
final class TellomiAttachmentDock: UIView, UITabBarDelegate {

    static let height: CGFloat = 62
    static let sideMargin: CGFloat = 20
    static let bottomMargin: CGFloat = 8
    static let lensInset: CGFloat = TellomiCustomAttachmentDock.lensInset

    var onSelect: ((TellomiAttachmentDockItem) -> Void)?

    let items: [TellomiAttachmentDockItem]
    private(set) var selectedItem: TellomiAttachmentDockItem
    /// iOS 26 起为 true（除非测试里要自绘的那种）。
    let usesSystemTabBar: Bool
    private let tabBar: UITabBar?
    private let tabBarItems: [UITabBarItem]
    private let custom: TellomiCustomAttachmentDock?

    init(items: [TellomiAttachmentDockItem], selectedItem: TellomiAttachmentDockItem, prefersSystemTabBar: Bool = true) {
        self.items = items
        self.selectedItem = selectedItem
        var systemAvailable = false
        if #available(iOS 26, *) {
            systemAvailable = true
        }
        usesSystemTabBar = systemAvailable && prefersSystemTabBar
        if usesSystemTabBar {
            let tabBarItems = items.enumerated().map { index, item in
                UITabBarItem(title: item.title, image: UIImage(imageLiteralResourceName: item.imageName), tag: index)
            }
            let bar = UITabBar()
            bar.items = tabBarItems
            bar.selectedItem = items.firstIndex(of: selectedItem).map { tabBarItems[$0] }
            bar.tintColor = .Signal.accent
            self.tabBar = bar
            self.tabBarItems = tabBarItems
            self.custom = nil
        } else {
            self.tabBar = nil
            self.tabBarItems = []
            self.custom = TellomiCustomAttachmentDock(items: items, selectedItem: selectedItem)
        }
        super.init(frame: .zero)
        if let tabBar {
            tabBar.delegate = self
            addSubview(tabBar)
            tabBar.autoPinEdgesToSuperviewEdges()
        } else if let custom {
            custom.onSelect = { [weak self] item in self?.onSelect?(item) }
            addSubview(custom)
            custom.autoPinEdgesToSuperviewEdges()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 放进 [host] 的底部（Sheet 或单独打开的页）。
    func install(in host: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        if usesSystemTabBar {
            // 系统 tab 栏自己按安全区摆胶囊：贴满宽度、贴着底边，高度用它自己的
            NSLayoutConstraint.activate([
                leadingAnchor.constraint(equalTo: host.leadingAnchor),
                trailingAnchor.constraint(equalTo: host.trailingAnchor),
                bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor, constant: Self.sideMargin),
                trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -Self.sideMargin),
                bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -Self.bottomMargin),
                heightAnchor.constraint(equalToConstant: Self.height),
            ])
        }
    }

    func select(_ item: TellomiAttachmentDockItem) {
        select(item, animated: false)
    }

    /// 换选中项；系统 tab 栏 animated 时由系统滑过去（同点那一格）。已经选中就什么都不做——不打断点下去时系统正在走的动画。
    func select(_ item: TellomiAttachmentDockItem, animated: Bool) {
        selectedItem = item
        if let tabBar {
            guard let index = items.firstIndex(of: item) else { return }
            let target = tabBarItems[index]
            guard tabBar.selectedItem !== target else { return }
            if animated, window != nil {
                tabBar.selectedItem = target
            } else {
                UIView.performWithoutAnimation {
                    tabBar.selectedItem = target
                    tabBar.layoutIfNeeded()
                }
            }
        } else {
            custom?.select(item, animated: animated)
        }
    }

    // MARK: - 出现（G-6：全部取消选图时 dock 回来）

    /// 自绘的：玻璃「凝结」出来（不动 alpha）。系统 tab 栏没有可动的 effect，只靠调用方的缩放。
    func prepareToAppear() {
        custom?.prepareToAppear()
    }

    func finishAppearing() {
        custom?.finishAppearing()
    }

    // MARK: - UITabBarDelegate

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let index = tabBarItems.firstIndex(where: { $0 === item }) else { return }
        // 系统已经把选中项换过去了（含重复点当前格）：记下来，交给页面 / Sheet 决定换不换页
        selectedItem = items[index]
        onSelect?(items[index])
    }
}

#if TESTABLE_BUILD
extension TellomiAttachmentDock {
    /// 同用户点了一格：系统 tab 栏先自己换选中项，再告诉代理。
    func tapForTesting(_ item: TellomiAttachmentDockItem) {
        if let tabBar, let index = items.firstIndex(of: item) {
            tabBar.selectedItem = tabBarItems[index]
            self.tabBar(tabBar, didSelect: tabBarItems[index])
        } else {
            custom?.tapForTesting(item)
        }
    }

    var systemTabBarForTesting: UITabBar? { tabBar }
    var customDockForTesting: TellomiCustomAttachmentDock? { custom }

    /// 系统 tab 栏上显示为选中的那一格。
    var visiblySelectedItemForTesting: TellomiAttachmentDockItem? {
        if let tabBar {
            return tabBar.selectedItem.flatMap { selected in tabBarItems.firstIndex(where: { $0 === selected }) }.map { items[$0] }
        }
        return custom?.selectedItem
    }

    var selectedItemTintForTesting: UIColor? { custom?.selectedItemTintForTesting ?? tabBar?.tintColor }
}
#endif

#if TESTABLE_BUILD
extension TellomiCustomAttachmentDock {
    func tapForTesting(_ item: TellomiAttachmentDockItem) {
        buttons[item]?.sendActions(for: .primaryActionTriggered)
    }

    var selectedItemTintForTesting: UIColor? { buttons[selectedItem]?.configuration?.baseForegroundColor }

    /// 镜片（dock 坐标）与某一格（dock 坐标）。
    var lensFrameForTesting: CGRect { background.contentView.convert(lens.frame, to: self) }

    func buttonFrameForTesting(_ item: TellomiAttachmentDockItem) -> CGRect? {
        buttons[item].map { $0.convert($0.bounds, to: self) }
    }

    var isLensAnimatingForTesting: Bool { lens.layer.animationKeys()?.isEmpty == false }

    /// 模拟拖动：按下在 [fromX]，拖到 [toX] 松手（dock 坐标）。
    func dragForTesting(fromX: CGFloat, toX: CGFloat) {
        dragX = fromX
        highlightedItem = item(atX: fromX)
        layoutLens()
        dragX = toX
        highlightedItem = item(atX: toX)
        updateColors()
        layoutLens()
        let item = item(atX: toX)
        endDrag()
        if let item {
            onSelect?(item)
        }
    }

    var highlightedItemForTesting: TellomiAttachmentDockItem? { highlightedItem }
}
#endif
