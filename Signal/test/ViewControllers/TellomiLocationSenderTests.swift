//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Contacts
import MapKit
import XCTest

@testable import Signal
@testable import SignalUI

/// spec attachment-files-location L-11（发送端）：选的地点把名称发出去（上游只发地址）；地图图改成 2:1、气球大头针。
final class TellomiLocationSenderTests: XCTestCase {

    private static let coordinate = CLLocationCoordinate2D(latitude: 31.2297, longitude: 121.456)

    private static func placemark(street: String = "南京西路789号", city: String = "上海市") -> MKPlacemark {
        let address = CNMutablePostalAddress()
        address.street = street
        address.city = city
        address.country = "中国"
        return MKPlacemark(coordinate: coordinate, postalAddress: address)
    }

    // MARK: - Message text

    func testAPlaceSendsItsNameAddressAndLink_andReadsBackAsAPlace() throws {
        let location = Location(
            name: "星巴克臻选上海烘焙工坊",
            location: CLLocation(latitude: Self.coordinate.latitude, longitude: Self.coordinate.longitude),
            placemark: Self.placemark(),
            tellomiCategory: .cafe,
            tellomiAddressLine: "静安区南京西路789号兴业太古汇",
        )
        XCTAssertEqual(
            location.messageText,
            "星巴克臻选上海烘焙工坊\n静安区南京西路789号兴业太古汇\nhttps://maps.google.com/maps?q=31.2297%2C121.456",
        )
        let parsed = try XCTUnwrap(TellomiLocationMessage.parse(body: location.messageText))
        XCTAssertEqual(parsed.name, "星巴克臻选上海烘焙工坊")
        XCTAssertEqual(parsed.address, "静安区南京西路789号兴业太古汇")
        XCTAssertEqual(parsed.latitude, 31.2297)
        XCTAssertEqual(parsed.longitude, 121.456)
    }

    /// No address line from the list: one is made from the placemark (without the country).
    func testAPlaceWithoutAnAddressLineUsesThePlacemark() throws {
        let location = Location(name: "外滩", location: nil, placemark: Self.placemark(street: "中山东一路", city: "上海市"))
        let parsed = try XCTUnwrap(TellomiLocationMessage.parse(body: location.messageText))
        XCTAssertEqual(parsed.name, "外滩")
        let address = try XCTUnwrap(parsed.address)
        XCTAssertTrue(address.contains("中山东一路"), address)
        XCTAssertFalse(address.contains("中国"), address)
        XCTAssertFalse(address.contains("\n"), address)
    }

    func testNewlinesInTheNameOrAddressDoNotBreakTheFormat() throws {
        let location = Location(name: "Two\nLines", location: nil, placemark: Self.placemark(), tellomiAddressLine: "A\nB")
        XCTAssertEqual(location.messageText, "Two Lines\nA B\nhttps://maps.google.com/maps?q=31.2297%2C121.456")
        XCTAssertEqual(TellomiLocationMessage.parse(body: location.messageText)?.name, "Two Lines")
    }

    /// Current location / a point on the map: unchanged from upstream (address lines, blank line, link); no name.
    func testAPlainLocationKeepsUpstreamsFormat() throws {
        let location = Location(name: nil, location: nil, placemark: Self.placemark())
        let body = location.messageText
        XCTAssertTrue(body.hasSuffix("\n\nhttps://maps.google.com/maps?q=31.2297%2C121.456"), body)
        let parsed = try XCTUnwrap(TellomiLocationMessage.parse(body: body))
        XCTAssertNil(parsed.name)
        XCTAssertFalse(parsed.isPlace)

        let noAddress = Location(name: nil, location: nil, placemark: MKPlacemark(coordinate: Self.coordinate))
        XCTAssertEqual(noAddress.messageText, "https://maps.google.com/maps?q=31.2297%2C121.456")
        XCTAssertEqual(Location(name: "  ", location: nil, placemark: MKPlacemark(coordinate: Self.coordinate)).messageText, noAddress.messageText)
    }

    // MARK: - Pin

