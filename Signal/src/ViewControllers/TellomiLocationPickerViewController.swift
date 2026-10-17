//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Contacts
import CoreLocation
import MapKit
import SignalServiceKit
import SignalUI

/// Tellomi（2026-10-17，TestFlight 0.1.0 (16) 反馈「位置功能缺少 Telegram 已有的能力」）：附件 Sheet 的「位置」页，
/// 照 Telegram iOS `LocationPickerController`（需求 `docs/product/specs/attachment-files-location.md` §3 L-3…L-8）：
/// - 上面是地图、下面是列表；列表往上滑时盖住地图（地图不缩小）；
/// - 第一行「发送我当前的位置」+「精确到 N 米」（单位按系统地区，`MKDistanceFormatter`）；定位没好时「正在定位…」；
///   没有定位权限时「未开启定位 · 去设置」（L-8：没权限也能拖地图、搜索、发选中的地点，同 Telegram Android）；
/// - 拖地图 = 选点：地图中心立一根大头针，拖动时抬起、停下落下；第一行变「发送这个位置」+ 反查出的地址；
/// - 「或者选择一个地点」：附近地点（MapKit 兴趣点；大陆数据来自高德，免 key、我们的服务端看不到位置），点一个立即发送；
///   地图拖到离上次查询 > 300 m 时出现「搜索此区域的地点」；
/// - 右上「地图类型」（地图 / 卫星 / 混合）与「回到我的位置」；
/// - 搜索：两组结果，「地图上的地址」（带「距离此地 X」）在前、「附近的地点」在后；点地址把地图移过去，点地点立即发送。
/// 发出去的消息格式不变（截图 + 地址 + 链接，上游 `Location`）——结构化位置消息等 ADR #1123；实时位置 owner 2026-09-23 定先不做（#1125）。
/// 只读了 Telegram 的源码弄清机制，代码是独立写的（GPLv2 与 AGPLv3 不兼容）。
final class TellomiLocationPickerViewController: OWSViewController {

