//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

import SignalServiceKit
@testable import Signal

/// Tellomi（tellomi/tellomi#1114）：聊天里点 tell.cc 链接要在 App 内打开，不经 Safari。
/// `ConversationViewController.handleUrl` 先过 `tellomiInAppRoute`，这里钉住分流的结果能被上游各个解析器认出来。
class TellomiInChatLinksTest: XCTestCase {
    private func route(_ string: String) -> ConversationViewController.TellomiInAppRoute {
        return ConversationViewController.tellomiInAppRoute(for: URL(string: string)!)
    }

    private func routedUrl(_ string: String) -> URL? {
        guard case .url(let url) = route(string) else { return nil }
        return url
    }

    func testUsernameCardsAreLookedUpDirectly() {
        XCTAssertEqual(route("https://tell.cc/ceshi.57"), .plainUsername("ceshi.57"))
        XCTAssertEqual(route("https://tell.cc/u#u/ceshi.57"), .plainUsername("ceshi.57"))
        XCTAssertEqual(route("tellomi://tell.cc/linktest.56/"), .plainUsername("linktest.56"))
    }

    func testOtherTellShapesReachTheUpstreamParsers() {
        // 群邀请 → signal.group
        XCTAssertNotNil(routedUrl("https://tell.cc/g#abc").flatMap { PossibleGroupInviteLinkUrl.parseFrom($0) })
        // 手机号名片 → signal.me/#p/…，不能被当成群邀请（Android #973 撞过的坑）
        let phoneLink = routedUrl("https://tell.cc/u#p/+16505550100")
        XCTAssertTrue(phoneLink.map { SignalDotMePhoneNumberLink.isPossibleUrl($0) } ?? false)
        XCTAssertNil(phoneLink.flatMap { PossibleGroupInviteLinkUrl.parseFrom($0) })
        // 贴纸包 → signal.art/addstickers
        XCTAssertTrue(routedUrl("https://tell.cc/s#pack_id=1&pack_key=2").map { StickerPackInfo.isStickerPackShare($0) } ?? false)
        // 通话链接 → signal.link/call
        XCTAssertEqual(routedUrl("https://tell.cc/call#key=abcd"), URL(string: "https://signal.link/call/#key=abcd"))
    }

    /// I-16：动态外链在 App 里打开这条动态（取不到就写「已不可见」），不交给浏览器。
    func testFeedPostLinksOpenThePost() {
        let id = "0a1b2c3d-0000-4000-8000-000000000001"
        XCTAssertEqual(route("https://tell.cc/m#\(id)"), .feedPost(contentId: id))
        XCTAssertEqual(route("https://tell.cc/m#\(id.uppercased())"), .feedPost(contentId: id), "id 一律小写")
        XCTAssertEqual(route("tellomi://tell.cc/m#\(id)"), .feedPost(contentId: id))
        XCTAssertEqual(route("https://tell.cc/m/#\(id)"), .feedPost(contentId: id))
        // 不是 UUID 的、http 的：不当成动态，按原来的规则走
        XCTAssertNotEqual(route("https://tell.cc/m#not-a-uuid"), .feedPost(contentId: "not-a-uuid"))
        if case .feedPost = route("http://tell.cc/m#\(id)") { XCTFail("http 不认") }
        if case .feedPost = route("https://tell.cc/m") { XCTFail("没有 id 不认") }
    }

    func testOrdinaryLinksAreLeftAlone() {
        XCTAssertEqual(route("https://example.com/a?b=c"), .url(URL(string: "https://example.com/a?b=c")!))
    }
}
