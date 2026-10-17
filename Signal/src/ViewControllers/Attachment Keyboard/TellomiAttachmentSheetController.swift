//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit

/// Tellomi（tellomi/tellomi#1121 F-1）：附件 Sheet 的容器。dock 的「相册」「文件」在同一个 Sheet 里换页，不收起 Sheet
/// （照 Telegram iOS `AttachmentController`：换页时内容交叉淡入淡出，Sheet 高度不变）。
///
/// 2026-10-17 第二版（owner 在 TestFlight 18 上：「换 tab 时动效是从第一个 tab 瞬间切过去的，不是真实的 iOS 液态玻璃」）：
/// - **dock 是 Sheet 的一条，各页共用**（照 Telegram iOS：`AttachmentPanel` 在 `AttachmentController` 里，不在页里）。手指点下去，
///   系统 tab 栏（iOS 26）自己的选中镜片开始走，换页时这一条一直在、动画不被打断；第一版每页各带一条、换页时临时接手，镜片要从头再来一遍。
/// - 换页的内容：新页不透明地放在底下，只有旧页在上面淡出（0.23 s，`AttachmentController.animateSwitchTransition`）。
/// - Sheet 展开到全屏（进位置 / 联系人 / 投票页）时，系统先把 Sheet 高度一下子设成全屏、再从下面推上来，贴着底边的 dock 会掉出屏幕几帧；
///   换档期间每一帧把 dock 挪回屏幕底边以内（`keepDockOnScreenDuringDetentChange`）。
///
/// 2026-10-16（owner 发来的《附件面板里位置 / 投票 / 联系人在面板内换页》方案）：「投票」也是这里的一页，照 Telegram iOS
/// `ChatControllerOpenAttachmentMenu` 的 `requestController`（`.poll` 把页面换进 Sheet），不再收起 Sheet 另开整屏。
final class TellomiAttachmentSheetController: UIViewController {

    enum Page: Equatable {
        case gallery
        case files
        case poll
        case contact
        case location
    }

    let photoPicker: TellomiPhotoPickerViewController
    private let makePage: (Page) -> UIViewController?
    /// 「文件」页只建一次（来回切换状态还在）；投票、联系人、位置页每次进都新建（上次没发的输入、搜索、选点不留着）。
    private var filesPage: UIViewController?
    private var otherPage: UIViewController?

    private(set) var page: Page = .gallery

    /// 各页共用的那条 dock；没有 dock 项（不是从「+」打开）时没有。
    let dock: TellomiAttachmentDock?

    /// 第一次出现在屏幕上（弹出动画走完）时调一次：会话页用它弹新功能提示卡（`TellomiFeatureIntro`）。
    var onFirstAppear: ((TellomiAttachmentSheetController) -> Void)?
    private var hasAppeared = false

    init(photoPicker: TellomiPhotoPickerViewController, makePage: @escaping (Page) -> UIViewController?) {
        self.photoPicker = photoPicker
        self.makePage = makePage
        let items = photoPicker.attachmentDockItems
        self.dock = items.isEmpty ? nil : TellomiAttachmentDock(items: items, selectedItem: .gallery)
        super.init(nibName: nil, bundle: nil)
        // 选图页的 view 还没建：给它共用的 dock，它就不再自己建
        photoPicker.sharedAttachmentDock = dock
        photoPicker.isActiveAttachmentPage = true
        dock?.onSelect = { [weak self] item in self?.didSelectDockItem(item) }
    }

