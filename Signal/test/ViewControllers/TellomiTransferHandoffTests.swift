//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit
import XCTest

@testable import Signal

/// Tellomi（交互审计 A-13 iOS 半边）：传完那一下，旧视图的样子交给新视图——谁先到都行、只在同一次排版之内、
/// 环缩小淡出、占位图盖在原图上等原图到了再淡掉。
@MainActor
final class TellomiTransferHandoffTests: XCTestCase {

    private final class Receiver: TellomiTransferHandoffReceiver {
        var canReceive = true
        var received = [TellomiTransferHandoff.Look]()
        var tellomiCanReceiveTransferHandoff: Bool { canReceive }
        func tellomiReceiveTransferHandoff(_ look: TellomiTransferHandoff.Look) {
            received.append(look)
        }
    }

    private var time: CFTimeInterval = 100

    private func makeHandoff() -> TellomiTransferHandoff {
        let handoff = TellomiTransferHandoff()
        handoff.now = { [unowned self] in self.time }
        return handoff
    }

    private func look(_ name: String = "ring") -> TellomiTransferHandoff.Look {
        let ring = UIView()
        ring.accessibilityIdentifier = name
        return TellomiTransferHandoff.Look(ring: ring, ringSize: CGSize(width: 44, height: 44), placeholder: UIImage())
    }

    // MARK: - 碰头

    func testTheFinishedViewTakesTheLookTheTransferringOneJustLeft() {
        let handoff = makeHandoff()
        let receiver = Receiver()
        handoff.transferringViewWillLeave(key: "m/1", look: look("old"))
        time += 0.03
        handoff.finishedViewDidEnter(key: "m/1", receiver: receiver)
        XCTAssertEqual(receiver.received.map { $0.ring.accessibilityIdentifier }, ["old"])
        XCTAssertTrue(handoff.isEmpty, "nothing kept once handed over")
    }

    /// `reloadItems` 换格子时新格子也可能先进窗口。
    func testItAlsoWorksWhenTheFinishedViewArrivesFirst() {
        let handoff = makeHandoff()
        let receiver = Receiver()
        handoff.finishedViewDidEnter(key: "m/1", receiver: receiver)
        XCTAssertTrue(receiver.received.isEmpty)
        time += 0.02
        handoff.transferringViewWillLeave(key: "m/1", look: look("old"))
        XCTAssertEqual(receiver.received.count, 1)
        XCTAssertTrue(handoff.isEmpty)
    }

    /// 滚出屏幕、关页面以后过了一会儿才出现的同一张图，不是这一次换格子。
    func testAnythingLaterThanOneLayoutPassIsNotTheSameSwap() {
        let handoff = makeHandoff()
        let receiver = Receiver()
        handoff.transferringViewWillLeave(key: "m/1", look: look())
        time += TellomiTransferHandoff.rendezvousWindow + 0.05
        handoff.finishedViewDidEnter(key: "m/1", receiver: receiver)
        XCTAssertTrue(receiver.received.isEmpty)

        let late = Receiver()
        time += 1
        handoff.transferringViewWillLeave(key: "m/2", look: look())
        handoff.finishedViewDidEnter(key: "m/3", receiver: late)
        XCTAssertTrue(late.received.isEmpty, "another message / attachment never matches")
        time += 1
        handoff.prune()
        XCTAssertTrue(handoff.isEmpty, "stale looks and waiters are dropped")
    }

    /// 新视图还在传（比如下了一半、格子因为别的原因重建）：它自己有环，不接。
    func testAViewThatIsStillTransferringDoesNotTakeIt() {
        let handoff = makeHandoff()
        let receiver = Receiver()
        handoff.finishedViewDidEnter(key: "m/1", receiver: receiver)
        receiver.canReceive = false
        handoff.transferringViewWillLeave(key: "m/1", look: look())
        XCTAssertTrue(receiver.received.isEmpty)
    }

    func testTheKeyIsPerMessageAndAttachment() {
        XCTAssertEqual(TellomiTransferHandoff.key(interactionUniqueId: "abc", attachmentId: 7), "abc/7")
        XCTAssertNotEqual(
            TellomiTransferHandoff.key(interactionUniqueId: "abc", attachmentId: 7),
            TellomiTransferHandoff.key(interactionUniqueId: "abd", attachmentId: 7),
        )
    }

    // MARK: - 过渡

    private func hostedContainer() -> (UIWindow, ManualLayoutViewWithLayer) {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let container = ManualLayoutViewWithLayer(name: "media")
        container.frame = CGRect(x: 40, y: 100, width: 240, height: 180)
        window.addSubview(container)
        return (window, container)
    }

