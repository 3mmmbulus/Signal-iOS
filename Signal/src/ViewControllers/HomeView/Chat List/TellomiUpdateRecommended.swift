//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1491 第二刀，需求 app-update-and-version-policy.md §3.4「推荐更新」、判据 3）：推荐更新的几处界面共用的东西。
enum TellomiUpdateOffersUI {

    /// 「立即更新」：清单里的 TestFlight 公开链接（验过签、只认 TestFlight / App Store 主机）；还没有链接时去官网下载页。
    @MainActor
    static func openUpdate(_ offer: TellomiUpdateManifests.Offer?) {
        UIApplication.shared.open(offer?.updateUrl ?? TSConstants.appStoreUrl)
    }

    static func title(_ offer: TellomiUpdateManifests.Offer) -> String {
        let format = OWSLocalizedString(
            "TELLOMI_UPDATE_AVAILABLE_TITLE",
            value: "Tellomi %@ is available",
            comment: "Tellomi: title of the card shown once on the chat list, the chat list reminder and the About row when a newer version is available. Embeds {{ version number, e.g. 0.1.5 }}.",
        )
        return String(format: format, offer.version)
    }
}

/// 进首页后弹一次的底部卡片：「Tellomi x 可用」+「更新不会影响手机上的聊天记录。了解更新内容」+「立即更新」/「以后再说」。
/// 同一个版本只弹一次（弹出去就记下，见 `ChatListFYISheetCoordinator`），可以下滑关掉；关掉以后会话列表顶部还有一条提示。
///
/// Telegram reference（只看机制，一行没搬）：iOS `TelegramUpdateUI/Sources/UpdateInfoController.swift` 非强制时带「跳过」；
/// Android 官网版 `UpdateAppAlertDialog` 同一版本只弹一次（`LaunchActivity.checkAppUpdate` 比 `pendingAppUpdate.version`）。
///
/// 不加 `final`：截图测试要换成按真实屏幕算最大高度的子类（`TestAppContext` 的 frame 只有 300×400）。
class TellomiUpdateRecommendedSheet: HeroSheetViewController {

    init(offer: TellomiUpdateManifests.Offer) {
        super.init(
            hero: .image(UIImage(named: "signal-logo-128")!.withRenderingMode(.alwaysTemplate), tintColor: .Signal.label, height: 64),
            title: TellomiUpdateOffersUI.title(offer),
            body: Body([.text(Self.bodyText(notesUrl: offer.notesUrl))]),
            primary: .button(HeroSheetViewController.Button(
                title: OWSLocalizedString(
                    "APP_EXPIRED_TELLOMI_BLOCKING_UPDATE_BUTTON",
                    value: "Update now",
                    comment: "Tellomi: The main button on the 'update required' page. Opens the page where the new version can be installed.",
                ),
                action: { sheet in
                    sheet.dismiss(animated: true) {
                        TellomiUpdateOffersUI.openUpdate(offer)
                    }
                },
            )),
            secondary: .button(HeroSheetViewController.Button(
                title: OWSLocalizedString(
                    "TELLOMI_UPDATE_AVAILABLE_LATER",
                    value: "Later",
                    comment: "Tellomi: secondary button on the card shown when a newer version is available. Closes the card.",
                ),
                style: .secondary,
                action: .dismiss,
            )),
        )
    }

    /// 清单带了更新说明的地址，正文下一行是「了解更新内容」链接（需求 §3.2.1：说明正文在官网更新日志，推荐卡片链过去），
    /// 点了在卡片上面打开网页；没有地址就只有那一句。链接单独一行：中文句号后面不留空格。
    static func bodyText(notesUrl: URL?) -> Body.TextContent {
        let chatsKept = OWSLocalizedString(
            "APP_EXPIRED_TELLOMI_BLOCKING_CHATS_KEPT",
            value: "Updating keeps all the chats on this phone.",
            comment: "Tellomi: On the 'update required' page, reassurance that updating keeps the chats on this phone.",
        )
        guard let notesUrl else {
            return .plain(chatsKept)
        }
        let learnMore = OWSLocalizedString(
            "APP_EXPIRED_TELLOMI_BLOCKING_LEARN_MORE",
            value: "What's in this update",
            comment: "Tellomi: Text button on the 'update required' page. Opens the release notes on our website.",
        )
        return .attributed(
            NSAttributedString.composed(of: [
                chatsKept,
                "\n",
                learnMore.styled(with: .link(notesUrl)),
            ]).styled(with: .font(.dynamicTypeSubheadline)),
        )
    }
}