    /// 只有相册、文件两页时的写法。
    convenience init(photoPicker: TellomiPhotoPickerViewController, makeFilesPage: @escaping () -> UIViewController) {
        self.init(photoPicker: photoPicker) { page in
            page == .files ? makeFilesPage() : nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background
        embed(photoPicker)
        if let dock {
            dock.install(in: view)
        }
        applyDockState(for: photoPicker, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasAppeared else { return }
        hasAppeared = true
        onFirstAppear?(self)
    }

    /// 选图页选了照片时不许下拉直接关（它自己按「有没有选中」设）：跟着当前页。
    override var isModalInPresentation: Bool {
        get { currentChild.isModalInPresentation || super.isModalInPresentation }
        set { super.isModalInPresentation = newValue }
    }

    /// 换到 [page]；已经是这一页就什么都不做（重复点当前格由页面自己处理：回到顶部并展开）。
    func show(_ page: Page, animated: Bool = true) {
        guard page != self.page else { return }
        let to: UIViewController
        switch page {
        case .gallery:
            to = photoPicker
        case .files:
            guard let files = filesPage ?? makePage(.files) else { return }
            filesPage = files
            to = files
        case .poll, .contact, .location:
            guard let other = makePage(page) else { return }
            to = other
        }
        // 上一次换页还没走完（连着点了两格）：先让它立刻走完（旧页拿掉），这次从那里接着走。
        // 不然点回刚淡出的那一页时，上一次淡出的收尾会把现在这页拿掉（白屏）。
        completeTransitionNow()
        let from: UIViewController = currentChild
        self.page = page
        if page != .files, page != .gallery {
            otherPage = to
        }
        // 旧页不再管 dock（它淡出时收到的键盘通知之类不许再动这条共用的 dock）
        (from as? TellomiAttachmentDockClient)?.isActiveAttachmentPage = false
        // 新页放在旧页底下、不透明（不让新页跟着淡入）
        embed(to, below: from.view)
        applyDockState(for: to, animated: animated)
        expandIfWanted(to, animated: animated)
        to.view.alpha = 1
        let finish = {
            from.willMove(toParent: nil)
            from.view.removeFromSuperview()
            from.removeFromParent()
        }
        guard animated else {
            finish()
            return
        }
        let token = UUID()
        transitionToken = token
        transitionCleanup = {
            from.view.layer.removeAllAnimations()
            from.view.alpha = 1
            finish()
        }
        UIView.animate(withDuration: Self.switchFadeDuration, delay: 0, options: [.curveEaseInOut], animations: {
            from.view.alpha = 0
        }, completion: { [weak self] _ in
            guard let self, self.transitionToken == token else { return }
            self.completeTransitionNow()
        })
    }

    /// 换页时旧页淡出的时长（Telegram iOS：0.23 s）。
    static let switchFadeDuration: TimeInterval = 0.23

    /// 正在走的那次换页：收尾（旧页拿掉）要做的事，和它的标记（淡出的完成回调只收自己那一次的尾）。
    private var transitionCleanup: (() -> Void)?
    private var transitionToken: UUID?

    private func completeTransitionNow() {
        let cleanup = transitionCleanup
        transitionCleanup = nil
        transitionToken = nil
        cleanup?()
    }

    private var currentChild: UIViewController {
        switch page {
        case .gallery: return photoPicker
        case .files: return filesPage ?? photoPicker
        case .poll, .contact, .location: return otherPage ?? photoPicker
        }
    }

    // MARK: - Dock

    /// dock 跟着当前页：选中这一页的格子（系统 tab 栏点下去时已经选上了，这里就不动它，不打断它自己的动画），按这一页要不要显示。
    private func applyDockState(for child: UIViewController, animated: Bool) {
        guard let dock, let client = child as? TellomiAttachmentDockClient else { return }
        client.isActiveAttachmentPage = true
        dock.select(client.attachmentDockItem, animated: animated)
        dock.isHidden = !client.wantsAttachmentDock
        view.bringSubviewToFront(dock)
    }

    /// dock 上点了一格：交给当前页（重复点当前格、换页、收起 Sheet 去别处都由页面决定）。
    /// 系统 tab 栏点下去自己已经换了选中项；页面最后没换页（置灰的格子、去 Sheet 外面的 GIF……）就换回当前页的格子。
    private func didSelectDockItem(_ item: TellomiAttachmentDockItem) {
        let before = page
        (currentChild as? TellomiAttachmentDockClient)?.attachmentDockDidSelect(item)
        if page == before, let client = currentChild as? TellomiAttachmentDockClient, let dock, dock.selectedItem != client.attachmentDockItem {
            dock.select(client.attachmentDockItem, animated: true)
        }
    }

    /// Sheet 换档（展开到全屏）期间：系统先把 Sheet 的高度一下子设成全屏、再把它从下面推上来，贴着 Sheet 底边的 dock 会先掉出屏幕
    /// 再跟着升上来（第一版录屏里约 3 帧看不到 dock）。换档的这一小段每一帧把 dock 往上挪，底边不超出屏幕。
    private func keepDockOnScreenDuringDetentChange() {
        guard let dock, dock.window != nil else { return }
        detentDisplayLink?.invalidate()
        detentChangeEndsAt = CACurrentMediaTime() + 0.5
        let link = CADisplayLink(target: self, selector: #selector(keepDockOnScreen))
        link.add(to: .main, forMode: .common)
        detentDisplayLink = link
    }

    private var detentDisplayLink: CADisplayLink?
    private var detentChangeEndsAt: CFTimeInterval = 0

    @objc
    private func keepDockOnScreen() {
        guard let dock, let window = view.window, CACurrentMediaTime() < detentChangeEndsAt else {
            detentDisplayLink?.invalidate()
            detentDisplayLink = nil
            dock?.transform = .identity
            return
        }
        guard let shown = view.layer.presentation(), let windowLayer = window.layer.presentation() else { return }
        // 这一帧 Sheet 在屏幕上的底边：超出窗口底边多少，dock 就往上挪多少
        let onScreen = shown.convert(shown.bounds, to: windowLayer)
        let overflow = max(0, onScreen.maxY - window.bounds.maxY)
        dock.transform = CGAffineTransform(translationX: 0, y: -overflow)
    }

    // MARK: - Pages

    /// 页面要全屏（投票：要键盘）就把 Sheet 展开到 large，展开完再告诉它（这时再弹键盘，半屏的 Sheet 不会被键盘顶成一条）。
    private func expandIfWanted(_ child: UIViewController, animated: Bool) {
        guard let page = child as? TellomiAttachmentSheetPage, page.wantsExpandedSheet else { return }
        guard let sheet = sheetPresentationController, sheet.selectedDetentIdentifier != .large else {
            page.attachmentSheetDidExpand()
            return
        }
        guard animated else {
            sheet.selectedDetentIdentifier = .large
            page.attachmentSheetDidExpand()
            return
        }
        sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        keepDockOnScreenDuringDetentChange()
        // animateChanges 没有完成回调；Sheet 换档的动画约 0.3 秒
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak page] in
            page?.attachmentSheetDidExpand()
        }
    }

    private func embed(_ child: UIViewController, below sibling: UIView? = nil) {
        guard child.parent !== self else { return }
        // 页的 view 还没建：先给它共用的 dock，它就不再自己建
        if let client = child as? TellomiAttachmentDockClient, dock != nil {
            client.sharedAttachmentDock = dock
        }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let sibling, sibling.superview === view {
            view.insertSubview(child.view, belowSubview: sibling)
        } else if let dock, dock.superview === view {
            view.insertSubview(child.view, belowSubview: dock)
        } else {
            view.addSubview(child.view)
        }
        child.didMove(toParent: self)
    }

    var visibleChildForTesting: UIViewController? { children.last }

    /// dock 的哪一格是 Sheet 里的页（在同一个 Sheet 里换）；不是的（GIF）返回 nil。
    static func page(for item: TellomiAttachmentDockItem) -> Page? {
        switch item {
        case .gallery: return .gallery
        case .file: return .files
        case .poll: return .poll
        case .contact: return .contact
        case .location: return .location
        case .gif: return nil
        }
    }
}

/// Tellomi（2026-10-17 第二版）：附件 Sheet 里的页。dock 由 Sheet 画一条、各页共用（照 Telegram iOS：tab 栏在 `AttachmentController`，
/// 不在页里）；页只说这一页对应哪一格、现在要不要显示 dock、点了 dock 怎么办。
protocol TellomiAttachmentDockClient: AnyObject {
    /// Sheet 在把页放进来之前给它：有了它，页就不自己建 dock，页里的「dock」就是这一条。nil = 页自己带 dock（单独打开、测试）。
    var sharedAttachmentDock: TellomiAttachmentDock? { get set }
    /// 是 Sheet 当前那一页：只有当前页能动共用的 dock（旧页淡出时收到的键盘通知之类不许动它）。
    var isActiveAttachmentPage: Bool { get set }
    /// 这一页对应 dock 的哪一格。
    var attachmentDockItem: TellomiAttachmentDockItem { get }
    /// 这一页现在要不要显示 dock（选了照片、搜索中、键盘起来时不要）。
    var wantsAttachmentDock: Bool { get }
    /// dock 上点了一格（含重复点当前格）。
    func attachmentDockDidSelect(_ item: TellomiAttachmentDockItem)
}

/// Tellomi（2026-10-16）：Sheet 里的页可以要求进来就展开到全屏。
protocol TellomiAttachmentSheetPage: AnyObject {
    var wantsExpandedSheet: Bool { get }
    /// Sheet 已经是全屏了（刚展开完，或者本来就是）。
    func attachmentSheetDidExpand()
}
