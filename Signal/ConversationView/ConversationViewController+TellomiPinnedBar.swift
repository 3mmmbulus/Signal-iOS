//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（pinned-messages.md 3.4 / 3.6）：会话顶上的置顶栏照两端 Telegram（规则在 `TellomiPinnedBar`），与安卓 `ConversationFragment` 一致：
/// - 置顶按消息在会话里的先后排；显示的那条跟着滚动走（屏幕上最新那条消息之前最新的一条置顶）。点一下跳到这条，再换成更早的一条，
///   定住到用户自己把它滚走；
/// - 右边：多条时是置顶列表，只有一条时是 ×——能取消置顶就问一句再取消（5 秒内能撤销），不能就只在本机藏起置顶栏，直到有新的置顶；
/// - 长按打开置顶列表（菜单只有 Telegram iOS 有，安卓没有，按「两端都有才做」不做）。
extension ConversationViewController {

    static let tellomiUnpinUndoSeconds = 5

    /// 置顶栏上的置顶：最早的在前；取消了、在等「撤销」或正在发的已经不在栏上。
    var tellomiPinnedBarPins: [TSMessage] {
        threadViewModel.pinnedMessages
            .filter { !viewState.tellomiHeldUnpins.contains($0.uniqueId) }
            .sorted { $0.sortId < $1.sortId }
    }

    /// 同上，顺手放掉已经发出去、置顶也真没了的那几条（再被置顶时要回到栏上）。
    func tellomiPrunedPinnedBarPins() -> [TSMessage] {
        let pinned = Set(threadViewModel.pinnedMessages.map(\.uniqueId))
        viewState.tellomiHeldUnpins = viewState.tellomiHeldUnpins.filter {
            viewState.tellomiUndoableUnpins.contains($0) || pinned.contains($0)
        }
        return tellomiPinnedBarPins
    }

    /// 屏幕上最新那条消息的位置；还没有（第一批消息还没上屏）就当在最底下。上游也只在上屏以后才读可见的行。
    private var tellomiNewestVisibleSortId: UInt64 {
        guard hasAppearedAndHasAppliedFirstLoad else {
            return .max
        }
        let sortId = lastVisibleSortId
        return sortId == 0 ? .max : sortId
    }

    /// 现在该显示第几条：点过以后定住的那条（还在的话），不然跟着屏幕走。
    func tellomiShownPinIndex(_ pins: [TSMessage]) -> Int {
        if
            let forced = viewState.tellomiForcedPinUniqueId,
            let index = pins.firstIndex(where: { $0.uniqueId == forced })
        {
            return index
        }
        return TellomiPinnedBar.pinFor(pins.map(\.sortId), newestVisible: tellomiNewestVisibleSortId)
    }

    /// 滚动、消息上屏、会话页出现时调：置顶栏换到和屏幕上的消息对应的那条；用户自己拖动时放开点过定住的那条。
    func tellomiTrackPinnedBar() {
        guard hasAppearedAndHasAppliedFirstLoad else {
            return
        }
        let pins = tellomiPinnedBarPins
        guard pins.count > 1 else {
            return
        }
        let newest = tellomiNewestVisibleSortId
        if
            let forced = viewState.tellomiForcedPinUniqueId,
            let forcedPin = pins.first(where: { $0.uniqueId == forced }),
            TellomiPinnedBar.releasesForcedPin(
                userDragging: isUserScrolling || isWaitingForDeceleration,
                newestVisibleBefore: viewState.tellomiPinnedBarNewestVisible,
                newestVisibleNow: newest,
                forcedPinPosition: forcedPin.sortId,
            )
        {
            viewState.tellomiForcedPinUniqueId = nil
        }
        viewState.tellomiPinnedBarNewestVisible = newest

        let index = tellomiShownPinIndex(pins)
        if index != pinnedMessageIndex {
            pinnedMessageIndex = index
            animateToNextPinnedMessage()
        }
    }

