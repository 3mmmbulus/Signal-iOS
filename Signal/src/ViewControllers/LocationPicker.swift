//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

//  Originally based on https://github.com/almassapargali/LocationPicker
//
//  Created by Almas Sapargali on 7/29/15.
//  Parts Copyright (c) 2015 almassapargali. All rights reserved.

import Contacts
import CoreLocation
import CoreServices
public import MapKit
import SignalServiceKit
import SignalUI
import UniformTypeIdentifiers

public protocol LocationPickerDelegate: AnyObject {
    func didPickLocation(_ locationPicker: LocationPicker, location: Location)
    func locationPickerDidCancel()
}

public class LocationPicker: UIViewController {

    public weak var delegate: LocationPickerDelegate?

    /// Tellomi（2026-10-16）：嵌在附件 Sheet 里时，发出位置之后由 Sheet 决定怎么收（收起整个 Sheet）；没设就照上游 pop / dismiss。
    public var onFinish: (() -> Void)?
    public var location: Location? { didSet { updateAnnotation() } }

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var localSearch: MKLocalSearch?

    private lazy var mapView = MKMapView()

    private lazy var resultsController: LocationSearchResults = {
        let locationResults = LocationSearchResults()
        locationResults.onSelectLocation = { [weak self] in self?.selectedLocation($0) }
        return locationResults
    }()

    private lazy var searchController: UISearchController = {
        let searchController = UISearchController(searchResultsController: resultsController)
        searchController.searchResultsUpdater = self
        searchController.hidesNavigationBarDuringPresentation = false
        return searchController
    }()

    private static let SearchTermKey = "SearchTermKey"
    private var searchTimer: Timer?

    deinit {
        searchTimer?.invalidate()
        localSearch?.cancel()
        geocoder.cancelGeocode()
    }

    override open func loadView() {
        view = mapView

        let currentLocationButton = UIButton()
        currentLocationButton.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        currentLocationButton.clipsToBounds = true
        currentLocationButton.layer.cornerRadius = 24

        // This icon doesn't look right when it's actually centered due to its odd shape.
        currentLocationButton.setTemplateImageName("location", tintColor: .white)
        currentLocationButton.ows_contentEdgeInsets = UIEdgeInsets(top: 2, left: 0, bottom: 0, right: 2)

        view.addSubview(currentLocationButton)
        currentLocationButton.autoSetDimensions(to: CGSize(square: 48))
        currentLocationButton.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 15)
        currentLocationButton.autoPinEdge(toSuperviewSafeArea: .bottom, withInset: 15)
        currentLocationButton.addAction(
            UIAction { [weak self] _ in self?.didPressCurrentLocation() },
            for: .primaryActionTriggered,
        )
    }

    override open func viewDidLoad() {
        super.viewDidLoad()

        title = OWSLocalizedString("LOCATION_PICKER_TITLE", comment: "The title for the location picker view")

        navigationItem.rightBarButtonItem = .closeButton { [weak delegate] in
            delegate?.locationPickerDidCancel()
        }

        locationManager.delegate = self
        mapView.delegate = self

        let searchBar = self.searchController.searchBar
        searchBar.placeholder = OWSLocalizedString(
            "LOCATION_PICKER_SEARCH_PLACEHOLDER",
            comment: "A string indicating that the user can search for a location",
        )

        navigationItem.searchController = searchController
        definesPresentationContext = true

        // Select a new location by long pressing
        let locationSelectGesture = UILongPressGestureRecognizer(target: self, action: #selector(addLocation))
        mapView.addGestureRecognizer(locationSelectGesture)

        // If we don't have location access granted, this does nothing.
        // If we do, this will start the map at the user's current location.
        mapView.showsUserLocation = true
        showCurrentLocation(requestAuthorizationIfNecessary: false)
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.isTranslucent = true
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(true)
        navigationController?.navigationBar.isTranslucent = true
    }

    private func didPressCurrentLocation() {
        showCurrentLocation()
    }

    func showCurrentLocation(requestAuthorizationIfNecessary: Bool = true) {
        if requestAuthorizationIfNecessary { requestAuthorization() }
        locationManager.startUpdatingLocation()
    }

    func requestAuthorization() {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // We are already authorized, do nothing!
            break
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            // The user previous explicitly denied access. Point them to settings to re-enable.
            let alert = ActionSheetController(
                title: OWSLocalizedString(
                    "MISSING_LOCATION_PERMISSION_TITLE",
                    comment: "Alert title indicating the user has denied location permissions",
                ),
                message: OWSLocalizedString(
                    "MISSING_LOCATION_PERMISSION_MESSAGE",
                    comment: "Alert body indicating the user has denied location permissions",
                ),
            )
            let openSettingsAction = ActionSheetAction(
                title: CommonStrings.openSystemSettingsButton,
                style: .default,
            ) { _ in UIApplication.shared.openSystemSettings() }
            alert.addAction(openSettingsAction)

            let dismissAction = ActionSheetAction(title: CommonStrings.dismissButton, style: .cancel, handler: nil)
            alert.addAction(dismissAction)
            presentActionSheet(alert)
        @unknown default:
            owsFailDebug("Unknown")
        }
    }

    func updateAnnotation() {
        mapView.removeAnnotations(mapView.annotations)
        if let location {
            mapView.addAnnotation(location)
            mapView.selectAnnotation(location, animated: true)
        }
    }

    func showCoordinates(_ coordinate: CLLocationCoordinate2D, animated: Bool = true) {
        // The amount of meters +/- the selected coordinate we want to ensure are visible on screen.
        let metersOffset: CLLocationDistance = 600
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: metersOffset, longitudinalMeters: metersOffset)
        mapView.setRegion(region, animated: animated)
    }

    func selectLocation(location: CLLocation) {
        // add point annotation to map
        let annotation = MKPointAnnotation()
        annotation.coordinate = location.coordinate
        mapView.addAnnotation(annotation)

        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { response, error in
            let error = error as NSError?
            let geocodeCanceled = error?.domain == kCLErrorDomain && error?.code == CLError.Code.geocodeCanceled.rawValue

            if let error, !geocodeCanceled {
                // show error and remove annotation
                let alert = ActionSheetController(title: nil, message: error.userErrorDescription)
                alert.addAction(ActionSheetAction(
                    title: CommonStrings.okayButton,
                    style: .cancel,
                    handler: { _ in },
                ))
                self.present(alert, animated: true) {
                    self.mapView.removeAnnotation(annotation)
                }
            } else if let placemark = response?.first {
                // get POI name from placemark if any
                let name = placemark.areasOfInterest?.first

                // pass user selected location too
                self.location = Location(name: name, location: location, placemark: placemark)
            }
        }
    }
}