    /// 选定要发的位置（发完由 Sheet 收起，见 `onFinish`）。
    var onPick: ((Location) -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let locationSource: TellomiLocationSource
    private let placeSearch: TellomiPlaceSearching

    init(locationSource: TellomiLocationSource = TellomiSystemLocationSource(), placeSearch: TellomiPlaceSearching = TellomiMapKitPlaceSearch()) {
        self.locationSource = locationSource
        self.placeSearch = placeSearch
        super.init()
    }

    // MARK: - State

    enum Mode: Equatable {
        /// 第一行发自己的位置。
        case currentLocation
        /// 第一行发地图中心（拖过地图或点了搜索里的地址）。
        case picked(CLLocationCoordinate2D)

        static func == (lhs: Mode, rhs: Mode) -> Bool {
            switch (lhs, rhs) {
            case (.currentLocation, .currentLocation): return true
            case let (.picked(a), .picked(b)): return a.latitude == b.latitude && a.longitude == b.longitude
            default: return false
            }
        }
    }

    enum PlacesState {
        case idle
        case loading
        case loaded([TellomiPlace])
        case empty
    }

    private(set) var mode: Mode = .currentLocation
    private(set) var placesState: PlacesState = .idle
    /// 选点的地址：nil = 还在反查（「正在定位…」）。
    private var pickedPlace: TellomiPlace?
    private var isResolvingPickedPlace = false
    /// 自己位置反查出的地址（发「当前位置」时带上；没查到也照样能发）。
    private var currentPlace: TellomiPlace?
    private var currentPlaceRequestedAt: CLLocation?
    private var lastPlacesCenter: CLLocation?
    private var hasCenteredOnUser = false
    fileprivate var isUserMovingMap = false
    private var geocodeTask: Task<Void, Never>?
    private var placesTask: Task<Void, Never>?

    /// 地图多高（列表顶上让出这么多，往上滑时列表盖住地图）。
    private var mapHeight: CGFloat { min(max(view.bounds.height * 0.4, 200), 360) }

    /// 默认跨度（Telegram：0.016°）。
    static let defaultSpan = MKCoordinateSpan(latitudeDelta: 0.016, longitudeDelta: 0.016)
    /// 拖到离上次查附近地点多远时出「搜索此区域的地点」（Telegram：300 m）。
    static let searchAreaDistance: CLLocationDistance = 300
    /// 自己移动多远时重查附近地点（Telegram：250 m）。
    static let refreshPlacesDistance: CLLocationDistance = 250

    // MARK: - Views

    private let mapView = MKMapView()
    private let centerPin = TellomiLocationCenterPin()
    private lazy var tableView: TellomiLocationListView = {
        let tableView = TellomiLocationListView(frame: .zero, style: .plain)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.register(TellomiLocationRowCell.self, forCellReuseIdentifier: TellomiLocationRowCell.reuseIdentifier)
        tableView.register(TellomiLocationSkeletonCell.self, forCellReuseIdentifier: TellomiLocationSkeletonCell.reuseIdentifier)
        tableView.estimatedRowHeight = 60
        return tableView
    }()

    private let tableHeaderSpacer = UIView()

    private lazy var mapTypeButton: UIButton = {
        let button = Self.makeRoundButton(symbol: "map")
        button.accessibilityLabel = OWSLocalizedString("LOCATION_PICKER_TELLOMI_MAP_TYPE", comment: "Accessibility label of the button that picks the map type (map, satellite, hybrid) in the location picker.")
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.mapTypeActions() ?? [])
        }])
        return button
    }()

    private lazy var myLocationButton: UIButton = {
        let button = Self.makeRoundButton(symbol: "location")
        button.accessibilityLabel = OWSLocalizedString("LOCATION_PICKER_TELLOMI_MY_LOCATION", comment: "Accessibility label of the button that moves the map back to the user's own location in the location picker.")
        button.addAction(UIAction { [weak self] _ in self?.didTapMyLocation() }, for: .primaryActionTriggered)
        return button
    }()

    private lazy var searchAreaButton: UIButton = {
        var configuration: UIButton.Configuration
        if #available(iOS 26, *) {
            configuration = .glass()
        } else {
            configuration = .filled()
            configuration.baseBackgroundColor = .Signal.background
        }
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .Signal.accent
        configuration.title = OWSLocalizedString("LOCATION_PICKER_TELLOMI_SEARCH_THIS_AREA", comment: "Button on the map in the location picker that looks up places around the map's center after the user moved the map.")
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.searchThisArea() })
        button.isHidden = true
        return button
    }()

    private lazy var searchResults: TellomiLocationSearchResultsController = {
        let results = TellomiLocationSearchResultsController()
        results.onSelectAddress = { [weak self] place in self?.didSelectSearchedAddress(place) }
        results.onSelectPlace = { [weak self] place in self?.send(place: place) }
        return results
    }()

    private lazy var searchController: UISearchController = {
        let searchController = UISearchController(searchResultsController: searchResults)
        searchController.searchResultsUpdater = self
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.placeholder = OWSLocalizedString("LOCATION_PICKER_SEARCH_PLACEHOLDER", comment: "A string indicating that the user can search for a location")
        return searchController
    }()

    private static func makeRoundButton(symbol: String) -> UIButton {
        var configuration: UIButton.Configuration
        if #available(iOS 26, *) {
            configuration = .glass()
        } else {
            configuration = .filled()
            configuration.baseBackgroundColor = .Signal.background
        }
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: symbol)
        configuration.baseForegroundColor = .Signal.accent
        let button = UIButton(configuration: configuration)
        button.autoSetDimensions(to: CGSize(square: 44))
        return button
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background
        title = OWSLocalizedString("LOCATION_PICKER_TITLE", comment: "The title for the location picker view")
        navigationItem.rightBarButtonItem = .closeButton { [weak self] in
            self?.onCancel?()
        }
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        if #available(iOS 13, *) {
            mapView.pointOfInterestFilter = .excludingAll
        }
        view.addSubview(mapView)
        mapView.autoPinEdge(toSuperviewSafeArea: .top)
        mapView.autoPinWidthToSuperview()
        mapHeightConstraint = mapView.autoSetDimension(.height, toSize: 200)

        // 认出「用户在拖地图」：和地图自己的手势一起识别
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didMoveMapByHand(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(didMoveMapByHand(_:)))
        for gesture in [pan, pinch] as [UIGestureRecognizer] {
            gesture.delegate = self
            mapView.addGestureRecognizer(gesture)
        }

        centerPin.isUserInteractionEnabled = false
        mapView.addSubview(centerPin)

        let buttons = UIStackView(arrangedSubviews: [mapTypeButton, myLocationButton])
        buttons.axis = .vertical
        buttons.spacing = 8
        mapView.addSubview(buttons)
        buttons.autoPinEdge(toSuperviewEdge: .trailing, withInset: 12)
        buttons.autoPinEdge(toSuperviewEdge: .top, withInset: 12)

        mapView.addSubview(searchAreaButton)
        searchAreaButton.autoHCenterInSuperview()
        searchAreaButton.autoPinEdge(toSuperviewEdge: .bottom, withInset: 12)

        tableView.tableHeaderView = tableHeaderSpacer
        view.addSubview(tableView)
        tableView.autoPinEdge(toSuperviewSafeArea: .top)
        tableView.autoPinWidthToSuperview()
        tableView.autoPinEdge(toSuperviewEdge: .bottom)

        locationSource.onChange = { [weak self] in self?.locationDidChange() }
        locationDidChange()
    }

    private var mapHeightConstraint: NSLayoutConstraint?
    private var hasRequestedAuthorization = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 上游一样：进来没问过就问「使用期间」（首次说明页 L-2 另做）
        if !hasRequestedAuthorization, locationSource.authorizationStatus == .notDetermined {
            hasRequestedAuthorization = true
            locationSource.requestWhenInUseAuthorization()
        }
        locationSource.startUpdating()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        locationSource.stopUpdating()
    }

    deinit {
        geocodeTask?.cancel()
        placesTask?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = mapHeight
        if mapHeightConstraint?.constant != height {
            mapHeightConstraint?.constant = height
        }
        if tableHeaderSpacer.frame.height != height {
            tableHeaderSpacer.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: height)
            tableView.tableHeaderView = tableHeaderSpacer
        }
        tableView.passThroughHeight = height
        tableView.contentInset.bottom = view.safeAreaInsets.bottom
        tableView.verticalScrollIndicatorInsets.bottom = view.safeAreaInsets.bottom
        // 大头针的尖端对准地图中心
        centerPin.frame = CGRect(
            x: mapView.bounds.midX - TellomiLocationCenterPin.size.width / 2,
            y: mapView.bounds.midY - TellomiLocationCenterPin.tipY,
            width: TellomiLocationCenterPin.size.width,
            height: TellomiLocationCenterPin.size.height,
        )
    }

    // MARK: - Location

    private var isLocationDenied: Bool {
        switch locationSource.authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    private func locationDidChange() {
        if let location = locationSource.location {
            if !hasCenteredOnUser, mode == .currentLocation {
                hasCenteredOnUser = true
                mapView.setRegion(MKCoordinateRegion(center: location.coordinate, span: Self.defaultSpan), animated: false)
            }
            // 第一次有位置、或者走出 250 m：重查附近地点、重查自己的地址
            if let last = lastPlacesCenter {
                if mode == .currentLocation, location.distance(from: last) > Self.refreshPlacesDistance {
                    loadPlaces(around: location.coordinate)
                }
            } else {
                loadPlaces(around: location.coordinate)
            }
            // 自己的地址：第一次、或者离上次反查的地方 > 50 m 才再查（定位约每秒更新一次，CLGeocoder 查得太勤会被限流）
            if currentPlaceRequestedAt.map({ location.distance(from: $0) > 50 }) ?? true {
                currentPlaceRequestedAt = location
                resolveCurrentPlace(location.coordinate)
            }
        }
        reloadSendRow()
    }

    private func resolveCurrentPlace(_ coordinate: CLLocationCoordinate2D) {
        Task { [weak self, placeSearch] in
            let place = await placeSearch.address(at: coordinate)
            await MainActor.run { self?.currentPlace = place }
        }
    }

    private func didTapMyLocation() {
        if isLocationDenied {
            openLocationSettings()
            return
        }
        setMode(.currentLocation)
        if let location = locationSource.location {
            mapView.setRegion(MKCoordinateRegion(center: location.coordinate, span: Self.defaultSpan), animated: true)
        } else {
            locationSource.requestWhenInUseAuthorization()
            locationSource.startUpdating()
        }
    }

    private func openLocationSettings() {
        UIApplication.shared.openSystemSettings()
    }

    // MARK: - Picking on the map

    @objc
    private func didMoveMapByHand(_ gesture: UIGestureRecognizer) {
        switch gesture.state {
        case .began:
            isUserMovingMap = true
            centerPin.setLifted(true, animated: true)
            setMode(.picked(mapView.centerCoordinate))
        case .ended, .cancelled, .failed:
            break
        default:
            break
        }
    }

    private func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        switch newMode {
        case .currentLocation:
            geocodeTask?.cancel()
            pickedPlace = nil
            isResolvingPickedPlace = false
            centerPin.isHidden = true
            searchAreaButton.isHidden = true
        case .picked:
            centerPin.isHidden = false
        }
        reloadSendRow()
    }

    /// 地图停下来：落下大头针、反查地图中心的地址。
    fileprivate func mapDidSettle() {
        guard isUserMovingMap else { return }
        isUserMovingMap = false
        centerPin.setLifted(false, animated: true)
        let center = mapView.centerCoordinate
        mode = .picked(center)
        resolvePickedPlace(center)
        updateSearchAreaButton(center: center)
        // 没有定位权限、一次都没查过附近地点：以第一次停下的地方为准
        if lastPlacesCenter == nil {
            loadPlaces(around: center)
        }
    }

    private func resolvePickedPlace(_ coordinate: CLLocationCoordinate2D) {
        geocodeTask?.cancel()
        pickedPlace = nil
        isResolvingPickedPlace = true
        reloadSendRow()
        geocodeTask = Task { [weak self, placeSearch] in
            let place = await placeSearch.address(at: coordinate)
            await MainActor.run {
                guard let self, !Task.isCancelled, self.mode == .picked(coordinate) else { return }
                self.pickedPlace = place
                self.isResolvingPickedPlace = false
                self.reloadSendRow()
            }
        }
    }

    private func updateSearchAreaButton(center: CLLocationCoordinate2D) {
        guard let last = lastPlacesCenter else {
            searchAreaButton.isHidden = true
            return
        }
        let distance = CLLocation(latitude: center.latitude, longitude: center.longitude).distance(from: last)
        searchAreaButton.isHidden = distance <= Self.searchAreaDistance
    }

    private func searchThisArea() {
        searchAreaButton.isHidden = true
        loadPlaces(around: mapView.centerCoordinate)
    }

    // MARK: - Nearby places

    private func loadPlaces(around coordinate: CLLocationCoordinate2D) {
        lastPlacesCenter = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        placesTask?.cancel()
        placesState = .loading
        reloadPlacesSection(animated: false)
        placesTask = Task { [weak self, placeSearch] in
            let places = (try? await placeSearch.nearbyPlaces(around: coordinate)) ?? []
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.placesState = places.isEmpty ? .empty : .loaded(places)
                self.reloadPlacesSection(animated: true)
            }
        }
    }

    // MARK: - Map type

    private func mapTypeActions() -> [UIMenuElement] {
        let types: [(MKMapType, String)] = [
            (.standard, OWSLocalizedString("LOCATION_PICKER_TELLOMI_MAP_STANDARD", comment: "Map type option in the location picker: the plain street map.")),
            (.satellite, OWSLocalizedString("LOCATION_PICKER_TELLOMI_MAP_SATELLITE", comment: "Map type option in the location picker: satellite imagery.")),
            (.hybrid, OWSLocalizedString("LOCATION_PICKER_TELLOMI_MAP_HYBRID", comment: "Map type option in the location picker: satellite imagery with street names.")),
        ]
        return types.map { type, title in
            UIAction(title: title, state: mapView.mapType == type ? .on : .off) { [weak self] _ in
                self?.mapView.mapType = type
            }
        }
    }

    // MARK: - Sending

    private func send(place: TellomiPlace) {
        send(Location(
            name: place.name,
            location: CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
            placemark: place.placemark,
            tellomiCategory: place.category,
            tellomiAddressLine: place.address,
        ))
    }

    private func send(_ location: Location) {
        onPick?(location)
        onFinish?()
    }

    private func didTapSendRow() {
        switch mode {
        case .currentLocation:
            if isLocationDenied {
                openLocationSettings()
                return
            }
            guard let location = locationSource.location else { return }
            // 发自己的位置不等反查：查到地址就带上，没查到只发坐标（Telegram 也只发坐标）
            let placemark = currentPlace?.placemark ?? MKPlacemark(coordinate: location.coordinate)
            send(Location(name: nil, location: location, placemark: placemark))
        case .picked(let coordinate):
            let placemark = pickedPlace?.placemark ?? MKPlacemark(coordinate: coordinate)
            send(Location(name: nil, location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), placemark: placemark))
        }
    }

    // MARK: - Search

    private func didSelectSearchedAddress(_ place: TellomiPlace) {
        searchController.isActive = false
        mapView.setRegion(MKCoordinateRegion(center: place.coordinate, span: Self.defaultSpan), animated: true)
        mode = .picked(place.coordinate)
        geocodeTask?.cancel()
        pickedPlace = place
        isResolvingPickedPlace = false
        centerPin.isHidden = false
        centerPin.setLifted(false, animated: false)
        updateSearchAreaButton(center: place.coordinate)
        reloadSendRow()
    }

    // MARK: - Rows

    fileprivate enum Section: Int, CaseIterable {
        case send
        case places
    }

    /// 第一行的样子（测试也用）。
    struct SendRow: Equatable {
        let title: String
        let subtitle: String
        let isEnabled: Bool
    }

    var sendRow: SendRow {
        switch mode {
        case .currentLocation:
            let title = OWSLocalizedString("LOCATION_PICKER_TELLOMI_SEND_CURRENT", comment: "First row of the location picker: sends the user's current location.")
            if isLocationDenied {
                return SendRow(title: title, subtitle: OWSLocalizedString("LOCATION_PICKER_TELLOMI_PERMISSION_OFF", comment: "Subtitle of the 'send my current location' row when location access is off. Tapping it opens Settings."), isEnabled: true)
            }
            guard let location = locationSource.location else {
                return SendRow(title: title, subtitle: Self.locatingText, isEnabled: false)
            }
            let accuracy = Self.distanceFormatter.string(fromDistance: max(1, location.horizontalAccuracy.rounded()))
            let format = OWSLocalizedString("LOCATION_PICKER_TELLOMI_ACCURATE_TO_FORMAT", comment: "Subtitle of the 'send my current location' row. Embeds {{ a distance such as '25 meters' }}.")
            return SendRow(title: title, subtitle: String(format: format, accuracy), isEnabled: true)
        case .picked:
            let title = OWSLocalizedString("LOCATION_PICKER_TELLOMI_SEND_THIS", comment: "First row of the location picker after the user moved the map: sends the location under the pin.")
            if isResolvingPickedPlace || isUserMovingMap {
                return SendRow(title: title, subtitle: Self.locatingText, isEnabled: !isUserMovingMap)
            }
            let subtitle = pickedPlace?.address ?? pickedPlace?.name ?? Self.coordinateText(mapView.centerCoordinate)
            return SendRow(title: title, subtitle: subtitle, isEnabled: true)
        }
    }

    private static var locatingText: String {
        OWSLocalizedString("LOCATION_PICKER_TELLOMI_LOCATING", comment: "Shown while the location or the address under the pin is not known yet.")
    }

    private static func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    static let distanceFormatter: MKDistanceFormatter = {
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .full
        return formatter
    }()

    private func reloadSendRow() {
        guard isViewLoaded else { return }
        // 还没上屏（表格还没取过数据）时只能整表重载
        guard tableView.window != nil else {
            tableView.reloadData()
            return
        }
        tableView.reloadRows(at: [IndexPath(row: 0, section: Section.send.rawValue)], with: .none)
    }

    private func reloadPlacesSection(animated: Bool) {
        guard isViewLoaded else { return }
        guard tableView.window != nil else {
            tableView.reloadData()
            return
        }
        tableView.reloadSections(IndexSet(integer: Section.places.rawValue), with: animated ? .automatic : .none)
    }
}

