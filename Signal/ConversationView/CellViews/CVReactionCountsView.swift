//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit

/// 消息下面的回应胶囊。
///
/// Tellomi（交互审计 A-07，owner 2026-10-17）照 Telegram 两端改了两处：
/// - **全部显示、放不下换行**：原来最多 3 格、第 3 格是「+N」。现在每个回应一格，按人数排，超过气泡最大宽度就换到下一行
///   （Telegram `ChatMessageReactionsFooterContentNode`）；各行朝屏幕中间那一侧对齐，和上游胶囊的摆法一致。
/// - **变化有交代**（和 Android `TellomiReactionPillAnimator` 同一套，Signal-Android#280）：同一条消息的回应变了时，
///   新出现的胶囊从 0.4 弹到原大并淡入；人数变了数字滚动（加一从下往上、减一从上往下）、胶囊轻弹一下；
///   只换了「是不是我回应的」底色 0.2 s 交叉淡变、轻弹一下。列表行复用给别的消息时不动。减弱动态效果时只淡变。
class CVReactionCountsView: ManualLayoutView {

    enum PillState: Equatable {
        case emoji(emoji: String, count: Int, fromLocalUser: Bool)

        var emoji: String {
            switch self {
            case .emoji(let emoji, _, _): emoji
            }
        }

        var count: Int {
            switch self {
            case .emoji(_, let count, _): count
            }
        }

        var fromLocalUser: Bool {
            switch self {
            case .emoji(_, _, let fromLocalUser): fromLocalUser
            }
        }
    }

    struct State: Equatable {
        let pills: [PillState]
    }

    static let height: CGFloat = 24
    static let inset: CGFloat = 7
    /// 换行时两行之间留的缝（胶囊自带 1 pt 背景色描边，再隔开一点）。
    static let rowSpacing: CGFloat = 2

    private var pillViews = [PillView]()
    private var displayedPills = [PillState]()
    private var alignsRowsRight = false

    /// 上一次画的是哪条消息、画成什么样：只有同一条消息的回应变了才动。
    private var lastMessageId: String?
    private var lastPills = [PillState]()

    init() {
        super.init(name: "reaction counts")
    }

    static func buildState(with reactionState: InteractionReactionState) -> State {
        // `emojiCounts` 已经按人数排好。
        State(pills: reactionState.emojiCounts.map { emojiCount in
            .emoji(
                emoji: emojiCount.emoji,
                count: emojiCount.count,
                fromLocalUser: emojiCount.emoji == reactionState.localUserEmoji,
            )
        })
    }

    private static func pillKey(_ index: Int) -> String {
        "CVReactionCountsView.pill\(index)"
    }

    // MARK: - 换行（单测覆盖）

