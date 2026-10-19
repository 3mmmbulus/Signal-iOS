//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0063 §6.5：服务端代抓不联网的那一半——白名单、请求体、回包、退避。
final class TellomiServerLinkPreviewTest: XCTestCase {

    // MARK: - 白名单

    func testEveryApprovedHostMapsToItsProvider() {
        let expected: [(String, String)] = [
            ("https://mp.weixin.qq.com/s/abc", "weixin-mp"),
            ("https://www.zhihu.com/question/1", "zhihu"),
            ("https://zhuanlan.zhihu.com/p/1", "zhihu"),
            ("https://weibo.com/123/Ab", "weibo"),
            ("https://m.weibo.cn/status/1", "weibo"),
            ("https://www.xiaohongshu.com/explore/1", "xiaohongshu"),
            ("https://xhslink.com/a/b", "xiaohongshu"),
            ("https://www.douyin.com/video/1", "douyin"),
            ("https://v.douyin.com/abc/", "douyin"),
            ("https://item.taobao.com/item.htm?id=1", "taobao"),
            ("https://detail.tmall.com/item.htm?id=1", "tmall"),
            ("https://chaoshi.detail.tmall.com/item.htm?id=1", "tmall"),
            ("https://MP.WEIXIN.QQ.COM/s/abc", "weixin-mp"),
        ]
        for (url, provider) in expected {
            XCTAssertEqual(TellomiServerLinkPreview.providerId(for: URL(string: url)!), provider, url)
        }
    }

    func testAnythingElseIsNotSentToTheServer() {
        let rejected = [
            "http://mp.weixin.qq.com/s/abc", // 不是 https
            "https://mp.weixin.qq.com:8443/s/abc", // 非默认端口
            "https://user@mp.weixin.qq.com/s/abc", // userinfo
            "https://evil.mp.weixin.qq.com/s/abc", // 子域不算
            "https://mp.weixin.qq.com.evil.com/s/abc",
            "https://m.tb.cn/h.abc", // 淘宝短链（脚本跳转）不在表里
            "https://passport.weibo.com/visitor",
            "https://example.com/",
        ]
        for url in rejected {
            XCTAssertNil(TellomiServerLinkPreview.providerId(for: URL(string: url)!), url)
        }
        XCTAssertFalse(TellomiServerLinkPreview.isEligible(URL(string: "https://mp.weixin.qq.com/s/abc")!, enabled: false), "开关关着就不走服务端")
    }

    func testTheFragmentNeverLeavesTheDevice() {
        let url = URL(string: "https://mp.weixin.qq.com/s/abc?x=1#rd")!
        XCTAssertEqual(TellomiServerLinkPreview.requestUrlString(url), "https://mp.weixin.qq.com/s/abc?x=1")
    }

    // MARK: - 回包

    func testACardIsReadAndTheServerDomainIsIgnored() {
        let image = Data([0xff, 0xd8, 0xff, 0xe0]).base64EncodedString()
        let body = #"{"title":"  标题  ","domain":"evil.example","provider":"weixin-mp","image":"\#(image)","imageContentType":"image/jpeg","imageWidth":4,"imageHeight":4}"#
        let answer = TellomiServerLinkPreview.answer(status: 200, body: Data(body.utf8), retryAfter: nil)
        XCTAssertEqual(answer, .card(.init(title: "标题", provider: "weixin-mp", imageData: Data([0xff, 0xd8, 0xff, 0xe0]), imageMimeType: "image/jpeg")))
    }

    func testABadImageIsDroppedButTheTitleIsKept() {
        let body = #"{"title":"T","provider":"zhihu","image":"%%%","imageContentType":"image/jpeg"}"#
        XCTAssertEqual(TellomiServerLinkPreview.answer(status: 200, body: Data(body.utf8), retryAfter: nil), .card(.init(title: "T", provider: "zhihu")))
        let svg = #"{"title":"T","provider":"zhihu","image":"AAAA","imageContentType":"image/svg+xml"}"#
        XCTAssertEqual(TellomiServerLinkPreview.answer(status: 200, body: Data(svg.utf8), retryAfter: nil), .card(.init(title: "T", provider: "zhihu")))
        let huge = Data(count: TellomiServerLinkPreview.maxImageBytes + 1).base64EncodedString()
        let big = #"{"title":"T","provider":"zhihu","image":"\#(huge)","imageContentType":"image/jpeg"}"#
        XCTAssertEqual(TellomiServerLinkPreview.answer(status: 200, body: Data(big.utf8), retryAfter: nil), .card(.init(title: "T", provider: "zhihu")))
    }

