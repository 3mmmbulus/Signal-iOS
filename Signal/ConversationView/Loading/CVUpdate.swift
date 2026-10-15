//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit

// The outcome of a CVC load is an update that describes how to
// transition from the last render state to the new render state.
struct CVUpdate {

    enum CVUpdateType {
        // No view items in the load window were effected.
        case minor
        // Complicated or unexpected changes occurred in the load window;
        // the view should be reloaded.
        case reloadAll
        // A subset of view items in the load window were effected;
        // the view should be updated using the update items.
        //
        // TODO: Do we need shouldAnimateUpdates? How does this fit with the scroll action?
        case diff(items: [Item], shouldAnimateUpdate: Bool)

        // MARK: -

        var debugName: String {
            switch self {
            case .minor:
                return "minor"
            case .reloadAll:
                return "reloadAll"
            case .diff:
                return "diff"
            }
        }
    }

    let type: CVUpdateType

    let renderState: CVRenderState
    let prevRenderState: CVRenderState

    let loadRequest: CVLoadRequest
    var loadType: CVLoadType { loadRequest.loadType }

    typealias Item = BatchUpdate<CVRenderItem>.Item
}

// MARK: -

extension CVUpdate {
    typealias ItemId = String

    // TODO: Eliminate.
    private static func itemId(for renderItem: CVRenderItem) -> ItemId {
        renderItem.interactionUniqueId
    }

    static func build(
        renderState: CVRenderState,
        prevRenderState: CVRenderState,
        loadRequest: CVLoadRequest,
    ) -> CVUpdate {

        func buildUpdate(type: CVUpdateType) -> CVUpdate {
            CVUpdate(
                type: type,
                renderState: renderState,
                prevRenderState: prevRenderState,
                loadRequest: loadRequest,
            )
        }

        let loadType = loadRequest.loadType
        let oldStyle = prevRenderState.conversationStyle
        let newStyle = renderState.conversationStyle
        let didStyleChange = newStyle != oldStyle

        if case .loadInitialMapping = loadType {
            // Don't do an incremental update for the initial load.
            return buildUpdate(type: .reloadAll)
        }

        var appearanceChangedItemIdSet = Set<ItemId>()
        var changedRenderItems = [CVRenderItem]()
        var oldRenderItemMap = [String: CVRenderItem]()
        for oldRenderItem in prevRenderState.items {
            oldRenderItemMap[itemId(for: oldRenderItem)] = oldRenderItem
        }
        for newRenderItem in renderState.items {
            let itemId = itemId(for: newRenderItem)
            guard let oldRenderItem = oldRenderItemMap[itemId] else {
                continue
            }

            // Whenever the style changes we should update all cells.
            if didStyleChange {
                changedRenderItems.append(newRenderItem)
                continue
            }

            switch newRenderItem.updateMode(other: oldRenderItem) {
            case .equal:
                continue
            case .stateChanged:
                // The item changed, so we need to update it.
                changedRenderItems.append(newRenderItem)
            case .appearanceChanged:
                // Take note of the fact that only the _appearance_ of the
                // item changed, not its state.
                appearanceChangedItemIdSet.insert(itemId)

                // The item changed, so we need to update it.
                changedRenderItems.append(newRenderItem)
            }
        }

        do {
            let batchUpdateItems = try BatchUpdate.build(
                viewType: .uiCollectionView,
                oldValues: prevRenderState.items,
                newValues: renderState.items,
                changedValues: changedRenderItems,
            )

            guard !batchUpdateItems.isEmpty else {
                return buildUpdate(type: .minor)
            }
            let oldItems = prevRenderState.items
            let shouldAnimateUpdate = Self.shouldAnimateUpdate(
                loadType: loadType,
                updateItems: batchUpdateItems,
                oldItemCount: oldItems.count,
                oldItems: oldItems,
                appearanceChangedItemIdSet: appearanceChangedItemIdSet,
            )

            return buildUpdate(type: .diff(
                items: batchUpdateItems,
                shouldAnimateUpdate: shouldAnimateUpdate,
            ))
        } catch {
            owsFailDebug("Error: \(error)")
            return buildUpdate(type: .reloadAll)
        }
    }