    /// 依次排进不超过 [maxWidth] 的行里，放不下就换行（Telegram 同样按顺序贪心换行）。
    /// [alignRight] 时每行靠右。返回每格的位置和整体大小。
    static func flowLayout(pillSizes: [CGSize], maxWidth: CGFloat, alignRight: Bool) -> (frames: [CGRect], size: CGSize) {
        var rows = [[Int]]()
        var rowWidths = [CGFloat]()
        for (index, size) in pillSizes.enumerated() {
            if let rowWidth = rowWidths.last, rowWidth + size.width <= maxWidth {
                rows[rows.count - 1].append(index)
                rowWidths[rowWidths.count - 1] += size.width
            } else {
                // 第一格，或这一行放不下了。
                rows.append([index])
                rowWidths.append(size.width)
            }
        }
        let width = rowWidths.max() ?? 0
        var frames = [CGRect](repeating: .zero, count: pillSizes.count)
        var y: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            var x = alignRight ? width - rowWidths[rowIndex] : 0
            for index in row {
                frames[index] = CGRect(origin: CGPoint(x: x, y: y), size: pillSizes[index])
                x += pillSizes[index].width
            }
            y += height + rowSpacing
        }
        let totalHeight = rows.isEmpty ? 0 : CGFloat(rows.count) * height + CGFloat(rows.count - 1) * rowSpacing
        return (frames, CGSize(width: width, height: totalHeight))
    }

    /// 整排在 [maxWidth] 内换行后的高度（`CVComponentMessage` 用它算回应排往气泡下面伸出多少）。
    static func measuredHeight(state: State, maxWidth: CGFloat) -> CGFloat {
        flowLayout(pillSizes: state.pills.map(PillView.size(pillState:)), maxWidth: maxWidth, alignRight: false).size.height
    }

    // MARK: - 配置

    func configure(state: State, cellMeasurement: CVCellMeasurement, messageId: String?, alignRowsRight: Bool) {
        while pillViews.count < state.pills.count {
            pillViews.append(PillView(pillKey: Self.pillKey(pillViews.count)))
        }

        let isSameMessage = messageId != nil && messageId == lastMessageId
        let previousByEmoji = Dictionary(lastPills.map { ($0.emoji, $0) }, uniquingKeysWith: { first, _ in first })

        for (index, pillState) in state.pills.enumerated() {
            let pillView = pillViews[index]
            pillView.configure(pillState: pillState, cellMeasurement: cellMeasurement)
            addSubview(pillView)
            if isSameMessage {
                let change = Self.change(from: previousByEmoji[pillState.emoji], to: pillState)
                pillView.animate(change, from: previousByEmoji[pillState.emoji])
            }
        }

        displayedPills = state.pills
        alignsRowsRight = alignRowsRight
        lastMessageId = messageId
        lastPills = state.pills

        let sizes = state.pills.map(PillView.size(pillState:))
        let pillViews = Array(self.pillViews.prefix(state.pills.count))
        addLayoutBlock { view in
            let layout = Self.flowLayout(pillSizes: sizes, maxWidth: view.bounds.width, alignRight: alignRowsRight)
            for (pillView, frame) in zip(pillViews, layout.frames) {
                ManualLayoutView.setSubviewFrame(subview: pillView, frame: frame)
            }
        }
    }

    static func measure(
        state: State,
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> CGSize {
        for (index, pillState) in state.pills.enumerated() {
            _ = PillView.measure(pillState: pillState, pillKey: pillKey(index), measurementBuilder: measurementBuilder)
        }
        return flowLayout(pillSizes: state.pills.map(PillView.size(pillState:)), maxWidth: maxWidth, alignRight: false).size
    }

    override func reset() {
        super.reset()

        for pillView in pillViews {
            pillView.reset()
        }
        displayedPills = []
        // 不忘 `lastMessageId` / `lastPills`：同一条消息重新配置前也会先 reset。
    }

    // MARK: - 变化（和 Android `TellomiReactionPillAnimator.changeFor` 同一个判断）

    enum Change: Equatable {
        case none
        case added
        case countUp
        case countDown
        case restyled
    }

    static func change(from before: PillState?, to after: PillState) -> Change {
        guard let before else { return .added }
        if after.count > before.count { return .countUp }
        if after.count < before.count { return .countDown }
        if after.fromLocalUser != before.fromLocalUser { return .restyled }
        return .none
    }

    /// Tellomi（交互审计 A-07）：回应飞入的落点——显示着「我」这次回应的那一格里的表情字。
    /// Tellomi（交互审计 A-09）：`point`（本视图坐标）下面的那个胶囊；落在胶囊之间就是 nil。
    func tellomiPill(at point: CGPoint) -> UIView? {
        visiblePillViews.first { $0.frame.contains(point) }
    }

    func emojiLabel(for emoji: String) -> UILabel? {
        visiblePillViews
            .first { Self.isFlyInTarget($0.displayedPillState, emoji: emoji) }?
            .emojiLabelForFlyIn
    }

    private var visiblePillViews: [PillView] {
        pillViews.filter { $0.superview === self && !$0.isHidden }
    }

    /// Tellomi（交互审计 A-07）：落点只认「我」的那一格。别人已经用同一个表情回应过时，菜单刚收起那一刻消息还是回应之前的样子
    /// （收菜单期间聊天列表不落 load），那一格并不是我这次的回应；认了它，紧接着 load 落地、格子重新配置，真表情就先露出来了。
    static func isFlyInTarget(_ pillState: PillState?, emoji: String) -> Bool {
        guard case .emoji(let pillEmoji, _, let fromLocalUser) = pillState else {
            return false
        }
        return fromLocalUser && pillEmoji == emoji
    }

    // MARK: -

    private class PillView: ManualStackViewWithLayer {

        private let pillKey: String

        private let emojiLabel = CVLabel()
        private let countLabel = CVLabel()

        /// Tellomi（交互审计 A-07）：这一格正在显示的内容，给回应飞入找落点。
        private(set) var displayedPillState: PillState?
        var emojiLabelForFlyIn: UILabel { emojiLabel }

        private static let pillBorderWidth: CGFloat = 1

        init(pillKey: String) {
            self.pillKey = pillKey

            super.init(name: pillKey)

            emojiLabel.clipsToBounds = true
            clipsToBounds = true
        }

        static var stackConfig: CVStackViewConfig {
            let layoutMargins = UIEdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7)
            return CVStackViewConfig(axis: .horizontal, alignment: .fill, spacing: 2, layoutMargins: layoutMargins)
        }

        static func emojiLabelConfig(pillState: PillState) -> CVLabelConfig? {
            assert(pillState.emoji.isSingleEmoji)

            // textColor doesn't matter for emoji.
            return CVLabelConfig.unstyledText(
                pillState.emoji,
                font: .boldSystemFont(ofSize: 14),
                textColor: .black,
                textAlignment: .center,
            )
        }

        static func countLabelConfig(pillState: PillState) -> CVLabelConfig? {
            let textColor: UIColor = {
                if pillState.fromLocalUser {
                    return Theme.isDarkThemeEnabled ? .ows_gray15 : .ows_gray90
                } else {
                    return Theme.secondaryTextAndIconColor
                }
            }()

            guard pillState.count > 1 else {
                return nil
            }
            let text = pillState.count.abbreviatedString

            return CVLabelConfig.unstyledText(
                text,
                font: .monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                textColor: textColor,
                textAlignment: .center,
            )
        }

        func configure(
            pillState: PillState,
            cellMeasurement: CVCellMeasurement,
        ) {

            addLayoutBlock { view in
                view.layer.borderWidth = Self.pillBorderWidth
                view.layer.cornerRadius = CVReactionCountsView.height / 2
            }

            layer.borderColor = Theme.backgroundColor.cgColor
            backgroundColor = Self.backgroundColor(fromLocalUser: pillState.fromLocalUser)

            var subviews = [UIView]()

            // Tellomi（交互审计 A-07）：飞行中会把落点的字暂时藏起来；重新配置（包括复用给别的消息）时一律露出来。
            emojiLabel.alpha = 1
            displayedPillState = pillState

            if let emojiLabelConfig = Self.emojiLabelConfig(pillState: pillState) {
                emojiLabelConfig.applyForRendering(label: emojiLabel)
                subviews.append(emojiLabel)
            }

            if let countLabelConfig = Self.countLabelConfig(pillState: pillState) {
                countLabelConfig.applyForRendering(label: countLabel)
                subviews.append(countLabel)
            }

            configure(
                config: Self.stackConfig,
                cellMeasurement: cellMeasurement,
                measurementKey: pillKey,
                subviews: subviews,
            )
        }

        static func backgroundColor(fromLocalUser: Bool) -> UIColor {
            if fromLocalUser {
                return Theme.isDarkThemeEnabled ? .ows_gray60 : .ows_gray25
            } else {
                return Theme.isDarkThemeEnabled ? .ows_gray90 : .ows_gray05
            }
        }

        /// 和 [measure] 一样的大小（左右各 7、表情和数字间 2、高固定），不登记到测量里；换行和算高度用。
        static func size(pillState: PillState) -> CGSize {
            var width = stackConfig.layoutMargins.left + stackConfig.layoutMargins.right
            if let emojiLabelConfig = emojiLabelConfig(pillState: pillState) {
                width += CVText.measureLabel(config: emojiLabelConfig, maxWidth: .greatestFiniteMagnitude).width
            }
            if let countLabelConfig = countLabelConfig(pillState: pillState) {
                width += stackConfig.spacing + CVText.measureLabel(config: countLabelConfig, maxWidth: .greatestFiniteMagnitude).width
            }
            return CGSize(width: width, height: CVReactionCountsView.height)
        }

        // MARK: Tellomi（交互审计 A-07）：变化的动画，和 Android `TellomiReactionPillAnimator` 同一组数

        static let popFromScale: CGFloat = 0.4
        static let bumpScale: CGFloat = 1.12
        static let fadeDuration: TimeInterval = 0.15
        static let rollDuration: TimeInterval = 0.22
        static let rollDistance: CGFloat = 8
        static let fillCrossfadeDuration: TimeInterval = 0.2

        func animate(_ change: CVReactionCountsView.Change, from previous: PillState?) {
            guard change != .none else { return }
            let reduceMotion = TellomiMotion.isReduceMotionEnabled

            switch change {
            case .none:
                return
            case .added:
                alpha = 0
                UIView.animate(withDuration: Self.fadeDuration, delay: 0, options: [.allowUserInteraction]) { self.alpha = 1 }
                if !reduceMotion {
                    springScale(from: Self.popFromScale, spring: TellomiMotion.emphasis)
                }
            case .countUp, .countDown:
                if !reduceMotion {
                    springScale(from: Self.bumpScale, spring: TellomiMotion.release)
                }
                if countLabel.superview === self {
                    let distance = reduceMotion ? 0 : (change == .countUp ? Self.rollDistance : -Self.rollDistance)
                    countLabel.transform = CGAffineTransform(translationX: 0, y: distance)
                    countLabel.alpha = 0
                    UIView.animate(withDuration: Self.rollDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                        self.countLabel.transform = .identity
                        self.countLabel.alpha = 1
                    }
                }
            case .restyled:
                if !reduceMotion {
                    springScale(from: Self.bumpScale, spring: TellomiMotion.release)
                }
            }

            // 「是不是我回应的」变了：底色交叉淡变（人数变的同时也可能变）。
            if let previous, previous.fromLocalUser != displayedPillState?.fromLocalUser, let newColor = backgroundColor {
                backgroundColor = Self.backgroundColor(fromLocalUser: previous.fromLocalUser)
                UIView.animate(withDuration: Self.fillCrossfadeDuration, delay: 0, options: [.allowUserInteraction]) {
                    self.backgroundColor = newColor
                }
            }
        }

        private func springScale(from scale: CGFloat, spring: TellomiMotion.Spring) {
            transform = CGAffineTransform(scaleX: scale, y: scale)
            TellomiMotion.animator(spring, reduceMotion: false) {
                self.transform = .identity
            }.startAnimation()
        }

        static func measure(
            pillState: PillState,
            pillKey: String,
            measurementBuilder: CVCellMeasurement.Builder,
        ) -> CGSize {

            var subviewInfos = [ManualStackSubviewInfo]()
            if let emojiLabelConfig = Self.emojiLabelConfig(pillState: pillState) {
                let labelSize = CVText.measureLabel(
                    config: emojiLabelConfig,
                    maxWidth: .greatestFiniteMagnitude,
                )
                subviewInfos.append(labelSize.asManualSubviewInfo)
            }

            if let countLabelConfig = Self.countLabelConfig(pillState: pillState) {
                let labelSize = CVText.measureLabel(
                    config: countLabelConfig,
                    maxWidth: .greatestFiniteMagnitude,
                )
                subviewInfos.append(labelSize.asManualSubviewInfo)
            }

            let stackMeasurement = ManualStackView.measure(
                config: Self.stackConfig,
                measurementBuilder: measurementBuilder,
                measurementKey: pillKey,
                subviewInfos: subviewInfos,
            )
            var result = stackMeasurement.measuredSize
            // Pin height.
            result.height = CVReactionCountsView.height
            return result
        }
    }
}