    func testACardWithoutATitleOrWithAnUnknownProviderIsAFailure() {
        for body in [#"{"title":"","provider":"zhihu"}"#, #"{"provider":"zhihu"}"#, #"{"title":"T","provider":"example"}"#, "not json"] {
            XCTAssertEqual(TellomiServerLinkPreview.answer(status: 200, body: Data(body.utf8), retryAfter: nil), .failed, body)
        }
        XCTAssertEqual(TellomiServerLinkPreview.answer(status: 200, body: nil, retryAfter: nil), .failed)
    }

    func testALongTitleIsCut() {
        let body = #"{"title":"\#(String(repeating: "长", count: 500))","provider":"weibo"}"#
        guard case .card(let card) = TellomiServerLinkPreview.answer(status: 200, body: Data(body.utf8), retryAfter: nil) else { return XCTFail() }
        XCTAssertEqual(card.title.count, TellomiServerLinkPreview.maxTitleLength)
    }

    func testStatusCodes() {
        XCTAssertEqual(TellomiServerLinkPreview.answer(status: 204, body: nil, retryAfter: nil), .noCard)
        XCTAssertEqual(TellomiServerLinkPreview.answer(status: 404, body: nil, retryAfter: nil), .notDeployed)
        XCTAssertEqual(TellomiServerLinkPreview.answer(status: 429, body: nil, retryAfter: "30"), .throttled(retryAfter: 30))
        XCTAssertEqual(TellomiServerLinkPreview.answer(status: 503, body: nil, retryAfter: nil), .throttled(retryAfter: nil))
        XCTAssertEqual(TellomiServerLinkPreview.answer(status: 422, body: nil, retryAfter: nil), .failed)
        XCTAssertEqual(TellomiServerLinkPreview.answer(status: 400, body: nil, retryAfter: nil), .failed)
    }

    func testOnlyBrandGenericAndPlainLinkResultsMayBeReplaced() {
        XCTAssertTrue(TellomiServerLinkPreview.mayReplace(level: "brand"))
        XCTAssertTrue(TellomiServerLinkPreview.mayReplace(level: "generic"))
        XCTAssertTrue(TellomiServerLinkPreview.mayReplace(level: "plain_link"))
        XCTAssertTrue(TellomiServerLinkPreview.mayReplace(level: nil))
        XCTAssertFalse(TellomiServerLinkPreview.mayReplace(level: "structured"))
        XCTAssertFalse(TellomiServerLinkPreview.mayReplace(level: "first_party"))
    }

    // MARK: - 退避

    func testTheGateClosesAfterNotDeployedOrThrottledAndReopens() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let gate = TellomiServerLinkPreviewGate(clock: { now })
        XCTAssertTrue(gate.isOpen)
        gate.record(.noCard)
        gate.record(.failed)
        XCTAssertTrue(gate.isOpen, "一条链接没卡片不影响下一条")

        gate.record(.notDeployed)
        XCTAssertFalse(gate.isOpen)
        now += TellomiServerLinkPreviewGate.notDeployedBackoff
        XCTAssertTrue(gate.isOpen)

        gate.record(.throttled(retryAfter: 30))
        now += 29
        XCTAssertFalse(gate.isOpen)
        now += 1
        XCTAssertTrue(gate.isOpen)

        gate.record(.throttled(retryAfter: 999_999))
        now += TellomiServerLinkPreviewGate.maxThrottle
        XCTAssertTrue(gate.isOpen, "Retry-After 封顶一小时")
    }
}
