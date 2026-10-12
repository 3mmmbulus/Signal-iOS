//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
public import UIKit

extension UIWindow.Level {

    // Behind everything, especially the root window.
    public static let _background: UIWindow.Level = .init(rawValue: -1)

    fileprivate static let _returnToCall: UIWindow.Level = .init(rawValue: UIWindow.Level.statusBar.rawValue - 1)

    // In front of the root window, behind the screen blocking window.

    // In front of the root window, behind the screen blocking window.
    fileprivate static let _callView: UIWindow.Level = .init(rawValue: UIWindow.Level.normal.rawValue + 2)

    // In front of the root window, behind CallView. We deliberately sit behind
    // an ongoing call, which doesn't depend on the chat connection.
    fileprivate static let _clockSkewBlocking: UIWindow.Level = .init(rawValue: UIWindow.Level.normal.rawValue + 1)

    // In front of the status bar and CallView
    fileprivate static let _screenBlocking: UIWindow.Level = .init(rawValue: UIWindow.Level.statusBar.rawValue + 2)

    // Tellomi（tellomi/tellomi#1139）：「必须更新」在最前面，连应用锁也盖住（需求 3.4：未解锁也能先更新，
    // 阻断页不显示任何私人内容；Telegram iOS 的 .update 层同样排在 .passcode 之上）。
    fileprivate static let _updateRequiredBlocking: UIWindow.Level = .init(rawValue: UIWindow.Level.statusBar.rawValue + 3)
}

class WindowManager: TellomiUpdateRequiredBlockHost {

    init() {
        AssertIsOnMainThread()
    }

    func setupWithRootWindow(_ rootWindow: UIWindow, screenBlockingWindow: UIWindow) {
        AssertIsOnMainThread()
        owsAssertBeta(self.rootWindow == nil)
        owsAssertBeta(self.screenBlockingWindow == nil)

        self.rootWindow = rootWindow
        self.screenBlockingWindow = screenBlockingWindow

        ensureWindowState()
    }

    func isAppWindow(_ window: UIWindow) -> Bool {
        return switch window {
        case rootWindow: true
        case returnToCallWindow: true
        case callViewWindow: true
        case clockSkewBlockingWindow: true
        case crossBorderConsentWindow: true
        case screenBlockingWindow: true
        case updateRequiredBlockingWindow: true
        default: false
        }
    }

    var captchaWindow: UIWindow {
        return shouldShowCallView ? callViewWindow : rootWindow
    }

    /// Tellomi（tellomi/tellomi#1139）：为真时用「必须更新」阻断页盖住整个 App（由 `TellomiUpdateRequiredMonitoringManager` 设置）。
    var isUpdateRequiredBlockActive: Bool = false {
        didSet {
            AssertIsOnMainThread()
            guard isUpdateRequiredBlockActive != oldValue else { return }
            ensureWindowState()
            NotificationCenter.default.post(name: .tellomiUpdateRequiredBlockDidChange, object: nil)
        }
    }

    /// Tellomi：阻断页上确认了「暂不更新，只看聊天记录」（owner 2026-09-24 规则 1）。
    var updateRequiredViewChatsOnlyHandler: (@MainActor () -> Void)?

    /// Tellomi（tellomi/tellomi#1491）：阻断页上随更新清单变的原因、版本、「了解更新内容」和「立即更新」的去处。
    var updateRequiredPageInfo: TellomiUpdateRequiredPageInfo = .serverRejected {
        didSet {
            AssertIsOnMainThread()
            guard updateRequiredPageInfo != oldValue else { return }
            updateRequiredBlockingViewController.pageInfo = updateRequiredPageInfo
        }
    }

    var isScreenBlockActive: Bool = false {
        didSet {
            AssertIsOnMainThread()
            ensureWindowState()
        }
    }

    /// Whether the app should be blocked because the device's clock is skewed.
    var isClockSkewBlockActive: Bool = false {
        didSet {
            AssertIsOnMainThread()
            ensureWindowState()
        }
    }

