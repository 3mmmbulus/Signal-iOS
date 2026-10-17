//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreLocation
import MapKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// spec attachment-files-location L-11：点位置消息打开的位置详情（照 Telegram `LocationViewController` / `LocationInfoListItem` /
/// `OpenInOptions`）——地图、名称、「地址 • 距离」、驾车 / 步行要多久、「路线」只列本机装了的地图 App、分享 / 复制地址。
final class TellomiLocationViewTests: SignalBaseTest {

    private static let place = TellomiLocationMessage(latitude: 31.2297, longitude: 121.456, name: "星巴克臻选上海烘焙工坊", address: "静安区南京西路789号兴业太古汇")
    private static let plain = TellomiLocationMessage(latitude: 31.2297, longitude: 121.456, name: nil, address: nil)

    // MARK: - Map apps

    func testOnlyInstalledMapAppsAreListed_appleMapsFirstAndAlways() {
        XCTAssertEqual(TellomiMapApp.installed(canOpen: { _ in false }).map(\.kind), [.appleMaps])
        let installed = TellomiMapApp.installed(canOpen: { ["iosamap", "qqmap"].contains($0.scheme ?? "") })
        XCTAssertEqual(installed.map(\.kind), [.appleMaps, .amap, .tencent])
        XCTAssertEqual(TellomiMapApp.installed(canOpen: { _ in true }).map(\.kind), [.appleMaps, .amap, .baidu, .tencent, .google])
    }