    func tellomiPinnedBarTitle(index: Int, count: Int) -> String {
        switch TellomiPinnedBar.title(index, count: count) {
        case .pinned:
            return OWSLocalizedString(
                "TELLOMI_PINNED_BAR_PINNED_MESSAGE",
                comment: "Tellomi (pinned-messages.md 3.4): title of the pinned bar at the top of a chat for the only pin, or the newest of several.",
            )
        case .previous:
            return OWSLocalizedString(
                "TELLOMI_PINNED_BAR_PREVIOUS_MESSAGE",
                comment: "Tellomi (pinned-messages.md 3.4): title of the pinned bar when it shows the older of two pins.",
            )
        case .numbered(let number):
            return String(
                format: OWSLocalizedString(
                    "TELLOMI_PINNED_BAR_PINNED_MESSAGE_N",
                    comment: "Tellomi (pinned-messages.md 3.4): title of the pinned bar for an older pin when there are three or more; #1 is the oldest. Embeds {{ number }}.",
                ),
                OWSFormat.formatInt(number),
            )
        }
    }

    /// 能不能取消这条置顶（ADR-0081 §4.3）：仅为我置顶的随时能；别的要置顶权限且群还在。
    func tellomiCanUnpin(_ message: TSMessage) -> Bool {
        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            let isPinnedForMe = message.sqliteRowId.map { TellomiPinsForMe.isPinnedForMe(interactionId: $0, tx: tx) } ?? false
            let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
            return TellomiPinChoice.canUnpin(
                isPinnedForMe: isPinnedForMe,
                canPinForEveryone: localAci.map { thread.canUserEditPinnedMessages(aci: $0, tx: tx) } ?? false,
                isTerminatedGroup: thread.isTerminatedGroup,
            )
        }
    }

    /// 本机藏起了置顶栏、而且之后没有更新的置顶。
    func tellomiIsPinnedBarHidden(newestPin: TSMessage) -> Bool {
        guard let rowId = newestPin.sqliteRowId else {
            return false
        }
        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiPinnedBar.isHidden(threadUniqueId: thread.uniqueId, newestPinRowId: rowId, tx: tx)
        }
    }

    /// 只有一条置顶时右边的 ×：能取消置顶就问一句再取消；不能就只在本机藏起置顶栏，直到有新的置顶（两端 Telegram 同样）。
    func tellomiClosePinnedBar() {
        guard let pin = tellomiPinnedBarPins.last else {
            return
        }
        guard tellomiCanUnpin(pin) else {
            guard let rowId = pin.sqliteRowId else {
                return
            }
            SSKEnvironment.shared.databaseStorageRef.write { tx in
                TellomiPinnedBar.hide(threadUniqueId: thread.uniqueId, newestPinRowId: rowId, tx: tx)
            }
            ensureBannerState()
            return
        }

        let actionSheet = ActionSheetController(
            title: nil,
            message: OWSLocalizedString(
                "TELLOMI_PINNED_BAR_UNPIN_QUESTION",
                comment: "Tellomi (pinned-messages.md 3.4): asked after tapping × on the pinned bar when you may unpin the message.",
            ),
        )
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString(
                "TELLOMI_PINNED_BAR_UNPIN",
                comment: "Tellomi (pinned-messages.md 3.4): button that unpins the message, in the sheet after tapping × on the pinned bar.",
            ),
            handler: { [weak self] _ in
                self?.tellomiUnpinWithUndo(pin)
            },
        ))
        actionSheet.addAction(OWSActionSheets.cancelAction)
        presentActionSheet(actionSheet)
    }

    /// 取消置顶，带「已取消置顶 · 撤销」5 秒；没撤销才发出去（两端 Telegram 都这样延后发）。这 5 秒里离开会话也照样发：等的时候拿着会话页。
    /// 与安卓 `ConversationFragment.tellomiUnpinWithUndo` 一致。
    func tellomiUnpinWithUndo(_ message: TSMessage) {
        let uniqueId = message.uniqueId
        guard viewState.tellomiHeldUnpins.insert(uniqueId).inserted else {
            return
        }
        viewState.tellomiUndoableUnpins.insert(uniqueId)
        ensureBannerState()

        let toast = ToastController(text: OWSLocalizedString(
            "TELLOMI_PINNED_BAR_UNPINNED",
            comment: "Tellomi (pinned-messages.md 3.6): toast after unpinning a message. Has an Undo button for 5 seconds.",
        ))
        toast.tellomiAction = (
            title: OWSLocalizedString(
                "TELLOMI_PINNED_BAR_UNDO",
                comment: "Tellomi (pinned-messages.md 3.6): button on the 'message unpinned' toast that keeps the message pinned.",
            ),
            handler: { [weak self] in
                guard let self, viewState.tellomiUndoableUnpins.remove(uniqueId) != nil else {
                    return
                }
                viewState.tellomiHeldUnpins.remove(uniqueId)
                ensureBannerState()
            },
        )
        let bottomInset = 10 + collectionView.contentInset.bottom + view.layoutMargins.bottom
        toast.presentToastView(from: .bottom, of: view, inset: bottomInset, dismissAfter: .seconds(Self.tellomiUnpinUndoSeconds))

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Self.tellomiUnpinUndoSeconds)) {
            // Intentionally strong: the unpin goes out even if the chat closed in the meantime.
            guard self.viewState.tellomiUndoableUnpins.remove(uniqueId) != nil else {
                return
            }
            self.tellomiSendUnpin(message)
        }
    }

    /// 发出取消置顶，不挡住界面；它真没了以后才回到栏上的计算（`tellomiPrunedPinnedBarPins`）。发不出去就放回栏上并照 Signal 提示。
    private func tellomiSendUnpin(_ message: TSMessage) {
        let uniqueId = message.uniqueId
        let unpinMessage = SSKEnvironment.shared.databaseStorageRef.write { tx in
            tellomiOutgoingUnpinMessage(for: message, tx: tx)
        }
        guard let unpinMessage else {
            viewState.tellomiHeldUnpins.remove(uniqueId)
            ensureBannerState()
            return
        }
        Task {
            do {
                try await sendPinMessageChange(pinMessage: unpinMessage)
            } catch {
                viewState.tellomiHeldUnpins.remove(uniqueId)
                ensureBannerState()
                OWSActionSheets.showActionSheet(
                    title: OWSLocalizedString(
                        "PINNED_MESSAGE_SEND_ERROR_SHEET_TITLE",
                        comment: "Title for error sheet shown if the pinned message failed to send",
                    ),
                    message: OWSLocalizedString(
                        "PINNED_MESSAGE_SEND_ERROR_SHEET_BODY",
                        comment: "Body for error sheet shown if the pinned message failed to send",
                    ),
                )
            }
        }
    }
}

