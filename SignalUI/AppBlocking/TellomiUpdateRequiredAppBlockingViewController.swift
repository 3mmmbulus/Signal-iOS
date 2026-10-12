//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit

/// Tellomi（tellomi/tellomi#1139，需求 app-update-and-version-policy 第 3.4 节）：「必须更新」阻断页。
///
/// 服务端对本版本回 499（或远程配置宣布到期）时整页盖住 App：主按钮「立即更新」，下面始终有「暂不更新，只看聊天记录」。
/// owner 2026-09-24 定：聊天记录只在这台手机上，任何情况下都不能把人锁在外面。选了只看记录，就回到上游的做法：
/// 会话列表顶上挂「已过期」提示、输入框换成「更新」，能看历史、不能收发。
///
/// 页面上没有任何私人内容，所以窗口放在应用锁之上（见 `WindowManager`）；从这里进只读要先过应用锁。
/// 什么时候盖由 `TellomiUpdateRequiredMonitoringManager` 决定：本机构建到期、没有可用的更新渠道时都不盖。
public class TellomiUpdateRequiredAppBlockingViewController: AppBlockingViewController {

    private let openUpdatePage: @MainActor () -> Void
    private let openNotes: @MainActor (URL) -> Void
    private let viewChatsOnly: @MainActor () -> Void

    /// 随更新清单变的原因、版本和「了解更新内容」（tellomi/tellomi#1491）；`TellomiUpdateRequiredMonitoringManager` 每次判断时更新。
    public var pageInfo: TellomiUpdateRequiredPageInfo = .serverRejected {
        didSet {
            guard pageInfo != oldValue else { return }
            subtitle = Self.subtitle(for: pageInfo)
            learnMoreButton.isHidden = pageInfo.notesUrl == nil
        }
    }