    private static func shouldAnimateUpdate(
        loadType: CVLoadType,
        updateItems: [CVUpdate.Item],
        oldItemCount: Int,
        oldItems: [CVRenderItem],
        appearanceChangedItemIdSet: Set<ItemId>,
    ) -> Bool {

        switch loadType {
        case .loadInitialMapping, .loadOlder, .loadNewer, .loadNewest, .loadPageAroundInteraction:
            return false
        case .loadSameLocation:
            break
        }

        // If user sends a new outgoing message, animate the change.
        var shouldAnimateUpdate = true
        var onlyAppearanceUpdateChanges = true
        var previousItemCount = oldItemCount
        for updateItem in updateItems {
            guard shouldAnimateUpdate else {
                // Exit early if we already know that we're not just
                // inserting a new message at the bottom of the conversation.
                break
            }

            let renderItem = updateItem.value
            switch updateItem.updateType {
            case .delete:
                onlyAppearanceUpdateChanges = false
                previousItemCount = oldItemCount - 1
                continue
            case .insert(let newIndex):
                onlyAppearanceUpdateChanges = false
                switch renderItem.interactionType {
                case .incomingMessage, .outgoingMessage, .typingIndicator:
                    // Allow animated insert if this item is one from the last item, as last item is likely a typing indicator
                    if newIndex < previousItemCount - 1 {
                        shouldAnimateUpdate = false
                    }
                case .unreadIndicator:
                    break
                default:
                    shouldAnimateUpdate = true
                }
            case .move:
                onlyAppearanceUpdateChanges = false
            case .update(let oldIndex, _):
                let itemId = Self.itemId(for: renderItem)
                let didOnlyAppearanceChange = appearanceChangedItemIdSet.contains(itemId)
                if didOnlyAppearanceChange {
                    continue
                }

                switch renderItem.interactionType {
                case .incomingMessage, .outgoingMessage, .typingIndicator:
                    // Tellomi（交互审计 A-05）：上游这里是 `newIndex + 2 > updateItems.count`——拿行号去比
                    // 「这一批有几条更新」，单条更新永远成立，所以回应胶囊、展开全文、编辑、远端删除、下载完成
                    // 这些让气泡变高变矮的更新一条都不动画，上面的消息一下跳过去。
                    // 改成按高度：高度变了就让这一批动画（Telegram 两端对聊天里的变化都动画）；高度没变的
                    // （回执、计数）不表态，照旧不为它单独动画，免得每次回执都交叉淡入一下。
                    guard
                        Self.tellomiDidCellHeightChange(
                            oldCellSize: oldItems[safe: oldIndex]?.cellSize,
                            newCellSize: renderItem.cellSize,
                        )
                    else {
                        continue
                    }
                    onlyAppearanceUpdateChanges = false
                case .collapseSet:
                    onlyAppearanceUpdateChanges = false
                default:
                    onlyAppearanceUpdateChanges = false
                    shouldAnimateUpdate = false
                }
            }
        }
        return shouldAnimateUpdate && !onlyAppearanceUpdateChanges
    }

    /// Tellomi（交互审计 A-05）：这条消息的格子高度变没变。旧的找不到时当没变（不为它动画）。
    static func tellomiDidCellHeightChange(oldCellSize: CGSize?, newCellSize: CGSize) -> Bool {
        guard let oldCellSize else {
            return false
        }
        return abs(oldCellSize.height - newCellSize.height) >= 0.5
    }
}

// MARK: -

extension CVRenderItem: BatchUpdateValue {
    public var batchUpdateId: String {
        interactionUniqueId
    }
}
