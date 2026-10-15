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
        let from: UIViewController = currentChild
        self.page = page
        if page != .files, page != .gallery {
            otherPage = to
        }
        embed(to)
        expandIfWanted(to, animated: animated)
        to.view.alpha = animated ? 0 : 1
        let finish = {
            from.willMove(toParent: nil)
            from.view.removeFromSuperview()
            from.removeFromParent()
        }
        guard animated else {
            finish()
            return
        }
        UIView.animate(withDuration: 0.2, animations: {
            to.view.alpha = 1
            from.view.alpha = 0
        }, completion: { _ in
            from.view.alpha = 1
            finish()
        })
    }

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

    private func embed(_ child: UIViewController) {
        guard child.parent !== self else { return }
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }

    var visibleChildForTesting: UIViewController? { children.last }

    /// dock 的哪一格是 Sheet 里的页（在同一个 Sheet 里换）；不是的（位置、联系人、GIF）返回 nil。
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

/// Tellomi（2026-10-16）：Sheet 里的页可以要求进来就展开到全屏。
protocol TellomiAttachmentSheetPage: AnyObject {
    var wantsExpandedSheet: Bool { get }
    /// Sheet 已经是全屏了（刚展开完，或者本来就是）。
    func attachmentSheetDidExpand()
}
