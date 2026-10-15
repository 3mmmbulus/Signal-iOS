//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（`docs/product/specs/whats-new-cards.md`，owner 2026-10-16 发来的文案）：新功能提示卡。
///
/// - 第一次进入对应界面时弹一次底部卡片（标题、每条「图标 + 一句话」、「知道了」），可以下滑划走。
/// - 一次只弹一张：触发界面给出候选，按顺序弹第一张该弹的（附件面板默认就是选图网格，先弹「附件面板」，下次打开再弹「选图」）。
/// - 弹出来就记已读（划走、点按钮都算），记在本机 `KeyValueStore`，换机不同步。
/// - 新装用户不弹：只给在这张卡出来之前注册的人（[introducedAt]），之后注册的人一开始看到的就是新样子。
///   用账号自己记的注册时间判断（`TSAccountManager.registrationDate`），不用另在启动时打标记。
enum TellomiFeatureIntro: String, CaseIterable {
    /// 卡 1：新版附件面板（位置、投票、联系人在面板里换页）。
    case attachmentSheet = "attachment_sheet_v2"
    /// 卡 2：选图更方便（序号、长按定时、发送前编辑）。
    case photoPicker = "photo_picker_v2"
    /// 卡 3：转发给多个聊天。
    case forwardGrid = "forward_grid_v1"

    /// 这张卡管谁：在这之前注册的老用户。三张都是 2026-10-17 00:00（北京时间）——随这一版发出去。
    var introducedAt: Date {
        switch self {
        case .attachmentSheet, .photoPicker, .forwardGrid:
            return Date(timeIntervalSince1970: 1_792_166_400)
        }
    }

    private static let store = KeyValueStore(collection: "TellomiFeatureIntro")

    /// 该不该弹：没读过，并且是在这张卡出来之前注册的。还没注册（拿不到注册时间）的不弹。纯函数，便于单测。
    static func shouldShow(_ intro: TellomiFeatureIntro, registrationDate: Date?, hasSeen: Bool) -> Bool {
        guard !hasSeen, let registrationDate else { return false }
        return registrationDate < intro.introducedAt
    }

    static func hasSeen(_ intro: TellomiFeatureIntro, tx: DBReadTransaction) -> Bool {
        store.getBool(intro.rawValue, defaultValue: false, transaction: tx)
    }

    static func markSeen(_ intro: TellomiFeatureIntro, tx: DBWriteTransaction) {
        store.setBool(true, key: intro.rawValue, transaction: tx)
    }

    /// 触发界面调：[candidates] 里第一张该弹的弹出来，弹出即记已读。上面已经盖着别的页面时不弹（下次再说）。返回弹了哪张。
    @MainActor
    @discardableResult
    static func presentFirstDue(_ candidates: [TellomiFeatureIntro], from presenter: UIViewController) -> TellomiFeatureIntro? {
        guard SSKEnvironment.hasShared else { return nil }
        let registrationDate = SSKEnvironment.shared.databaseStorageRef.read { tx in
            DependenciesBridge.shared.tsAccountManager.registrationDate(tx: tx)
        }
        return presentFirstDue(candidates, from: presenter, registrationDate: registrationDate)
    }

    /// 同上，注册时间由调用方给（单测用）。
    @MainActor
    @discardableResult
    static func presentFirstDue(
        _ candidates: [TellomiFeatureIntro],
        from presenter: UIViewController,
        registrationDate: Date?,
    ) -> TellomiFeatureIntro? {
        guard SSKEnvironment.hasShared, presenter.presentedViewController == nil, presenter.viewIfLoaded?.window != nil else { return nil }
        let databaseStorage = SSKEnvironment.shared.databaseStorageRef
        let due: TellomiFeatureIntro? = databaseStorage.read { tx in
            candidates.first { shouldShow($0, registrationDate: registrationDate, hasSeen: hasSeen($0, tx: tx)) }
        }
        guard let due else { return nil }
        databaseStorage.write { tx in markSeen(due, tx: tx) }
        presenter.present(due.makeSheet(), animated: true)
        return due
    }

    // MARK: - 卡片