// MARK: - Table

extension TellomiLocationPickerViewController: UITableViewDataSource, UITableViewDelegate {

    static let skeletonRowCount = 8

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .send: return 1
        case .places:
            switch placesState {
            case .idle: return 0
            case .loading: return Self.skeletonRowCount
            // 末行是数据来源署名
            case .loaded(let places): return places.count + 1
            case .empty: return 1
            }
        case nil: return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard Section(rawValue: section) == .places else { return nil }
        if case .idle = placesState { return nil }
        return OWSLocalizedString("LOCATION_PICKER_TELLOMI_NEARBY_HEADER", comment: "Header above the list of nearby places in the location picker.")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .send:
            let cell = tableView.dequeueReusableCell(withIdentifier: TellomiLocationRowCell.reuseIdentifier, for: indexPath) as! TellomiLocationRowCell
            let row = sendRow
            cell.configure(
                icon: TellomiLocationIcons.circle(symbol: mode == .currentLocation ? "location.fill" : "mappin", color: .Signal.accent),
                title: row.title,
                subtitle: row.subtitle,
                titleColor: .Signal.accent,
            )
            cell.isUserInteractionEnabled = row.isEnabled
            cell.contentView.alpha = row.isEnabled ? 1 : 0.6
            return cell
        case .places:
            switch placesState {
            case .loading, .idle:
                return tableView.dequeueReusableCell(withIdentifier: TellomiLocationSkeletonCell.reuseIdentifier, for: indexPath)
            case .empty:
                let cell = tableView.dequeueReusableCell(withIdentifier: TellomiLocationRowCell.reuseIdentifier, for: indexPath) as! TellomiLocationRowCell
                cell.configureNote(OWSLocalizedString("LOCATION_PICKER_TELLOMI_NO_PLACES", comment: "Shown in the location picker when no places were found around the map's center."))
                return cell
            case .loaded(let places):
                let cell = tableView.dequeueReusableCell(withIdentifier: TellomiLocationRowCell.reuseIdentifier, for: indexPath) as! TellomiLocationRowCell
                if indexPath.row < places.count {
                    let place = places[indexPath.row]
                    let (symbol, color) = TellomiLocationIcons.category(place.category)
                    cell.configure(icon: TellomiLocationIcons.circle(symbol: symbol, color: color), title: place.name ?? "", subtitle: place.address ?? "", titleColor: .Signal.label)
                } else {
                    cell.configureNote(OWSLocalizedString("LOCATION_PICKER_TELLOMI_DATA_SOURCE", comment: "Last row of the nearby places list in the location picker: where the place data comes from."))
                }
                return cell
            }
        case nil:
            return UITableViewCell()
        }
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch Section(rawValue: indexPath.section) {
        case .send: return sendRow.isEnabled
        case .places:
            if case .loaded(let places) = placesState { return indexPath.row < places.count }
            return false
        case nil: return false
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .send:
            didTapSendRow()
        case .places:
            if case .loaded(let places) = placesState, indexPath.row < places.count {
                send(place: places[indexPath.row])
            }
        case nil:
            break
        }
    }
}

