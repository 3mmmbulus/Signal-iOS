//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（交互审计 A-05 iOS）：消息变高变矮时这一批更新要动画；删掉的消息淡出并缩小。
@MainActor
final class TellomiConversationItemAnimationTest: SignalBaseTest {

    // MARK: - 哪些更新动画

    func testOnlyAHeightChangeCountsAsAnimatable() {
        let old = CGSize(width: 390, height: 60)
        XCTAssertTrue(CVUpdate.tellomiDidCellHeightChange(oldCellSize: old, newCellSize: CGSize(width: 390, height: 84)), "加了回应胶囊：变高")
        XCTAssertTrue(CVUpdate.tellomiDidCellHeightChange(oldCellSize: old, newCellSize: CGSize(width: 390, height: 44)), "远端删除换成一行提示：变矮")
        XCTAssertFalse(CVUpdate.tellomiDidCellHeightChange(oldCellSize: old, newCellSize: old), "回执、计数：高度不变")
        XCTAssertFalse(CVUpdate.tellomiDidCellHeightChange(oldCellSize: old, newCellSize: CGSize(width: 390, height: 60.3)), "不到半点的取整误差不算")
        XCTAssertFalse(CVUpdate.tellomiDidCellHeightChange(oldCellSize: nil, newCellSize: old), "找不到旧的：不为它动画")
    }

    // MARK: - 删掉的消息

    func testDeletedItemFadesAndShrinks() {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(row: 2, section: 0))
        attributes.frame = CGRect(x: 0, y: 120, width: 390, height: 60)

        let deleted = ConversationViewLayout.tellomiDeletedItemAttributes(attributes, reduceMotion: false)
        XCTAssertEqual(deleted.alpha, 0)
        XCTAssertEqual(deleted.transform, CGAffineTransform(scaleX: 0.9, y: 0.9))
        XCTAssertEqual(deleted.center, attributes.center, "原地缩，不挪")
        XCTAssertEqual(attributes.alpha, 1, "不改传进来的那份")
        XCTAssertEqual(attributes.transform, .identity)