extension LocationPicker: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // The user requested we select their current location, do so and then stop listening for location updates.
        guard let location = locations.first else {
            return owsFailDebug("Unexpectedly received location update with no location")
        }
        // Only animate if this is not the first location we're showing.
        let shouldAnimate = self.location != nil
        showCoordinates(location.coordinate, animated: shouldAnimate)
        selectLocation(location: location)
        manager.stopUpdatingLocation()
    }

    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // If location permission was just granted, show the current location
        guard status == .authorizedWhenInUse else { return }
        showCurrentLocation()
    }
}

// MARK: Searching

extension LocationPicker: UISearchResultsUpdating {
    public func updateSearchResults(for searchController: UISearchController) {
        guard let term = searchController.searchBar.text else { return }

        // clear old results
        showItemsForSearchResult(nil)

        searchTimer?.invalidate()
        searchTimer = nil

        let searchTerm = term.trimmingCharacters(in: CharacterSet.whitespaces)
        if !searchTerm.isEmpty {
            // Search after a slight delay to debounce while the user is typing.
            searchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                self?.searchFromTimer(searchTerm)
            }
        }
    }

    private func searchFromTimer(_ term: String) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = term

        if let location = locationManager.location {
            // If we have a currently selected location, search relative to that location,
            // where the +/- degrees of the region we're searching around is reflected
            // by the latitude and longitude delta below.
            let latlongDelta: CLLocationDegrees = 2

            request.region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: latlongDelta, longitudeDelta: latlongDelta),
            )
        }

        localSearch?.cancel()
        localSearch = MKLocalSearch(request: request)
        localSearch?.start { [weak self] response, _ in
            self?.showItemsForSearchResult(response)
        }
    }

    func showItemsForSearchResult(_ searchResult: MKLocalSearch.Response?) {
        resultsController.locations = searchResult?.mapItems.map { Location(name: $0.name, placemark: $0.placemark) } ?? []
        resultsController.tableView.reloadData()
    }

    func selectedLocation(_ location: Location) {
        // dismiss search results
        dismiss(animated: true) {
            // set location, this also adds annotation
            self.location = location
            self.showCoordinates(location.coordinate)
        }
    }
}

// MARK: Selecting location with gesture

extension LocationPicker {
    @objc
    private func addLocation(_ gestureRecognizer: UIGestureRecognizer) {
        if gestureRecognizer.state == .began {
            let point = gestureRecognizer.location(in: mapView)
            let coordinates = mapView.convert(point, toCoordinateFrom: mapView)
            let location = CLLocation(latitude: coordinates.latitude, longitude: coordinates.longitude)
            selectLocation(location: location)
        }
    }
}

// MARK: MKMapViewDelegate

extension LocationPicker: MKMapViewDelegate {
    public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation { return nil }

        let pin = MKPinAnnotationView(annotation: annotation, reuseIdentifier: "annotation")
        pin.pinTintColor = .Signal.accent
        pin.animatesDrop = annotation is MKPointAnnotation
        pin.rightCalloutAccessoryView = sendLocationButton()
        pin.canShowCallout = true
        return pin
    }

    func sendLocationButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(imageLiteralResourceName: "send-blue-30"), for: .normal)
        button.sizeToFit()
        return button
    }

    public func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
        if let location {
            delegate?.didPickLocation(self, location: location)
        }

        if let onFinish {
            onFinish()
        } else if let navigation = navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            presentingViewController?.dismiss(animated: true, completion: nil)
        }
    }

    public func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
        if let userPin = views.first(where: { $0.annotation is MKUserLocation }) {
            userPin.canShowCallout = false
        }
    }
}