// MARK: - Map

extension TellomiLocationPickerViewController: MKMapViewDelegate, UIGestureRecognizerDelegate {
    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        // 手指还按在地图上（含松手后的惯性开始前）：算用户在拖
        let isTouching = mapView.gestureRecognizers?.contains { $0.state == .began || $0.state == .changed } ?? false
        if isTouching, !isUserMovingMap {
            isUserMovingMap = true
            centerPin.setLifted(true, animated: true)
            setMode(.picked(mapView.centerCoordinate))
        }
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        mapDidSettle()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Search

extension TellomiLocationPickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let term = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults.search(term, around: mapView.centerCoordinate, using: placeSearch)
    }
}

#if TESTABLE_BUILD
extension TellomiLocationPickerViewController {
    var placeNamesForTesting: [String] {
        if case .loaded(let places) = placesState { return places.compactMap(\.name) }
        return []
    }

    var isLoadingPlacesForTesting: Bool {
        if case .loading = placesState { return true }
        return false
    }

    var isShowingNoPlacesForTesting: Bool {
        if case .empty = placesState { return true }
        return false
    }

    var isSearchAreaButtonShownForTesting: Bool { !searchAreaButton.isHidden }
    var isCenterPinShownForTesting: Bool { !centerPin.isHidden }