    /// Tellomi：已注册但还没同意跨境（升级上来的老用户）时，跨境告知挡在所有界面前面（tellomi/tellomi#1133）。
    /// 同意之前网络本来就是关着的（`TellomiCrossBorderConsent`），这一层只负责让用户看到并作出选择。
    var isCrossBorderConsentBlockActive: Bool = false {
        didSet {
            AssertIsOnMainThread()
            ensureWindowState()
        }
    }

    func updateWindowFrames() {
        let desiredFrame = CurrentAppContext().frame
        for window in [rootWindow!, callViewWindow, clockSkewBlockingWindow, crossBorderConsentWindow, screenBlockingWindow!] {
            guard window.frame != desiredFrame else { continue }
            window.frame = desiredFrame
        }
        // Tellomi（tellomi/tellomi#1139）
        if updateRequiredBlockingWindow.frame != desiredFrame {
            updateRequiredBlockingWindow.frame = desiredFrame
        }
    }

    // MARK: Windows

    // UIWindow.Level.normal
    var rootWindow: UIWindow!

    // UIWindow.Level._returnToCall
    private lazy var returnToCallWindow: UIWindow = {
        AssertIsOnMainThread()
        guard let rootWindow else {
            owsFail("rootWindow is nil")
        }

        let window = OWSWindow(frame: rootWindow.bounds)
        window.windowLevel = ._returnToCall
        window.isHidden = true
        window.isOpaque = true
        window.clipsToBounds = true
        window.rootViewController = returnToCallViewController

        return window
    }()

    private lazy var returnToCallViewController = ReturnToCallViewController()

    // UIWindow.Level._callView
    lazy var callViewWindow: UIWindow = {
        AssertIsOnMainThread()
        guard let rootWindow else {
            owsFail("rootWindow is nil")
        }

        let window = OWSWindow(frame: rootWindow.bounds)
        window.windowLevel = ._callView
        window.isHidden = true
        window.isOpaque = true
        window.backgroundColor = .Signal.background
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = nil

        return window

    }()

    private func newCallNavigationController() -> UINavigationController {
        let viewController = WindowRootViewController()
        viewController.view.backgroundColor = Theme.launchScreenBackgroundColor

        // NOTE: Do not use OWSNavigationController for call window.
        // It adjusts the size of the navigation bar to reflect the
        // call window.  We don't want those adjustments made within
        // the call window itself.
        let navigationController = WindowRootNavigationViewController(rootViewController: viewController)
        navigationController.isNavigationBarHidden = true
        return navigationController
    }

    // UIWindow.Level._clockSkewBlocking
    private lazy var clockSkewBlockingWindow: UIWindow = {
        AssertIsOnMainThread()
        guard let rootWindow else {
            owsFail("rootWindow is nil")
        }

        let window = OWSWindow(frame: rootWindow.bounds)
        window.windowLevel = ._clockSkewBlocking
        window.isHidden = true
        window.isOpaque = true
        window.backgroundColor = Theme.launchScreenBackgroundColor
        window.rootViewController = ClockSkewAppBlockingViewController(
            onSubmitDebugLogs: { viewController in
                DebugLogs(dumper: .fromGlobals()).promptToSubmitLogs(
                    from: viewController,
                    supportTag: "ClockSkew",
                )
            },
        )

        return window
    }()

    // UIWindow.Level._clockSkewBlocking（两个挡板不会同时出现：没同意跨境就不联网，也就量不出时钟偏差）
    private lazy var crossBorderConsentWindow: UIWindow = {
        AssertIsOnMainThread()
        guard let rootWindow else {
            owsFail("rootWindow is nil")
        }

        let window = OWSWindow(frame: rootWindow.bounds)
        window.windowLevel = ._clockSkewBlocking
        window.isHidden = true
        window.isOpaque = true
        window.backgroundColor = Theme.launchScreenBackgroundColor
        window.rootViewController = Self.makeCrossBorderConsentBlockingViewController()
        return window
    }()