// MARK: UISearchBarDelegate

class LocationSearchResults: UITableViewController {
    var locations: [Location] = []
    var onSelectLocation: ((Location) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        extendedLayoutIncludesOpaqueBars = true
        tableView.backgroundColor = Theme.backgroundColor
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return locations.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LocationCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "LocationCell")

        let location = locations[indexPath.row]
        cell.textLabel?.text = location.name
        cell.textLabel?.textColor = Theme.primaryTextColor
        cell.detailTextLabel?.text = location.singleLineAddress
        cell.detailTextLabel?.textColor = Theme.secondaryTextAndIconColor
        cell.backgroundColor = Theme.backgroundColor

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelectLocation?(locations[indexPath.row])
    }
}

public class Location: NSObject {
    public let name: String?

    /// Tellomi（spec L-11）：选的地点的类别，决定发出去的地图上大头针的颜色和图标。
    public let tellomiCategory: MKPointOfInterestCategory?

    /// Tellomi（spec L-11）：选的地点的一行地址（位置页列表里的那行）；没有时从地标拼。
    public let tellomiAddressLine: String?

    // difference from placemark location is that if location was reverse geocoded,
    // then location point to user selected location
    public let location: CLLocation
    public let placemark: CLPlacemark

    static let postalAddressFormatter = CNPostalAddressFormatter()

    public var address: String? {
        guard let postalAddress = placemark.postalAddress else {
            return nil
        }
        return Location.postalAddressFormatter.string(from: postalAddress)
    }

    public var singleLineAddress: String? {
        guard let formattedAddress = address else {
            return nil
        }
        let addressLines = formattedAddress.components(separatedBy: .newlines)
        return ListFormatter.localizedString(byJoining: addressLines)
    }

    public var urlString: String {
        return "https://maps.google.com/maps?q=\(coordinate.latitude)%2C\(coordinate.longitude)"
    }

    enum LocationError: Error {
        case assertion
    }

    public init(
        name: String?,
        location: CLLocation? = nil,
        placemark: CLPlacemark,
        tellomiCategory: MKPointOfInterestCategory? = nil,
        tellomiAddressLine: String? = nil,
    ) {
        self.name = name
        self.location = location ?? placemark.location!
        self.placemark = placemark
        self.tellomiCategory = tellomiCategory
        self.tellomiAddressLine = tellomiAddressLine
    }

    /// 地点（有名称）用类别的颜色和图标，普通位置用主题色 + 大头针（Telegram：没有类别的用主题色）。
    var tellomiSnapshotPin: TellomiLocationSnapshot.Pin {
        guard tellomiPlaceName != nil, tellomiCategory != nil else {
            return .location
        }
        return .place(category: tellomiCategory)
    }

    func prepareAttachment() async throws -> SendableAttachment {
        // Tellomi（spec L-11）：上游画 256 pt 见方、系统大头针；改成 2:1 + 气球大头针（`TellomiLocationSnapshot`）。
        let image = try await TellomiLocationSnapshot.generate(coordinate: coordinate, pin: tellomiSnapshotPin)
        let normalizedImage = try NormalizedImage.forImage(image)
        let previewableAttachment = PreviewableAttachment.imageAttachmentForNormalizedImage(normalizedImage)
        return try await SendableAttachment.forPreviewableAttachment(previewableAttachment, imageQualityLevel: .one)
    }

    /// Tellomi（spec L-11）：名称放进正文时用的一行（去掉换行，免得打乱格式）。
    var tellomiPlaceName: String? {
        name?.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    public var messageText: String {
        // Tellomi（spec L-11）：上游从来不发名称（选了一个地点，对方只看到地址）。选的地点改发
        // 「名称\n一行地址\n链接」——Signal-Android 带名称的格式，Tellomi 认得出名称，老客户端照样显示这三行、点链接。
        if let placeName = tellomiPlaceName {
            let addressLine = (tellomiAddressLine ?? TellomiPlace.singleLineAddress(placemark))?
                .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces).nilIfEmpty
            return [placeName, addressLine, urlString].compactMap { $0 }.joined(separator: "\n")
        }

        // The message body will look something like:
        //
        // Place Name, 123 Street Name
        //
        // https://maps.google.com/maps

        // Tellomi（spec L-11）：没反查到地址时地标的地址是空的，上游会发出「\n\n链接」，空行去掉。
        if let address = address?.nilIfEmpty {
            return address + "\n\n" + urlString
        } else {
            return urlString
        }
    }
}

extension Location: MKAnnotation {

    public var coordinate: CLLocationCoordinate2D {
        return location.coordinate
    }

    public var title: String? {
        if let name {
            return name
        } else if
            let postalAddress = placemark.postalAddress,
            let firstAddressLine = Location.postalAddressFormatter.string(from: postalAddress).components(separatedBy: .newlines).first
        {
            return firstAddressLine
        } else {
            return "\(coordinate.latitude), \(coordinate.longitude)"
        }
    }
}