    public init(
        openUpdatePage: @escaping @MainActor () -> Void,
        openNotes: @escaping @MainActor (URL) -> Void,
        viewChatsOnly: @escaping @MainActor () -> Void,
    ) {
        self.openUpdatePage = openUpdatePage
        self.openNotes = openNotes
        self.viewChatsOnly = viewChatsOnly

        // 这几条只写了 4 种语言。iOS 找不到键时不回落英文、直接显示键名，所以都带英文 value（taishi 审查 b15 不阻塞 1）。
        super.init(
            headerImage: UIImage(named: "signal-logo-128")!.withRenderingMode(.alwaysTemplate),
            title: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_TITLE",
                value: "Update Tellomi to continue",
                comment: "Tellomi: Title of the full-screen page shown when this version of the app can no longer be used and must be updated.",
            ),
            subtitle: Self.subtitle(for: .serverRejected),
        )
    }

    /// 原因（按更新清单写的 `requiredReason`，需求 3.4）→ 更新不影响聊天记录 → 新版本号（清单给了时）。
    public static func subtitle(for pageInfo: TellomiUpdateRequiredPageInfo) -> String {
        let reasonText: String
        switch pageInfo.reason {
        case .security:
            reasonText = OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_REASON_SECURITY",
                value: "This version has a security problem. To protect your account and messages, update to keep using Tellomi.",
                comment: "Tellomi: On the 'update required' page, why the app must be updated: this version has a security problem.",
            )
        case .other:
            reasonText = OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_REASON_OTHER",
                value: "This version needs an update to keep sending and receiving messages.",
                comment: "Tellomi: On the 'update required' page, why the app must be updated, when the reason is neither security nor the server protocol.",
            )
        case .protocolChange, nil:
            reasonText = OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_REASON_SERVER_REJECTED",
                value: "This version can no longer communicate with the server. Update to keep sending and receiving messages.",
                comment: "Tellomi: On the 'update required' page, why the app must be updated: the server no longer accepts this version.",
            )
        }
        let chatsKept = OWSLocalizedString(
            "APP_EXPIRED_TELLOMI_BLOCKING_CHATS_KEPT",
            value: "Updating keeps all the chats on this phone.",
            comment: "Tellomi: On the 'update required' page, reassurance that updating keeps the chats on this phone.",
        )
        var text = reasonText + "\n\n" + chatsKept
        if let newVersion = pageInfo.newVersion {
            let format = OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_NEW_VERSION",
                value: "Version %@",
                comment: "Tellomi: On the 'update required' page, the version the update installs. Embeds {{ version number, e.g. 0.1.5 }}.",
            )
            text += "\n\n" + String(format: format, newVersion)
        }
        return text
    }

    // MARK: - Views

    public private(set) lazy var updateButton: UIButton = {
        let button = UIButton(
            configuration: .largePrimary(title: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_UPDATE_BUTTON",
                value: "Update now",
                comment: "Tellomi: The main button on the 'update required' page. Opens the page where the new version can be installed.",
            )),
        )
        // 和上游 ClockSkewAppBlockingViewController 一样，从 @objc 方法（MainActor）里调外面给的回调。
        button.addTarget(self, action: #selector(didTapUpdate), for: .primaryActionTriggered)
        button.accessibilityIdentifier = "tellomi.updateRequired.updateButton"
        return button
    }()

    /// 「了解更新内容」（需求 3.4 布局里主按钮下面的次级文字链）：更新清单给了地址才显示。
    public private(set) lazy var learnMoreButton: UIButton = {
        let button = UIButton(
            configuration: .mediumBorderless(title: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_LEARN_MORE",
                value: "What's in this update",
                comment: "Tellomi: Text button on the 'update required' page. Opens the release notes on our website.",
            )),
        )
        button.addTarget(self, action: #selector(didTapLearnMore), for: .primaryActionTriggered)
        button.accessibilityIdentifier = "tellomi.updateRequired.learnMoreButton"
        button.isHidden = true
        return button
    }()

    public private(set) lazy var viewChatsOnlyButton: UIButton = {
        let button = UIButton(
            configuration: .mediumBorderless(title: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_VIEW_CHATS_ONLY_BUTTON",
                value: "Not now, just view my chats",
                comment: "Tellomi: Secondary button on the 'update required' page. Leaves the page without updating; the app then only shows the chat history and can't send or receive.",
            )),
        )
        button.addTarget(self, action: #selector(didTapViewChatsOnly), for: .primaryActionTriggered)
        button.accessibilityIdentifier = "tellomi.updateRequired.viewChatsOnlyButton"
        return button
    }()

    @objc
    private func didTapUpdate() {
        openUpdatePage()
    }

    @objc
    private func didTapLearnMore() {
        guard let notesUrl = pageInfo.notesUrl else { return }
        openNotes(notesUrl)
    }

    /// 先说清后果再放行，和 Android 上游「不要更新」的确认框同一个意思。
    @objc
    private func didTapViewChatsOnly() {
        let actionSheet = ActionSheetController(
            title: nil,
            message: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_VIEW_CHATS_ONLY_CONFIRM_MESSAGE",
                value: "You can view your chat history, but you won't be able to send or receive messages until you update.",
                comment: "Tellomi: Confirmation shown after tapping 'Not now, just view my chats' on the 'update required' page.",
            ),
        )
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString(
                "APP_EXPIRED_TELLOMI_BLOCKING_VIEW_CHATS_ONLY_CONFIRM",
                value: "Don't Update",
                comment: "Tellomi: Button in the confirmation after tapping 'Not now, just view my chats'. Leaves the 'update required' page without updating.",
            ),
            handler: { [weak self] _ in
                self?.confirmViewChatsOnly()
            },
        ))
        actionSheet.addAction(OWSActionSheets.cancelAction)
        presentActionSheet(actionSheet)
    }

    /// 确认框里点了「不更新」。单独拆出来，用例才能从页面这一步接起（`ActionSheetAction` 的 handler 在外面拿不到）。
    func confirmViewChatsOnly() {
        viewChatsOnly()
    }

    // MARK: - Lifecycle

    override public func viewDidLoad() {
        super.viewDidLoad()

        // 下面的窗口（没上锁时的会话列表）不能被旁白读到、点到（taishi 审查 b15 要改 2）。
        view.accessibilityViewIsModal = true

        // 上游 AppBlockingViewController 的标、标题、说明（一个 UIStackView）不在滚动视图里。最大字号下放不下时说明被压扁、
        // 后面几行直接裁掉（375×667、AX5 实测：两段说明只剩 94pt，「更新不会影响聊天记录」看不到；taishi 审查 b15 不阻塞 4）。
        // 把它和两个按钮一起挪进滚动视图：放得下时仍是内容在按钮上方的剩余空间里居中、按钮贴底；放不下时整页一起滚。
        guard let contentStack = view.subviews.first(where: { $0 is UIStackView }) else {
            owsFailDebug("AppBlockingViewController no longer has its content stack")
            return
        }
        contentStack.removeFromSuperview()

        let scrollView = UIScrollView()
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        let page = UIView()
        scrollView.addSubview(page)
        // 三个按钮叠在一起：「了解更新内容」没有时（isHidden）不占地方
        let buttonStack = UIStackView(arrangedSubviews: [updateButton, learnMoreButton, viewChatsOnlyButton])
        buttonStack.axis = .vertical
        buttonStack.spacing = 8
        for subview in [contentStack, buttonStack] {
            page.addSubview(subview)
        }

        // 内容居中用的区域：页面顶边留 40（同上游的边距），到「立即更新」上方 24。
        let contentArea = UILayoutGuide()
        page.addLayoutGuide(contentArea)

        let pageFillsTheScreen = page.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        pageFillsTheScreen.priority = .defaultLow
        let contentCentered = contentStack.centerYAnchor.constraint(equalTo: contentArea.centerYAnchor)
        contentCentered.priority = .defaultHigh

        for subview in [scrollView, page, contentStack, buttonStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            page.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            page.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            page.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            page.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
            pageFillsTheScreen,

            contentArea.topAnchor.constraint(equalTo: page.topAnchor, constant: 40),
            contentArea.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -24),

            contentStack.topAnchor.constraint(greaterThanOrEqualTo: contentArea.topAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentArea.bottomAnchor),
            contentCentered,
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: 40),
            contentStack.centerXAnchor.constraint(equalTo: page.centerXAnchor),

            buttonStack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 40),
            buttonStack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -40),
            buttonStack.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -16),
        ])
    }
}