        let reduced = ConversationViewLayout.tellomiDeletedItemAttributes(attributes, reduceMotion: true)
        XCTAssertEqual(reduced.alpha, 0)
        XCTAssertEqual(reduced.transform, .identity, "减弱动态效果：只淡出")
    }

    /// 真的 `ConversationViewLayout` 挂在窗口里的集合视图上：删一行，被删的格子在动画里朝「透明 + 0.9」走；
    /// 同一批里整行刷新的格子不缩。
    func testCollectionViewDeleteUsesTheShrinkingFinalAttributes() throws {
        let thread = ContactThreadFactory().create()
        let style = ConversationStyle(
            type: .`default`,
            thread: thread,
            viewWidth: 390,
            hasWallpaper: false,
            shouldDimWallpaperInDarkMode: false,
            chatColor: ChatColorSettingStore.Constants.defaultColor.colorSetting,
        )
        let source = FakeConversationSource(heights: [60, 60, 60, 60, 60])
        let layout = ConversationViewLayout(conversationStyle: style)
        layout.delegate = source
        let collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), collectionViewLayout: layout)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: FakeConversationSource.reuseIdentifier)
        collectionView.dataSource = source

        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.addSubview(collectionView)
        window.isHidden = false
        defer { window.isHidden = true }
        collectionView.layoutIfNeeded()

        let deletedCell = try XCTUnwrap(collectionView.cellForItem(at: IndexPath(row: 2, section: 0)))
        let reloadedCell = try XCTUnwrap(collectionView.cellForItem(at: IndexPath(row: 0, section: 0)))

        source.delete(row: 2)
        source.resize(row: 0, height: 84)
        collectionView.performBatchUpdates {
            collectionView.deleteItems(at: [IndexPath(row: 2, section: 0)])
            collectionView.reloadItems(at: [IndexPath(row: 0, section: 0)])
        }

        XCTAssertEqual(deletedCell.alpha, 0)
        XCTAssertEqual(deletedCell.transform, CGAffineTransform(scaleX: 0.9, y: 0.9))
        XCTAssertFalse(deletedCell.layer.animationKeys()?.isEmpty ?? true, "是动画过去的，不是一下变过去")
        XCTAssertEqual(reloadedCell.transform, .identity, "整行刷新的旧格子不缩")
    }

    // MARK: - 发送动画（M9）

    /// 由发送动画飞过来的那一格出现时不从透明淡入（落定那一刻它已经是不透明的）；别的新格子照旧淡入。
    func testASendFlightInsertionAppearsOpaque_otherInsertionsFadeIn() throws {
        let thread = ContactThreadFactory().create()
        let style = ConversationStyle(
            type: .`default`,
            thread: thread,
            viewWidth: 390,
            hasWallpaper: false,
            shouldDimWallpaperInDarkMode: false,
            chatColor: ChatColorSettingStore.Constants.defaultColor.colorSetting,
        )
        let source = FakeConversationSource(heights: [60, 60, 60])
        let layout = ConversationViewLayout(conversationStyle: style)
        layout.delegate = source
        let collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), collectionViewLayout: layout)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: FakeConversationSource.reuseIdentifier)
        collectionView.dataSource = source

        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.addSubview(collectionView)
        window.isHidden = false
        defer { window.isHidden = true }
        collectionView.layoutIfNeeded()

        source.append(height: 60)
        source.append(height: 60)
        layout.tellomiSendFlightInsertions = [IndexPath(row: 3, section: 0)]
        collectionView.performBatchUpdates {
            collectionView.insertItems(at: [IndexPath(row: 3, section: 0), IndexPath(row: 4, section: 0)])
        }

        let flown = try XCTUnwrap(collectionView.cellForItem(at: IndexPath(row: 3, section: 0)))
        let other = try XCTUnwrap(collectionView.cellForItem(at: IndexPath(row: 4, section: 0)))
        XCTAssertEqual(flown.layer.presentation()?.opacity ?? Float(flown.alpha), 1, "飞过来的那一格不淡入")
        XCTAssertLessThan(other.layer.presentation()?.opacity ?? 0, 1, "别的新格子照旧淡入")
        layout.finalizeCollectionViewUpdates()
        XCTAssertTrue(layout.tellomiSendFlightInsertions.isEmpty, "一批更新完就清掉")
    }
}

// MARK: -

private struct FakeConversationLayoutItem: ConversationViewLayoutItem {
    let interactionUniqueId: String
    let cellSize: CGSize

    func vSpacing(previousLayoutItem: ConversationViewLayoutItem) -> CGFloat { 4 }
    var canBeUsedForContinuity: Bool { true }
    var isDateHeader: Bool { false }
}

private final class FakeConversationSource: NSObject, ConversationViewLayoutDelegate, UICollectionViewDataSource {
    static let reuseIdentifier = "cell"

    private var items: [FakeConversationLayoutItem]
    private(set) var renderStateId: UInt = 1

    init(heights: [CGFloat]) {
        items = heights.enumerated().map { index, height in
            FakeConversationLayoutItem(interactionUniqueId: "m\(index)", cellSize: CGSize(width: 390, height: height))
        }
    }

    func delete(row: Int) {
        items.remove(at: row)
        renderStateId += 1
    }

    func append(height: CGFloat) {
        items.append(FakeConversationLayoutItem(interactionUniqueId: "m\(items.count)", cellSize: CGSize(width: 390, height: height)))
        renderStateId += 1
    }

    func resize(row: Int, height: CGFloat) {
        items[row] = FakeConversationLayoutItem(interactionUniqueId: items[row].interactionUniqueId, cellSize: CGSize(width: 390, height: height))
        renderStateId += 1
    }

    var layoutItems: [ConversationViewLayoutItem] { items }
    var layoutHeaderHeight: CGFloat { 0 }
    var layoutFooterHeight: CGFloat { 0 }
    var conversationViewController: ConversationViewController? { nil }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.reuseIdentifier, for: indexPath)
        cell.backgroundColor = .systemBlue
        return cell
    }
}
