import CarPlay
import CoreLocation
import MapKit
import UIKit

/// CarPlay template scene. Compiles against CarPlay.framework and the Info.plist scene.
/// Do not add com.apple.developer.carplay-maps to entitlements; that entitlement is
/// portal-whitelisted and breaks CI signing when it is present before approval.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPMapTemplateDelegate, CPPointOfInterestTemplateDelegate {
    var interfaceController: CPInterfaceController?
    var carWindow: CPWindow?
    private var mapTemplate: CPMapTemplate?
    private var navigationSession: CPNavigationSession?
    private var mapController: CarPlayMapController?
    private var recordButton: CPBarButton?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        self.carWindow = window
        LocationTracker.shared.start()

        let controller = CarPlayMapController()
        window.rootViewController = controller
        mapController = controller

        let mapTemplate = CPMapTemplate()
        mapTemplate.mapDelegate = self
        self.mapTemplate = mapTemplate
        configureChrome(mapTemplate)
        interfaceController.setRootTemplate(mapTemplate, animated: true) { _, _ in }
        controller.refresh()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        navigationSession?.finishTrip()
        navigationSession = nil
        self.interfaceController = nil
        self.carWindow = nil
        mapTemplate = nil
        mapController = nil
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        navigationSession?.finishTrip()
        navigationSession = nil
    }

    private func configureChrome(_ mapTemplate: CPMapTemplate) {
        let trails = CPBarButton(title: "Trails") { [weak self] _ in
            self?.showTrails()
        }
        let camps = CPBarButton(title: "<3° Camps") { [weak self] _ in
            self?.showCamps()
        }
        let record = CPBarButton(title: TrailRouteRecorder.shared.isRecording ? "Stop Rec" : "Record") { [weak self] _ in
            TrailRouteRecorder.shared.toggleFromRail()
            self?.configureChrome(mapTemplate)
            self?.mapController?.refresh()
        }
        recordButton = record
        mapTemplate.leadingNavigationBarButtons = [trails, camps]
        mapTemplate.trailingNavigationBarButtons = [record]

        let recenter = CPMapButton { [weak self] _ in
            self?.mapController?.recenter()
        }
        recenter.image = UIImage(systemName: "location.fill")
        let pan = CPMapButton { [weak self] _ in
            self?.mapTemplate?.showPanningInterface(animated: true)
        }
        pan.image = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")
        mapTemplate.mapButtons = [recenter, pan]
    }

    private func showTrails() {
        let here = LocationTracker.shared.userCoordinate
        let trails = USATrailAtlas.all.sorted { lhs, rhs in
            guard let here else { return lhs.name < rhs.name }
            return Self.meters(from: here, to: lhs.centerCoordinate) < Self.meters(from: here, to: rhs.centerCoordinate)
        }.prefix(14)
        let items: [CPListItem] = trails.map { trail in
            let away = here.map { String(format: "%.0f mi", Self.meters(from: $0, to: trail.centerCoordinate) / 1609.344) } ?? trail.state
            let fit = trail.reqClearanceIn >= 11.5 || trail.reqLocker ? "Check clearance" : "Rig-fit likely"
            let item = CPListItem(text: trail.name, detailText: "\(trail.state) · \(away) · \(fit)")
            item.handler = { [weak self] _, completion in
                self?.startNavigation(title: trail.name, coordinate: trail.centerCoordinate, summary: "\(trail.region) · \(fit)")
                self?.mapController?.showLine(trail.coordinates)
                completion()
            }
            return item
        }
        let list = CPListTemplate(title: "Trails & Corridors", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true) { _, _ in }
    }

    private func showCamps() {
        let here = LocationTracker.shared.userCoordinate
        let camps = USATrailAtlas.all.flatMap(\.campSpots).sorted { lhs, rhs in
            guard let here else { return lhs.name < rhs.name }
            return Self.meters(from: here, to: lhs.coordinate) < Self.meters(from: here, to: rhs.coordinate)
        }.prefix(16)
        let points: [CPPointOfInterest] = camps.map { spot in
            let item = MKMapItem(placemark: MKPlacemark(coordinate: spot.coordinate))
            item.name = spot.name
            let pin = UIImage(systemName: "tent.fill") ?? UIImage()
            return CPPointOfInterest(
                location: item,
                title: spot.name,
                subtitle: String(format: "%.1f° slope", spot.slopeDeg),
                summary: "Flat dispersed camp",
                detailTitle: spot.name,
                detailSubtitle: "Tap to start GPS route",
                detailSummary: String(format: "%d%% sky", spot.starlinkPct),
                pinImage: pin
            )
        }
        if points.isEmpty {
            let list = CPListTemplate(title: "<3° Flat Camps", sections: [CPListSection(items: [CPListItem(text: "No pads nearby", detailText: nil)])])
            interfaceController?.pushTemplate(list, animated: true) { _, _ in }
            return
        }
        let template = CPPointOfInterestTemplate(title: "<3° Flat Camps", pointsOfInterest: points, selectedIndex: 0)
        template.pointOfInterestDelegate = self
        interfaceController?.pushTemplate(template, animated: true) { _, _ in }
    }

    func pointOfInterestTemplate(_ pointOfInterestTemplate: CPPointOfInterestTemplate, didChangeMapRegion region: MKCoordinateRegion) {}

    func pointOfInterestTemplate(_ pointOfInterestTemplate: CPPointOfInterestTemplate, didSelectPointOfInterest pointOfInterest: CPPointOfInterest) {
        let coordinate = pointOfInterest.location.placemark.coordinate
        let title = pointOfInterest.title.isEmpty ? (pointOfInterest.location.name ?? "Flat Camp") : pointOfInterest.title
        startNavigation(title: title, coordinate: coordinate, summary: "Flat camp under 3°")
    }

    private func startNavigation(title: String, coordinate: CLLocationCoordinate2D, summary: String) {
        navigationSession?.finishTrip()
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        destination.name = title
        let choice = CPRouteChoice(
            summaryVariants: [summary],
            additionalInformationVariants: ["Phone GPS"],
            selectionSummaryVariants: ["Route to \(title)"]
        )
        let trip = CPTrip(origin: MKMapItem.forCurrentLocation(), destination: destination, routeChoices: [choice])
        guard let mapTemplate else { return }
        let session = mapTemplate.startNavigationSession(for: trip)
        let maneuver = CPManeuver()
        maneuver.instructionVariants = ["Continue to \(title)"]
        let miles = max(0.2, (LocationTracker.shared.userCoordinate.map { Self.meters(from: $0, to: coordinate) / 1609.344 }) ?? 5)
        maneuver.initialTravelEstimates = CPTravelEstimates(
            distanceRemaining: Measurement(value: miles, unit: UnitLength.miles),
            timeRemaining: miles / 22.0 * 3600
        )
        session.upcomingManeuvers = [maneuver]
        navigationSession = session
        mapController?.showDestination(coordinate, title: title)
        interfaceController?.popToRootTemplate(animated: true) { _, _ in }
    }

    private static func meters(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }
}

