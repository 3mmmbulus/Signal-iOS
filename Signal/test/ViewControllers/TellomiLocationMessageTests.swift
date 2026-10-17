//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// spec attachment-files-location L-11：从 Signal-iOS、Signal-Android 和 Tellomi 发的正文里认出位置消息；别的正文不认。
final class TellomiLocationMessageTests: XCTestCase {

    // MARK: - Signal-iOS（上游 `Location.messageText`：多行地址 + 空行 + 链接）

    func testSignalIOSWithAMultiLineAddress() throws {
        let body = "1 Infinite Loop\nCupertino CA 95014\nUnited States\n\nhttps://maps.google.com/maps?q=37.33233141%2C-122.0312186"
        let location = try XCTUnwrap(TellomiLocationMessage.parse(body: body))
        XCTAssertEqual(location.latitude, 37.33233141)
        XCTAssertEqual(location.longitude, -122.0312186)
        XCTAssertNil(location.name)
        XCTAssertEqual(location.address, "1 Infinite Loop, Cupertino CA 95014, United States")
        XCTAssertFalse(location.isPlace)
    }

    func testSignalIOSWithAChineseAddressJoinsWithoutCommas() throws {
        let body = "中国\n上海市静安区\n南京西路789号\n\nhttps://maps.google.com/maps?q=31.2304%2C121.4737"
        let location = try XCTUnwrap(TellomiLocationMessage.parse(body: body))
        XCTAssertNil(location.name)
        XCTAssertEqual(location.address, "中国上海市静安区南京西路789号")
    }

    func testSignalIOSWithoutAnAddressIsJustTheLink() throws {
        let location = try XCTUnwrap(TellomiLocationMessage.parse(body: "https://maps.google.com/maps?q=-33.8688%2C151.2093"))
        XCTAssertEqual(location.latitude, -33.8688)
        XCTAssertEqual(location.longitude, 151.2093)
        XCTAssertNil(location.name)
        XCTAssertNil(location.address)
        XCTAssertFalse(location.isPlace)
    }

    /// Swift 把很小的数写成科学计数法（`\(1.0e-05)` = "1e-05"）。
    func testSignalIOSCoordinatesInScientificNotation() throws {
        let location = try XCTUnwrap(TellomiLocationMessage.parse(body: "https://maps.google.com/maps?q=1e-05%2C-2.5e-06"))
        XCTAssertEqual(location.latitude, 0.00001)
        XCTAssertEqual(location.longitude, -0.0000025)
    }

    // MARK: - Signal-Android（上游 `SignalPlace.getDescription()`：[名称\n][地址\n]链接，没有空行）

    func testSignalAndroidWithAnAddress() throws {
        let body = "1600 Amphitheatre Pkwy, Mountain View, CA 94043, USA\nhttps://maps.google.com/maps?q=37.4219983%2C-122.084"
        let location = try XCTUnwrap(TellomiLocationMessage.parse(body: body))
        XCTAssertEqual(location.latitude, 37.4219983)
        XCTAssertEqual(location.longitude, -122.084)
        XCTAssertNil(location.name)
        XCTAssertEqual(location.address, "1600 Amphitheatre Pkwy, Mountain View, CA 94043, USA")
    }

    /// 老版本的 Signal-Android 选地点时带名称。
    func testSignalAndroidWithANameAndAnAddress() throws {
        let body = "Googleplex\n1600 Amphitheatre Pkwy, Mountain View, CA 94043, USA\nhttps://maps.google.com/maps?q=37.4219983%2C-122.084"
        let location = try XCTUnwrap(TellomiLocationMessage.parse(body: body))
        XCTAssertEqual(location.name, "Googleplex")
        XCTAssertEqual(location.address, "1600 Amphitheatre Pkwy, Mountain View, CA 94043, USA")
        XCTAssertTrue(location.isPlace)
    }

    func testSignalAndroidWithNothingButTheLink() throws {
        let location = try XCTUnwrap(TellomiLocationMessage.parse(body: "https://maps.google.com/maps?q=22.3193%2C114.1694"))
        XCTAssertNil(location.address)
    }

    // MARK: - Tellomi（选了一个地点：名称\n单行地址\n链接）

    func testTellomiPlace() throws {
        let body = "星巴克臻选上海烘焙工坊\n静安区南京西路789号兴业太古汇\nhttps://maps.google.com/maps?q=31.2297%2C121.4560"
        let location = try XCTUnwrap(TellomiLocationMessage.parse(body: body))
        XCTAssertEqual(location.name, "星巴克臻选上海烘焙工坊")
        XCTAssertEqual(location.address, "静安区南京西路789号兴业太古汇")
        XCTAssertEqual(location.latitude, 31.2297)
        XCTAssertEqual(location.longitude, 121.4560)
        XCTAssertTrue(location.isPlace)
    }

