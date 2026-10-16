//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

// Tellomi（交互审计 A-15，iOS 半边）：多选。
// - 两根手指按住往上 / 往下拖，连着选 / 取消一串消息；手指靠近列表上下边缘时自动滚。照 Telegram iOS 的机制（只读，代码是自己写的）：
//   双指竖拖、起点那条原来没选就一路选上、选了就一路取消、退回去的恢复原样、靠边 50 pt 停 0.45 s 后开始滚。
//   和 Tellomi 安卓（Signal-Android#310）同一套「起点到手指下这一段」的规则。
// - 勾选时勾弹一下、轻触感。
// - 进出多选时顶栏交叉淡入、底栏（输入栏 ↔ 多选操作栏）旧的滑下去新的滑上来，不硬切。

/// 一次拖选：起点那条决定这次是「选」还是「取消」；从起点到手指下的那条（按列表顺序）都设成这个状态，拖回来时退出这一段的恢复拖之前的样子。
///
/// 只认消息本身（不认日期、未读线、系统消息，同 Telegram 和安卓）：调用方给的 `orderedIds` 里只放能拖选的消息。
struct TellomiDragSelection {

    struct Change: Equatable {
        let interactionId: String
        let selectionType: CVSelectionType
    }

    let anchorId: String
    /// true：一路选上；false：一路取消。
    let selecting: Bool

    /// 进过这一段的消息拖之前的样子（部分选中也照原样记）。
    private var originalTypes: [String: CVSelectionType] = [:]
    private var rangeIds: [String] = []

    init(anchorId: String, anchorType: CVSelectionType) {
        self.anchorId = anchorId
        // 整条都选了才算「选了」：只选了文字或只选了附件的，拖一下是补全。
        self.selecting = anchorType != .allContent
    }

    /// 手指到了 `currentId` 那条：返回要改成什么样的消息（先恢复退出这一段的，再设进这一段的）。
    /// 起点或手指下的那条不在 `orderedIds` 里（被滚出加载窗口、正在重排）就这一下不动。
    mutating func update(orderedIds: [String], currentId: String, currentType: (String) -> CVSelectionType) -> [Change] {
        guard
            let anchorIndex = orderedIds.firstIndex(of: anchorId),
            let currentIndex = orderedIds.firstIndex(of: currentId)
        else {
            return []
        }
        let newRange = Array(orderedIds[min(anchorIndex, currentIndex)...max(anchorIndex, currentIndex)])
        let newRangeSet = Set(newRange)
        var changes = [Change]()

        for id in rangeIds where !newRangeSet.contains(id) {
            let current = currentType(id)
            let original = originalTypes[id] ?? current
            if current != original {
                changes.append(Change(interactionId: id, selectionType: original))
            }
        }

        let target: CVSelectionType = selecting ? .allContent : .none
        for id in newRange {
            let current = currentType(id)
            if originalTypes[id] == nil {
                originalTypes[id] = current
            }
            if current != target {
                changes.append(Change(interactionId: id, selectionType: target))
            }
        }

        rangeIds = newRange
        return changes
    }
}

/// 靠边自动滚（照 Telegram iOS 的数）：手指进到可见区上 / 下边 50 pt 以内，停 0.45 s 后开始滚；越靠边越快，最多每帧（60 Hz）15 pt。
enum TellomiDragSelectAutoScroll {
    static let zoneHeight: CGFloat = 50
    static let activationDelay: TimeInterval = 0.45
    static let maxStep: CGFloat = 15
    /// 手指在可见区外（顶栏、底栏上）时按离边 5 pt 算，Telegram 同。
    static let edgeInset: CGFloat = 5

    /// 每帧（按 60 Hz 算）该滚多少：负数往上（更早的消息），正数往下；不在边缘区返回 nil。
    static func step(y: CGFloat, visibleTop: CGFloat, visibleBottom: CGFloat) -> CGFloat? {
        guard visibleBottom - visibleTop > 2 * edgeInset else {
            return nil
        }
        let clampedY = min(max(y, visibleTop + edgeInset), visibleBottom - edgeInset)
        let middle = (visibleTop + visibleBottom) / 2
        func speed(distanceFromEdge: CGFloat) -> CGFloat {
            let depth = (zoneHeight - min(zoneHeight, max(0, distanceFromEdge))) / zoneHeight
            return maxStep * min(1, 0.15 + depth * depth)
        }
        if clampedY < visibleTop + zoneHeight, clampedY < middle {
            return -speed(distanceFromEdge: clampedY - visibleTop)
        }
        if clampedY > visibleBottom - zoneHeight, clampedY >= middle {
            return speed(distanceFromEdge: visibleBottom - clampedY)
        }
        return nil
    }

