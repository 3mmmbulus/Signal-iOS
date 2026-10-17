//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import MapKit
import SignalServiceKit
import SignalUI

/// 估算到这里要多久（驾车、步行，同时问）；真机是 `MKDirections.calculateETA`（Telegram `getExpectedTravelTime`），测试里换掉。
@MainActor
protocol TellomiTravelTimeProviding: AnyObject {
    func travelTimes(to coordinate: CLLocationCoordinate2D) async -> (driving: TimeInterval?, walking: TimeInterval?)
}

@MainActor
final class TellomiMapKitTravelTimes: TellomiTravelTimeProviding {
    func travelTimes(to coordinate: CLLocationCoordinate2D) async -> (driving: TimeInterval?, walking: TimeInterval?) {
        let driving = Task { await Self.travelTime(to: coordinate, transportType: .automobile) }
        let walking = Task { await Self.travelTime(to: coordinate, transportType: .walking) }
        return (await driving.value, await walking.value)
    }

    private static func travelTime(to coordinate: CLLocationCoordinate2D, transportType: MKDirectionsTransportType) async -> TimeInterval? {
        let request = MKDirections.Request()
        request.source = .forCurrentLocation()
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        request.transportType = transportType
        request.requestsAlternateRoutes = false
        return try? await MKDirections(request: request).calculateETA().expectedTravelTime
    }
}

/// Tellomi（spec attachment-files-location L-11）：点聊天里的位置消息打开的位置详情。
///
/// 照 Telegram `LocationViewController` / `LocationViewControllerNode` / `LocationInfoListItem`（独立实现）：
/// - 整屏地图，以这个点为中心、跨度 0.008°（`LocationMapNode.viewMapSpan`），点上一个气球大头针；
/// - 左上关闭、右上分享（玻璃圆钮 44，距边 16），中间标题「位置」（semibold 17）；右侧地图类型、回到这个点；
/// - 底部玻璃面板（距屏幕边 6，上圆角 38，下圆角随屏幕）：图标 40（左 20 / 上 14）、名称（semibold 17，没有名称写「位置」）、
///   「地址 • 距离」（regular 15；不到 10 米写「你在这里」；没有地址先写「正在定位…」再反查）；
///   下面两个按钮（高 52、左右 30、间距 10）：驾车 / 步行要多久（`MKDirections.calculateETA`），都算不出时一个「获取路线」；
/// - 「路线」只列本机装了的地图 App（`TellomiMapApp`）；只有苹果地图时直接打开。
/// - 分享 = 同一个「用…打开」+「分享」「复制地址」（Telegram 的分享也是先列 App 再加一个分享按钮）。
/// 没有定位权限时不在这里申请（首次说明页 L-2 在位置页）：不显示距离，路线按钮写「获取路线」。
final class TellomiLocationViewController: UIViewController, MKMapViewDelegate {

    enum TravelTime: Equatable {
        case calculating
        case unknown
        case ready(TimeInterval)
    }

    let location: TellomiLocationMessage
    private let locationSource: TellomiLocationSource
    private let placeSearch: TellomiPlaceSearching
    private let travelTimes: TellomiTravelTimeProviding
    private let canOpenURL: (URL) -> Bool
    private let openApp: (TellomiMapApp, TellomiMapApp.Directions?) -> Void