    /// The schemes asked with `canOpenURL` are declared in Signal-Info.plist (otherwise iOS always says no).
    func testTheQuerySchemesAreDeclared() throws {
        let declared = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String])
        for kind in TellomiMapApp.Kind.allCases {
            if let scheme = TellomiMapApp(kind: kind).queryScheme {
                XCTAssertTrue(declared.contains(scheme), scheme)
            }
        }
    }

    func testDirectionsLinks() throws {
        func query(_ kind: TellomiMapApp.Kind, _ directions: TellomiMapApp.Directions?) throws -> (String, [String: String]) {
            let url = try XCTUnwrap(TellomiMapApp(kind: kind).url(for: Self.place, directions: directions, fallbackName: "Location"))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            return ("\(components.scheme ?? "")://\(components.host ?? "")\(components.path)", items)
        }

        var (base, items) = try query(.amap, .driving)
        XCTAssertEqual(base, "iosamap://path")
        XCTAssertEqual(items["dlat"], "31.229700")
        XCTAssertEqual(items["dlon"], "121.456000")
        XCTAssertEqual(items["dname"], "星巴克臻选上海烘焙工坊")
        XCTAssertEqual(items["dev"], "0")
        XCTAssertEqual(items["t"], "0")
        (_, items) = try query(.amap, .walking)
        XCTAssertEqual(items["t"], "2")
        (base, items) = try query(.amap, nil)
        XCTAssertEqual(base, "iosamap://viewMap")
        XCTAssertEqual(items["poiname"], "星巴克臻选上海烘焙工坊")

        (base, items) = try query(.baidu, .walking)
        XCTAssertEqual(base, "baidumap://map/direction")
        XCTAssertEqual(items["destination"], "name:星巴克臻选上海烘焙工坊|latlng:31.229700,121.456000")
        XCTAssertEqual(items["coord_type"], "gcj02")
        XCTAssertEqual(items["mode"], "walking")
        (base, items) = try query(.baidu, nil)
        XCTAssertEqual(base, "baidumap://map/marker")
        XCTAssertEqual(items["location"], "31.229700,121.456000")

        (base, items) = try query(.tencent, .driving)
        XCTAssertEqual(base, "qqmap://map/routeplan")
        XCTAssertEqual(items["type"], "drive")
        XCTAssertEqual(items["tocoord"], "31.229700,121.456000")
        (base, items) = try query(.tencent, nil)
        XCTAssertEqual(base, "qqmap://map/marker")
        XCTAssertEqual(items["marker"], "coord:31.229700,121.456000;title:星巴克臻选上海烘焙工坊;addr:静安区南京西路789号兴业太古汇")

        (_, items) = try query(.google, .walking)
        XCTAssertEqual(items["daddr"], "31.229700,121.456000")
        XCTAssertEqual(items["directionsmode"], "walking")

        XCTAssertNil(TellomiMapApp(kind: .appleMaps).url(for: Self.place, directions: .driving, fallbackName: "Location"))
        let item = TellomiMapApp(kind: .appleMaps).appleMapsItem(for: Self.plain, fallbackName: "Location")
        XCTAssertEqual(item.name, "Location")
        XCTAssertEqual(item.placemark.coordinate.latitude, 31.2297, accuracy: 1e-9)
    }

    // MARK: - The page

    @MainActor
    func testAPlaceShowsItsNameAddressAndDistance() async throws {
        let hosted = host(location: Self.place, status: .authorizedWhenInUse)
        defer { hosted.tearDown() }
        XCTAssertEqual(hosted.page.nameLabel.text, "星巴克臻选上海烘焙工坊")
        XCTAssertEqual(hosted.page.subtitleLabel.text, "静安区南京西路789号兴业太古汇")

        // 1.1 km away (units follow the region: kilometres in the US test region are miles… so only the shape is checked).
        hosted.source.update(CLLocation(latitude: 31.2397, longitude: 121.456))
        let subtitle = try XCTUnwrap(hosted.page.subtitleLabel.text)
        XCTAssertTrue(subtitle.hasPrefix("静安区南京西路789号兴业太古汇 • "), subtitle)
        XCTAssertTrue(subtitle.hasSuffix(" from here"), subtitle)

        // Within 10 m: "You are here".
        hosted.source.update(CLLocation(latitude: 31.22973, longitude: 121.456))
        XCTAssertEqual(hosted.page.subtitleLabel.text, "静安区南京西路789号兴业太古汇 • You are here")
    }

    @MainActor
    func testWithoutAnAddressItSaysLocatingThenLooksItUp() async throws {
        let search = FakeAddressLookup()
        search.result = TellomiPlace(name: nil, address: "南京西路789号", coordinate: Self.plain.coordinate, category: nil)
        search.delay = 0.3
        let hosted = host(location: Self.plain, status: .denied, search: search)
        defer { hosted.tearDown() }
        XCTAssertEqual(hosted.page.nameLabel.text, "Location")
        XCTAssertEqual(hosted.page.subtitleLabel.text, "Locating…")
        try await waitUntil { hosted.page.subtitleLabel.text == "南京西路789号" }
        XCTAssertEqual(search.calls, 1)
    }

    /// Without permission the page does not ask for it (the first-use page L-2 is in the picker), shows no distance, and has one
    /// "Get Directions" button.
    @MainActor
    func testWithoutPermissionNothingIsAskedAndThereIsOneGetDirectionsButton() async throws {
        let travel = FakeTravelTimes(driving: 600, walking: 1800)
        let hosted = host(location: Self.place, status: .notDetermined, travel: travel)
        defer { hosted.tearDown() }
        hosted.page.viewDidAppear(false)
        XCTAssertEqual(hosted.source.authorizationRequests, 0)
        XCTAssertFalse(hosted.page.mapView.showsUserLocation)
        XCTAssertEqual(hosted.page.subtitleLabel.text, "静安区南京西路789号兴业太古汇")
        XCTAssertEqual(travel.calls, 0)
        XCTAssertEqual(hosted.page.drivingTime, .unknown)
        hosted.window.layoutIfNeeded()
        XCTAssertFalse(hosted.page.drivingButton.isHidden)
        XCTAssertTrue(hosted.page.walkingButton.isHidden)
        XCTAssertEqual(hosted.page.drivingButton.configuration?.attributedTitle.map { String($0.characters) }, "Get Directions")
        XCTAssertEqual(hosted.page.drivingButton.frame.size.width, hosted.page.panel.frame.size.width - 60, accuracy: 0.5)
    }

    /// With permission: driving and walking times (Telegram `LocationInfoListItem` numbers: 52 high, 30 from the panel's sides,
    /// 10 apart, 18 under the subtitle; icon 40 at (20, 14), text from x = 72; the panel 6 from the screen's edges).
    @MainActor
    func testDrivingAndWalkingTimesAndTheLayout() async throws {
        let travel = FakeTravelTimes(driving: 600, walking: 1800)
        let hosted = host(location: Self.place, status: .authorizedWhenInUse, travel: travel)
        defer { hosted.tearDown() }
        hosted.source.update(CLLocation(latitude: 31.2397, longitude: 121.456))
        hosted.page.viewDidAppear(false)
        try await waitUntil { hosted.page.drivingTime == .ready(600) }
        hosted.window.layoutIfNeeded()

        let page = hosted.page
        XCTAssertEqual(travel.calls, 1)
        XCTAssertEqual(page.drivingButton.configuration?.attributedTitle.map { String($0.characters) }, TellomiLocationViewController.durationText(600))
        XCTAssertEqual(page.walkingButton.configuration?.attributedTitle.map { String($0.characters) }, TellomiLocationViewController.durationText(1800))
        XCTAssertFalse(page.walkingButton.isHidden)

        let panel = page.panel.frame
        XCTAssertEqual(panel.minX, 6)
        XCTAssertEqual(panel.maxX, hosted.window.bounds.size.width - 6)
        XCTAssertEqual(panel.maxY, hosted.window.bounds.size.height - 6)
        XCTAssertEqual(page.drivingButton.frame.size.height, 52)
        XCTAssertEqual(page.drivingButton.frame.minX, 30)
        XCTAssertEqual(page.walkingButton.frame.maxX, panel.size.width - 30, accuracy: 1)
        XCTAssertEqual(page.walkingButton.frame.minX - page.drivingButton.frame.maxX, 10, accuracy: 0.5)
        XCTAssertEqual(page.drivingButton.frame.minY - page.subtitleLabel.frame.maxY, 18, accuracy: 0.5)
        XCTAssertEqual(page.nameLabel.frame.minX, 72)
        XCTAssertEqual(page.nameLabel.frame.minY, 14)
        XCTAssertEqual(page.nameLabel.font.pointSize, 17)
        XCTAssertEqual(page.subtitleLabel.font.pointSize, 15)
        XCTAssertEqual(page.closeButton.frame, CGRect(x: 16, y: 16, width: 44, height: 44))
        XCTAssertEqual(page.shareButton.frame.maxX, hosted.window.bounds.size.width - 16)

        // The map: the pin on the location, which is in the middle of the map between the title bar and the panel.
        XCTAssertEqual(page.mapView.annotations.compactMap { $0 as? MKPointAnnotation }.first?.coordinate.latitude ?? 0, 31.2297, accuracy: 1e-9)
        let point = page.mapView.convert(Self.place.coordinate, toPointTo: page.view)
        XCTAssertEqual(point.x, page.view.bounds.midX, accuracy: 1.5)
        XCTAssertEqual(point.y, (page.closeButton.frame.maxY + panel.minY) / 2, accuracy: 1.5)
        // The span (Telegram `LocationMapNode.viewMapSpan`) fits that area.
        XCTAssertEqual(page.mapView.region.span.latitudeDelta, 0.008, accuracy: 0.004)
    }

    @MainActor
    func testOnlyAppleMaps_directionsOpenItStraightAway() async throws {
        var opened = [(TellomiMapApp.Kind, TellomiMapApp.Directions?)]()
        let hosted = host(location: Self.place, status: .denied, canOpen: { _ in false }, openApp: { opened.append(($0.kind, $1)) })
        defer { hosted.tearDown() }
        hosted.page.viewDidAppear(false)
        hosted.page.drivingButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, .appleMaps)
        XCTAssertEqual(opened.first?.1, .driving)
        XCTAssertNil(hosted.page.presentedViewController)
    }

    @MainActor
    func testSeveralApps_directionsListThem_andPickingOneOpensIt() async throws {
        var opened = [(TellomiMapApp.Kind, TellomiMapApp.Directions?)]()
        let hosted = host(location: Self.place, status: .denied, canOpen: { $0.scheme == "iosamap" || $0.scheme == "baidumap" }, openApp: { opened.append(($0.kind, $1)) })
        defer { hosted.tearDown() }
        hosted.page.viewDidAppear(false)
        hosted.page.drivingButton.sendActions(for: .primaryActionTriggered)
        let sheet = try XCTUnwrap(hosted.page.presentedViewController as? TellomiOpenInSheet)
        sheet.loadViewIfNeeded()
        XCTAssertEqual(sheet.optionButtons.map(\.accessibilityLabel), ["Apple Maps", "Amap", "Baidu Maps"])
        XCTAssertTrue(sheet.actionButtons.isEmpty)
        sheet.optionButtons[1].sendActions(for: .primaryActionTriggered)
        try await waitUntil(timeout: 3) { !opened.isEmpty }
        XCTAssertEqual(opened.first?.0, .amap)
        XCTAssertEqual(opened.first?.1, .driving)
    }

    /// Share = the apps + "Share" + "Copy Address" (Telegram: the apps + one share button).
    @MainActor
    func testShareListsTheAppsWithShareAndCopyAddress() async throws {
        let hosted = host(location: Self.place, status: .denied, canOpen: { _ in true })
        defer { hosted.tearDown() }
        hosted.page.shareButton.sendActions(for: .primaryActionTriggered)
        let sheet = try XCTUnwrap(hosted.page.presentedViewController as? TellomiOpenInSheet)
        sheet.loadViewIfNeeded()
        XCTAssertEqual(sheet.optionButtons.count, 5)
        XCTAssertEqual(sheet.actionButtons.map { $0.configuration?.attributedTitle.map { String($0.characters) } }, ["Share", "Copy Address"])
        XCTAssertEqual(hosted.page.shareText, "星巴克臻选上海烘焙工坊\n静安区南京西路789号兴业太古汇\nhttps://maps.google.com/maps?q=31.2297%2C121.456")
    }

    @MainActor
    func testCopyAddress() {
        let hosted = host(location: Self.place, status: .denied)
        defer { hosted.tearDown() }
        UIPasteboard.general.string = ""
        hosted.page.copyAddress()
        XCTAssertEqual(UIPasteboard.general.string, "星巴克臻选上海烘焙工坊 静安区南京西路789号兴业太古汇")
    }

    @MainActor
    func testSatelliteTurnsTheTitleWhite() {
        let hosted = host(location: Self.place, status: .denied)
        defer { hosted.tearDown() }
        hosted.page.setMapType(.satellite)
        XCTAssertEqual(hosted.page.mapView.mapType, .satellite)
        hosted.page.setMapType(.standard)
        XCTAssertEqual(hosted.page.mapView.mapType, .standard)
    }

    // MARK: - "Open in" sheet layout (Telegram `OpenInOptionsScreen`)

    @MainActor
    func testOpenInSheetLayout() throws {
        let sheet = TellomiOpenInSheet(apps: TellomiMapApp.installed(canOpen: { $0.scheme == "iosamap" }), actions: [
            .init(title: "Share", isPrimary: true) {},
        ]) { _ in }
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        window.rootViewController = sheet
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        XCTAssertEqual(sheet.optionButtons.count, 2)
        let first = sheet.optionButtons[0].frame, second = sheet.optionButtons[1].frame
        XCTAssertEqual(first.size, CGSize(width: 80, height: 112))
        XCTAssertEqual(second.minX - first.maxX, 64, "two apps are 64 apart")
        XCTAssertEqual((first.minX + second.maxX) / 2, 201, accuracy: 0.5, "centred")
        XCTAssertEqual(sheet.optionButtons[0].superview?.frame.minY, 82)
        let share = try XCTUnwrap(sheet.actionButtons.first)
        XCTAssertEqual(share.frame.size.height, 52)
        XCTAssertEqual(share.frame.minX, 30)
        XCTAssertEqual(share.frame.minY, 82 + 112 + 22)
    }

    // MARK: - Hosting

    private struct Hosted {
        let window: UIWindow
        let page: TellomiLocationViewController
        let source: FakeLocationViewSource

        func tearDown() {
            page.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
        }
    }

    @MainActor
    private func host(
        location: TellomiLocationMessage,
        status: CLAuthorizationStatus,
        search: FakeAddressLookup = FakeAddressLookup(),
        travel: FakeTravelTimes = FakeTravelTimes(driving: nil, walking: nil),
        canOpen: @escaping (URL) -> Bool = { _ in false },
        openApp: ((TellomiMapApp, TellomiMapApp.Directions?) -> Void)? = { _, _ in },
    ) -> Hosted {
        let source = FakeLocationViewSource(status: status)
        let page = TellomiLocationViewController(
            location: location,
            locationSource: source,
            placeSearch: search,
            travelTimes: travel,
            canOpenURL: canOpen,
            openApp: openApp,
        )
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = page
        window.isHidden = false
        window.layoutIfNeeded()
        return Hosted(window: window, page: page, source: source)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

// MARK: - Fakes

private final class FakeLocationViewSource: TellomiLocationSource {
    var authorizationStatus: CLAuthorizationStatus
    var location: CLLocation?
    var onChange: (() -> Void)?
    var authorizationRequests = 0

    init(status: CLAuthorizationStatus) {
        authorizationStatus = status
    }

    func requestWhenInUseAuthorization() {
        authorizationRequests += 1
    }

    func startUpdating() {}
    func stopUpdating() {}

    func update(_ location: CLLocation) {
        self.location = location
        onChange?()
    }
}

private final class FakeAddressLookup: TellomiPlaceSearching {
    var result: TellomiPlace?
    var delay: TimeInterval = 0
    private(set) var calls = 0

    func nearbyPlaces(around coordinate: CLLocationCoordinate2D) async throws -> [TellomiPlace] { [] }

    func search(_ term: String, around coordinate: CLLocationCoordinate2D) async -> (addresses: [TellomiPlace], places: [TellomiPlace]) { ([], []) }

    func address(at coordinate: CLLocationCoordinate2D) async -> TellomiPlace? {
        calls += 1
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return result
    }
}

@MainActor
private final class FakeTravelTimes: TellomiTravelTimeProviding {
    let driving: TimeInterval?
    let walking: TimeInterval?
    private(set) var calls = 0

    init(driving: TimeInterval?, walking: TimeInterval?) {
        self.driving = driving
        self.walking = walking
    }

    func travelTimes(to coordinate: CLLocationCoordinate2D) async -> (driving: TimeInterval?, walking: TimeInterval?) {
        calls += 1
        return (driving, walking)
    }
}