    /// 拖选时按这个点找消息：手指在顶栏 / 底栏上时算作可见区里最靠边的那条。
    static func clampedY(_ y: CGFloat, visibleTop: CGFloat, visibleBottom: CGFloat) -> CGFloat {
        guard visibleBottom - visibleTop > 2 * edgeInset else {
            return y
        }
        return min(max(y, visibleTop + edgeInset), visibleBottom - edgeInset)
    }
}

/// 勾选时勾那个圈弹一下（照 Telegram iOS `CheckNode.setSelected` 的数）：选上 1 → 0.9 → 1.1 → 1（0.08 + 0.13 + 0.1 s），
/// 取消 1 → 0.9 → 1（0.08 + 0.13 s）。减弱动态效果时不弹，只有原来的淡入淡出。
enum TellomiCheckPop {
    static let animationKey = "tellomiCheckPop"

    static func animation(selected: Bool) -> CAKeyframeAnimation {
        let easeOut = CAMediaTimingFunction(name: .easeOut)
        let easeIn = CAMediaTimingFunction(name: .easeIn)
        let segments: [(scale: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunction)] = selected
            ? [(0.9, 0.08, easeOut), (1.1, 0.13, easeOut), (1, 0.1, easeIn)]
            : [(0.9, 0.08, easeOut), (1, 0.13, easeOut)]
        let total = segments.reduce(0) { $0 + $1.duration }
        var values: [CGFloat] = [1]
        var keyTimes: [NSNumber] = [0]
        var elapsed: CFTimeInterval = 0
        for segment in segments {
            elapsed += segment.duration
            values.append(segment.scale)
            keyTimes.append(NSNumber(value: elapsed / total))
        }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.timingFunctions = segments.map(\.timing)
        animation.duration = total
        return animation
    }
}

/// 两根手指一起竖着拖（同 Telegram iOS `ChatHistoryListSelectionRecognizer`：正好两根、竖着挪 5 pt 才算、两指相距超过 200 pt 不算）。
///
/// 列表的滚动手势要等它放弃（`require(toFail:)`）：不在多选时一按下就放弃；只有一根手指、挪出 6 pt（在滚动）也马上放弃，
/// 所以单指滚动不受影响。拖选途中抬起任一根手指就结束。
final class TellomiTwoFingerPanRecognizer: UIGestureRecognizer {
    static let activationDistance: CGFloat = 5
    static let maxFingerSpread: CGFloat = 200
    static let singleFingerSlop: CGFloat = 6

    var shouldBegin: (() -> Bool)?

