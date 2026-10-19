//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

extension FeedMinorSession {
    /// 单测 / 截图用：换掉 App 级的那一份。
    static var overrideForTesting: FeedMinorSession?
    private static var sharedInstance: FeedMinorSession?
    private static var sharedTicker: FeedMinorTicker?

    /// App 级的那一份（`TellomiFeed.isMinorTimeEnabled` 关着时是 nil：不计时、不锁）。第一次用到时建，带上 15 秒的计时器和前后台通知。
    static var current: FeedMinorSession? {
        if let overrideForTesting { return overrideForTesting }
        guard TellomiFeed.isMinorTimeEnabled else { return nil }
        if let sharedInstance { return sharedInstance }
        let session = FeedMinorSession(gate: FeedMinorGate(memory: StoredFeedMinorModeMemory(), usage: StoredFeedMinorUsage()))
        sharedTicker = FeedMinorTicker(session: session)
        sharedInstance = session
        return session
    }
}

/// `FeedMinorSession` 的 15 秒计时器和前后台通知。
@MainActor
final class FeedMinorTicker: NSObject {
    private weak var session: FeedMinorSession?
    private var timer: Timer?

    init(session: FeedMinorSession) {
        self.session = session
        super.init()
        session.onTickingChanged = { [weak self] ticking in self?.setTicking(ticking) }
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: .OWSApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: .OWSApplicationWillEnterForeground, object: nil)
        setTicking(session.isTicking)
    }

    private(set) var isTimerRunning = false

    private func setTicking(_ ticking: Bool) {
        timer?.invalidate()
        timer = nil
        isTimerRunning = ticking
        guard ticking else { return }
        let timer = Timer(timeInterval: TimeInterval(FeedMinorTime.tickMillis) / 1000, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.session?.timerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc
    private func didEnterBackground() {
        session?.didEnterBackground()
    }

    @objc
    private func willEnterForeground() {
        session?.willEnterForeground()
    }
}

/// 每个动态页面都装一个（`install(in:)`，放在 `viewDidLoad` 最后）：
/// - 页面出现 / 消失告诉 `FeedMinorSession`（计时就看有没有动态页面在屏幕上）；这是一个子控制器，出现和消失跟着宿主页走。
/// - 锁着时盖上提示页（夜间 / 当日用满）并禁用导航栏上的按钮（返回键照常），解锁后拿掉。
/// 所以通知推送、链接、搜索直接打开的详情和从动态标签点进去的一样，都过同一个检查。
@MainActor
final class FeedMinorLockController: UIViewController {
    let session: FeedMinorSession
    let lockView = FeedMinorLockView()
    private var observation: FeedMinorObservation?
    /// 锁变了，宿主还想做点自己的事（动态标签：藏发布按钮、停曝光）。
    var onLockChanged: ((FeedMinorTime.Lock?) -> Void)?
    /// 「返回聊天」做什么（单测里换掉）。
    var returnToChats: @MainActor (UIViewController) -> Void = { FeedMinorLockController.returnToChats(from: $0) }

    init(session: FeedMinorSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        observation = session.observe { [weak self] lock in self?.apply(lock) }
        lockView.onReturnToChats = { [weak self] in
            guard let self, let host = self.parent else { return }
            self.returnToChats(host)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 装到一个动态页面上。时限关着（`session` 是 nil）就什么也不装。
    @discardableResult
    static func install(in host: UIViewController, session: FeedMinorSession? = FeedMinorSession.current) -> FeedMinorLockController? {
        guard let session else { return nil }
        let controller = FeedMinorLockController(session: session)
        host.addChild(controller)
        host.view.addSubview(controller.view)
        controller.view.autoPinEdgesToSuperviewEdges()
        controller.didMove(toParent: host)
        controller.apply(session.lock)
        return controller
    }

    override func loadView() {
        view = lockView
    }

    var isLocked: Bool { !lockView.isHidden }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.screenWillAppear(self)
        apply(session.lock)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.screenDidDisappear(self)
    }

    func apply(_ lock: FeedMinorTime.Lock?) {
        let locked = lock != nil
        if let lock { lockView.apply(lock) }
        lockView.isHidden = !locked
        if let host = parent {
            host.view.bringSubviewToFront(view)
            for sibling in host.view.subviews where sibling !== view {
                sibling.accessibilityElementsHidden = locked
            }
            let items = (host.navigationItem.leftBarButtonItems ?? []) + (host.navigationItem.rightBarButtonItems ?? [])
            for item in items {
                item.isEnabled = !locked
            }
        }
        onLockChanged?(lock)
    }

    /// 「返回聊天」：弹出来的动态页面先关掉，然后切到聊天标签，动态标签退回列表（下次进来还是盖着的）。
    static func returnToChats(from host: UIViewController) {
        let container = host.navigationController ?? host
        let home = findHome(host.view.window?.rootViewController)
        let finish = {
            home?.selectedHomeTab = .chatList
            home?.feedNavController.popToRootViewController(animated: false)
        }
        if let presenting = container.presentingViewController {
            presenting.dismiss(animated: true, completion: finish)
        } else {
            finish()
        }
    }

    private static func findHome(_ controller: UIViewController?) -> HomeTabBarController? {
        guard let controller else { return nil }
        if let home = controller as? HomeTabBarController { return home }
        for child in controller.children {
            if let home = findHome(child) { return home }
        }
        return findHome(controller.presentedViewController)
    }
}
