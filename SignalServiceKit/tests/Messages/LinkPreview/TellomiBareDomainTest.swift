//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

/// 裸域名的例外（用户 2026-10-19，§5.6 例外，同 iOS「信息」App）。
final class TellomiBareDomainTest: XCTestCase {

    func testBareDomainsAreGivenAsHttps() {
        XCTAssertEqual(TellomiBareDomain.httpsUrl(forTypedText: "baidu.com"), "https://baidu.com")
        XCTAssertEqual(TellomiBareDomain.httpsUrl(forTypedText: "www.baidu.com"), "https://www.baidu.com")
        XCTAssertEqual(TellomiBareDomain.httpsUrl(forTypedText: "m.jd.com/"), "https://m.jd.com")
        XCTAssertEqual(TellomiBareDomain.httpsUrl(forTypedText: "Baidu.COM"), "https://baidu.com")
        XCTAssertEqual(TellomiBareDomain.httpsUrl(forTypedText: "news.bbc.co.uk"), "https://news.bbc.co.uk")
        XCTAssertEqual(TellomiBareDomain.httpsUrl(forTypedText: "my-site.io"), "https://my-site.io")
        XCTAssertEqual(TellomiBareDomain.httpsUrl(forTypedText: "example.xn--fiqs8s"), "https://example.xn--fiqs8s")
    }

    func testAnythingMoreThanADomainIsNotBare() {
        for text in ["baidu.com/s", "baidu.com/?q=1", "baidu.com#a", "baidu.com:8080", "me@baidu.com", "baidu.com//", "https://baidu.com"] {
            XCTAssertNil(TellomiBareDomain.httpsUrl(forTypedText: text), text)
        }
    }

    func testIpAddressesAndInvalidHostsAreNotBare() {
        for text in ["192.168.1.1", "8.8.8.8", "10.0.0.1", "[::1]", "localhost", "com", "baidu.c", "baidu.c0m", "-baidu.com", "baidu-.com",
                     "bai_du.com", "baidu..com", ".baidu.com", "baidu.com.", "", "百度.com",
                     String(repeating: "a", count: 64) + ".com"] {
            XCTAssertNil(TellomiBareDomain.httpsUrl(forTypedText: text), text)
        }
    }

    func testPrivateReservedAndFileLikeSuffixesAreNotBare() {
        for text in ["nas.local", "printer.lan", "db.internal", "box.home", "x.corp", "1.168.192.in-addr.arpa", "router.home.arpa",
                     "a.test", "a.example", "a.invalid", "a.onion", "a.localhost", "invoice.zip", "clip.mov",
                     "example.com", "www.example.org", "example.net"] {
            XCTAssertNil(TellomiBareDomain.httpsUrl(forTypedText: text), text)
        }
    }

    func testBareDomainUrlForm() {
        XCTAssertTrue(TellomiBareDomain.isBareDomainUrl("https://baidu.com"))
        XCTAssertTrue(TellomiBareDomain.isBareDomainUrl("https://baidu.com/"))
        XCTAssertTrue(TellomiBareDomain.isBareDomainUrl("HTTPS://www.jd.com"))
        XCTAssertFalse(TellomiBareDomain.isBareDomainUrl("http://baidu.com"))
        XCTAssertFalse(TellomiBareDomain.isBareDomainUrl("https://baidu.com/s?wd=1"))
        XCTAssertFalse(TellomiBareDomain.isBareDomainUrl("https://192.168.1.1"))
        XCTAssertFalse(TellomiBareDomain.isBareDomainUrl("https://nas.local/"))
        XCTAssertFalse(TellomiBareDomain.isBareDomainUrl("baidu.com"))
    }
}