/// Tellomi（pinned-messages.md 3.4）：置顶栏左边的竖线——每条置顶一段，最早的在上，正显示的那段实色；多于 3 段只露 3 段，
/// 上 / 下还有更多时那头渐隐（安卓 `PinnedLineView`；iOS `AnimatedNavigationStripeNode`）。与安卓 `TellomiPinnedLine` 一致。
final class TellomiPinnedLineView: UIView {
    private static let size = CGSize(width: 2, height: 34)
    private static let gap: CGFloat = 4

    private let fadeMask = CAGradientLayer()

    init(index: Int, count: Int) {
        super.init(frame: .zero)

        let window = TellomiPinnedBar.segments(index, count: count)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.spacing = Self.gap
        for segmentIndex in window.first..<(window.first + window.count) {
            let segment = UIView()
            segment.backgroundColor = segmentIndex == index ? UIColor.Signal.label : UIColor.Signal.tertiaryLabel
            segment.layer.cornerRadius = Self.size.width / 2
            stack.addArrangedSubview(segment)
        }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])

        if window.fadeTop || window.fadeBottom {
            let opaque = UIColor.black.cgColor
            let clear = UIColor.clear.cgColor
            fadeMask.colors = [window.fadeTop ? clear : opaque, opaque, opaque, window.fadeBottom ? clear : opaque]
            fadeMask.locations = [0, 0.25, 0.75, 1]
            layer.mask = fadeMask
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fadeMask.frame = bounds
    }
}