    /// Tellomi（tellomi/tellomi#1338）：已注册设备升级后的盖页 = 完整同意 + 最上面「《隐私政策》已更新至 2.0.0 版。」（需求第六节法务项 c）；
    /// 6.6 起是品牌底色空白盖页上的小弹窗，关不掉。
    /// 拆成静态方法，是为了用例能走这里真的接线（同 `makeUpdateRequiredBlockingViewController`）。
    static func makeCrossBorderConsentBlockingViewController() -> TellomiCrossBorderNoticeViewController {
        return TellomiCrossBorderNoticeViewController(mode: .consentAfterPolicyUpdate, onAgree: {})
    }

    // UIWindow.Level._background if inactive,
    // UIWindow.Level._screenBlocking() if active.
    private var screenBlockingWindow: UIWindow!

    // UIWindow.Level._updateRequiredBlocking（Tellomi，tellomi/tellomi#1139）
    private lazy var updateRequiredBlockingViewController = Self.makeUpdateRequiredBlockingViewController(host: self)

    /// 拆成静态方法，是为了用例能走这里真的接线（taishi 审查 b15 启用前置 2）。
    static func makeUpdateRequiredBlockingViewController(host: TellomiUpdateRequiredBlockHost) -> TellomiUpdateRequiredAppBlockingViewController {
        let viewController = TellomiUpdateRequiredAppBlockingViewController(
            openUpdatePage: { [weak host] in
                // 阻断页只在有我们自己的更新渠道时才会出现（TellomiUpdateRequiredMonitoringManager.hasUpdateChannel）：
                // 更新清单里验过签的 TestFlight 公开链接（只认 TestFlight / App Store 主机），或者 appStoreUrl 就是我们配的那条。
                // 不会把人送去装别的 App。
                UIApplication.shared.open(host?.updateRequiredPageInfo.updateUrl ?? TSConstants.appStoreUrl)
            },
            openNotes: { url in
                UIApplication.shared.open(url)
            },
            viewChatsOnly: { [weak host] in
                host?.updateRequiredViewChatsOnlyHandler?()
            },
        )
        viewController.pageInfo = host.updateRequiredPageInfo
        return viewController
    }

    private lazy var updateRequiredBlockingWindow: UIWindow = {
        AssertIsOnMainThread()
        guard let rootWindow else {
            owsFail("rootWindow is nil")
        }

        let window = OWSWindow(frame: rootWindow.bounds)
        window.windowLevel = ._updateRequiredBlocking
        window.isHidden = true
        window.isOpaque = true
        window.backgroundColor = Theme.launchScreenBackgroundColor
        window.rootViewController = updateRequiredBlockingViewController

        return window
    }()

    // MARK: Window State

