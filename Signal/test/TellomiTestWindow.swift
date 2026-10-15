//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

extension UIWindow {
    /// 测试里用的窗口：挂到测试宿主的场景上。
    ///
    /// 应用改用 UIScene 之后（Signal-iOS#207），没挂在场景上的窗口（`UIWindow(frame:)`）不上屏：截图是白的，
    /// 在它上面 present 不出来，键盘也不弹。拿不到场景时（不该发生）退回老写法。
    /// 场景会一直留着挂在它上面的窗口，所以每个测试结束时由 `TellomiTestWindowJanitor` 把这些窗口摘下来。
    @MainActor
    static func tellomiTestWindow(frame: CGRect) -> UIWindow {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return UIWindow(frame: frame)
        }
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        TellomiTestWindowJanitor.shared.track(window)
        return window
    }

    /// 把这个测试开过的测试窗口都摘下来。`SignalBaseTest.tearDown` 在拆掉测试环境**之前**调：摘窗口时 UIKit 会把还没跑完的
    /// 动画收尾（比如吸管收起的弹簧动画），收尾里会读 `DependenciesBridge`，环境拆了再摘就崩（2026-10-15 实测）。
    @MainActor
    static func tellomiDetachTestWindows() {
        TellomiTestWindowJanitor.shared.detachAll()
    }
}

/// 场景留着挂在它上面的窗口（隐藏了也留着）：上一个测试的窗口和它里面的东西（比如还在播的视频）会活到下一个测试，
/// 在测试环境已经拆掉之后触发回调（2026-10-15 实测：`AlbumViewerScreenshotTests` 播完视频，下一个测试里
/// `SSKEnvironment.shared` 为 nil 崩掉）。每个测试结束时把它们隐藏、拿掉根控制器、从场景上摘下来（`SignalBaseTest` 在 `tearDown` 拆环境之前摘，
/// 别的测试类在测试结束时摘）——和以前没挂场景的窗口随测试一起释放是一样的效果。
@MainActor
private final class TellomiTestWindowJanitor: NSObject, XCTestObservation {

    static let shared: TellomiTestWindowJanitor = {
        let janitor = TellomiTestWindowJanitor()
        XCTestObservationCenter.shared.addTestObserver(janitor)
        return janitor
    }()

    private var windows: [UIWindow] = []

    func track(_ window: UIWindow) {
        windows.append(window)
    }

    func detachAll() {
        guard !windows.isEmpty else { return }
        var controllers: [WeakController] = []
        autoreleasepool {
            for window in windows {
                var controller = window.rootViewController
                while let current = controller {
                    controllers.append(WeakController(current))
                    controller = current.presentedViewController
                }
                window.isHidden = true
                window.rootViewController = nil
                window.windowScene = nil
            }
            windows.removeAll()
        }
        // 控制器释放时还会用到测试环境（比如 `MediaGallery.deinit` 读 `SSKEnvironment`），播放器的收尾又是异步的：
        // 在这里转主循环，等这些控制器真的放掉（最多 2 秒），再让 `tearDown` 拆环境。
        let deadline = Date(timeIntervalSinceNow: 2)
        repeat {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        } while controllers.contains(where: { $0.controller != nil }) && Date() < deadline
    }

    private struct WeakController {
        weak var controller: UIViewController?

        init(_ controller: UIViewController) {
            self.controller = controller
        }
    }

    /// 兜底：不是 `SignalBaseTest` 的测试类（不拆环境）也在测试结束时摘掉。
    nonisolated func testCaseDidFinish(_ testCase: XCTestCase) {
        MainActor.assumeIsolated {
            detachAll()
        }
    }
}