    func tapSendRowForTesting() { didTapSendRow() }
    func tapPlaceForTesting(at index: Int) {
        tableView(tableView, didSelectRowAt: IndexPath(row: index, section: Section.places.rawValue))
    }

    /// 模拟用户把地图拖到 [coordinate] 松手。
    func moveMapByHandForTesting(to coordinate: CLLocationCoordinate2D) {
        isUserMovingMap = true
        setMode(.picked(coordinate))
        mapView.setCenter(coordinate, animated: false)
        mapDidSettle()
    }

    func selectSearchedAddressForTesting(_ place: TellomiPlace) { didSelectSearchedAddress(place) }
    func tapMyLocationForTesting() { didTapMyLocation() }
    var tableViewForTesting: UITableView { tableView }
}
#endif

// MARK: - Model and providers

/// 一个地点 / 地址。
struct TellomiPlace {
    let name: String?
    let address: String?
    let coordinate: CLLocationCoordinate2D
    let category: MKPointOfInterestCategory?
    let placemark: CLPlacemark

    init(name: String?, address: String?, coordinate: CLLocationCoordinate2D, category: MKPointOfInterestCategory?, placemark: CLPlacemark? = nil) {
        self.name = name
        self.address = address
        self.coordinate = coordinate
        self.category = category
        self.placemark = placemark ?? MKPlacemark(coordinate: coordinate)
    }

    init(mapItem: MKMapItem) {
        self.init(
            name: mapItem.name,
            address: Self.singleLineAddress(mapItem.placemark),
            coordinate: mapItem.placemark.coordinate,
            category: mapItem.pointOfInterestCategory,
            placemark: mapItem.placemark,
        )
    }

    init(placemark: CLPlacemark) {
        self.init(
            name: placemark.name,
            address: Self.singleLineAddress(placemark),
            coordinate: placemark.location?.coordinate ?? kCLLocationCoordinate2DInvalid,
            category: nil,
            placemark: placemark,
        )
    }

    private static let postalAddressFormatter = CNPostalAddressFormatter()