    private func ensureWindowState() {
        AssertIsOnMainThread()

        // To avoid bad frames, we never want to hide the blocking window, so we manipulate
        // its window level to "hide" it behind other windows.  The other windows have fixed
        // window level and are shown/hidden as necessary.
        //
        // Note that we always "hide" before we "show".

        // Tellomi（tellomi/tellomi#1139）：「必须更新」照上游两个阻断窗口（应用锁、时钟偏差）的写法，先把根窗口和通话窗口藏起来，
        // 免得会话列表在下面继续显示、被旁白读到（taishi 审查 b15 要改 2）。锁窗口照旧按 isScreenBlockActive 处理，
        // 所以选了「只看聊天记录」、收起阻断页以后，锁上着就先看到应用锁。
        // 通话中先不盖（上游的时钟偏差页也排在通话后面），挂断后 ensureWindowState 会再盖上。
        if isUpdateRequiredBlockActive, !hasCall {
            if isScreenBlockActive {
                ensureScreenBlockWindowShown()
            } else {
                ensureScreenBlockWindowHidden()
            }
            ensureRootWindowHidden()
            ensureReturnToCallWindowHidden()
            ensureCallViewWindowHidden()
            ensureClockSkewBlockWindowHidden()
            ensureUpdateRequiredBlockWindowShown()
            return
        }
        ensureUpdateRequiredBlockWindowHidden()

        if isScreenBlockActive {
            ensureScreenBlockWindowShown()
            ensureRootWindowHidden()
            ensureReturnToCallWindowHidden()
            ensureCallViewWindowHidden()
            ensureClockSkewBlockWindowHidden()
            ensureCrossBorderConsentWindowHidden()
        }
        // Show Call View
        else if shouldShowCallView, callViewController != nil {
            ensureCallViewWindowShown()
            ensureRootWindowHidden()
            ensureReturnToCallWindowHidden()
            ensureScreenBlockWindowHidden()
            ensureClockSkewBlockWindowHidden()
            ensureCrossBorderConsentWindowHidden()
        }
        // Tellomi: Show Cross-Border Consent Block (tellomi/tellomi#1133)
        else if isCrossBorderConsentBlockActive {
            ensureCrossBorderConsentWindowShown()
            ensureRootWindowHidden()
            ensureReturnToCallWindowHidden()
            ensureCallViewWindowHidden()
            ensureScreenBlockWindowHidden()
            ensureClockSkewBlockWindowHidden()
        }
        // Show Clock Skew Block
        else if isClockSkewBlockActive {
            ensureClockSkewBlockWindowShown()
            ensureRootWindowHidden()
            ensureReturnToCallWindowHidden()
            ensureCallViewWindowHidden()
            ensureScreenBlockWindowHidden()
            ensureCrossBorderConsentWindowHidden()
        }
        // Show Root Window
        else {
            ensureRootWindowShown()
            ensureScreenBlockWindowHidden()
            ensureClockSkewBlockWindowHidden()
            ensureCrossBorderConsentWindowHidden()

            // Add "Return to Call" banner
            if callViewController != nil {
                ensureReturnToCallWindowShown()
            } else {
                ensureReturnToCallWindowHidden()
            }

            ensureCallViewWindowHidden()
        }
    }

    private func ensureUpdateRequiredBlockWindowShown() {
        AssertIsOnMainThread()

        if updateRequiredBlockingWindow.isHidden {
            Logger.info("showing update required window.")
        }

        updateRequiredBlockingWindow.makeKeyAndVisible()
    }

    private func ensureUpdateRequiredBlockWindowHidden() {
        AssertIsOnMainThread()

        guard !updateRequiredBlockingWindow.isHidden else { return }

        Logger.info("hiding update required window.")
        updateRequiredBlockingWindow.isHidden = true
    }

    private func ensureRootWindowShown() {
        AssertIsOnMainThread()

        if rootWindow.isHidden {
            Logger.info("showing root window.")
        }

        // By calling makeKeyAndVisible we ensure the rootViewController becomes first responder.
        // In the normal case, that means the SignalViewController will call `becomeFirstResponder`
        // on the vc on top of its navigation stack.
        if !rootWindow.isKeyWindow || rootWindow.isHidden {
            rootWindow.makeKeyAndVisible()
        }

        workAroundRotationIssue(rootWindow)
    }

    private func ensureRootWindowHidden() {
        AssertIsOnMainThread()

        guard !rootWindow.isHidden else { return }

        Logger.info("hiding root window.")
        rootWindow.isHidden = true
    }

    private func ensureReturnToCallWindowShown() {
        AssertIsOnMainThread()

        guard returnToCallWindow.isHidden else { return }

        guard let callViewController else {
            owsFailBeta("callViewController is nil")
            return
        }

        Logger.info("showing 'return to call' window.")
        returnToCallWindow.isHidden = false
        returnToCallViewController.displayForCallViewController(callViewController)
    }

