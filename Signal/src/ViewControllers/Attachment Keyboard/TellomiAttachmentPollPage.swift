//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

protocol TellomiAttachmentNavigationPageDelegate: AnyObject {
    /// dock 里点了这一页以外的格子。
    func navigationPage(_ page: TellomiAttachmentNavigationPage, didSelectDockItem item: TellomiAttachmentDockItem)
}

/// Tellomi（2026-10-16，owner 发来的《附件面板里位置 / 投票 / 联系人在面板内换页》方案第 3 节）：附件 Sheet 里由上游页面
/// 充当内容的一页（投票、联系人）——上游页面放在自己的导航栈里（标题、关闭、发送照旧），底部是和另外两页同一位置的 dock。
///
/// 照 Telegram iOS：`ChatControllerOpenAttachmentMenu` 的 `requestController` 把这些页面换进附件菜单，底部 tab 一直在、
/// 键盘出来时收起；进来展开到全屏；✕ / 发完收起整个菜单（由页面自己的回调交给会话页，不赖子控制器的 dismiss）。
class TellomiAttachmentNavigationPage: UIViewController, TellomiAttachmentSheetPage, TellomiAttachmentDockClient {

    weak var delegate: TellomiAttachmentNavigationPageDelegate?

    let navigation: OWSNavigationController
    private let dockItem: TellomiAttachmentDockItem
    private let dockItems: [TellomiAttachmentDockItem]
    /// 在附件 Sheet 里时用 Sheet 那一条共用的 dock（2026-10-17 第二版）；单独打开时自己建一条。
    private var dock: TellomiAttachmentDock? { sharedAttachmentDock ?? ownDock }
    private lazy var ownDock: TellomiAttachmentDock? = {
        guard sharedAttachmentDock == nil, !dockItems.isEmpty else { return nil }
        return TellomiAttachmentDock(items: dockItems, selectedItem: dockItem)
    }()
    private var isKeyboardShown = false

    /// 这一页要用到、但没人持有的对象（例如上游页面的代理适配对象，上游只弱引用它）。
    var retainedObjects: [AnyObject] = []

    init(root: UIViewController, dockItem: TellomiAttachmentDockItem, dockItems: [TellomiAttachmentDockItem]) {
        self.navigation = OWSNavigationController(rootViewController: root)
        self.dockItem = dockItem
        self.dockItems = dockItems
        super.init(nibName: nil, bundle: nil)
        // 上游页面的搜索栏（位置、联系人）放在导航栏里：iOS 26 默认会挪到底部工具栏，正好压在 dock 下面。
        if #available(iOS 16, *) {
            root.navigationItem.preferredSearchBarPlacement = .stacked
        }
        if #available(iOS 26, *) {
            root.navigationItem.searchBarPlacementAllowsToolbarIntegration = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.groupedBackground

        addChild(navigation)
        navigation.view.frame = view.bounds
        navigation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigation.view)
        navigation.didMove(toParent: self)

        if let dock {
            if sharedAttachmentDock == nil {
                dock.onSelect = { [weak self] item in self?.didSelectDockItem(item) }
                dock.install(in: view)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        setDockVisible(dock != nil)
    }

    // MARK: - TellomiAttachmentSheetPage

    var wantsExpandedSheet: Bool { true }

    func attachmentSheetDidExpand() {}

    // MARK: - Dock

    /// dock 在时把导航栈的安全区往上让出 dock 的高度（表格自己按安全区留底），最后一行不会压在 dock 下面；键盘出来时 dock 收起、不让。
    private func setDockVisible(_ visible: Bool) {
        guard let dock else { return }
        // 只有当前页能动 dock（Sheet 里共用的那一条；换页后这页淡出时收到的键盘通知不许再动它）
        if isActiveAttachmentPage {
            dock.isHidden = !visible
        }
        navigation.additionalSafeAreaInsets.bottom = visible ? TellomiAttachmentDock.height + TellomiAttachmentDock.bottomMargin : 0
    }

    var isDockShownForTesting: Bool { dock.map { !$0.isHidden } ?? false }

    // MARK: TellomiAttachmentDockClient

    var sharedAttachmentDock: TellomiAttachmentDock?
    var isActiveAttachmentPage = true
    var attachmentDockItem: TellomiAttachmentDockItem { dockItem }
    var wantsAttachmentDock: Bool { !isKeyboardShown }

    func attachmentDockDidSelect(_ item: TellomiAttachmentDockItem) {
        didSelectDockItem(item)
    }

    @objc
    private func keyboardWillShow() {
        isKeyboardShown = true
        setDockVisible(false)
    }

    @objc
    private func keyboardWillHide() {
        isKeyboardShown = false
        setDockVisible(true)
    }

    private func didSelectDockItem(_ item: TellomiAttachmentDockItem) {
        guard item != dockItem else {
            // 重复点当前格：展开到全屏（同另外两页）
            if let sheet = sheetPresentationController ?? parent?.sheetPresentationController, sheet.selectedDetentIdentifier != .large {
                sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
            }
            return
        }
        navigation.view.endEditing(true)
        delegate?.navigationPage(self, didSelectDockItem: item)
    }

    func selectDockItemForTesting(_ item: TellomiAttachmentDockItem) {
        didSelectDockItem(item)
    }
}

/// 「投票」页：上游 `NewPollViewController2`，不在出现时就抢焦点，等 Sheet 展开完再弹键盘（半屏的 Sheet 会被键盘顶成一条）。
final class TellomiAttachmentPollPage: TellomiAttachmentNavigationPage {

    let poll: NewPollViewController2

    init(poll: NewPollViewController2, dockItems: [TellomiAttachmentDockItem]) {
        self.poll = poll
        super.init(root: poll, dockItem: .poll, dockItems: dockItems)
        poll.autoFocusesQuestion = false
    }

    override func attachmentSheetDidExpand() {
        poll.loadViewIfNeeded()
        poll.focusQuestion()
    }
}
