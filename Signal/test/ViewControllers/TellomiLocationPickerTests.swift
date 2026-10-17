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

/// 附件 Sheet 的「位置」页（2026-10-17，照 Telegram `LocationPickerController`；需求 attachment-files-location.md §3 L-3…L-8）。
final class TellomiLocationPickerTests: SignalBaseTest {

    private let home = CLLocationCoordinate2D(latitude: 29.5630, longitude: 106.5516)

    // MARK: - 发送当前位置（L-4）

    /// 第一行「发送我当前的位置」+「精确到 N」（单位按系统地区）；点了马上发，不等反查地址（Telegram 也只发坐标）。
    @MainActor
    func testSendCurrentLocationShowsAccuracyAndSendsWithoutWaitingForTheAddress() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        hosted.source.update(CLLocation(coordinate: home, altitude: 0, horizontalAccuracy: 25, verticalAccuracy: 10, timestamp: Date()))

        let row = hosted.picker.sendRow
        XCTAssertEqual(row.title, "Send My Current Location")
        XCTAssertEqual(row.subtitle, String(format: "Accurate to %@", TellomiLocationPickerViewController.distanceFormatter.string(fromDistance: 25)))
        XCTAssertTrue(row.isEnabled)

        hosted.picker.tapSendRowForTesting()
        let sent = try XCTUnwrap(hosted.sent.first)
        XCTAssertEqual(sent.coordinate.latitude, home.latitude, accuracy: 1e-9)
        XCTAssertEqual(sent.coordinate.longitude, home.longitude, accuracy: 1e-9)
        XCTAssertNil(sent.name)
        XCTAssertEqual(hosted.finished, 1, "发完收起 Sheet")
    }

    /// 自己的地址不会每次定位更新都反查：离上次反查 > 50 m 才再查。
    @MainActor
    func testCurrentAddressIsNotLookedUpOnEveryUpdate() async throws {
        let search = FakePlaceSearch()
        let hosted = host(search: search)
        defer { hosted.tearDown() }
        for offset in [0.0, 0.00005, 0.0001, 0.00015] {
            hosted.source.update(CLLocation(latitude: home.latitude + offset, longitude: home.longitude))
        }
        try await waitUntil { search.addressCalls.count == 1 }
        hosted.source.update(CLLocation(latitude: home.latitude + 0.001, longitude: home.longitude))
        try await waitUntil { search.addressCalls.count == 2 }
    }

    /// 还没有定位：「正在定位…」，点不了。
    @MainActor
    func testWithoutAFixTheRowSaysLocatingAndIsDisabled() {
        let hosted = host()
        defer { hosted.tearDown() }
        XCTAssertEqual(hosted.picker.sendRow.subtitle, "Locating…")
        XCTAssertFalse(hosted.picker.sendRow.isEnabled)
        hosted.picker.tapSendRowForTesting()
        XCTAssertTrue(hosted.sent.isEmpty)
    }

    // MARK: - 没有权限（L-8）

    /// 拒绝了定位：第一行提示去设置；仍然能拖地图选点并发出去（同 Telegram Android，法律文档「拒绝只影响发送当前位置」）。
    @MainActor
    func testDeniedLocationStillAllowsPickingOnTheMap() async throws {
        let search = FakePlaceSearch()
        search.addressResult = TellomiPlace(name: "解放碑", address: "重庆市渝中区民权路", coordinate: home, category: nil)
        let hosted = host(status: .denied, search: search)
        defer { hosted.tearDown() }
        XCTAssertEqual(hosted.picker.sendRow.title, "Send My Current Location")
        XCTAssertEqual(hosted.picker.sendRow.subtitle, "Location access is off · Open Settings")
        XCTAssertTrue(hosted.picker.sendRow.isEnabled, "点了去设置")

        hosted.picker.moveMapByHandForTesting(to: home)
        XCTAssertEqual(hosted.picker.sendRow.title, "Send This Location")
        XCTAssertTrue(hosted.picker.isCenterPinShownForTesting, "地图中心立着大头针")
        try await waitUntil { hosted.picker.sendRow.subtitle == "重庆市渝中区民权路" }

        hosted.picker.tapSendRowForTesting()
        let sent = try XCTUnwrap(hosted.sent.first)
        XCTAssertEqual(sent.coordinate.latitude, home.latitude, accuracy: 1e-4)
        XCTAssertEqual(sent.coordinate.longitude, home.longitude, accuracy: 1e-4)
    }

    // MARK: - 附近地点（L-6）

    /// 有了自己的位置就查附近地点（先 8 行骨架）；点一个立即发，带名称。
    @MainActor
    func testNearbyPlacesLoadAroundTheUserAndTappingOneSendsIt() async throws {
        let search = FakePlaceSearch()
        search.nearbyResult = [
            TellomiPlace(name: "洪崖洞", address: "嘉陵江滨江路88号", coordinate: CLLocationCoordinate2D(latitude: 29.5629, longitude: 106.5774), category: .museum),
            TellomiPlace(name: "小面馆", address: "民生路", coordinate: CLLocationCoordinate2D(latitude: 29.5601, longitude: 106.5700), category: .restaurant),
        ]
        search.nearbyDelay = 0.2
        let hosted = host(search: search)
        defer { hosted.tearDown() }
        hosted.source.update(CLLocation(latitude: home.latitude, longitude: home.longitude))
        XCTAssertTrue(hosted.picker.isLoadingPlacesForTesting, "先是骨架")
        XCTAssertEqual(hosted.picker.tableViewForTesting.numberOfRows(inSection: 1), TellomiLocationPickerViewController.skeletonRowCount)
        try await waitUntil { hosted.picker.placeNamesForTesting == ["洪崖洞", "小面馆"] }
        XCTAssertEqual(search.nearbyCalls.count, 1)
        XCTAssertEqual(search.nearbyCalls.first?.latitude ?? 0, home.latitude, accuracy: 1e-9)
        XCTAssertEqual(hosted.picker.tableViewForTesting.numberOfRows(inSection: 1), 3, "两个地点 + 末行数据来源署名")

        hosted.picker.tapPlaceForTesting(at: 0)
        let sent = try XCTUnwrap(hosted.sent.first)
        XCTAssertEqual(sent.name, "洪崖洞")
        XCTAssertEqual(sent.coordinate.longitude, 106.5774, accuracy: 1e-9)
    }

    /// 附近没有地点：一行「附近没有已知地点」。
    @MainActor
    func testNoPlacesShowsTheEmptyNote() async throws {
        let hosted = host()
        defer { hosted.tearDown() }
        hosted.source.update(CLLocation(latitude: home.latitude, longitude: home.longitude))
        try await waitUntil { hosted.picker.isShowingNoPlacesForTesting }
        XCTAssertEqual(hosted.picker.tableViewForTesting.numberOfRows(inSection: 1), 1)
    }

    /// 地图拖到离上次查询 > 300 m：出「搜索此区域的地点」（Telegram：300 m）；点了以地图中心重查。100 m 不出。
    @MainActor
    func testMovingTheMapFarShowsSearchThisArea() async throws {
        let search = FakePlaceSearch()
        let hosted = host(search: search)
        defer { hosted.tearDown() }
        hosted.source.update(CLLocation(latitude: home.latitude, longitude: home.longitude))
        try await waitUntil { search.nearbyCalls.count == 1 }

        hosted.picker.moveMapByHandForTesting(to: CLLocationCoordinate2D(latitude: home.latitude + 0.0009, longitude: home.longitude))
        XCTAssertFalse(hosted.picker.isSearchAreaButtonShownForTesting, "约 100 m：不出")
        hosted.picker.moveMapByHandForTesting(to: CLLocationCoordinate2D(latitude: home.latitude + 0.01, longitude: home.longitude))
        XCTAssertTrue(hosted.picker.isSearchAreaButtonShownForTesting, "约 1.1 km：出")
    }

    // MARK: - 回到我的位置、搜索（L-3、L-7）

    /// 「回到我的位置」：第一行回到「发送我当前的位置」，大头针收起。
    @MainActor
    func testMyLocationGoesBackToTheCurrentLocationRow() {
        let hosted = host()
        defer { hosted.tearDown() }
        hosted.source.update(CLLocation(latitude: home.latitude, longitude: home.longitude))
        hosted.picker.moveMapByHandForTesting(to: CLLocationCoordinate2D(latitude: home.latitude + 0.01, longitude: home.longitude))
        XCTAssertEqual(hosted.picker.sendRow.title, "Send This Location")

        hosted.picker.tapMyLocationForTesting()
        XCTAssertEqual(hosted.picker.mode, .currentLocation)
        XCTAssertEqual(hosted.picker.sendRow.title, "Send My Current Location")
        XCTAssertFalse(hosted.picker.isCenterPinShownForTesting)
    }

    /// 搜索里点一个地址：地图移过去，第一行变「发送这个位置」+ 那个地址（不再反查）。
    @MainActor
    func testPickingASearchedAddressMakesItTheSendRow() throws {
        let search = FakePlaceSearch()
        let hosted = host(search: search)
        defer { hosted.tearDown() }
        let target = CLLocationCoordinate2D(latitude: 29.5800, longitude: 106.5300)
        hosted.picker.selectSearchedAddressForTesting(TellomiPlace(name: "观音桥", address: "重庆市江北区观音桥步行街", coordinate: target, category: nil))
        XCTAssertEqual(hosted.picker.mode, .picked(target))
        XCTAssertEqual(hosted.picker.sendRow.title, "Send This Location")
        XCTAssertEqual(hosted.picker.sendRow.subtitle, "重庆市江北区观音桥步行街")
        XCTAssertTrue(search.addressCalls.isEmpty, "地址已知，不反查")

        hosted.picker.tapSendRowForTesting()
        let sent = try XCTUnwrap(hosted.sent.first)
        XCTAssertEqual(sent.coordinate.latitude, target.latitude, accuracy: 1e-9)
    }

    /// 搜索结果：地址在前、地点在后；都没有时一行「没有找到」。
    @MainActor
    func testSearchResultsGroupAddressesBeforePlaces() async throws {
        let search = FakePlaceSearch()
        search.searchResult = (
            addresses: [TellomiPlace(name: "解放碑步行街", address: nil, coordinate: home, category: nil)],
            places: [TellomiPlace(name: "解放碑", address: "民权路", coordinate: home, category: .museum)],
        )
        let results = TellomiLocationSearchResultsController()
        results.loadViewIfNeeded()
        results.search("解放碑", around: home, using: search)
        try await waitUntil(timeout: TellomiLocationSearchResultsController.debounce + 2) { results.places.count == 1 }
        XCTAssertEqual(results.addresses.map(\.name), ["解放碑步行街"])
        XCTAssertEqual(results.tableView.numberOfRows(inSection: 0), 1)
        XCTAssertEqual(results.tableView.numberOfRows(inSection: 1), 1)
        XCTAssertEqual(results.tableView(results.tableView, titleForHeaderInSection: 0), "Addresses on the map")
        XCTAssertEqual(results.tableView(results.tableView, titleForHeaderInSection: 1), "Places nearby")

        search.searchResult = (addresses: [], places: [])
        results.search("没有这个地方", around: home, using: search)
        try await waitUntil(timeout: TellomiLocationSearchResultsController.debounce + 2) { results.tableView.numberOfRows(inSection: 0) == 1 }
        XCTAssertEqual(results.tableView.numberOfRows(inSection: 1), 0)
    }

    /// 地点类别有自己的图标与颜色，不认识的类别用通用大头针。
    func testCategoryIcons() {
        XCTAssertEqual(TellomiLocationIcons.category(.restaurant).0, "fork.knife")
        XCTAssertEqual(TellomiLocationIcons.category(.park).0, "leaf.fill")
        XCTAssertEqual(TellomiLocationIcons.category(nil).0, "mappin")
    }

    // MARK: - Screenshots

    /// 截图（TELLOMI_SHOTS=1）：当前位置 + 附近地点、拖过地图（发送这个位置 + 搜索此区域）、没有权限、附近没有地点。
    @MainActor
    func testScreenshots() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let screenSize = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first)
        let search = FakePlaceSearch()
        search.nearbyResult = [
            TellomiPlace(name: "洪崖洞", address: "重庆市渝中区嘉陵江滨江路88号", coordinate: CLLocationCoordinate2D(latitude: 29.5629, longitude: 106.5774), category: .museum),
            TellomiPlace(name: "解放碑步行街", address: "重庆市渝中区民权路", coordinate: CLLocationCoordinate2D(latitude: 29.5577, longitude: 106.5770), category: .store),
            TellomiPlace(name: "老火锅", address: "重庆市渝中区八一路", coordinate: CLLocationCoordinate2D(latitude: 29.5560, longitude: 106.5760), category: .restaurant),
            TellomiPlace(name: "山城咖啡", address: "重庆市渝中区五四路", coordinate: CLLocationCoordinate2D(latitude: 29.5590, longitude: 106.5740), category: .cafe),
            TellomiPlace(name: "人民公园", address: "重庆市渝中区新华路", coordinate: CLLocationCoordinate2D(latitude: 29.5600, longitude: 106.5790), category: .park),
        ]
        search.addressResult = TellomiPlace(name: nil, address: "重庆市渝中区沧白路", coordinate: home, category: nil)
        let hosted = host(width: screenSize.width, height: screenSize.height, search: search)
        hosted.source.update(CLLocation(coordinate: home, altitude: 0, horizontalAccuracy: 12, verticalAccuracy: 10, timestamp: Date()))
        try await waitUntil { !hosted.picker.placeNamesForTesting.isEmpty }
        try await Task.sleep(nanoseconds: 2_500_000_000) // 地图瓦片
        try save(render(hosted.window), name: "location-current.png", width: screenSize.width)

        hosted.picker.moveMapByHandForTesting(to: CLLocationCoordinate2D(latitude: home.latitude + 0.006, longitude: home.longitude))
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try save(render(hosted.window), name: "location-picked.png", width: screenSize.width)
        hosted.tearDown()

        let denied = host(width: screenSize.width, height: screenSize.height, status: .denied, search: FakePlaceSearch())
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try save(render(denied.window), name: "location-denied.png", width: screenSize.width)
        denied.tearDown()
    }

    // MARK: - Helpers

    private struct Hosted {
        let window: UIWindow
        let picker: TellomiLocationPickerViewController
        let source: FakeLocationSource
        let recorder: Recorder

        var sent: [Location] { recorder.sent }
        var finished: Int { recorder.finished }

        func tearDown() {
            window.isHidden = true
        }
    }

    private final class Recorder {
        var sent: [Location] = []
        var finished = 0
    }

    @MainActor
    private func host(width: CGFloat = 402, height: CGFloat = 874, status: CLAuthorizationStatus = .authorizedWhenInUse, search: FakePlaceSearch = FakePlaceSearch()) -> Hosted {
        let source = FakeLocationSource(status: status)
        let picker = TellomiLocationPickerViewController(locationSource: source, placeSearch: search)
        let recorder = Recorder()
        picker.onPick = { recorder.sent.append($0) }
        picker.onFinish = { recorder.finished += 1 }
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = OWSNavigationController(rootViewController: picker)
        window.isHidden = false
        window.layoutIfNeeded()
        return Hosted(window: window, picker: picker, source: source, recorder: recorder)
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

    @MainActor
    private func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func save(_ image: UIImage, name: String, width: CGFloat) throws {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }
}

// MARK: - Fakes

private final class FakeLocationSource: TellomiLocationSource {
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

private final class FakePlaceSearch: TellomiPlaceSearching {
    var nearbyResult: [TellomiPlace] = []
    var nearbyDelay: TimeInterval = 0
    var searchResult: (addresses: [TellomiPlace], places: [TellomiPlace]) = ([], [])
    var addressResult: TellomiPlace?
    private(set) var nearbyCalls: [CLLocationCoordinate2D] = []
    private(set) var addressCalls: [CLLocationCoordinate2D] = []

    func nearbyPlaces(around coordinate: CLLocationCoordinate2D) async throws -> [TellomiPlace] {
        nearbyCalls.append(coordinate)
        if nearbyDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(nearbyDelay * 1_000_000_000))
        }
        return nearbyResult
    }

    func search(_ term: String, around coordinate: CLLocationCoordinate2D) async -> (addresses: [TellomiPlace], places: [TellomiPlace]) {
        searchResult
    }

    func address(at coordinate: CLLocationCoordinate2D) async -> TellomiPlace? {
        addressCalls.append(coordinate)
        return addressResult
    }
}
