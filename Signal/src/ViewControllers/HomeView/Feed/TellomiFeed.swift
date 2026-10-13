//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// M11 动态（ADR-0071、`docs/product/specs/dynamic-feed.md`、tellomi/tellomi#1355）的总开关。
///
/// 客户端不做任何区域判断（ADR-0071 §十五）：显不显示入口只看服务端下发的 `global.feed.enabled`。
/// 内部用户可以在「Internal → Tellomi Feed → Force feed tab」里先打开，方便在服务端下发之前开发和内测。
/// 和 Android 的 `TellomiFeed`（tellomi/Signal-Android#180）同口径。
enum TellomiFeed {

    static var isTabEnabled: Bool {
        return isTabEnabled(
            remoteEnabled: RemoteConfig.current.isTellomiFeedEnabled,
            forcedByInternalUser: isForcedByInternalUser,
        )
    }

    /// 纯函数版本，单测用。
    static func isTabEnabled(remoteEnabled: Bool, forcedByInternalUser: Bool) -> Bool {
        return remoteEnabled || forcedByInternalUser
    }

    private static let forceTabKey = "TellomiFeed.forceFeedTab"

    /// 内部设置里的「Force feed tab」。只有内部构建认这个值（正式包里永远是 false）。
    /// 存在本机 UserDefaults：只是开发开关，不进备份、不跨设备。
    static var isForcedByInternalUser: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: forceTabKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: forceTabKey)
            NotificationCenter.default.post(name: .tellomiFeedTabStateDidChange, object: nil)
        }
    }

    /// 内部用户强制打开动态标签时，信息流用本机样例，不连内容引擎。内容引擎接上之后改成单独的开关。
    static var isSampleDataEnabled: Bool {
        return isForcedByInternalUser
    }
}

extension Notification.Name {
    /// 「动态」标签该不该显示可能变了（内部开关切换）。远程配置的变化在回到前台时重新判断。
    static let tellomiFeedTabStateDidChange = Notification.Name("TellomiFeedTabStateDidChange")
}
