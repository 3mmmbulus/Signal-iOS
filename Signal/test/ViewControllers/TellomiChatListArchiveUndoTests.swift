//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 交互审计 A-24（iOS 半边）：左滑「存档」做完就让行滑走（`completion(true)`），底栏上方出「聊天已存档 · 撤销」；
/// 点「撤销」移回聊天列表，原来置顶的重新置顶。照 Telegram iOS 归档后的 `UndoOverlayController(.archivedChat, undo: true)`。
final class TellomiChatListArchiveUndoTests: SignalBaseTest {

    @MainActor
    func testSwipeArchiveFinishesTheSwipeAndOffersUndo() throws {
        let thread = write { tx in
            TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress.randomForTesting(), transaction: tx)
        }
        let threadUniqueId = thread.uniqueId
        try write { tx in
            try DependenciesBridge.shared.pinnedThreadManager.pinThread(thread, updateStorageService: false, tx: tx)
        }
        let host = try makeHost()
        defer { host.window.isHidden = true }

        let threadViewModel = read { tx in ThreadViewModel(threadUniqueId: threadUniqueId, forChatList: true, transaction: tx) }
        XCTAssertTrue(threadViewModel.isPinned)
        let configuration = try XCTUnwrap(host.provider.trailingSwipeActionsConfiguration(threadViewModel: threadViewModel))
        let archive = try XCTUnwrap(configuration.actions.first, "左滑第一个是「存档」")

        var completed: Bool?
        archive.handler(archive, UIView()) { completed = $0 }
        XCTAssertEqual(completed, true, "归档做完：行跟着滑走，不先弹回")
        read { tx in
            let stored = DependenciesBridge.shared.threadStore.fetchThread(uniqueId: threadUniqueId, tx: tx)
            XCTAssertEqual(stored?.isArchived, true)
            XCTAssertTrue(DependenciesBridge.shared.pinnedThreadManager.pinnedThreads(tx: tx).isEmpty, "归档时取消置顶（上游行为）")
        }

        let toast = try XCTUnwrap(host.root.view.subviews.compactMap { $0 as? ToastView }.last, "底栏上方出提示条")
        let undo = try XCTUnwrap(toast.tellomiActionButton, "提示条带「撤销」")
        XCTAssertEqual(undo.configuration?.attributedTitle.map { String($0.characters) }, "Undo")

        undo.sendActions(for: .primaryActionTriggered)
        read { tx in
            let stored = DependenciesBridge.shared.threadStore.fetchThread(uniqueId: threadUniqueId, tx: tx)
            XCTAssertEqual(stored?.isArchived, false, "撤销：移回聊天列表")
            XCTAssertEqual(DependenciesBridge.shared.pinnedThreadManager.pinnedThreads(tx: tx).map(\.uniqueId), [threadUniqueId], "原来置顶的重新置顶")
        }
        XCTAssertEqual(host.provider.completeCount, 2, "归档、撤销各刷新一次列表")
    }

    /// 取消归档（在「已存档聊天」里左滑）也是做完就滑走，但不出撤销；置顶、静音这类行还在的，照旧弹回。
    @MainActor
    func testUnarchiveFinishesTheSwipeWithoutUndoAndOtherActionsStillBounceBack() throws {
        let thread = write { tx in
            let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress.randomForTesting(), transaction: tx)
            thread.updateWith(isArchived: true, updateStorageService: false, transaction: tx)
            return thread
        }
        let host = try makeHost()
        defer { host.window.isHidden = true }

        let archived = read { tx in ThreadViewModel(threadUniqueId: thread.uniqueId, forChatList: true, transaction: tx) }
        let unarchive = try XCTUnwrap(host.provider.trailingSwipeActionsConfiguration(threadViewModel: archived)?.actions.first)
        var completed: Bool?
        unarchive.handler(unarchive, UIView()) { completed = $0 }
        XCTAssertEqual(completed, true)
        XCTAssertTrue(host.root.view.subviews.compactMap { $0 as? ToastView }.isEmpty, "取消归档不出撤销")

        let current = read { tx in ThreadViewModel(threadUniqueId: thread.uniqueId, forChatList: true, transaction: tx) }
        let pin = try XCTUnwrap(host.provider.leadingSwipeActionsConfiguration(threadViewModel: current)?.actions.last, "左边右滑最后一个是「置顶」")
        var pinCompleted: Bool?
        pin.handler(pin, UIView()) { pinCompleted = $0 }
        XCTAssertEqual(pinCompleted, false, "置顶后行还在，照旧弹回")
    }

    /// 提示条的样子（只在 TELLOMI_SHOTS=1 时截）：右边「撤销」在玻璃底上看得清。
    @MainActor
    func testArchivedToastScreenshot() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let host = try makeHost()
        defer { host.window.isHidden = true }
        host.provider.tellomiPresentArchivedUndo(threadUniqueIds: ["a"], pinnedThreadUniqueIds: [])
        try await Task.sleep(nanoseconds: 800_000_000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: host.window.bounds, format: format).image { _ in
            host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
        }
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("402")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("chat-list-archived-undo-toast.png"))
    }

    // MARK: -

    private struct Host {
        let window: UIWindow
        let root: UIViewController
        let provider: TestProvider
    }

    @MainActor
    private func makeHost() throws -> Host {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let provider = TestProvider()
        window.rootViewController = provider
        window.isHidden = false
        provider.view.layoutIfNeeded()
        return Host(window: window, root: provider, provider: provider)
    }
}

private final class TestProvider: UIViewController, ThreadContextualActionProvider {
    var completeCount = 0

    func threadContextualActionShouldCloseThreadIfActive(threadViewModel: ThreadViewModel) {}

    func threadContextualActionDidComplete() {
        completeCount += 1
    }
}