    struct Content {
        let symbol: String
        let title: String
        let items: [(symbol: String, text: String)]
    }

    var content: Content {
        switch self {
        case .attachmentSheet:
            return Content(
                symbol: "plus.circle",
                title: OWSLocalizedString("TELLOMI_INTRO_ATTACHMENT_SHEET_V2_TITLE", comment: "Title of the one-time card introducing the new attachment panel (opened with '+' in a chat)."),
                items: [
                    ("photo.on.rectangle", OWSLocalizedString("TELLOMI_INTRO_ATTACHMENT_SHEET_V2_ITEM_1", comment: "One-time card about the new attachment panel, line 1: photos and files are pages of the same panel.")),
                    ("mappin.and.ellipse", OWSLocalizedString("TELLOMI_INTRO_ATTACHMENT_SHEET_V2_ITEM_2", comment: "One-time card about the new attachment panel, line 2: location, polls and contacts are done inside the panel.")),
                ],
            )
        case .photoPicker:
            return Content(
                symbol: "photo",
                title: OWSLocalizedString("TELLOMI_INTRO_PHOTO_PICKER_V2_TITLE", comment: "Title of the one-time card introducing the improved photo picker."),
                items: [
                    ("number.circle", OWSLocalizedString("TELLOMI_INTRO_PHOTO_PICKER_V2_ITEM_1", comment: "One-time photo picker card, line 1: selected photos show their order number and are sent in that order.")),
                    ("clock", OWSLocalizedString("TELLOMI_INTRO_PHOTO_PICKER_V2_ITEM_2", comment: "One-time photo picker card, line 2: long-press the send button to schedule the message.")),
                    ("slider.horizontal.3", OWSLocalizedString("TELLOMI_INTRO_PHOTO_PICKER_V2_ITEM_3", comment: "One-time photo picker card, line 3: crop, draw and adjust photos before sending.")),
                ],
            )
        case .forwardGrid:
            return Content(
                symbol: "arrowshape.turn.up.right",
                title: OWSLocalizedString("TELLOMI_INTRO_FORWARD_GRID_V1_TITLE", comment: "Title of the one-time card introducing the forward picker with avatars."),
                items: [
                    ("person.2", OWSLocalizedString("TELLOMI_INTRO_FORWARD_GRID_V1_ITEM_1", comment: "One-time forward picker card: pick several chats at once, shown as avatars.")),
                ],
            )
        }
    }

    func makeSheet() -> HeroSheetViewController {
        let content = self.content
        return HeroSheetViewController(
            hero: .circleIcon(
                icon: Self.symbolImage(content.symbol, side: 32),
                iconSize: 32,
                tintColor: .Signal.accent,
                backgroundColor: UIColor.Signal.accent.withAlphaComponent(0.12),
            ),
            title: content.title,
            body: HeroSheetViewController.Body(font: .dynamicTypeBody, [
                .bullets(content.items.map { item in
                    HeroSheetViewController.Body.BulletPoint(icon: Self.symbolImage(item.symbol, side: 24), text: item.text)
                }),
            ]),
            primary: .button(HeroSheetViewController.Button(
                title: OWSLocalizedString("TELLOMI_INTRO_GOT_IT", comment: "The only button on the one-time 'what's new' cards. Closes the card."),
                action: .dismiss,
            )),
            secondary: nil,
        )
    }

    /// 卡片把图标放进正方形框里（上游 `HeroSheetViewController` 定死 24 / 32 见方、拉伸填满）；SF Symbol 多半不是正方形，
    /// 先按比例画进正方形透明底，免得被拉宽、压扁。保持 template，颜色跟着卡片的 tint。
    static func symbolImage(_ name: String, side: CGFloat) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: side, weight: .regular)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else {
            owsFailDebug("missing SF Symbol \(name)")
            return UIImage()
        }
        let canvas = CGSize(width: side, height: side)
        let scale = min(1, side / max(symbol.size.width, symbol.size.height))
        let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let origin = CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2)
        return UIGraphicsImageRenderer(size: canvas).image { _ in
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: origin, size: size))
        }.withRenderingMode(.alwaysTemplate)
    }
}
