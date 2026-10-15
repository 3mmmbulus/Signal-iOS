//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

protocol TellomiAttachmentPollPageDelegate: AnyObject {
    /// dock 里点了「投票」以外的格子。
    func pollPage(_ page: TellomiAttachmentPollPage, didSelectDockItem item: TellomiAttachmentDockItem)
}

/// Tellomi（2026-10-16，owner 发来的《附件面板里位置 / 投票 / 联系人在面板内换页》方案第 3.2 节）：附件 Sheet 里的「投票」页。
///
/// 照 Telegram iOS：`ChatControllerOpenAttachmentMenu` 的 `requestController` 把 `.poll` 的页面换进附件菜单，
/// 底部 tab 一直在、键盘出来时收起；✕ / 发完收起整个菜单。投票的内容沿用上游 `NewPollViewController2`
/// （自己的导航栏：标题、关闭、发送），它不再自己 dismiss，而是交给 [NewPollViewController2.onClose]——
/// 嵌在容器里时子控制器的 dismiss 转给谁 UIKit 没有保证，不赖它。
final class TellomiAttachmentPollPage: UIViewController, TellomiAttachmentSheetPage {

    weak var delegate: TellomiAttachmentPollPageDelegate?

    let poll: NewPollViewController2
    private let navigation: OWSNavigationController
    private let dock: TellomiAttachmentDock?

    init(poll: NewPollViewController2, dockItems: [TellomiAttachmentDockItem]) {
        self.poll = poll
        self.navigation = OWSNavigationController(rootViewController: poll)
        self.dock = dockItems.isEmpty ? nil : TellomiAttachmentDock(items: dockItems, selectedItem: .poll)
        super.init(nibName: nil, bundle: nil)
        poll.autoFocusesQuestion = false
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
            dock.onSelect = { [weak self] item in self?.didSelectDockItem(item) }
            dock.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(dock)
            NSLayoutConstraint.activate([
                dock.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: TellomiAttachmentDock.sideMargin),
                dock.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -TellomiAttachmentDock.sideMargin),
                dock.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -TellomiAttachmentDock.bottomMargin),
                dock.heightAnchor.constraint(equalToConstant: TellomiAttachmentDock.height),
            ])
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        setDockVisible(dock != nil)
    }

    // MARK: - TellomiAttachmentSheetPage

    var wantsExpandedSheet: Bool { true }

    func attachmentSheetDidExpand() {
        poll.loadViewIfNeeded()
        poll.focusQuestion()
    }

    // MARK: - Dock

    /// dock 在时把投票页的安全区往上让出 dock 的高度（表格自己按安全区留底），最后一行不会压在 dock 下面；键盘出来时 dock 收起、不让。
    private func setDockVisible(_ visible: Bool) {
        guard let dock else { return }
        dock.isHidden = !visible
        navigation.additionalSafeAreaInsets.bottom = visible ? TellomiAttachmentDock.height + TellomiAttachmentDock.bottomMargin : 0
    }

    var isDockShownForTesting: Bool { dock.map { !$0.isHidden } ?? false }

    @objc
    private func keyboardWillShow() {
        setDockVisible(false)
    }

    @objc
    private func keyboardWillHide() {
        setDockVisible(true)
    }

    private func didSelectDockItem(_ item: TellomiAttachmentDockItem) {
        guard item != .poll else {
            // 重复点「投票」：展开到全屏（同另外两页）
            if let sheet = sheetPresentationController ?? parent?.sheetPresentationController, sheet.selectedDetentIdentifier != .large {
                sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
            }
            return
        }
        poll.view.endEditing(true)
        delegate?.pollPage(self, didSelectDockItem: item)
    }

    func selectDockItemForTesting(_ item: TellomiAttachmentDockItem) {
        didSelectDockItem(item)
    }
}