    static func singleLineAddress(_ placemark: CLPlacemark) -> String? {
        guard let postalAddress = placemark.postalAddress else { return nil }
        // 国家那一行不要（「中国, 重庆市 渝中区, …」→「重庆市 渝中区, …」）
        let country = postalAddress.country.trimmingCharacters(in: .whitespaces)
        let lines = postalAddressFormatter.string(from: postalAddress)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != country }
        return lines.isEmpty ? nil : lines.joined(separator: ", ")
    }
}

/// 定位（真机是 `CLLocationManager`）。
protocol TellomiLocationSource: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var location: CLLocation? { get }
    var onChange: (() -> Void)? { get set }
    func requestWhenInUseAuthorization()
    func startUpdating()
    func stopUpdating()
}

/// 附近地点、搜索、反查地址（真机是 MapKit：大陆数据来自高德，免 key，由手机直接问，我们的服务端看不到位置）。
protocol TellomiPlaceSearching: AnyObject {
    func nearbyPlaces(around coordinate: CLLocationCoordinate2D) async throws -> [TellomiPlace]
    func search(_ term: String, around coordinate: CLLocationCoordinate2D) async -> (addresses: [TellomiPlace], places: [TellomiPlace])
    func address(at coordinate: CLLocationCoordinate2D) async -> TellomiPlace?
}

final class TellomiSystemLocationSource: NSObject, TellomiLocationSource, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var latest: CLLocation?
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var location: CLLocation? { latest }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        latest = location
        onChange?()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        startUpdating()
        onChange?()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Logger.warn("location update failed: \(error)")
    }
}

final class TellomiMapKitPlaceSearch: TellomiPlaceSearching {
    /// 附近地点的范围（米）。
    static let nearbyRadius: CLLocationDistance = 500

    /// 兴趣点查询失败或者没结果时，用这几类关键词各搜一次再合起来（见 `nearbyPlaces`）。
    static let fallbackQueries: [String] = ["餐厅", "咖啡", "酒店", "商场", "公园", "地铁站"]
    /// 合起来以后最多列多少个。
    static let maxNearbyPlaces = 30

    func nearbyPlaces(around coordinate: CLLocationCoordinate2D) async throws -> [TellomiPlace] {
        let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: Self.nearbyRadius)
        request.pointOfInterestFilter = .includingAll
        var items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        if items.isEmpty {
            // 2026-10-17 模拟器实测：地图数据是高德（大陆）时 MKLocalPointsOfInterestRequest 一律报 MKError 5（GEOError -10），
            // 关键词搜索却正常（重庆「餐厅」「coffee」各 25 条）。所以兴趣点查询不行就按几类常见地点各搜一次、合起来按距离排。
            let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: Self.nearbyRadius * 2, longitudinalMeters: Self.nearbyRadius * 2)
            items = await withTaskGroup(of: [MKMapItem].self) { group in
                for query in Self.fallbackQueries {
                    group.addTask {
                        let request = MKLocalSearch.Request()
                        request.naturalLanguageQuery = query
                        request.region = region
                        request.resultTypes = .pointOfInterest
                        return (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
                    }
                }
                var all: [MKMapItem] = []
                for await batch in group {
                    all.append(contentsOf: batch)
                }
                return all
            }
        }
        var seen = Set<String>()
        return items
            .map(TellomiPlace.init(mapItem:))
            .filter { place in
                // 同一个地方可能被几类关键词都搜到；离得太远的（关键词搜索不严格按范围）不要
                let key = "\(place.name ?? "")|\(String(format: "%.4f,%.4f", place.coordinate.latitude, place.coordinate.longitude))"
                let distance = CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude).distance(from: center)
                return distance <= Self.nearbyRadius * 3 && seen.insert(key).inserted
            }
            .sorted { lhs, rhs in
                CLLocation(latitude: lhs.coordinate.latitude, longitude: lhs.coordinate.longitude).distance(from: center)
                    < CLLocation(latitude: rhs.coordinate.latitude, longitude: rhs.coordinate.longitude).distance(from: center)
            }
            .prefix(Self.maxNearbyPlaces)
            .map { $0 }
    }

    func search(_ term: String, around coordinate: CLLocationCoordinate2D) async -> (addresses: [TellomiPlace], places: [TellomiPlace]) {
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        async let addresses = items(term, region: region, types: .address)
        async let places = items(term, region: region, types: .pointOfInterest)
        return await (addresses, places)
    }

    private func items(_ term: String, region: MKCoordinateRegion, types: MKLocalSearch.ResultType) async -> [TellomiPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = term
        request.region = region
        request.resultTypes = types
        // 没有结果时 MapKit 报 placemarkNotFound：当成空
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.map(TellomiPlace.init(mapItem:))
    }

    func address(at coordinate: CLLocationCoordinate2D) async -> TellomiPlace? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let place = TellomiPlace(placemark: placemark)
        // 反查回来的点不一定正好在大头针下面：坐标用大头针的
        return TellomiPlace(name: place.name, address: place.address, coordinate: coordinate, category: nil, placemark: placemark)
    }
}

// MARK: - Views

/// 列表头上让出地图那一块：点在那一块上的触摸交给底下的地图。
final class TellomiLocationListView: UITableView {
    var passThroughHeight: CGFloat = 0

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // point 在 bounds 坐标里（含 contentOffset）；地图那一块在内容的 0..<passThroughHeight
        guard point.y >= passThroughHeight else { return false }
        return super.point(inside: point, with: event)
    }
}