final class CarPlayMapController: UIViewController, MKMapViewDelegate {
    private let mapView = MKMapView()
    private let speedLabel = UILabel()
    private let elevationLabel = UILabel()
    private var timer: Timer?
    private var line: MKPolyline?

    override func viewDidLoad() {
        super.viewDidLoad()
        mapView.frame = view.bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        view.addSubview(mapView)

        let stack = UIStackView(arrangedSubviews: [speedLabel, elevationLabel])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for label in [speedLabel, elevationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 18, weight: .bold)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.72)
            label.layer.cornerRadius = 8
            label.clipsToBounds = true
        }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)
        ])
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refresh()
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let renderer = MKPolylineRenderer(overlay: overlay)
        renderer.strokeColor = UIColor(red: 0.93, green: 0.11, blue: 0.36, alpha: 1)
        renderer.lineWidth = 5
        return renderer
    }

    func recenter() {
        mapView.setUserTrackingMode(.follow, animated: true)
    }

    func showDestination(_ coordinate: CLLocationCoordinate2D, title: String) {
        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        pin.title = title
        mapView.addAnnotation(pin)
        mapView.showAnnotations([pin], animated: true)
    }

    func showLine(_ coordinates: [CLLocationCoordinate2D]) {
        if let line { mapView.removeOverlay(line) }
        guard coordinates.count >= 2 else { return }
        let overlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
        line = overlay
        mapView.addOverlay(overlay)
    }

    func refresh() {
        let speed = Int(PhoneSensorHub.shared.speedMph.rounded())
        let altitude = PhoneSensorHub.shared.altitudeFt
        speedLabel.text = "  \(speed) MPH  "
        elevationLabel.text = "  \(altitude) FT  "
        if TrailRouteRecorder.shared.isRecording {
            showLine(TrailRouteRecorder.shared.activePoints.map(\.coordinate))
        }
    }

    deinit {
        timer?.invalidate()
    }
}