    func testThePinFollowsTheKindOfLocation() {
        let cafe = Location(name: "Cafe", location: nil, placemark: Self.placemark(), tellomiCategory: .cafe)
        let (cafeSymbol, cafeColor) = TellomiLocationIcons.category(.cafe)
        XCTAssertEqual(cafe.tellomiSnapshotPin.symbolName, cafeSymbol)
        XCTAssertTrue(Self.sameColor(cafe.tellomiSnapshotPin.color, cafeColor))
        // A place without a category and a plain location: the accent colour and a pin (Telegram: no type → accent).
        for location in [
            Location(name: "Somewhere", location: nil, placemark: Self.placemark()),
            Location(name: nil, location: nil, placemark: Self.placemark(), tellomiCategory: .cafe),
        ] {
            XCTAssertEqual(location.tellomiSnapshotPin.symbolName, "mappin")
            XCTAssertTrue(Self.sameColor(location.tellomiSnapshotPin.color, .Signal.accent))
        }
    }

    private static func sameColor(_ a: UIColor, _ b: UIColor) -> Bool {
        let light = UITraitCollection(userInterfaceStyle: .light)
        return a.resolvedColor(with: light).cgColor == b.resolvedColor(with: light).cgColor
    }

    // MARK: - Snapshot geometry (Telegram: 300 × 150, the balloon's centre 10 pt above the map's centre)

    func testTheTipIsBelowTheCentreSoTheBalloonCentresTenPointsAbove() {
        XCTAssertEqual(TellomiLocationSnapshot.size, CGSize(width: 300, height: 150))
        let tip = TellomiLocationSnapshot.tipPoint
        let balloonTop = tip.y - TellomiLocationSnapshot.pinTailLength - TellomiLocationSnapshot.pinHeadDiameter
        XCTAssertEqual(tip.x, 150)
        XCTAssertEqual((balloonTop + tip.y) / 2, 75 - 10, accuracy: 0.01)
    }

    /// The map's centre moves north by the tip's offset, so the point lands under the tip.
    func testTheMapCentreMovesNorthByTheTipsOffset() {
        let center = TellomiLocationSnapshot.mapCenter(forTipAt: Self.coordinate)
        XCTAssertEqual(center.longitude, Self.coordinate.longitude, accuracy: 1e-9)
        XCTAssertGreaterThan(center.latitude, Self.coordinate.latitude)
        // 150 pt of map is 0.003° of latitude; the tip is 16.5 pt below the centre.
        let offsetPoints = TellomiLocationSnapshot.tipPoint.y - 75
        XCTAssertEqual(center.latitude - Self.coordinate.latitude, 0.003 * offsetPoints / 150, accuracy: 0.00002)
    }

    func testTheRenderedPinSitsOnTheTip() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let gray = UIColor(white: 0.9, alpha: 1)
        let map = UIGraphicsImageRenderer(size: TellomiLocationSnapshot.size, format: format).image { context in
            gray.setFill()
            context.fill(CGRect(origin: .zero, size: TellomiLocationSnapshot.size))
        }
        let pin = TellomiLocationSnapshot.Pin(color: .systemRed, symbolName: "circle.fill")
        let tip = TellomiLocationSnapshot.tipPoint
        let image = TellomiLocationSnapshot.render(map: map, tip: tip, pin: pin)
        XCTAssertEqual(image.size, TellomiLocationSnapshot.size)
        XCTAssertEqual(image.scale, 2)

        let headCenterY = tip.y - TellomiLocationSnapshot.pinTailLength - TellomiLocationSnapshot.pinHeadDiameter / 2
        // On the balloon (left of the glyph): the pin colour.
        try assertColor(in: image, at: CGPoint(x: tip.x - 17, y: headCenterY), isClose: .systemRed)
        // Just above the tip, on the tail: the pin colour.
        try assertColor(in: image, at: CGPoint(x: tip.x, y: tip.y - 4), isClose: .systemRed)
        // The glyph in the middle of the head is white.
        try assertColor(in: image, at: CGPoint(x: tip.x, y: headCenterY - 4), isClose: .white)
        // Well away from the pin: the map.
        try assertColor(in: image, at: CGPoint(x: 20, y: 20), isClose: gray)
        try assertColor(in: image, at: CGPoint(x: tip.x + 40, y: tip.y), isClose: gray)
    }

    private func assertColor(in image: UIImage, at point: CGPoint, isClose expected: UIColor, file: StaticString = #filePath, line: UInt = #line) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        expected.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        let actual = pixel.prefix(3).map { CGFloat($0) / 255 }
        let distance = max(abs(actual[0] - r), abs(actual[1] - g), abs(actual[2] - b))
        XCTAssertLessThan(distance, 0.12, "\(point): \(actual) vs \([r, g, b])", file: file, line: line)
    }
}