// MARK: -

#if DEBUG

@available(iOS 17, *)
#Preview {
    TellomiUpdateRequiredAppBlockingViewController(openUpdatePage: {}, openNotes: { _ in }, viewChatsOnly: {})
}

@available(iOS 17, *)
#Preview("Manifest: security") {
    let viewController = TellomiUpdateRequiredAppBlockingViewController(openUpdatePage: {}, openNotes: { _ in }, viewChatsOnly: {})
    viewController.pageInfo = TellomiUpdateRequiredPageInfo(
        reason: .security,
        newVersion: "0.1.1",
        notesUrl: URL(string: "https://www.tellomi.app/changelog/#ios"),
        updateUrl: URL(string: "https://testflight.apple.com/join/AbCdEfGh"),
    )
    return viewController
}

#endif

/// 阻断页上随更新清单变的几样（tellomi/tellomi#1491，需求 app-update-and-version-policy §3.4）。
public struct TellomiUpdateRequiredPageInfo: Equatable {
    /// 更新清单此刻判「必须」时写的原因；不是清单要求的（服务端 499）为 nil，显示「无法与服务器通信」那一句。
    public var reason: TellomiUpdateManifest.RequiredReason?
    /// 清单里比现在新的最新版版本号。
    public var newVersion: String?
    /// 「了解更新内容」：官网更新日志。
    public var notesUrl: URL?
    /// 「立即更新」去哪：清单里的 TestFlight 公开链接（验过签、只认 TestFlight / App Store 主机）；nil = 官网下载页。
    public var updateUrl: URL?

    public init(reason: TellomiUpdateManifest.RequiredReason?, newVersion: String?, notesUrl: URL?, updateUrl: URL?) {
        self.reason = reason
        self.newVersion = newVersion
        self.notesUrl = notesUrl
        self.updateUrl = updateUrl
    }

    /// 还没有更新清单：服务端 499 的那一句，没有版本、没有链接。
    public static let serverRejected = TellomiUpdateRequiredPageInfo(reason: nil, newVersion: nil, notesUrl: nil, updateUrl: nil)
}