    private var activeTouches = Set<UITouch>()
    private var singleFingerStart: CGPoint?
    private var twoFingerStart: CGPoint?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        activeTouches.formUnion(touches)
        guard state == .possible else {
            return
        }
        guard activeTouches.count <= 2, shouldBegin?() ?? true else {
            state = .failed
            return
        }
        if activeTouches.count == 1 {
            singleFingerStart = touches.first?.location(in: view)
        } else {
            twoFingerStart = centroid()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        switch state {
        case .possible:
            if activeTouches.count < 2 {
                // 一根手指在挪：是滚动，让给列表
                if let start = singleFingerStart, let touch = activeTouches.first {
                    let location = touch.location(in: view)
                    if hypot(location.x - start.x, location.y - start.y) > Self.singleFingerSlop {
                        state = .failed
                    }
                }
                return
            }
            let points = activeTouches.map { $0.location(in: view) }
            if points.count == 2, hypot(points[0].x - points[1].x, points[0].y - points[1].y) > Self.maxFingerSpread {
                state = .failed
                return
            }
            if let start = twoFingerStart, abs(centroid().y - start.y) >= Self.activationDistance {
                state = .began
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        activeTouches.subtract(touches)
        finishIfNeeded(cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        activeTouches.subtract(touches)
        finishIfNeeded(cancelled: true)
    }

    override func reset() {
        super.reset()
        activeTouches.removeAll()
        singleFingerStart = nil
        twoFingerStart = nil
    }

    /// 两根手指的中点（拖选按这个点找消息）。
    override func location(in view: UIView?) -> CGPoint {
        guard !activeTouches.isEmpty else {
            return super.location(in: view)
        }
        let points = activeTouches.map { $0.location(in: view) }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func centroid() -> CGPoint {
        location(in: view)
    }

    private func finishIfNeeded(cancelled: Bool) {
        switch state {
        case .began, .changed:
            // 拖选途中抬起任一根手指就结束
            state = cancelled ? .cancelled : .ended
        case .possible:
            if activeTouches.isEmpty {
                state = .failed
            } else if twoFingerStart != nil {
                // 两根变一根：这次不是拖选
                state = .failed
            }
        default:
            break
        }
    }
}

/// 一次拖选的状态（会话页里建、存在 `CVViewState`）：选了哪一段、手指在哪、靠边自动滚的计时和帧。
@MainActor
final class TellomiDragSelectState {
    var session: TellomiDragSelection?
    /// 手指在列表可见区里的位置（列表自己的坐标减去滚动偏移）：自动滚时手指不动、底下的消息在变。
    var viewportPoint: CGPoint?
    var scrollStep: CGFloat?
    let feedback = UISelectionFeedbackGenerator()

    private var activationTimer: Timer?
    private var displayLink: CADisplayLink?
    private var onFrame: ((CGFloat) -> Void)?

    /// 进到边缘区：第一次要停 0.45 s 才开始滚，滚过一次之后再进边缘区马上接着滚（Telegram 同）。
    func startAutoScrollIfNeeded(onFrame: @escaping (CGFloat) -> Void) {
        self.onFrame = onFrame
        if let displayLink {
            displayLink.isPaused = false
            return
        }
        guard activationTimer == nil else {
            return
        }
        activationTimer = Timer.scheduledTimer(withTimeInterval: TellomiDragSelectAutoScroll.activationDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startDisplayLink()
            }
        }
    }

    func pauseAutoScroll() {
        activationTimer?.invalidate()
        activationTimer = nil
        displayLink?.isPaused = true
    }

    func end() {
        pauseAutoScroll()
        displayLink?.invalidate()
        displayLink = nil
        onFrame = nil
        session = nil
        viewportPoint = nil
        scrollStep = nil
    }

    private func startDisplayLink() {
        activationTimer = nil
        guard displayLink == nil else {
            return
        }
        let link = CADisplayLink(target: TellomiDisplayLinkProxy(owner: self), selector: #selector(TellomiDisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        // 每帧滚的距离按 60 Hz 定，ProMotion 上按实际帧长折算，快慢一样
        let frameScale = CGFloat((link.targetTimestamp - link.timestamp) * 60).clamp(0.5, 4)
        onFrame?(frameScale)
    }
}

/// CADisplayLink 会强引用 target：中间隔一层弱引用，拖选结束时 `invalidate`。
private final class TellomiDisplayLinkProxy: NSObject {
    weak var owner: TellomiDragSelectState?

    init(owner: TellomiDragSelectState) {
        self.owner = owner
    }

    @objc
    func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.tick(link)
        }
    }
}

// MARK: - 选中状态

extension CVSelectionState {

    /// 这条现在选了哪些部分（文字 / 附件 / 整条）。
    func tellomiSelectionType(_ interactionId: String) -> CVSelectionType {
        var type: CVSelectionType = .none
        if isSelected(interactionId, selectionType: .primaryContent) {
            type.formUnion(.primaryContent)
        }
        if isSelected(interactionId, selectionType: .secondaryContent) {
            type.formUnion(.secondaryContent)
        }
        return type
    }

    /// 把这条设成正好选了 `type` 这些部分（拖选、拖回来恢复时用；不是来回切）。
    func tellomiSetSelection(_ type: CVSelectionType, itemViewModel: CVItemViewModel) {
        let current = tellomiSelectionType(itemViewModel.interaction.uniqueId)
        let toRemove = current.subtracting(type)
        if !toRemove.isEmpty {
            remove(itemViewModel: itemViewModel, selectionType: toRemove)
        }
        let toAdd = type.subtracting(current)
        if !toAdd.isEmpty {
            add(itemViewModel: itemViewModel, selectionType: toAdd)
        }
    }
}

// MARK: - 会话页

extension ConversationViewController {

    func tellomiConfigureDragSelect() {
        let recognizer = viewState.tellomiDragSelectRecognizer
        recognizer.addTarget(self, action: #selector(tellomiHandleDragSelect(_:)))
        recognizer.shouldBegin = { [weak self] in
            guard let self else {
                return false
            }
            return self.uiMode == .selection && !self.viewState.isInPreviewPlatter
        }
        collectionView.addGestureRecognizer(recognizer)
        // 两根手指按在列表上时先看是不是拖选：不在多选、或者只有一根手指在挪，它马上放弃，滚动照常
        collectionView.panGestureRecognizer.require(toFail: recognizer)
    }

    private var tellomiDragSelect: TellomiDragSelectState {
        if let state = viewState.tellomiDragSelectState {
            return state
        }
        let state = TellomiDragSelectState()
        viewState.tellomiDragSelectState = state
        return state
    }

    @objc
    private func tellomiHandleDragSelect(_ recognizer: TellomiTwoFingerPanRecognizer) {
        let drag = tellomiDragSelect
        switch recognizer.state {
        case .began, .changed:
            if recognizer.state == .began {
                drag.feedback.prepare()
            }
            let point = recognizer.location(in: collectionView)
            drag.viewportPoint = CGPoint(x: point.x, y: point.y - collectionView.contentOffset.y)
            tellomiDragSelectUpdate()
            tellomiDragSelectUpdateAutoScroll()
        default:
            drag.end()
        }
    }

    private var tellomiVisibleTop: CGFloat { collectionView.adjustedContentInset.top }
    private var tellomiVisibleBottom: CGFloat { collectionView.bounds.height - collectionView.adjustedContentInset.bottom }

    /// 手指下面那条消息，改成起点到它这一段该有的样子。
    private func tellomiDragSelectUpdate() {
        let drag = tellomiDragSelect
        guard let viewportPoint = drag.viewportPoint else {
            return
        }
        let contentPoint = CGPoint(
            x: viewportPoint.x.clamp(1, max(1, collectionView.bounds.width - 1)),
            y: TellomiDragSelectAutoScroll.clampedY(viewportPoint.y, visibleTop: tellomiVisibleTop, visibleBottom: tellomiVisibleBottom) + collectionView.contentOffset.y,
        )
        guard
            let indexPath = collectionView.indexPathForItem(at: contentPoint),
            let item = loadCoordinator.renderItems[safe: indexPath.row],
            item.rootComponent is CVComponentMessage
        else {
            return
        }

        let selectionState = self.selectionState
        if drag.session == nil {
            // 起点：第一下就按在它上面（或者按在日期这类东西上、拖到第一条消息）
            drag.session = TellomiDragSelection(anchorId: item.interactionUniqueId, anchorType: selectionState.tellomiSelectionType(item.interactionUniqueId))
        }
        let messages = loadCoordinator.renderItems.filter { $0.rootComponent is CVComponentMessage }
        guard
            let changes = drag.session?.update(
                orderedIds: messages.map(\.interactionUniqueId),
                currentId: item.interactionUniqueId,
                currentType: { selectionState.tellomiSelectionType($0) },
            ),
            !changes.isEmpty
        else {
            return
        }

        let messagesById = Dictionary(messages.map { ($0.interactionUniqueId, $0) }, uniquingKeysWith: { first, _ in first })
        for change in changes {
            guard let renderItem = messagesById[change.interactionId] else {
                continue
            }
            selectionState.tellomiSetSelection(change.selectionType, itemViewModel: CVItemViewModelImpl(renderItem: renderItem))
            if
                let indexPath = loadCoordinator.indexPath(forInteractionUniqueId: change.interactionId),
                let cell = collectionView.cellForItem(at: indexPath) as? CVCell
            {
                cell.tellomiUpdateSelectionViews(selectionState: selectionState, animated: true)
            }
        }
        drag.feedback.selectionChanged()
        drag.feedback.prepare()
    }

    private func tellomiDragSelectUpdateAutoScroll() {
        let drag = tellomiDragSelect
        guard let viewportPoint = drag.viewportPoint else {
            return
        }
        drag.scrollStep = TellomiDragSelectAutoScroll.step(y: viewportPoint.y, visibleTop: tellomiVisibleTop, visibleBottom: tellomiVisibleBottom)
        guard drag.scrollStep != nil else {
            drag.pauseAutoScroll()
            return
        }
        drag.startAutoScrollIfNeeded { [weak self] frameScale in
            self?.tellomiDragSelectAutoScrollFrame(frameScale: frameScale)
        }
    }

    private func tellomiDragSelectAutoScrollFrame(frameScale: CGFloat) {
        guard let step = tellomiDragSelect.scrollStep else {
            return
        }
        let minOffsetY = -collectionView.adjustedContentInset.top
        let maxOffsetY = max(minOffsetY, collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
        let offsetY = (collectionView.contentOffset.y + step * frameScale).clamp(minOffsetY, maxOffsetY)
        guard offsetY != collectionView.contentOffset.y else {
            return
        }
        collectionView.contentOffset.y = offsetY
        // 手指没动、底下的消息换了：接着选
        tellomiDragSelectUpdate()
    }
}

// MARK: - 进出多选：顶栏 / 底栏

enum TellomiSelectionBars {
    static let navigationBarTransitionKey = "tellomiSelectionBars"

    /// 只有「普通 ↔ 多选」才换栏动画；搜索有它自己的过渡。
    static func isSelectionToggle(from oldMode: ConversationUIMode, to newMode: ConversationUIMode) -> Bool {
        guard oldMode != .search, newMode != .search else {
            return false
        }
        return (oldMode == .selection) != (newMode == .selection)
    }
}

/// 多选进出时底栏互换：旧栏的快照滑下去、淡出，新栏从下面滑上来。新栏只动位置、不动透明度——栏里是玻璃 / 模糊效果，
/// 给它的父视图做透明度动画会让效果失灵。减弱动态效果时不滑，只把旧栏淡掉。
@MainActor
final class TellomiBottomBarSwap {
    private weak var snapshot: UIView?
    private weak var incoming: UIView?
    private var animator: UIViewPropertyAnimator?

    /// 上一次还没播完又切了：立刻落到终点（快照拿掉、新栏回原位）。
    func finishImmediately() {
        animator?.stopAnimation(true)
        animator = nil
        snapshot?.removeFromSuperview()
        incoming?.transform = .identity
    }

    func run(snapshot: UIView, incoming: UIView, reduceMotion: Bool) {
        finishImmediately()
        self.snapshot = snapshot
        self.incoming = incoming

        let animator: UIViewPropertyAnimator
        if reduceMotion {
            animator = UIViewPropertyAnimator(duration: TellomiMotion.reducedMotionCrossfadeDuration, curve: .easeInOut) {
                snapshot.alpha = 0
            }
        } else {
            let outgoingTravel = snapshot.bounds.height
            UIView.performWithoutAnimation {
                incoming.transform = CGAffineTransform(translationX: 0, y: incoming.bounds.height)
            }
            // 栏贴着屏幕底边：不回弹，免得冲过头露出底下的缝（Telegram 同样是 0.4 s 不回弹的弹簧）
            animator = TellomiMotion.animator(TellomiMotion.move.withoutBounce, reduceMotion: false) {
                incoming.transform = .identity
                snapshot.transform = CGAffineTransform(translationX: 0, y: outgoingTravel)
                snapshot.alpha = 0
            }
        }
        animator.addCompletion { [weak snapshot, weak incoming] _ in
            snapshot?.removeFromSuperview()
            incoming?.transform = .identity
        }
        self.animator = animator
        animator.startAnimation()
    }
}

extension ConversationViewController {

    func tellomiCrossfadeNavigationBarIfSelectionToggled(from oldValue: ConversationUIMode) {
        guard
            TellomiSelectionBars.isSelectionToggle(from: oldValue, to: uiMode),
            view.window != nil,
            let navigationBar = navigationController?.navigationBar
        else {
            return
        }
        // 接下来同一轮里换标题和按钮：整条顶栏从旧样子淡到新样子
        let transition = CATransition()
        transition.type = .fade
        transition.duration = TellomiMotion.fadeInDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        navigationBar.layer.add(transition, forKey: TellomiSelectionBars.navigationBarTransitionKey)
    }

    /// 换底栏之前：要是输入栏和多选操作栏互换，给旧栏拍一张快照放在原处（之后滑下去）。
    func tellomiSnapshotOutgoingSelectionBottomBar(incoming: UIView?) -> UIView? {
        tellomiBottomBarSwapState.finishImmediately()
        guard
            view.window != nil,
            let incoming,
            let outgoing = bottomBarContainer.subviews.first,
            outgoing !== incoming,
            outgoing.bounds.height > 0
        else {
            return nil
        }
        let isSelectionSwap = (outgoing === inputToolbar && incoming === selectionToolbar)
            || (outgoing === selectionToolbar && incoming === inputToolbar)
        guard isSelectionSwap, let snapshot = outgoing.snapshotView(afterScreenUpdates: false) else {
            return nil
        }
        snapshot.frame = outgoing.convert(outgoing.bounds, to: view)
        snapshot.isUserInteractionEnabled = false
        view.insertSubview(snapshot, aboveSubview: bottomBarContainer)
        return snapshot
    }

    func tellomiAnimateSelectionBottomBarSwap(outgoing snapshot: UIView?, incoming: UIView?) {
        guard let snapshot else {
            return
        }
        guard let incoming else {
            snapshot.removeFromSuperview()
            return
        }
        bottomBarContainer.layoutIfNeeded()
        tellomiBottomBarSwapState.run(snapshot: snapshot, incoming: incoming, reduceMotion: TellomiMotion.isReduceMotionEnabled)
    }

    private var tellomiBottomBarSwapState: TellomiBottomBarSwap {
        if let swap = viewState.tellomiBottomBarSwap {
            return swap
        }
        let swap = TellomiBottomBarSwap()
        viewState.tellomiBottomBarSwap = swap
        return swap
    }
}