    private func ensureReturnToCallWindowHidden() {
        AssertIsOnMainThread()

        guard !returnToCallWindow.isHidden else { return }

        Logger.info("hiding 'return to call' window.")
        returnToCallWindow.isHidden = true
    }

    private func ensureCallViewWindowShown() {
        AssertIsOnMainThread()

        if callViewWindow.isHidden {
            Logger.info("showing call window.")
        }

        callViewWindow.makeKeyAndVisible()
    }

    private func ensureCallViewWindowHidden() {
        AssertIsOnMainThread()

        guard !callViewWindow.isHidden else { return }

        Logger.info("hiding call window.")
        callViewWindow.isHidden = true
    }

    private func ensureClockSkewBlockWindowShown() {
        AssertIsOnMainThread()

        if clockSkewBlockingWindow.isHidden {
            Logger.info("showing clock skew window.")
        }

        clockSkewBlockingWindow.makeKeyAndVisible()
    }

    private func ensureClockSkewBlockWindowHidden() {
        AssertIsOnMainThread()

        guard !clockSkewBlockingWindow.isHidden else { return }

        Logger.info("hiding clock skew window.")
        clockSkewBlockingWindow.isHidden = true
    }

    private func ensureCrossBorderConsentWindowShown() {
        AssertIsOnMainThread()

        if crossBorderConsentWindow.isHidden {
            Logger.info("showing cross-border consent window.")
        }

        crossBorderConsentWindow.makeKeyAndVisible()
    }

    private func ensureCrossBorderConsentWindowHidden() {
        AssertIsOnMainThread()

        guard !crossBorderConsentWindow.isHidden else { return }

        Logger.info("hiding cross-border consent window.")
        crossBorderConsentWindow.isHidden = true
    }

    private func ensureScreenBlockWindowShown() {
        AssertIsOnMainThread()

        if screenBlockingWindow.windowLevel != ._screenBlocking {
            Logger.info("showing block window.")
        }

        screenBlockingWindow.windowLevel = ._screenBlocking
        screenBlockingWindow.makeKeyAndVisible()
    }

    private func ensureScreenBlockWindowHidden() {
        AssertIsOnMainThread()

        guard screenBlockingWindow.windowLevel != ._background else { return }

        Logger.info("hiding block window.")

        // Never hide the blocking window (that can lead to bad frames).
        // Instead, manipulate its window level to move it in front of
        // or behind the root window.
        screenBlockingWindow.windowLevel = ._background
    }

    // MARK: Calls

    var shouldShowCallView: Bool = false

    var hasCall: Bool {
        AssertIsOnMainThread()
        return callViewController != nil
    }

    private var callViewController: CallViewControllerWindowReference?

    func startCall<T: UIViewController & CallViewControllerWindowReference>(viewController: T) {
        AssertIsOnMainThread()
        Logger.info("startCall")

        callViewController = viewController

        // Attach callViewController to window.
        let callNavigationController = self.newCallNavigationController()
        self.callViewWindow.rootViewController = callNavigationController
        callNavigationController.pushViewController(viewController, animated: false)

        shouldShowCallView = true

        // CallViewController only supports portrait for iPhones, but if we're _already_ landscape it won't
        // automatically switch.
        if !UIDevice.current.isIPad {
            UIDevice.current.ows_setOrientation(.portrait)
        }

        ensureWindowState()
    }

    func endCall<T: UIViewController & CallViewControllerWindowReference>(viewController: T) {
        AssertIsOnMainThread()

        guard callViewController === viewController else {
            Logger.warn("Ignoring end call request from obsolete call view controller.")
            return
        }

        callViewWindow.rootViewController = nil
        callViewController = nil

        shouldShowCallView = false

        ensureWindowState()
    }

    /// Minimizes the current call (or exits if it's not yet started).
    @MainActor
    func minimizeCallIfNeeded() {
        callViewController?.minimizeIfNeeded()
    }