/// 地图中心的大头针：拖地图时抬起，停下落下（Telegram `LocationMapNode` 选点针的做法）。
final class TellomiLocationCenterPin: UIView {
    static let size = CGSize(width: 40, height: 64)
    /// 针尖离顶部多远（对准地图中心的那一点）。
    static let tipY: CGFloat = 52

    private let head = UIView()
    private let dot = UIView()
    private let stick = UIView()
    private let shadow = UIView()
    private(set) var isLifted = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true

        shadow.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        shadow.frame = CGRect(x: 15, y: Self.tipY - 3, width: 10, height: 6)
        shadow.layer.cornerRadius = 3
        addSubview(shadow)

        stick.backgroundColor = .Signal.accent
        stick.frame = CGRect(x: 19, y: 28, width: 2, height: Self.tipY - 28)
        addSubview(stick)

        head.backgroundColor = .Signal.accent
        head.frame = CGRect(x: 6, y: 2, width: 28, height: 28)
        head.layer.cornerRadius = 14
        head.layer.shadowColor = UIColor.black.cgColor
        head.layer.shadowOpacity = 0.2
        head.layer.shadowRadius = 4
        head.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(head)

        dot.backgroundColor = .white
        dot.frame = CGRect(x: 10, y: 10, width: 8, height: 8)
        dot.layer.cornerRadius = 4
        head.addSubview(dot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setLifted(_ lifted: Bool, animated: Bool) {
        guard lifted != isLifted else { return }
        isLifted = lifted
        let changes = {
            let lift = lifted ? CGAffineTransform(translationX: 0, y: -10) : .identity
            self.head.transform = lift
            self.stick.transform = lift
            self.shadow.transform = lifted ? CGAffineTransform(scaleX: 1.6, y: 1.6) : .identity
            self.shadow.alpha = lifted ? 0.5 : 1
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        if lifted {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: changes)
        } else {
            UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: changes)
        }
    }
}

/// 图标在彩色圆里 + 标题 + 副标题。
final class TellomiLocationRowCell: UITableViewCell {
    static let reuseIdentifier = "TellomiLocationRowCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        backgroundColor = .Signal.background
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(icon: UIImage, title: String, subtitle: String, titleColor: UIColor) {
        var content = UIListContentConfiguration.subtitleCell()
        content.image = icon
        content.imageProperties.maximumSize = CGSize(square: 40)
        content.text = title
        content.textProperties.font = .dynamicTypeBody.semibold()
        content.textProperties.color = titleColor
        content.secondaryText = subtitle
        content.secondaryTextProperties.color = .Signal.secondaryLabel
        content.secondaryTextProperties.numberOfLines = 2
        contentConfiguration = content
        selectionStyle = .default
        accessibilityLabel = [title, subtitle].joined(separator: ", ")
    }

    func configureNote(_ text: String) {
        var content = UIListContentConfiguration.cell()
        content.text = text
        content.textProperties.font = .dynamicTypeFootnote
        content.textProperties.color = .Signal.secondaryLabel
        content.textProperties.alignment = .center
        contentConfiguration = content
        selectionStyle = .none
        accessibilityLabel = text
    }
}

/// 附近地点加载中：一行灰色占位（8 行，Telegram 的骨架）。
final class TellomiLocationSkeletonCell: UITableViewCell {
    static let reuseIdentifier = "TellomiLocationSkeletonCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .Signal.background
        selectionStyle = .none
        let color = UIColor.Signal.secondaryFill
        let circle = UIView()
        circle.backgroundColor = color
        circle.layer.cornerRadius = 20
        let title = UIView()
        title.backgroundColor = color
        title.layer.cornerRadius = 4
        let subtitle = UIView()
        subtitle.backgroundColor = color
        subtitle.layer.cornerRadius = 4
        for view in [circle, title, subtitle] {
            contentView.addSubview(view)
        }
        circle.autoSetDimensions(to: CGSize(square: 40))
        circle.autoPinEdge(toSuperviewMargin: .leading)
        circle.autoVCenterInSuperview()
        title.autoSetDimensions(to: CGSize(width: 140, height: 12))
        title.autoPinEdge(.leading, to: .trailing, of: circle, withOffset: 16)
        title.autoPinEdge(toSuperviewEdge: .top, withInset: 16)
        subtitle.autoSetDimensions(to: CGSize(width: 200, height: 10))
        subtitle.autoPinEdge(.leading, to: .leading, of: title)
        subtitle.autoPinEdge(.top, to: .bottom, of: title, withOffset: 10)
        subtitle.autoPinEdge(toSuperviewEdge: .bottom, withInset: 16)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 列表里的圆形彩色图标。
enum TellomiLocationIcons {
    static func circle(symbol: String, color: UIColor, diameter: CGFloat = 40) -> UIImage {
        let size = CGSize(square: diameter)
        let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: diameter * 0.42, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            if let glyph {
                let origin = CGPoint(x: (size.width - glyph.size.width) / 2, y: (size.height - glyph.size.height) / 2)
                glyph.draw(at: origin)
            }
        }
    }