    func testTheRingShrinksAndFadesWhereItWasThenGoes() {
        let (window, container) = hostedContainer()
        defer { window.isHidden = true }
        let ring = UIView()

        TellomiTransferHandoff.playRingExit(ring, size: CGSize(width: 44, height: 44), in: container, reduceMotion: false)

        XCTAssertTrue(ring.superview === container)
        XCTAssertEqual(ring.bounds.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(ring.center, CGPoint(x: 120, y: 90), "centred on the media")
        XCTAssertEqual(ring.alpha, 0, "model value: fading out")
        XCTAssertEqual(ring.transform.a, TellomiTransferHandoff.ringExitScale, accuracy: 1e-6, "shrinking to 0.8")
        XCTAssertFalse(ring.isUserInteractionEnabled)

        let gone = expectation(description: "removed")
        DispatchQueue.main.asyncAfter(deadline: .now() + TellomiMotion.fadeOutDuration + 0.3) {
            XCTAssertNil(ring.superview)
            gone.fulfill()
        }
        wait(for: [gone], timeout: 2)
    }

    /// 减弱动态效果：只淡，不缩。
    func testWithReduceMotionTheRingOnlyFades() {
        let (window, container) = hostedContainer()
        defer { window.isHidden = true }
        let ring = UIView()
        TellomiTransferHandoff.playRingExit(ring, size: CGSize(width: 44, height: 44), in: container, reduceMotion: true)
        XCTAssertEqual(ring.alpha, 0)
        XCTAssertEqual(ring.transform, .identity)
    }

    /// 占位图紧贴在原图上面（角标、遮罩、播放键还在它上面），铺满；淡掉以后摘掉。
    func testThePlaceholderLiesOverTheImageUntilItFades() {
        let (window, container) = hostedContainer()
        defer { window.isHidden = true }
        let media = UIImageView()
        container.addSubview(media)
        let badge = UIView()
        container.addSubview(badge)

        let placeholderView = TellomiTransferHandoff.coverWithPlaceholder(UIImage(), above: media, in: container)

        XCTAssertEqual(container.subviews, [media, placeholderView, badge])
        XCTAssertEqual(placeholderView.frame, container.bounds)
        XCTAssertEqual(placeholderView.contentMode, .scaleAspectFill)
        XCTAssertEqual(placeholderView.alpha, 1, "stays until the image is up")

        TellomiTransferHandoff.fadeOutPlaceholder(placeholderView)
        XCTAssertEqual(placeholderView.alpha, 0)
        let gone = expectation(description: "removed")
        DispatchQueue.main.asyncAfter(deadline: .now() + TellomiMotion.fadeOutDuration + 0.3) {
            XCTAssertNil(placeholderView.superview)
            TellomiTransferHandoff.fadeOutPlaceholder(placeholderView)
            gone.fulfill()
        }
        wait(for: [gone], timeout: 2)
    }

    // MARK: - 原图什么时候到

    private final class FakeAdapter: MediaViewAdapter, @unchecked Sendable {
        private let view: UIView
        private var loaded = false
        @MainActor
        init() {
            view = UIView()
        }

        var mediaView: UIView { view }
        var isLoaded: Bool { loaded }
        let cacheKey: CVMediaCache.CacheKey = .blurHash("tellomi-test-\(UUID().uuidString)")
        let shouldBeRenderedByYY = false
        func applyMedia(_ media: AnyObject) { loaded = true }
        func loadMedia() async throws -> AnyObject { NSObject() }
        func unloadMedia() { loaded = false }
    }

    func testTheOwnerHearsOnceWhenTheImageIsUp() {
        let adapter = FakeAdapter()
        let reusableMediaView = ReusableMediaView(mediaViewAdapter: adapter, mediaCache: CVMediaCache())
        let owner = NSObject()
        reusableMediaView.owner = owner
        XCTAssertFalse(reusableMediaView.tellomiIsLoaded)

        var calls = 0
        let loaded = expectation(description: "loaded")
        reusableMediaView.tellomiOnLoadFinished = {
            calls += 1
            XCTAssertTrue(reusableMediaView.tellomiIsLoaded, "called after the image is applied")
            loaded.fulfill()
        }
        reusableMediaView.load()
        wait(for: [loaded], timeout: 5)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(reusableMediaView.tellomiOnLoadFinished, "cleared after the call")
    }

    func testANewOwnerDoesNotGetTheOldOwnersCallback() {
        let reusableMediaView = ReusableMediaView(mediaViewAdapter: FakeAdapter(), mediaCache: CVMediaCache())
        let first = NSObject()
        reusableMediaView.owner = first
        reusableMediaView.tellomiOnLoadFinished = { XCTFail("belongs to the first owner") }
        let second = NSObject()
        reusableMediaView.owner = second
        XCTAssertNil(reusableMediaView.tellomiOnLoadFinished)
        reusableMediaView.owner = second
        XCTAssertNil(reusableMediaView.tellomiOnLoadFinished)
    }
}