    func leaveCallView() {
        AssertIsOnMainThread()

        guard let callViewController else {
            owsFailBeta("callViewController == nil")
            return
        }
        owsAssertBeta(shouldShowCallView)

        callViewController.willMoveToPip(pipWindow: returnToCallWindow)

        shouldShowCallView = false
        ensureWindowState()
    }

    func returnToCallView() {
        AssertIsOnMainThread()

        guard let callViewController else {
            return
        }

        guard !shouldShowCallView else {
            ensureWindowState()
            return
        }

        shouldShowCallView = true

        returnToCallViewController.resignCall()
        callViewController.returnFromPip(pipWindow: returnToCallWindow)

        ensureWindowState()
    }

    var isCallInPip: Bool {
        return returnToCallViewController.isCallInPip
    }
}

// This VC can become first responder
// when presented to ensure that the input accessory is updated.
private class WindowRootViewController: UIViewController {

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.defaultSupportedOrientations
    }
}

private class WindowRootNavigationViewController: UINavigationController {

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.defaultSupportedOrientations
    }
}

private func workAroundRotationIssue(_ window: UIWindow) {
    // ### Symptom
    //
    // The app can get into a degraded state where the main window will incorrectly remain locked in
    // portrait mode. Worse yet, the status bar and input window will continue to rotate with respect
    // to the device orientation. So once you're in this degraded state, the status bar and input
    // window can be in landscape while simultaneoulsy the view controller behind them is in portrait.
    //
    // ### To Reproduce
    //
    // On an iPhone6 (not reproducible on an iPhoneX)
    //
    // 0. Ensure "screen protection" is enabled (not necessarily screen lock)
    // 1. Enter Conversation View Controller
    // 2. Pop Keyboard
    // 3. Begin dismissing keyboard with one finger, but stopping when it's about 50% dismissed,
    //    keep your finger there with the keyboard partially dismissed.
    // 4. With your other hand, hit the home button to leave Signal.
    // 5. Re-enter Signal
    // 6. Rotate to landscape
    //
    // Expected: Conversation View, Input Toolbar window, and Settings Bar should all rotate to landscape.
    // Actual: The input toolbar and the settings toolbar rotate to landscape, but the Conversation
    //         View remains in portrait, this looks super broken.
    //
    // ### Background
    //
    // Some debugging shows that the `ConversationViewController.view.window.isInterfaceAutorotationDisabled`
    // is true. This is a private property, whose function we don't exactly know, but it seems like
    // `interfaceAutorotation` is disabled when certain transition animations begin, and then
    // re-enabled once the animation completes.
    //
    // My best guess is that autorotation is intended to be disabled for the duration of the
    // interactive-keyboard-dismiss-transition, so when we start the interactive dismiss, autorotation
    // has been disabled, but because we hide the main app window in the middle of the transition,
    // autorotation doesn't have a chance to be re-enabled.
    //
    // ## So, The Fix
    //
    // If we find ourself in a situation where autorotation is disabled while showing the rootWindow,
    // we re-enable autorotation.

    // let encodedSelectorString1 = "isInterfaceAutorotationDisabled".encodedForSelector
    let encodedSelectorString1 = "egVaAAZ2BHdydHZSBwYBBAEGcgZ6AQBVegVyc312dQ=="
    guard let selectorString1 = encodedSelectorString1.decodedForSelector else {
        owsFailDebug("selectorString1 was unexpectedly nil")
        return
    }
    let selector1 = NSSelectorFromString(selectorString1)

    guard window.responds(to: selector1) else {
        owsFailDebug("failure: doesn't respond to selector1")
        return
    }
    let imp1 = window.method(for: selector1)
    typealias Selector1MethodType = @convention(c) (UIWindow, Selector) -> Bool
    let func1: Selector1MethodType = unsafeBitCast(imp1, to: Selector1MethodType.self)
    let isDisabled = func1(window, selector1)

    guard isDisabled else {
        return
    }

    Logger.info("autorotation is disabled.")

    // The remainder of this method calls:
    //   [[UIScrollToDismissSupport supportForScreen:window.screen] finishScrollViewTransition]
    // after verifying the methods/classes exist.

    // let encodedKlassString = "UIScrollToDismissSupport".encodedForSelector
    let encodedKlassString = "ZlpkdAQBfX1lAVV6BX56BQVkBwICAQQG"
    guard let klassString = encodedKlassString.decodedForSelector else {
        owsFailDebug("klassString was unexpectedly nil")
        return
    }
    guard let klass = NSClassFromString(klassString) else {
        owsFailDebug("klass was unexpectedly nil")
        return
    }

    // let encodedSelector2String = "supportForScreen:".encodedForSelector
    let encodedSelector2String = "BQcCAgEEBlcBBGR0BHZ2AEs="
    guard let selector2String = encodedSelector2String.decodedForSelector else {
        owsFailDebug("selector2String was unexpectedly nil")
        return
    }
    let selector2 = NSSelectorFromString(selector2String)
    guard klass.responds(to: selector2) else {
        owsFailDebug("klass didn't respond to selector")
        return
    }
    let imp2 = klass.method(for: selector2)
    typealias Selector2MethodType = @convention(c) (AnyClass, Selector, UIScreen) -> AnyObject?
    let func2: Selector2MethodType = unsafeBitCast(imp2, to: Selector2MethodType.self)
    guard let dismissSupport = func2(klass, selector2, window.screen) else {
        owsFailDebug("selector2String call unexpectedly returned nil")
        return
    }

    // let encodedSelector3String = "finishScrollViewTransition".encodedForSelector
    let encodedSelector3String = "d3oAegV5ZHQEAX19Z3p2CWUEcgAFegZ6AQA="
    guard let selector3String = encodedSelector3String.decodedForSelector else {
        owsFailDebug("selector3String was unexpectedly nil")
        return
    }
    let selector3 = NSSelectorFromString(selector3String)
    guard dismissSupport.responds(to: selector3) else {
        owsFailDebug("dismissSupport didn't respond to selector")
        return
    }
    let imp3 = dismissSupport.method(for: selector3)
    typealias Selector3MethodType = @convention(c) (AnyObject, Selector) -> Void
    let func3: Selector3MethodType = unsafeBitCast(imp3, to: Selector3MethodType.self)
    func3(dismissSupport, selector3)

    Logger.info("finished scrollView transition")
}