    init(
        location: TellomiLocationMessage,
        locationSource: TellomiLocationSource = TellomiSystemLocationSource(),
        placeSearch: TellomiPlaceSearching = TellomiMapKitPlaceSearch(),
        travelTimes: TellomiTravelTimeProviding = TellomiMapKitTravelTimes(),
        canOpenURL: @escaping (URL) -> Bool = { UIApplication.shared.canOpenURL($0) },
        openApp: ((TellomiMapApp, TellomiMapApp.Directions?) -> Void)? = nil,
    ) {
        self.location = location
        self.locationSource = locationSource
        self.placeSearch = placeSearch
        self.travelTimes = travelTimes
        self.canOpenURL = canOpenURL
        self.openApp = openApp ?? { app, directions in
            app.open(location, directions: directions, fallbackName: Self.locationTitle)
        }
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static var locationTitle: String {
        OWSLocalizedString("ATTACHMENT_KEYBOARD_LOCATION", comment: "A button to select a location from the Attachment Keyboard")
    }

    // MARK: - State

    private(set) var drivingTime: TravelTime = .calculating
    private(set) var walkingTime: TravelTime = .calculating
    private(set) var address: String?
    private var addressTask: Task<Void, Never>?
    private var travelTimeTask: Task<Void, Never>?

    var isLocationAuthorized: Bool {
        switch locationSource.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    // MARK: - Views

    let mapView = MKMapView()
    private let annotation = MKPointAnnotation()
    private let topFade = UIView()
    private let topFadeLayer = CAGradientLayer()
    private let titleLabel = UILabel()
    private(set) lazy var closeButton = Self.makeGlassButton(symbol: "xmark", accessibilityLabel: CommonStrings.dismissButton) { [weak self] in
        self?.dismiss(animated: true)
    }
    private(set) lazy var shareButton = Self.makeGlassButton(symbol: "square.and.arrow.up", accessibilityLabel: CommonStrings.shareButton) { [weak self] in
        self?.didTapShare()
    }
    private(set) lazy var mapTypeButton: UIButton = {
        let button = Self.makeGlassButton(
            symbol: "map",
            accessibilityLabel: OWSLocalizedString("LOCATION_PICKER_TELLOMI_MAP_TYPE", comment: "Accessibility label of the button that picks the map type (map, satellite, hybrid) in the location picker."),
            action: nil,
        )
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.mapTypeActions() ?? [])
        }])
        return button
    }()
    private(set) lazy var recenterButton = Self.makeGlassButton(
        symbol: "scope",
        accessibilityLabel: OWSLocalizedString("LOCATION_VIEW_TELLOMI_SHOW_LOCATION", comment: "Accessibility label of the button that moves the map back to the shared location on the location details page."),
    ) { [weak self] in
        self?.recenter(animated: true)
    }

    let panel: UIVisualEffectView = {
        if #available(iOS 26, *) {
            return UIVisualEffectView(effect: UIGlassEffect())
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    }()
    private let infoButton = UIControl()
    private let iconView = UIImageView()
    let nameLabel = UILabel()
    let subtitleLabel = UILabel()
    private(set) lazy var drivingButton = Self.makeDirectionsButton { [weak self] in self?.didTapDirections(.driving) }
    private(set) lazy var walkingButton = Self.makeDirectionsButton { [weak self] in self?.didTapDirections(.walking) }
    private let placeholderViews = [UIView(), UIView()]

    // MARK: - Layout constants (Telegram `LocationInfoListItem` / `LocationViewControllerNode`)

    static let panelInset: CGFloat = 6
    static let panelTopRadius: CGFloat = 38
    static let iconFrame = CGRect(x: 20, y: 14, width: 40, height: 40)
    static let textLeft: CGFloat = 72
    static let textTop: CGFloat = 14
    static let directionsTopSpacing: CGFloat = 18
    static let directionsHeight: CGFloat = 52
    static let directionsSideInset: CGFloat = 30
    static let directionsSpacing: CGFloat = 10
    static let bottomInset: CGFloat = 16
    static let mapSpan = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background

        mapView.delegate = self
        // margins 只算标题栏和面板（安全区已经在里面了），苹果的标志和「法律信息」也排在面板上面。
        mapView.insetsLayoutMarginsFromSafeArea = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsUserLocation = isLocationAuthorized
        mapView.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: Self.pinReuseIdentifier)
        annotation.coordinate = location.coordinate
        annotation.title = location.name
        mapView.addAnnotation(annotation)
        view.addSubview(mapView)

        topFadeLayer.colors = [UIColor.Signal.background.withAlphaComponent(0.65).cgColor, UIColor.Signal.background.withAlphaComponent(0).cgColor]
        topFade.layer.addSublayer(topFadeLayer)
        topFade.isUserInteractionEnabled = false
        view.addSubview(topFade)

        titleLabel.text = Self.locationTitle
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .Signal.label
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        view.addSubview(shareButton)
        view.addSubview(mapTypeButton)
        view.addSubview(recenterButton)

        if #available(iOS 26, *) {
            panel.cornerConfiguration = .uniformEdges(topRadius: .fixed(Self.panelTopRadius), bottomRadius: .containerConcentric(minimum: 22))
        } else {
            panel.layer.cornerRadius = Self.panelTopRadius
            panel.layer.cornerCurve = .continuous
            panel.clipsToBounds = true
        }
        view.addSubview(panel)

        iconView.image = TellomiLocationIcons.circle(symbol: "mappin", color: .Signal.accent, diameter: Self.iconFrame.width)
        infoButton.addSubview(iconView)
        nameLabel.text = location.name ?? Self.locationTitle
        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        nameLabel.textColor = .Signal.label
        infoButton.addSubview(nameLabel)
        subtitleLabel.font = .systemFont(ofSize: 15)
        subtitleLabel.textColor = .Signal.secondaryLabel
        infoButton.addSubview(subtitleLabel)
        infoButton.isAccessibilityElement = true
        infoButton.accessibilityTraits = .button
        infoButton.addAction(UIAction { [weak self] _ in self?.recenter(animated: true) }, for: .primaryActionTriggered)
        infoButton.addInteraction(UIContextMenuInteraction(delegate: self))
        panel.contentView.addSubview(infoButton)

        for placeholder in placeholderViews {
            placeholder.backgroundColor = .Signal.secondaryFill
            placeholder.layer.cornerRadius = Self.directionsHeight / 2
            placeholder.layer.cornerCurve = .continuous
            panel.contentView.addSubview(placeholder)
        }
        panel.contentView.addSubview(drivingButton)
        panel.contentView.addSubview(walkingButton)

        address = location.address
        updateInfo()
        updateDirections()

        locationSource.onChange = { [weak self] in self?.updateInfo() }
        if address == nil {
            resolveAddress()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if isLocationAuthorized {
            locationSource.startUpdating()
        }
        calculateTravelTimes()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        locationSource.stopUpdating()
    }

    deinit {
        addressTask?.cancel()
        travelTimeTask?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        mapView.frame = bounds

        topFade.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 80)
        topFadeLayer.frame = topFade.bounds

        closeButton.frame = CGRect(x: 16 + view.safeAreaInsets.left, y: 16, width: 44, height: 44)
        shareButton.frame = CGRect(x: bounds.width - 16 - 44 - view.safeAreaInsets.right, y: 16, width: 44, height: 44)
        let titleSize = titleLabel.sizeThatFits(CGSize(width: bounds.width - 2 * (16 + 44 + 8), height: 40))
        titleLabel.frame = CGRect(x: (bounds.width - titleSize.width) / 2, y: closeButton.frame.midY - titleSize.height / 2, width: titleSize.width, height: titleSize.height)
        mapTypeButton.frame = CGRect(x: shareButton.frame.minX, y: shareButton.frame.maxY + 12, width: 44, height: 44)
        recenterButton.frame = CGRect(x: shareButton.frame.minX, y: mapTypeButton.frame.maxY + 8, width: 44, height: 44)

        let panelWidth = bounds.width - Self.panelInset * 2
        let textWidth = panelWidth - Self.textLeft - 15
        let nameHeight = ceil(nameLabel.font.lineHeight)
        let subtitleHeight = ceil(subtitleLabel.font.lineHeight)
        let infoHeight = max(Self.iconFrame.maxY, Self.textTop + nameHeight + subtitleHeight) + 4
        infoButton.frame = CGRect(x: 0, y: 0, width: panelWidth, height: infoHeight)
        iconView.frame = Self.iconFrame
        nameLabel.frame = CGRect(x: Self.textLeft, y: Self.textTop, width: textWidth, height: nameHeight)
        subtitleLabel.frame = CGRect(x: Self.textLeft, y: nameLabel.frame.maxY, width: textWidth, height: subtitleHeight)

        let directionsY = subtitleLabel.frame.maxY + Self.directionsTopSpacing
        let rowWidth = panelWidth - Self.directionsSideInset * 2
        let halfWidth = floor((rowWidth - Self.directionsSpacing) / 2)
        let showsTwo = !walkingButton.isHidden
        drivingButton.frame = CGRect(x: Self.directionsSideInset, y: directionsY, width: showsTwo ? halfWidth : rowWidth, height: Self.directionsHeight)
        walkingButton.frame = CGRect(x: Self.directionsSideInset + halfWidth + Self.directionsSpacing, y: directionsY, width: halfWidth, height: Self.directionsHeight)
        placeholderViews[0].frame = CGRect(x: Self.directionsSideInset, y: directionsY, width: halfWidth, height: Self.directionsHeight)
        placeholderViews[1].frame = CGRect(x: Self.directionsSideInset + halfWidth + Self.directionsSpacing, y: directionsY, width: halfWidth, height: Self.directionsHeight)

        let bottomPadding = Self.bottomInset + max(0, view.safeAreaInsets.bottom - Self.panelInset)
        let panelHeight = directionsY + Self.directionsHeight + bottomPadding
        panel.frame = CGRect(x: Self.panelInset, y: bounds.height - Self.panelInset - panelHeight, width: panelWidth, height: panelHeight)

        // 这个点在面板上方的地图里居中；面板高度变了（路线按钮出来了）时重新放一下。
        if lastEdgePadding != mapEdgePadding {
            lastEdgePadding = mapEdgePadding
            mapView.layoutMargins = mapEdgePadding
            if !hasMovedMap {
                recenter(animated: false)
            }
        }
    }

    private var lastEdgePadding = UIEdgeInsets.zero
    /// 用户自己拖过地图以后，面板变高不再把地图拉回来。
    private var hasMovedMap = false

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        if mapView.subviews.first?.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true {
            hasMovedMap = true
        }
    }

    // MARK: - Map

    private static let pinReuseIdentifier = "TellomiLocationViewController.pin"

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation === self.annotation else {
            return nil
        }
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.pinReuseIdentifier, for: annotation)
        let image = Self.pinImage
        view.image = image
        // 尖落在这个点上（图的最下面留了影子的位置）。
        view.centerOffset = CGPoint(x: 0, y: -(image.size.height / 2 - Self.pinImageShadowSpace))
        view.canShowCallout = false
        return view
    }

    private static let pinImageShadowSpace: CGFloat = 4

    /// 和气泡里的地图同一个气球大头针（`TellomiLocationSnapshot.drawPin`）。
    static var pinImage: UIImage {
        let headDiameter = TellomiLocationSnapshot.pinHeadDiameter
        let size = CGSize(width: headDiameter + 12, height: headDiameter + TellomiLocationSnapshot.pinTailLength + 6 + pinImageShadowSpace)
        return UIGraphicsImageRenderer(size: size).image { context in
            TellomiLocationSnapshot.drawPin(
                .location,
                tip: CGPoint(x: size.width / 2, y: size.height - pinImageShadowSpace),
                in: context.cgContext,
            )
        }
    }

    /// 以这个点为中心、跨度 0.008°，居中在标题下、面板上的那块地图里（`setRegion` 在地图的 layoutMargins 里居中，
    /// margins 就是标题栏和面板挡住的部分）。
    func recenter(animated: Bool) {
        mapView.setRegion(MKCoordinateRegion(center: location.coordinate, span: Self.mapSpan), animated: animated)
    }

    /// 地图上被标题栏和面板挡住的部分。
    private var mapEdgePadding: UIEdgeInsets {
        guard panel.frame.height > 0 else { return .zero }
        return UIEdgeInsets(top: closeButton.frame.maxY, left: 0, bottom: view.bounds.height - panel.frame.minY, right: 0)
    }

    private func mapTypeActions() -> [UIMenuElement] {
        let types: [(MKMapType, String)] = [
            (.standard, OWSLocalizedString("LOCATION_PICKER_TELLOMI_MAP_STANDARD", comment: "Map type option in the location picker: the plain street map.")),
            (.satellite, OWSLocalizedString("LOCATION_PICKER_TELLOMI_MAP_SATELLITE", comment: "Map type option in the location picker: satellite imagery.")),
            (.hybrid, OWSLocalizedString("LOCATION_PICKER_TELLOMI_MAP_HYBRID", comment: "Map type option in the location picker: satellite imagery with street names.")),
        ]
        return types.map { type, title in
            UIAction(title: title, state: mapView.mapType == type ? .on : .off) { [weak self] _ in
                self?.setMapType(type)
            }
        }
    }

    /// 卫星图上标题换成白色（Telegram：卫星 / 混合时界面换深色）。
    func setMapType(_ type: MKMapType) {
        mapView.mapType = type
        titleLabel.textColor = type == .standard ? .Signal.label : .white
        topFade.isHidden = type != .standard
    }

    // MARK: - Info

    /// 「地址 • 距离」。
    var subtitleText: String {
        var components = [String]()
        components.append(address ?? OWSLocalizedString("LOCATION_PICKER_TELLOMI_LOCATING", comment: "Shown while the location or the address under the pin is not known yet."))
        if let distance = distanceText {
            components.append(distance)
        }
        return components.joined(separator: " • ")
    }

    /// 离我多远：不到 10 米写「你在这里」；不知道我在哪（没权限 / 还没定到位）时没有。单位按系统地区。
    var distanceText: String? {
        guard isLocationAuthorized, let userLocation = locationSource.location else {
            return nil
        }
        let distance = userLocation.distance(from: CLLocation(latitude: location.latitude, longitude: location.longitude))
        if distance < 10 {
            return OWSLocalizedString("LOCATION_VIEW_TELLOMI_YOU_ARE_HERE", comment: "On the location details page, shown instead of a distance when the user is at the shared location.")
        }
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        let format = OWSLocalizedString("LOCATION_PICKER_TELLOMI_DISTANCE_FROM_HERE_FORMAT", comment: "Subtitle of an address result in the location picker search. Embeds {{ a distance such as '2 kilometers' }}.")
        return String(format: format, formatter.string(fromDistance: distance))
    }

    private func updateInfo() {
        subtitleLabel.text = subtitleText
        infoButton.accessibilityLabel = [nameLabel.text, subtitleLabel.text].compactMap { $0 }.joined(separator: ", ")
        if isViewLoaded, travelTimeTask == nil, drivingTime == .calculating, locationSource.location != nil {
            calculateTravelTimes()
        }
    }

    private func resolveAddress() {
        addressTask?.cancel()
        let coordinate = location.coordinate
        addressTask = Task { [weak self, placeSearch] in
            let place = await placeSearch.address(at: coordinate)
            guard !Task.isCancelled, let self else { return }
            // Telegram：查不到时空着，不再写「正在定位…」。
            self.address = place?.address ?? place?.name ?? ""
            self.updateInfo()
        }
    }

    // MARK: - Directions

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func durationText(_ time: TimeInterval) -> String {
        durationFormatter.string(from: max(60, time)) ?? ""
    }

    private func calculateTravelTimes() {
        guard travelTimeTask == nil, drivingTime == .calculating else {
            return
        }
        guard isLocationAuthorized else {
            drivingTime = .unknown
            walkingTime = .unknown
            updateDirections()
            return
        }
        let coordinate = location.coordinate
        travelTimeTask = Task { [weak self, travelTimes] in
            let (drivingTime, walkingTime) = await travelTimes.travelTimes(to: coordinate)
            guard !Task.isCancelled, let self else { return }
            self.drivingTime = drivingTime.map(TravelTime.ready) ?? .unknown
            self.walkingTime = walkingTime.map(TravelTime.ready) ?? .unknown
            self.updateDirections()
        }
    }

    /// 两个都在算：两块占位；都算不出：一个「获取路线」占满一行；否则算出来的那个 / 两个。
    private func updateDirections() {
        let isCalculating = drivingTime == .calculating && walkingTime == .calculating
        placeholderViews.forEach { $0.isHidden = !isCalculating }
        drivingButton.isHidden = isCalculating
        walkingButton.isHidden = true

        if !isCalculating {
            switch (drivingTime, walkingTime) {
            case (.ready(let driving), .ready(let walking)):
                Self.configure(drivingButton, symbol: "car.fill", title: Self.durationText(driving))
                Self.configure(walkingButton, symbol: "figure.walk", title: Self.durationText(walking))
                walkingButton.isHidden = false
            case (.ready(let driving), _):
                Self.configure(drivingButton, symbol: "car.fill", title: Self.durationText(driving))
            case (_, .ready(let walking)):
                Self.configure(drivingButton, symbol: "figure.walk", title: Self.durationText(walking))
                drivingButton.tag = 1
            default:
                Self.configure(drivingButton, symbol: nil, title: OWSLocalizedString("LOCATION_VIEW_TELLOMI_GET_DIRECTIONS", comment: "Button on the location details page that lists the map apps to get directions to the shared location in."))
            }
        }
        view.setNeedsLayout()
    }

    private func didTapDirections(_ directions: TellomiMapApp.Directions) {
        // 只算出步行时，第一个按钮是步行。
        let directions: TellomiMapApp.Directions = (directions == .driving && drivingButton.tag == 1) ? .walking : directions
        let apps = TellomiMapApp.installed(canOpen: canOpenURL)
        if apps.count == 1, let app = apps.first {
            openApp(app, directions)
            return
        }
        present(TellomiOpenInSheet(apps: apps, actions: []) { [weak self] app in
            self?.openApp(app, directions)
        }, animated: true)
    }

    // MARK: - Share / copy

    /// 分享的文字：名称、地址、地图链接（每个客户端都认得、都打得开）。
    var shareText: String {
        let link = "https://maps.google.com/maps?q=\(location.latitude)%2C\(location.longitude)"
        return [location.name, address?.nilIfEmpty, link].compactMap { $0 }.joined(separator: "\n")
    }

    private func didTapShare() {
        var actions = [TellomiOpenInSheet.Action(title: CommonStrings.shareButton, isPrimary: true) { [weak self] in
            self?.presentSystemShare()
        }]
        if address?.nilIfEmpty != nil {
            actions.append(TellomiOpenInSheet.Action(title: Self.copyAddressTitle, isPrimary: false) { [weak self] in
                self?.copyAddress()
            })
        }
        let apps = TellomiMapApp.installed(canOpen: canOpenURL)
        present(TellomiOpenInSheet(apps: apps, actions: actions) { [weak self] app in
            self?.openApp(app, nil)
        }, animated: true)
    }

    static var copyAddressTitle: String {
        OWSLocalizedString("LOCATION_VIEW_TELLOMI_COPY_ADDRESS", comment: "Action on the location details page that copies the shared location's address.")
    }

    private func presentSystemShare() {
        let activity = UIActivityViewController(activityItems: [shareText], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        present(activity, animated: true)
    }

    func copyAddress() {
        guard let address = address?.nilIfEmpty else { return }
        UIPasteboard.general.string = [location.name, address].compactMap { $0 }.joined(separator: " ")
        // 提示在面板上面（不然被面板挡住）。
        presentToast(
            text: OWSLocalizedString("COPIED_TO_CLIPBOARD", comment: "Indicator that a value has been copied to the clipboard."),
            extraVInset: panel.frame.height,
        )
    }

    // MARK: - Buttons

    private static func makeGlassButton(symbol: String, accessibilityLabel: String, action: (() -> Void)?) -> UIButton {
        var configuration: UIButton.Configuration
        if #available(iOS 26, *) {
            configuration = .glass()
        } else {
            configuration = .filled()
            configuration.baseBackgroundColor = .Signal.background
        }
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        configuration.baseForegroundColor = .Signal.label
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = accessibilityLabel
        if let action {
            button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        }
        return button
    }

    private static func makeDirectionsButton(action: @escaping () -> Void) -> UIButton {
        var configuration: UIButton.Configuration
        if #available(iOS 26, *) {
            configuration = .prominentGlass()
        } else {
            configuration = .filled()
        }
        configuration.baseBackgroundColor = .Signal.accent
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.imagePadding = 5
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    private static func configure(_ button: UIButton, symbol: String?, title: String) {
        guard var configuration = button.configuration else { return }
        configuration.image = symbol.flatMap { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)) }
        var attributedTitle = AttributedString(title)
        attributedTitle.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        configuration.attributedTitle = attributedTitle
        button.configuration = configuration
        button.tag = 0
        button.accessibilityLabel = title
    }
}

// MARK: - Long press on the info: copy the address / share

extension TellomiLocationViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            var actions = [UIMenuElement]()
            if self.address?.nilIfEmpty != nil {
                actions.append(UIAction(title: Self.copyAddressTitle, image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.copyAddress()
                })
            }
            actions.append(UIAction(title: CommonStrings.shareButton, image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.presentSystemShare()
            })
            return UIMenu(children: actions)
        })
    }
}