    func testTellomiPlaceWithoutAnAddressIsOneLine() throws {
        // A place whose address is unknown sends only its name; one line reads as an address (Android's single line).
        let location = try XCTUnwrap(TellomiLocationMessage.parse(body: "外滩\nhttps://maps.google.com/maps?q=31.2400%2C121.4900"))
        XCTAssertNil(location.name)
        XCTAssertEqual(location.address, "外滩")
    }

    // MARK: - Tolerated variations

    func testUnencodedCommaHttpExtraParametersAndSpaces() throws {
        XCTAssertNotNil(TellomiLocationMessage.parse(body: "https://maps.google.com/maps?q=37.1,-122.2"))
        XCTAssertNotNil(TellomiLocationMessage.parse(body: "http://maps.google.com/maps?q=37.1%2C-122.2"))
        XCTAssertNotNil(TellomiLocationMessage.parse(body: "https://MAPS.GOOGLE.COM/maps?q=37.1%2C-122.2&z=15"))
        XCTAssertNotNil(TellomiLocationMessage.parse(body: "https://maps.google.com/?q=37.1%2C-122.2"))
        XCTAssertNotNil(TellomiLocationMessage.parse(body: "https://maps.google.com/maps?q=37.1%2C%20-122.2"))
        XCTAssertNotNil(TellomiLocationMessage.parse(body: "Somewhere\r\n\r\nhttps://maps.google.com/maps?q=37.1%2C-122.2\r\n"))
        XCTAssertNotNil(TellomiLocationMessage.parse(body: "  Somewhere  \n\n  https://maps.google.com/maps?q=37.1%2C-122.2  \n\n"))
        XCTAssertNotNil(TellomiLocationMessage.parse(body: "https://maps.google.com/maps?q=90%2C180"))
        XCTAssertNotNil(TellomiLocationMessage.parse(body: "https://maps.google.com/maps?q=-90%2C-180"))
    }

    func testBlankLinesAboveTheTextAreIgnored() throws {
        let location = try XCTUnwrap(TellomiLocationMessage.parse(body: "\n\nName\nAddress\nhttps://maps.google.com/maps?q=1%2C2"))
        XCTAssertEqual(location.name, "Name")
        XCTAssertEqual(location.address, "Address")
    }

    // MARK: - Not a location

    func testMalformedOrOtherTextIsNotALocation() {
        let bodies = [
            "",
            "\n\n",
            "Hello",
            "https://maps.google.com/maps",
            "https://maps.google.com/maps?q=",
            "https://maps.google.com/maps?q=abc%2Cdef",
            "https://maps.google.com/maps?q=37.1",
            "https://maps.google.com/maps?q=37.1%2C-122.2%2C5",
            "https://maps.google.com/maps?q=91%2C0",
            "https://maps.google.com/maps?q=0%2C181",
            "https://maps.google.com/maps?q=nan%2C0",
            "https://maps.google.com/maps?q=inf%2C0",
            "https://maps.google.com/maps?ll=37.1%2C-122.2",
            "https://maps.google.com/search?q=37.1%2C-122.2",
            "https://maps.google.com.evil.example/maps?q=37.1%2C-122.2",
            "https://example.com/maps?q=37.1%2C-122.2",
            "ftp://maps.google.com/maps?q=37.1%2C-122.2",
            "maps.google.com/maps?q=37.1%2C-122.2",
            // The link has to be the whole last line.
            "Meet here https://maps.google.com/maps?q=37.1%2C-122.2",
            "https://maps.google.com/maps?q=37.1%2C-122.2 see you",
            // Text after the link: it is not the last line.
            "https://maps.google.com/maps?q=37.1%2C-122.2\nsee you there",
            // Too much text above the link to be an address.
            "1\n2\n3\n4\n5\n6\n7\nhttps://maps.google.com/maps?q=37.1%2C-122.2",
            String(repeating: "x", count: 301) + "\nhttps://maps.google.com/maps?q=37.1%2C-122.2",
        ]
        for body in bodies {
            XCTAssertNil(TellomiLocationMessage.parse(body: body), body)
        }
    }

    func testSixLinesAboveTheLinkIsStillALocation() throws {
        let body = "1\n2\n3\n4\n5\n6\n\nhttps://maps.google.com/maps?q=37.1%2C-122.2"
        let location = try XCTUnwrap(TellomiLocationMessage.parse(body: body))
        XCTAssertEqual(location.address, "1, 2, 3, 4, 5, 6")
    }
}