// MARK: - Tellomi

/// 已注册但还没同意跨境时挡住整个 App（tellomi/tellomi#1133）。未注册的人在要连服务端的那一页单独问：
/// - 号码页「下一步」（发号码之前）；
/// - 欢迎页「恢复或转移账户」和 iPad 的「切换到关联」；
/// - 关联设备的二维码页 `ProvisioningQRCodeViewController`：iPad 未注册启动、`.relinking`、号码页菜单「关联此设备」都到这一页；
///   关联设备的两处（iPad「切换到关联」和这一页）出的是只读版（tellomi/tellomi#1338，需求第六节 ④）；
/// - 快速恢复 / 转移的二维码页 `BaseQuickRestoreQRCodeViewController`：iPad 转移选择页「转移」，以及注册流程续跑到扫码那一步。
/// provisioning socket 是 libsignal 直连、不经过两道闸，`ProvisioningSocketManager.openNewProvisioningSocket()` 另有一道闸兜底。
class TellomiCrossBorderConsentMonitoringManager {
    private let windowManager: WindowManager

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    func start() {
        AssertIsOnMainThread()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(update),
            name: TellomiCrossBorderConsent.didChangeNotification,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(update),
            name: .registrationStateDidChange,
            object: nil,
        )

        update()
    }

    @objc
    private func update() {
        AssertIsOnMainThread()

        let isRegistered = DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered
        windowManager.isCrossBorderConsentBlockActive = isRegistered && !TellomiCrossBorderConsent.hasAgreed
    }
}
