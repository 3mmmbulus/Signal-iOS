//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit

/// Tellomi（tellomi/tellomi#1121 F-1）：附件 Sheet 的容器。dock 的「相册」「文件」在同一个 Sheet 里换页，不收起 Sheet
/// （照 Telegram iOS `AttachmentController`：换页时内容交叉淡入淡出，Sheet 高度不变）。
/// 各页各自带着同一位置的 dock（选中的格子不同），所以换页时 dock 看起来不动。
///
/// 2026-10-17（TestFlight (16) 反馈「换页有闪动」「没有液态玻璃」）：照 Telegram iOS `AttachmentController.animateSwitchTransition`
/// 的做法换页——新页直接以不透明放在底下，只有旧页在上面淡出（0.23 s）；dock 换页期间由 Sheet 上面一条临时 dock 接手，
/// 镜片从旧格滑到新格，滑完再换回新页自己的 dock（两条 dock 一模一样，看不出换）。
/// 原来两页同时 0.2 s 交叉淡入淡出：玻璃（`UIVisualEffectView`）的透明度一不是 1 就画不对，新页的 dock 淡入到最后一下子「跳」成玻璃，
/// 两条 dock 叠着半透明，就是看到的闪。
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

    /// 第一次出现在屏幕上（弹出动画走完）时调一次：会话页用它弹新功能提示卡（`TellomiFeatureIntro`）。
    var onFirstAppear: ((TellomiAttachmentSheetController) -> Void)?
    private var hasAppeared = false

    init(photoPicker: TellomiPhotoPickerViewController, makePage: @escaping (Page) -> UIViewController?) {
        self.photoPicker = photoPicker
        self.makePage = makePage
        super.init(nibName: nil, bundle: nil)
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
        // 上一次换页还没走完（连着点了两格）：先让它立刻走完（旧页拿掉、dock 交接完），这次从那里接着走。
        // 不然点回刚淡出的那一页时，上一次淡出的收尾会把现在这页拿掉（白屏）。
        completeTransitionNow()
        let from: UIViewController = currentChild
        self.page = page
        if page != .files, page != .gallery {
            otherPage = to
        }
        // 旧页 dock 此刻在屏幕上的位置：要在 Sheet 展开之前记下（展开以后 Sheet 里的坐标就已经是展开后的了）
        let fromDockPlacement = animated ? DockPlacement(from) : nil
        // 新页放在旧页底下、不透明（不让新页里的玻璃跟着淡入）
        embed(to, below: from.view)
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
        to.view.layoutIfNeeded()
        let handoff = fromDockPlacement.flatMap { dockHandoff(from: $0, to: to) }
        let token = UUID()
        transitionToken = token
        transitionCleanup = {
            from.view.layer.removeAllAnimations()
            from.view.alpha = 1
            handoff?.restoreFromDock()
            finish()
        }
        UIView.animate(withDuration: Self.switchFadeDuration, delay: 0, options: [.curveEaseInOut], animations: {
            from.view.alpha = 0
        }, completion: { [weak self] _ in
            guard let self, self.transitionToken == token else { return }
            self.completeTransitionNow()
        })
    }

    /// 正在走的那次换页：收尾（旧页拿掉、旧页 dock 恢复）要做的事，和它的标记（淡出的完成回调只收自己那一次的尾）。
    private var transitionCleanup: (() -> Void)?
    private var transitionToken: UUID?

    private func completeTransitionNow() {
        finishDockHandoff()
        let cleanup = transitionCleanup
        transitionCleanup = nil
        transitionToken = nil
        cleanup?()
    }

    /// 换页时旧页淡出的时长（Telegram iOS：0.23 s）。
    static let switchFadeDuration: TimeInterval = 0.23

    /// 换页前旧页 dock 的样子：它在窗口上的位置、镜片在哪、选中哪格。旧页没有 dock 或 dock 正藏着（选图中、搜索中）就是 nil。
    private struct DockPlacement {
        let dock: TellomiAttachmentDock
        let frameInWindow: CGRect
        let lensFrame: CGRect

        init?(_ page: UIViewController) {
            guard let dock = (page as? TellomiAttachmentDockHosting)?.attachmentDock, let window = dock.window, !dock.isHidden else {
                return nil
            }
            self.dock = dock
            frameInWindow = dock.convert(dock.bounds, to: window)
            lensFrame = dock.currentLensFrame
        }
    }

    /// 换页期间盖在两页上面的临时 dock：镜片从旧页选中的格子滑到新页的格子，滑完换回新页自己的 dock。
    /// 新页没有 dock、或 dock 正藏着就不接手，只换内容。
    private func dockHandoff(from placement: DockPlacement, to: UIViewController) -> DockHandoff? {
        let fromDock = placement.dock
        guard
            let toDock = (to as? TellomiAttachmentDockHosting)?.attachmentDock,
            let window = view.window,
            !toDock.isHidden,
            fromDock.items == toDock.items
        else {
            return nil
        }
        let transitionDock = TellomiAttachmentDock(items: fromDock.items, selectedItem: fromDock.selectedItem)
        transitionDock.isUserInteractionEnabled = false
        // 放在窗口上：新页要展开 Sheet 时（位置、联系人、投票），Sheet 是从下面长上来的，贴着 Sheet 底边的 dock 会先掉出屏幕再滑回来
        // （录屏里约 3 帧看不到 dock）；窗口上的这条自己从旧位置走到新位置（iOS 26 半屏的 Sheet 离屏幕边有一圈空，全屏没有，两处差几 pt）。
        // 同 Telegram：tab 栏不在 Sheet 的内容里。
        let endFrame = toDock.convert(toDock.bounds, to: window)
        transitionDock.frame = placement.frameInWindow
        window.addSubview(transitionDock)
        transitionDock.layoutIfNeeded()
        transitionDock.placeLens(at: placement.lensFrame)
        fromDock.isHidden = true
        toDock.isHidden = true
        if endFrame != placement.frameInWindow {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
                transitionDock.frame = endFrame
                transitionDock.layoutIfNeeded()
            }
        }
        transitionDock.select(toDock.selectedItem, animated: true)
        self.transitionDock = transitionDock
        transitionDockTarget = toDock

        let handoff = DockHandoff(fromDock: fromDock)
        // 镜片滑完（弹簧 0.4 s）、Sheet 展开完（约 0.35 s）再换回新页的 dock
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak transitionDock] in
            guard let self, let transitionDock, self.transitionDock === transitionDock else { return }
            self.finishDockHandoff()
        }
        return handoff
    }

    /// 临时 dock 拿掉、新页自己的 dock 露出来（到点了，或者又换页了、Sheet 要收起了）。
    private func finishDockHandoff() {
        transitionDockTarget?.isHidden = false
        transitionDockTarget = nil
        transitionDock?.removeFromSuperview()
        transitionDock = nil
    }

    /// 临时 dock 在窗口上：Sheet 收起时不能留在聊天页上面。
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        finishDockHandoff()
    }

    private final class DockHandoff {
        private weak var fromDock: TellomiAttachmentDock?

        init(fromDock: TellomiAttachmentDock) {
            self.fromDock = fromDock
        }

        /// 旧页（相册、文件页会留着再用）的 dock 换完页恢复显示。
        func restoreFromDock() {
            fromDock?.isHidden = false
        }
    }

    private weak var transitionDock: TellomiAttachmentDock?
    /// 临时 dock 交接完要露出来的那条（新页自己的 dock）。
    private weak var transitionDockTarget: TellomiAttachmentDock?

    private var currentChild: UIViewController {
        switch page {
        case .gallery: return photoPicker
        case .files: return filesPage ?? photoPicker
        case .poll, .contact, .location: return otherPage ?? photoPicker
        }
    }

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
        // animateChanges 没有完成回调；Sheet 换档的动画约 0.3 秒
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak page] in
            page?.attachmentSheetDidExpand()
        }
    }

    private func embed(_ child: UIViewController, below sibling: UIView? = nil) {
        guard child.parent !== self else { return }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let sibling, sibling.superview === view {
            view.insertSubview(child.view, belowSubview: sibling)
        } else {
            view.addSubview(child.view)
        }
        child.didMove(toParent: self)
    }

    var visibleChildForTesting: UIViewController? { children.last }

    var transitionDockForTesting: TellomiAttachmentDock? { transitionDock }

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

/// Tellomi（2026-10-17）：带 dock 的页把 dock 交出来，换页时 Sheet 用它接手镜片动画（只读它的位置与选中项，换页期间藏起来）。
protocol TellomiAttachmentDockHosting: AnyObject {
    var attachmentDock: TellomiAttachmentDock? { get }
}

/// Tellomi（2026-10-16）：Sheet 里的页可以要求进来就展开到全屏。
protocol TellomiAttachmentSheetPage: AnyObject {
    var wantsExpandedSheet: Bool { get }
    /// Sheet 已经是全屏了（刚展开完，或者本来就是）。
    func attachmentSheetDidExpand()
}