    /// 地点类别 → 图标与底色（Telegram 按类别配色：餐饮橙、户外绿、购物黄、出行蓝…；这里用系统图标）。
    static func category(_ category: MKPointOfInterestCategory?) -> (String, UIColor) {
        let orange = UIColor(rgbHex: 0xFF9500)
        let green = UIColor(rgbHex: 0x34C759)
        let yellow = UIColor(rgbHex: 0xFFB300)
        let blue = UIColor(rgbHex: 0x1C9FFF)
        let red = UIColor(rgbHex: 0xFF3B30)
        let purple = UIColor(rgbHex: 0xAF52DE)
        let brown = UIColor(rgbHex: 0xA2845E)
        let gray = UIColor(rgbHex: 0x8E8E93)
        switch category {
        case .restaurant?: return ("fork.knife", orange)
        case .cafe?: return ("cup.and.saucer.fill", brown)
        case .bakery?: return ("birthday.cake.fill", orange)
        case .brewery?, .winery?, .nightlife?: return ("wineglass.fill", purple)
        case .foodMarket?, .store?: return ("bag.fill", yellow)
        case .hotel?: return ("bed.double.fill", purple)
        case .park?, .nationalPark?, .beach?, .campground?: return ("leaf.fill", green)
        case .publicTransport?: return ("tram.fill", blue)
        case .airport?: return ("airplane", blue)
        case .gasStation?, .evCharger?: return ("fuelpump.fill", blue)
        case .parking?, .carRental?: return ("car.fill", blue)
        case .hospital?, .pharmacy?: return ("cross.case.fill", red)
        case .school?, .university?, .library?: return ("graduationcap.fill", blue)
        case .museum?, .theater?, .movieTheater?: return ("building.columns.fill", purple)
        case .bank?, .atm?: return ("banknote.fill", green)
        case .fitnessCenter?, .stadium?: return ("figure.run", green)
        case .police?, .fireStation?: return ("shield.fill", red)
        case .postOffice?: return ("envelope.fill", blue)
        default: return ("mappin", gray)
        }
    }
}

/// 搜索结果：「地图上的地址」在前、「附近的地点」在后（Telegram `LocationSearchContainerNode`）。
final class TellomiLocationSearchResultsController: UITableViewController {
    var onSelectAddress: ((TellomiPlace) -> Void)?
    var onSelectPlace: ((TellomiPlace) -> Void)?

    private(set) var addresses: [TellomiPlace] = []
    private(set) var places: [TellomiPlace] = []
    private var term = ""
    private var center = CLLocationCoordinate2D()
    private var hasResults = false
    private var searchTask: Task<Void, Never>?

    /// 防抖（Telegram：1 s）。
    static let debounce: TimeInterval = 1.0

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(TellomiLocationRowCell.self, forCellReuseIdentifier: TellomiLocationRowCell.reuseIdentifier)
        tableView.backgroundColor = .Signal.background
    }

    func search(_ term: String, around center: CLLocationCoordinate2D, using placeSearch: TellomiPlaceSearching) {
        guard term != self.term else { return }
        self.term = term
        self.center = center
        searchTask?.cancel()
        addresses = []
        places = []
        hasResults = false
        tableView.reloadData()
        guard !term.isEmpty else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let results = await placeSearch.search(term, around: center)
            await MainActor.run {
                guard let self, !Task.isCancelled, self.term == term else { return }
                self.addresses = results.addresses
                self.places = results.places
                self.hasResults = true
                self.tableView.reloadData()
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            // 都没有结果：一行「没有找到」
            return addresses.isEmpty && places.isEmpty && hasResults ? 1 : addresses.count
        }
        return places.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0, !addresses.isEmpty {
            return OWSLocalizedString("LOCATION_PICKER_TELLOMI_SEARCH_ADDRESSES", comment: "Header of the address results when searching in the location picker.")
        }
        if section == 1, !places.isEmpty {
            return OWSLocalizedString("LOCATION_PICKER_TELLOMI_SEARCH_PLACES", comment: "Header of the place results when searching in the location picker.")
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TellomiLocationRowCell.reuseIdentifier, for: indexPath) as! TellomiLocationRowCell
        if indexPath.section == 0 {
            guard indexPath.row < addresses.count else {
                let format = OWSLocalizedString("LOCATION_PICKER_TELLOMI_SEARCH_NO_RESULTS_FORMAT", comment: "Shown when a search in the location picker found nothing. Embeds {{ the search term }}.")
                cell.configureNote(String(format: format, term))
                return cell
            }
            let place = addresses[indexPath.row]
            let distance = CLLocation(latitude: center.latitude, longitude: center.longitude)
                .distance(from: CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude))
            let format = OWSLocalizedString("LOCATION_PICKER_TELLOMI_DISTANCE_FROM_HERE_FORMAT", comment: "Subtitle of an address result in the location picker search. Embeds {{ a distance such as '2 kilometers' }}.")
            cell.configure(
                icon: TellomiLocationIcons.circle(symbol: "mappin", color: .Signal.accent),
                title: place.name ?? place.address ?? "",
                subtitle: String(format: format, TellomiLocationPickerViewController.distanceFormatter.string(fromDistance: distance)),
                titleColor: .Signal.label,
            )
        } else {
            let place = places[indexPath.row]
            let (symbol, color) = TellomiLocationIcons.category(place.category)
            cell.configure(icon: TellomiLocationIcons.circle(symbol: symbol, color: color), title: place.name ?? "", subtitle: place.address ?? "", titleColor: .Signal.label)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0, indexPath.row < addresses.count {
            onSelectAddress?(addresses[indexPath.row])
        } else if indexPath.section == 1, indexPath.row < places.count {
            onSelectPlace?(places[indexPath.row])
        }
    }
}
