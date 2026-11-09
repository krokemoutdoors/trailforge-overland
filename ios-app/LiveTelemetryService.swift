import Foundation
import CoreLocation
import CoreMotion
import ImageIO
import CoreGraphics
import UIKit

// MARK: - Live US Government Overland Telemetry (USGS + SNOTEL + NIFC Wildfire + USFS MVUM)
struct USGSGaugeReading: Codable, Identifiable {
    let id: String // Site code e.g. "09010500"
    let siteName: String
    let dischargeCfs: Double
    let gageHeightFt: Double
    let timestampISO: String
}

struct WildfirePerimeter: Codable, Identifiable {
    let id: String
    let incidentName: String
    let acres: Double
    let percentContained: Double
    let latitude: Double
    let longitude: Double
}

@MainActor
final class LiveTelemetryService: ObservableObject {
    @Published var gaugeReadings: [String: USGSGaugeReading] = [:]
    @Published var activeFires: [WildfirePerimeter] = []
    @Published var lastUpdated: Date?
    @Published var discoveredTrails: [OverlandTrail] = []
    @Published var isScanningTrails: Bool = false
    @Published var scanStatus: String = ""
    @Published var campUpdatedAt: Date?
    private var trailScanGeneration = 0
    private var trailScanAnchor: CLLocationCoordinate2D?
    private var trailScanDebounce: Task<Void, Never>?
    private var scanAnchors: [CLLocationCoordinate2D] = []
    private var activeObserver: NSObjectProtocol?

    init() {
        discoveredTrails = CockpitStore.loadDiscoveredTrails()
        campUpdatedAt = CampCatalog.latestStamp()
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshOfficialCamps(force: false)
            }
        }
    }

    func scheduleTrailRefresh(around center: CLLocationCoordinate2D) {
        trailScanDebounce?.cancel()
        trailScanDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await fetchTrailsInMapRegion(center: center)
        }
    }

    func cancelScheduledTrailRefresh() {
        trailScanDebounce?.cancel()
        trailScanDebounce = nil
    }

    /// Fetches real-time river crossing flow (00060 = Discharge CFS, 00065 = Gage Height ft) from USGS NWIS
    func fetchUSGSStreamflow(siteCodes: [String] = ["09010500", "09180500", "10261500"]) async {
        let joined = siteCodes.joined(separator: ",")
        guard let url = URL(string: "https://waterservices.usgs.gov/nwis/iv/?format=json&sites=\(joined)&parameterCd=00060,00065") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let valObj = root["value"] as? [String: Any],
                  let seriesList = valObj["timeSeries"] as? [[String: Any]] else { return }

            var tempCfs: [String: Double] = [:]
            var tempHt: [String: Double] = [:]
            var tempName: [String: String] = [:]
            var tempTime: [String: String] = [:]

            for series in seriesList {
                guard let sourceInfo = series["sourceInfo"] as? [String: Any],
                      let siteName = sourceInfo["siteName"] as? String,
                      let siteCodeArr = sourceInfo["siteCode"] as? [[String: Any]],
                      let siteCode = siteCodeArr.first?["value"] as? String,
                      let variable = series["variable"] as? [String: Any],
                      let varCodeArr = variable["variableCode"] as? [[String: Any]],
                      let varCode = varCodeArr.first?["value"] as? String,
                      let valuesArr = series["values"] as? [[String: Any]],
                      let valItems = valuesArr.first?["value"] as? [[String: Any]],
                      let latest = valItems.last,
                      let valStr = latest["value"] as? String,
                      let numVal = Double(valStr) else { continue }

                tempName[siteCode] = siteName
                tempTime[siteCode] = (latest["dateTime"] as? String) ?? ""
                if varCode == "00060" { tempCfs[siteCode] = numVal }
                if varCode == "00065" { tempHt[siteCode] = numVal }
            }

            for code in siteCodes {
                if let name = tempName[code] {
                    gaugeReadings[code] = USGSGaugeReading(
                        id: code,
                        siteName: name,
                        dischargeCfs: tempCfs[code] ?? 0.0,
                        gageHeightFt: tempHt[code] ?? 0.0,
                        timestampISO: tempTime[code] ?? ""
                    )
                }
            }
            lastUpdated = Date()
        } catch {
            print("USGS fetch error: \(error)")
        }
    }

    /// Queries NIFC WFIGS Active Fire Perimeters within bounding box
    func fetchNIFCWildfires(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) async {
        let query = "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Interagency_Perimeters_Current/FeatureServer/0/query?where=1%3D1&outFields=poly_IncidentName,poly_GISAcres,attr_PercentContained&f=geojson"
        guard let url = URL(string: query) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let features = root["features"] as? [[String: Any]] {
                var parsed: [WildfirePerimeter] = []
                for (idx, feat) in features.prefix(15).enumerated() {
                    let props = (feat["properties"] as? [String: Any]) ?? [:]
                    let name = (props["poly_IncidentName"] as? String) ?? "Active Incident"
                    let acres = (props["poly_GISAcres"] as? Double) ?? 0.0
                    let contained = (props["attr_PercentContained"] as? Double) ?? 0.0
                    parsed.append(WildfirePerimeter(
                        id: "fire-\(idx)",
                        incidentName: name,
                        acres: acres,
                        percentContained: contained,
                        latitude: (minLat + maxLat) / 2.0,
                        longitude: (minLon + maxLon) / 2.0
                    ))
                }
                activeFires = parsed
            }
        } catch {
            print("NIFC wildfire fetch error: \(error)")
        }
    }
}

struct GPSFix: Sendable {
    var latitude: Double
    var longitude: Double
    var speedMps: Double
    var altitudeMeters: Double
    var verticalAccuracy: Double
    var timestamp: Date
}

/// Latest phone GPS speed and elevation for the cockpit HUD and CarPlay map.
@MainActor
final class PhoneSensorHub {
    static let shared = PhoneSensorHub()
    var speedMph: Double = 0
    var altitudeFt: Int = 0
    var coordinate: CLLocationCoordinate2D?
    var onUpdate: (() -> Void)?

    func publish(speedMph: Double, altitudeFt: Int, coordinate: CLLocationCoordinate2D?) {
        self.speedMph = speedMph
        self.altitudeFt = altitudeFt
        if let coordinate { self.coordinate = coordinate }
        onUpdate?()
    }
}

@MainActor
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationTracker()

    private let manager = CLLocationManager()
    private let altimeter = CMAltimeter()

    @Published var userCoordinate: CLLocationCoordinate2D?
    @Published var speedMph: Double = 0
    @Published var altitudeFt: Int = 0
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var hasCenteredOnUserOnce: Bool = false
    @Published var locationRevision: Int = 0
    var headingDegrees: Double = 0

    private var lastUIPublish = Date.distantPast
    private var lastUICoordinate: CLLocationCoordinate2D?
    private var lastHeadingPublish = Date.distantPast
    private var lastRawCoordinate: CLLocationCoordinate2D?
    private var lastRawDate: Date?
    private var gpsAltitudeMeters: Double = 0
    private var altimeterOffset: Double?
    private var altimeterActive = false
    private var didStartAltimeter = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.headingFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        authorizationStatus = manager.authorizationStatus
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        startAltimeter()
    }

    func requestLocation() {
        start()
    }

    private func startAltimeter() {
        guard !didStartAltimeter, CMAltimeter.isRelativeAltitudeAvailable() else { return }
        didStartAltimeter = true
        altimeterActive = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let relative = data.relativeAltitude.doubleValue
            Task { @MainActor in
                self?.applyRelativeAltitude(relative)
            }
        }
    }

    /// Speed and elevation update on every hardware callback. The 5 m gate only limits map republish.
    func apply(_ fix: GPSFix) {
        let coordinate = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        if fix.speedMps >= 0 {
            speedMph = max(0, fix.speedMps * 2.2369362920544)
        } else if let previous = lastRawCoordinate, let previousDate = lastRawDate {
            let dt = fix.timestamp.timeIntervalSince(previousDate)
            if dt > 0.2 {
                let meters = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                speedMph = max(0, (meters / dt) * 2.2369362920544)
            }
        } else {
            speedMph = 0
        }
        if fix.verticalAccuracy >= 0 {
            gpsAltitudeMeters = fix.altitudeMeters
            if altimeterOffset == nil {
                altimeterOffset = fix.altitudeMeters
            }
            if !altimeterActive {
                altitudeFt = Int((fix.altitudeMeters * 3.280839895).rounded())
            }
        }
        lastRawCoordinate = coordinate
        lastRawDate = fix.timestamp
        PhoneSensorHub.shared.publish(speedMph: speedMph, altitudeFt: altitudeFt, coordinate: coordinate)
        TrailRouteRecorder.shared.capture(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitudeFt: altitudeFt,
            speedMph: speedMph,
            timestamp: fix.timestamp
        )

        let moved: Double
        if let previous = lastUICoordinate {
            moved = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        } else {
            moved = .greatestFiniteMagnitude
        }
        let elapsed = Date().timeIntervalSince(lastUIPublish)
        guard elapsed >= 1.0 || moved >= 5.0 else { return }
        lastUIPublish = Date()
        lastUICoordinate = coordinate
        userCoordinate = coordinate
        if !hasCenteredOnUserOnce {
            hasCenteredOnUserOnce = true
        }
        locationRevision += 1
    }

    private func applyRelativeAltitude(_ relativeMeters: Double) {
        let absolute = (altimeterOffset ?? gpsAltitudeMeters) + relativeMeters
        altitudeFt = Int((absolute * 3.280839895).rounded())
        PhoneSensorHub.shared.publish(speedMph: speedMph, altitudeFt: altitudeFt, coordinate: userCoordinate ?? lastRawCoordinate)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let fix = GPSFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speedMps: location.speed,
            altitudeMeters: location.altitude,
            verticalAccuracy: location.verticalAccuracy,
            timestamp: location.timestamp
        )
        Task { @MainActor in
            self.apply(fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            let delta = abs(degrees - self.headingDegrees)
            let wrapped = min(delta, 360 - delta)
            guard wrapped >= 5, Date().timeIntervalSince(self.lastHeadingPublish) >= 1 else { return }
            self.lastHeadingPublish = Date()
            self.headingDegrees = degrees
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.manager.startUpdatingLocation()
                self.manager.startUpdatingHeading()
            }
        }
    }
}

enum USStateLocator {
    private struct Box {
        var code: String
        var minLat: Double
        var maxLat: Double
        var minLon: Double
        var maxLon: Double
        var area: Double { (maxLat - minLat) * (maxLon - minLon) }
    }

    private static let boxes: [Box] = [
        Box(code: "AL", minLat: 30.22, maxLat: 35.01, minLon: -88.47, maxLon: -84.89),
        Box(code: "AK", minLat: 51.20, maxLat: 71.40, minLon: -168.00, maxLon: -130.00),
        Box(code: "AZ", minLat: 31.33, maxLat: 37.00, minLon: -114.82, maxLon: -109.04),
        Box(code: "AR", minLat: 33.00, maxLat: 36.50, minLon: -94.62, maxLon: -89.64),
        Box(code: "CA", minLat: 32.53, maxLat: 42.01, minLon: -124.48, maxLon: -114.13),
        Box(code: "CO", minLat: 36.99, maxLat: 41.00, minLon: -109.06, maxLon: -102.04),
        Box(code: "CT", minLat: 40.98, maxLat: 42.05, minLon: -73.73, maxLon: -71.79),
        Box(code: "DE", minLat: 38.45, maxLat: 39.84, minLon: -75.79, maxLon: -75.05),
        Box(code: "FL", minLat: 24.52, maxLat: 31.00, minLon: -87.63, maxLon: -80.03),
        Box(code: "GA", minLat: 30.36, maxLat: 35.00, minLon: -85.61, maxLon: -80.84),
        Box(code: "HI", minLat: 18.91, maxLat: 22.24, minLon: -160.25, maxLon: -154.81),
        Box(code: "ID", minLat: 41.99, maxLat: 49.00, minLon: -117.24, maxLon: -111.04),
        Box(code: "IL", minLat: 36.97, maxLat: 42.51, minLon: -91.51, maxLon: -87.50),
        Box(code: "IN", minLat: 37.77, maxLat: 41.76, minLon: -88.10, maxLon: -84.78),
        Box(code: "IA", minLat: 40.38, maxLat: 43.50, minLon: -96.64, maxLon: -90.14),
        Box(code: "KS", minLat: 36.99, maxLat: 40.00, minLon: -102.05, maxLon: -94.59),
        Box(code: "KY", minLat: 36.50, maxLat: 39.15, minLon: -89.57, maxLon: -81.96),
        Box(code: "LA", minLat: 28.93, maxLat: 33.02, minLon: -94.04, maxLon: -88.82),
        Box(code: "ME", minLat: 43.06, maxLat: 47.46, minLon: -71.08, maxLon: -66.95),
        Box(code: "MD", minLat: 37.91, maxLat: 39.72, minLon: -79.49, maxLon: -75.05),
        Box(code: "MA", minLat: 41.24, maxLat: 42.89, minLon: -73.51, maxLon: -69.93),
        Box(code: "MI", minLat: 41.70, maxLat: 48.31, minLon: -90.42, maxLon: -82.41),
        Box(code: "MN", minLat: 43.50, maxLat: 49.38, minLon: -97.24, maxLon: -89.49),
        Box(code: "MS", minLat: 30.17, maxLat: 35.00, minLon: -91.66, maxLon: -88.10),
        Box(code: "MO", minLat: 35.99, maxLat: 40.61, minLon: -95.77, maxLon: -89.10),
        Box(code: "MT", minLat: 44.36, maxLat: 49.00, minLon: -116.05, maxLon: -104.04),
        Box(code: "NE", minLat: 40.00, maxLat: 43.00, minLon: -104.05, maxLon: -95.31),
        Box(code: "NV", minLat: 35.00, maxLat: 42.00, minLon: -120.01, maxLon: -114.04),
        Box(code: "NH", minLat: 42.70, maxLat: 45.31, minLon: -72.56, maxLon: -70.70),
        Box(code: "NJ", minLat: 38.93, maxLat: 41.36, minLon: -75.56, maxLon: -73.89),
        Box(code: "NM", minLat: 31.33, maxLat: 37.00, minLon: -109.05, maxLon: -103.00),
        Box(code: "NY", minLat: 40.50, maxLat: 45.02, minLon: -79.76, maxLon: -71.86),
        Box(code: "NC", minLat: 33.84, maxLat: 36.59, minLon: -84.32, maxLon: -75.46),
        Box(code: "ND", minLat: 45.94, maxLat: 49.00, minLon: -104.05, maxLon: -96.55),
        Box(code: "OH", minLat: 38.40, maxLat: 41.98, minLon: -84.82, maxLon: -80.52),
        Box(code: "OK", minLat: 33.62, maxLat: 37.00, minLon: -103.00, maxLon: -94.43),
        Box(code: "OR", minLat: 41.99, maxLat: 46.29, minLon: -124.57, maxLon: -116.46),
        Box(code: "PA", minLat: 39.72, maxLat: 42.27, minLon: -80.52, maxLon: -74.69),
        Box(code: "RI", minLat: 41.15, maxLat: 42.02, minLon: -71.91, maxLon: -71.12),
        Box(code: "SC", minLat: 32.05, maxLat: 35.22, minLon: -83.35, maxLon: -78.54),
        Box(code: "SD", minLat: 42.48, maxLat: 45.95, minLon: -104.06, maxLon: -96.44),
        Box(code: "TN", minLat: 34.98, maxLat: 36.68, minLon: -90.31, maxLon: -81.65),
        Box(code: "TX", minLat: 25.84, maxLat: 36.50, minLon: -106.65, maxLon: -93.51),
        Box(code: "UT", minLat: 36.99, maxLat: 42.00, minLon: -114.05, maxLon: -109.04),
        Box(code: "VT", minLat: 42.73, maxLat: 45.02, minLon: -73.44, maxLon: -71.46),
        Box(code: "VA", minLat: 36.54, maxLat: 39.47, minLon: -83.68, maxLon: -75.24),
        Box(code: "WA", minLat: 45.54, maxLat: 49.00, minLon: -124.85, maxLon: -116.92),
        Box(code: "WV", minLat: 37.20, maxLat: 40.64, minLon: -82.64, maxLon: -77.72),
        Box(code: "WI", minLat: 42.49, maxLat: 47.08, minLon: -92.89, maxLon: -86.25),
        Box(code: "WY", minLat: 40.99, maxLat: 45.01, minLon: -111.06, maxLon: -104.05)
    ]

    private static let names: [String: String] = [
        "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR", "california": "CA",
        "colorado": "CO", "connecticut": "CT", "delaware": "DE", "florida": "FL", "georgia": "GA",
        "hawaii": "HI", "idaho": "ID", "illinois": "IL", "indiana": "IN", "iowa": "IA",
        "kansas": "KS", "kentucky": "KY", "louisiana": "LA", "maine": "ME", "maryland": "MD",
        "massachusetts": "MA", "michigan": "MI", "minnesota": "MN", "mississippi": "MS", "missouri": "MO",
        "montana": "MT", "nebraska": "NE", "nevada": "NV", "new hampshire": "NH", "new jersey": "NJ",
        "new mexico": "NM", "new york": "NY", "north carolina": "NC", "north dakota": "ND", "ohio": "OH",
        "oklahoma": "OK", "oregon": "OR", "pennsylvania": "PA", "rhode island": "RI", "south carolina": "SC",
        "south dakota": "SD", "tennessee": "TN", "texas": "TX", "utah": "UT", "vermont": "VT",
        "virginia": "VA", "washington": "WA", "west virginia": "WV", "wisconsin": "WI", "wyoming": "WY"
    ]

    static func code(latitude: Double, longitude: Double, tagged: String? = nil) -> String {
        if let tagged {
            let trimmed = tagged.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()
            if names.values.contains(upper) { return upper }
            if let named = names[trimmed.lowercased()] { return named }
        }
        let matches = boxes.filter {
            latitude >= $0.minLat && latitude <= $0.maxLat && longitude >= $0.minLon && longitude <= $0.maxLon
        }
        return matches.min(by: { $0.area < $1.area })?.code ?? "US"
    }
}

extension LiveTelemetryService {
    func fetchTrailsInMapRegion(center: CLLocationCoordinate2D, radiusMeters: Int = 18_000) async {
        if scanAnchors.contains(where: { moved($0, center) < 1_500 }) { return }
        if isScanningTrails, let anchor = trailScanAnchor, moved(anchor, center) < 1_500 { return }
        trailScanGeneration += 1
        let generation = trailScanGeneration
        trailScanAnchor = center
        isScanningTrails = true
        scanStatus = "Scanning USA 4x4 trails…"

        await withTaskGroup(of: [OverlandTrail].self) { group in
            group.addTask {
                await Self.fetchOverpassTrails(center: center)
            }
            group.addTask {
                await Self.fetchUSFSRoads(center: center, radiusMeters: radiusMeters)
            }
            group.addTask {
                await CampCatalog.trails(around: center, force: false)
            }
            for await trails in group {
                guard generation == trailScanGeneration else { continue }
                let annotated = await CampSurvey.annotate(trails)
                absorbDiscovered(annotated, generation: generation, center: center)
            }
        }
        guard generation == trailScanGeneration else { return }
        isScanningTrails = false
        if !scanAnchors.contains(where: { moved($0, center) < 200 }) {
            scanAnchors.append(center)
            if scanAnchors.count > 40 { scanAnchors.removeFirst(scanAnchors.count - 40) }
        }
        let stamp = campUpdatedAt.map { " · Updated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        if discoveredTrails.isEmpty {
            scanStatus = "No public 4x4 tracks returned for this area.\(stamp)"
        } else {
            scanStatus = "\(discoveredTrails.count) local USA trails\(stamp)"
        }
    }

    func refreshOfficialCamps(force: Bool) async {
        var centers: [CLLocationCoordinate2D] = []
        if let here = LocationTracker.shared.userCoordinate {
            centers.append(here)
        }
        for pack in CockpitStore.loadPacks() {
            if let lat = pack.minLat, let lon = pack.minLon, let maxLat = pack.maxLat, let maxLon = pack.maxLon {
                centers.append(CLLocationCoordinate2D(latitude: (lat + maxLat) / 2, longitude: (lon + maxLon) / 2))
            }
        }
        if centers.isEmpty, let anchor = trailScanAnchor {
            centers.append(anchor)
        }
        guard !centers.isEmpty else { return }
        UserDefaults.standard.set(centers[0].latitude, forKey: "tf-camp-lat")
        UserDefaults.standard.set(centers[0].longitude, forKey: "tf-camp-lon")
        for center in centers {
            let trails = await CampCatalog.trails(around: center, force: force)
            guard !trails.isEmpty else { continue }
            let annotated = await CampSurvey.annotate(trails)
            mergeCamps(annotated)
        }
        campUpdatedAt = CampCatalog.latestStamp()
        let stamp = campUpdatedAt.map { " · Updated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        if !discoveredTrails.isEmpty {
            scanStatus = "\(discoveredTrails.count) local USA trails\(stamp)"
        }
    }

    private func mergeCamps(_ loaded: [OverlandTrail]) {
        var byID: [String: OverlandTrail] = [:]
        for trail in discoveredTrails { byID[trail.id] = trail }
        for trail in loaded { byID[trail.id] = trail }
        var merged = CampCatalog.dedupe(Array(byID.values))
        if merged.count > 200 {
            merged = Array(merged.prefix(200))
        }
        discoveredTrails = merged
        CockpitStore.saveDiscoveredTrails(merged)
    }

    private func absorbDiscovered(_ loaded: [OverlandTrail], generation: Int, center: CLLocationCoordinate2D) {
        guard generation == trailScanGeneration, !loaded.isEmpty else { return }
        var byID: [String: OverlandTrail] = [:]
        for trail in discoveredTrails {
            byID[trail.id] = trail
        }
        for trail in loaded {
            byID[trail.id] = trail
        }
        var merged = CampCatalog.dedupe(Array(byID.values))
        if merged.count > 200 {
            let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
            merged.sort { lhs, rhs in
                let left = CLLocation(latitude: lhs.centerLat, longitude: lhs.centerLon)
                let right = CLLocation(latitude: rhs.centerLat, longitude: rhs.centerLon)
                return left.distance(from: origin) < right.distance(from: origin)
            }
            merged = Array(merged.prefix(200))
        }
        discoveredTrails = merged
        campUpdatedAt = CampCatalog.latestStamp() ?? campUpdatedAt
        let stamp = campUpdatedAt.map { " · Updated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        scanStatus = "\(merged.count) local USA trails\(stamp)"
        CockpitStore.saveDiscoveredTrails(merged)
    }

    private func moved(_ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }

    private static func fetchOverpassTrails(center: CLLocationCoordinate2D) async -> [OverlandTrail] {
        let south = center.latitude - 0.09
        let north = center.latitude + 0.09
        let west = center.longitude - 0.11
        let east = center.longitude + 0.11
        let box = "\(south),\(west),\(north),\(east)"
        let query = """
        [out:json][timeout:10];
        (
          way["highway"~"track|path"]["tracktype"~"grade2|grade3|grade4|grade5"](\(box));
          way["highway"="track"]["4wd_only"="yes"](\(box));
          way["highway"="unclassified"]["surface"~"unpaved|gravel|dirt|sand|rock"](\(box));
          node["tourism"~"camp_site|camp_pitch"](\(box));
        );
        out geom 60;
        """
        guard let data = await postOverpass(query),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }
        return elements.compactMap(parseOverpassElement)
    }

    private static func postOverpass(_ query: String) async -> Data? {
        let urls = [
            "https://overpass-api.de/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter"
        ]
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 14
            request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = query.data(using: .utf8)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  !data.isEmpty else { continue }
            return data
        }
        return nil
    }

    private static func parseOverpassElement(_ element: [String: Any]) -> OverlandTrail? {
        if (element["type"] as? String) == "node" {
            return parseCampNode(element)
        }
        return parseOverpassWay(element)
    }

    private static func parseCampNode(_ element: [String: Any]) -> OverlandTrail? {
        guard let nodeID = (element["id"] as? NSNumber)?.stringValue ?? element["id"] as? String,
              let lat = element["lat"] as? Double,
              let lon = element["lon"] as? Double else { return nil }
        let tags = stringMap(element["tags"])
        let name = tags["name"] ?? tags["ref"] ?? "Camp"
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        return OverlandTrail(
            id: "osm-camp-\(nodeID)",
            name: name,
            region: "Camp",
            agency: tags["operator"] ?? "OpenStreetMap",
            distanceMi: 0.1,
            peakElevFt: 0,
            reqClearanceIn: 8.6,
            minCanopyFt: 12.5,
            waterCrossingIn: 0,
            reqLocker: false,
            gateStatus: "CHECK",
            snotelSnowIn: 0,
            usgsFlowCfs: 0,
            state: USStateLocator.code(latitude: lat, longitude: lon, tagged: tags["addr:state"] ?? tags["is_in:state"]),
            centerLat: lat,
            centerLon: lon,
            coordinates: [coordinate],
            flatCamps: [(name: "\(name) · Mapped campsite · slope unknown", lat: lat, lon: lon, slopeDeg: -1, starlinkPct: 0)],
            legalStatus: "osm"
        )
    }

    private static func parseOverpassWay(_ element: [String: Any]) -> OverlandTrail? {
        guard let wayID = (element["id"] as? NSNumber)?.stringValue ?? element["id"] as? String,
              let geometry = element["geometry"] as? [[String: Any]] else { return nil }
        let tags = stringMap(element["tags"])
        let coordinates: [CLLocationCoordinate2D] = geometry.compactMap { point in
            guard let lat = point["lat"] as? Double, let lon = point["lon"] as? Double else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        guard coordinates.count >= 2 else { return nil }
        let mid = coordinates[coordinates.count / 2]
        let name = tags["name"] ?? tags["ref"] ?? tags["official_name"] ?? "OSM \(wayID)"
        let fit = clearanceEstimate(tracktype: tags["tracktype"], surface: tags["surface"], fourWheelOnly: tags["4wd_only"] == "yes")
        return OverlandTrail(
            id: "osm-\(wayID)",
            name: name,
            region: "Live USA scan",
            agency: tags["operator"] ?? "OpenStreetMap",
            distanceMi: max(0.4, polylineMiles(coordinates)),
            peakElevFt: 0,
            reqClearanceIn: fit.clearance,
            minCanopyFt: fit.canopy,
            waterCrossingIn: fit.water,
            reqLocker: fit.locker,
            gateStatus: "CHECK",
            snotelSnowIn: 0,
            usgsFlowCfs: 0,
            state: USStateLocator.code(latitude: mid.latitude, longitude: mid.longitude, tagged: tags["addr:state"] ?? tags["is_in:state"]),
            centerLat: mid.latitude,
            centerLon: mid.longitude,
            coordinates: coordinates,
            flatCamps: [],
            legalStatus: "osm"
        )
    }

    private static func fetchUSFSRoads(center: CLLocationCoordinate2D, radiusMeters: Int) async -> [OverlandTrail] {
        var components = URLComponents(string: "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_RoadBasic_01/MapServer/0/query")
        components?.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "geometry", value: "\(center.longitude),\(center.latitude)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "distance", value: "\(radiusMeters)"),
            URLQueryItem(name: "units", value: "esriSRUnit_Meter"),
            URLQueryItem(name: "outFields", value: "*"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "resultRecordCount", value: "40"),
            URLQueryItem(name: "f", value: "json")
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let features = root["features"] as? [[String: Any]] else { return [] }
            return features.enumerated().compactMap { index, feature in
                parseUSFSFeature(feature, index: index)
            }
        } catch {
            print("USFS MVUM fetch error: \(error)")
            return []
        }
    }

    private static func parseUSFSFeature(_ feature: [String: Any], index: Int) -> OverlandTrail? {
        let attributes = feature["attributes"] as? [String: Any] ?? [:]
        let name = firstString(in: attributes, keys: ["NAME", "ROAD_NAME", "ROAD_SYMBOL", "SYMBOL", "ID", "OBJECTID"]) ?? "USFS Road \(index + 1)"
        let geometry = feature["geometry"] as? [String: Any]
        let coordinates = coordinatesFromArcGIS(geometry?["paths"])
        guard coordinates.count >= 2 else { return nil }
        let sampled = downsample(coordinates, limit: 60)
        let mid = sampled[sampled.count / 2]
        let surface = firstString(in: attributes, keys: ["SURFACE_TYPE", "SURFACE"]) ?? ""
        let fit = clearanceEstimate(tracktype: nil, surface: surface.lowercased(), fourWheelOnly: false)
        let identifier = firstString(in: attributes, keys: ["ID", "OBJECTID", "GLOBALID"]) ?? "\(index)"
        return OverlandTrail(
            id: "usfs-\(identifier)",
            name: name.hasPrefix("FS") || name.hasPrefix("FR") ? name : "FS \(name)",
            region: "USFS road",
            agency: "USFS",
            distanceMi: max(0.4, polylineMiles(sampled)),
            peakElevFt: 0,
            reqClearanceIn: fit.clearance,
            minCanopyFt: fit.canopy,
            waterCrossingIn: fit.water,
            reqLocker: fit.locker,
            gateStatus: "CHECK",
            snotelSnowIn: 0,
            usgsFlowCfs: 0,
            state: USStateLocator.code(
                latitude: mid.latitude,
                longitude: mid.longitude,
                tagged: firstString(in: attributes, keys: ["STATE", "STATE_CODE", "ADMIN_STATE"])
            ),
            centerLat: mid.latitude,
            centerLon: mid.longitude,
            coordinates: sampled,
            flatCamps: [],
            legalStatus: "mvum"
        )
    }

    private static func clearanceEstimate(tracktype: String?, surface: String?, fourWheelOnly: Bool) -> (clearance: Double, canopy: Double, water: Int, locker: Bool) {
        switch tracktype {
        case "grade5":
            return (12.0, 9.0, 18, true)
        case "grade4":
            return (10.5, 10.0, 14, fourWheelOnly)
        case "grade3":
            return (9.2, 11.5, 10, false)
        case "grade2":
            return (8.0, 12.5, 6, false)
        default:
            if fourWheelOnly { return (10.2, 11.0, 12, true) }
            if surface?.contains("rock") == true { return (10.4, 13.0, 8, false) }
            if surface?.contains("sand") == true { return (9.0, 14.0, 0, false) }
            return (8.6, 12.5, 6, false)
        }
    }

    private static func polylineMiles(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        var meters = 0.0
        for index in 1..<coordinates.count {
            let start = CLLocation(latitude: coordinates[index - 1].latitude, longitude: coordinates[index - 1].longitude)
            let end = CLLocation(latitude: coordinates[index].latitude, longitude: coordinates[index].longitude)
            meters += start.distance(from: end)
        }
        return meters / 1609.344
    }

    private static func coordinatesFromArcGIS(_ rawPaths: Any?) -> [CLLocationCoordinate2D] {
        guard let paths = rawPaths as? [Any], let firstPath = paths.first as? [Any] else { return [] }
        return firstPath.compactMap { point in
            guard let pair = point as? [Any], pair.count >= 2 else { return nil }
            let lon = (pair[0] as? NSNumber)?.doubleValue
            let lat = (pair[1] as? NSNumber)?.doubleValue
            guard let lat, let lon else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    private static func downsample(_ coordinates: [CLLocationCoordinate2D], limit: Int) -> [CLLocationCoordinate2D] {
        guard coordinates.count > limit, limit >= 2 else { return coordinates }
        let stride = Double(coordinates.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            coordinates[min(coordinates.count - 1, Int((Double(index) * stride).rounded()))]
        }
    }

    private static func stringMap(_ raw: Any?) -> [String: String] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var tags: [String: String] = [:]
        for (key, value) in dict {
            if let text = value as? String, !text.isEmpty {
                tags[key] = text
            } else if let number = value as? NSNumber {
                tags[key] = number.stringValue
            }
        }
        return tags
    }

    private static func firstString(in attributes: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = attributes[key] as? String, !value.isEmpty { return value }
            if let value = attributes[key] as? Int { return String(value) }
            if let value = attributes[key] as? Double { return String(Int(value)) }
        }
        return nil
    }
}

enum CampSurvey {
    private static let tileZoom = 12
    private static var tilePixels: [String: (width: Int, height: Int, bytes: [UInt8])] = [:]
    private static var slopeCache: [String: Double] = loadSlopes()
    private static var landCache: [String: String] = [:]

    static func annotate(_ trails: [OverlandTrail]) async -> [OverlandTrail] {
        var annotated: [OverlandTrail] = []
        annotated.reserveCapacity(trails.count)
        for trail in trails {
            var copy = trail
            if CampCatalog.isMapped(trail.id) {
                let slope = await measureSlope(latitude: trail.centerLat, longitude: trail.centerLon)
                let bit = slope.map { String(format: "measured %.1f°", $0) } ?? "slope unknown"
                let base = trail.name.split(separator: "·").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? trail.name
                let source = CampCatalog.sourceName(trail.id)
                copy.flatCamps = [(
                    name: "\(base) · Mapped campsite · \(source) · \(bit)",
                    lat: trail.centerLat,
                    lon: trail.centerLon,
                    slopeDeg: slope ?? -1,
                    starlinkPct: 0
                )]
            } else if trail.id.hasPrefix("osm-") || trail.id.hasPrefix("usfs-") {
                copy.flatCamps = await dispersed(along: trail.coordinates, title: trail.name)
            }
            annotated.append(copy)
        }
        return annotated
    }

    private static func dispersed(along coordinates: [CLLocationCoordinate2D], title: String) async -> [(name: String, lat: Double, lon: Double, slopeDeg: Double, starlinkPct: Int)] {
        var kept: [(name: String, lat: Double, lon: Double, slopeDeg: Double, starlinkPct: Int)] = []
        for seed in pullouts(coordinates) {
            let land = await publicLand(latitude: seed.latitude, longitude: seed.longitude)
            guard land == "USFS" || land == "BLM" else { continue }
            guard let slope = await measureSlope(latitude: seed.latitude, longitude: seed.longitude), slope < 3 else { continue }
            kept.append((
                name: String(format: "%@ pull-out · Dispersed – measured %.1f°, %@ land", title, slope, land),
                lat: seed.latitude,
                lon: seed.longitude,
                slopeDeg: (slope * 10).rounded() / 10,
                starlinkPct: 0
            ))
            if kept.count >= 3 { break }
        }
        return kept
    }

    private static func pullouts(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 2 else { return [] }
        var seeds: [CLLocationCoordinate2D] = []
        var traveled = 0.0
        var next = 400.0
        for index in 1..<coordinates.count where seeds.count < 4 {
            let start = coordinates[index - 1]
            let end = coordinates[index]
            traveled += CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            guard traveled >= next else { continue }
            let dLat = end.latitude - start.latitude
            let dLon = end.longitude - start.longitude
            let length = max(1e-9, hypot(dLat, dLon))
            let side = 30.0 / 111_320.0
            seeds.append(CLLocationCoordinate2D(
                latitude: end.latitude + (-dLon / length) * side,
                longitude: end.longitude + (dLat / length) * side
            ))
            next += 700
        }
        return seeds
    }

    private static func measureSlope(latitude: Double, longitude: Double) async -> Double? {
        let key = cacheKey(latitude, longitude)
        if let cached = slopeCache[key] { return cached }
        let span = 45.0
        let dLat = span / 111_320.0
        let dLon = span / max(20_000, 111_320 * cos(latitude * .pi / 180))
        let samples = [
            (latitude, longitude),
            (latitude + dLat, longitude),
            (latitude - dLat, longitude),
            (latitude, longitude + dLon),
            (latitude, longitude - dLon)
        ]
        var elevations: [Double] = []
        for sample in samples {
            guard let elev = await elevation(latitude: sample.0, longitude: sample.1) else { return nil }
            elevations.append(elev)
        }
        var maxSlope = 0.0
        for index in 1..<elevations.count {
            let degrees = atan2(abs(elevations[index] - elevations[0]), span) * 180 / .pi
            maxSlope = max(maxSlope, degrees)
        }
        let slope = (maxSlope * 10).rounded() / 10
        slopeCache[key] = slope
        saveSlopes()
        return slope
    }

    private static func elevation(latitude: Double, longitude: Double) async -> Double? {
        let z = tileZoom
        let n = pow(2.0, Double(z))
        let xf = (longitude + 180) / 360 * n
        let latRad = latitude * .pi / 180
        let yf = (1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n
        let x = Int(floor(xf))
        let y = Int(floor(yf))
        guard let tile = await tile(x: x, y: y, z: z) else { return nil }
        let px = min(tile.width - 1, max(0, Int((xf - Double(x)) * Double(tile.width))))
        let py = min(tile.height - 1, max(0, Int((yf - Double(y)) * Double(tile.height))))
        let index = (py * tile.width + px) * 4
        guard tile.bytes.count >= index + 3 else { return nil }
        let red = Double(tile.bytes[index])
        let green = Double(tile.bytes[index + 1])
        let blue = Double(tile.bytes[index + 2])
        return red * 256 + green + blue / 256 - 32768
    }

    private static func tile(x: Int, y: Int, z: Int) async -> (width: Int, height: Int, bytes: [UInt8])? {
        let key = "\(z)/\(x)/\(y)"
        if let cached = tilePixels[key] { return cached }
        guard let url = URL(string: "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/\(key).png") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let tile = (width: width, height: height, bytes: bytes)
        tilePixels[key] = tile
        return tile
    }

    private static func publicLand(latitude: Double, longitude: Double) async -> String {
        let key = cacheKey(latitude, longitude)
        if let cached = landCache[key] { return cached }
        if await landHit(layer: 22, latitude: latitude, longitude: longitude) {
            landCache[key] = "BLM"
            return "BLM"
        }
        if await landHit(layer: 24, latitude: latitude, longitude: longitude) {
            landCache[key] = "USFS"
            return "USFS"
        }
        landCache[key] = ""
        return ""
    }

    private static func landHit(layer: Int, latitude: Double, longitude: Double) async -> Bool {
        var parts = URLComponents(string: "https://gis.blm.gov/arcgis/rest/services/lands/BLM_Natl_SMA_LimitedScale/MapServer/\(layer)/query")
        parts?.queryItems = [
            URLQueryItem(name: "geometry", value: "\(longitude),\(latitude)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "returnCountOnly", value: "true"),
            URLQueryItem(name: "f", value: "json")
        ]
        guard let url = parts?.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (root["count"] as? Int ?? 0) > 0
    }

    private static func cacheKey(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }

    private static func loadSlopes() -> [String: Double] {
        guard let data = UserDefaults.standard.data(forKey: "tf-slope-v1"),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return decoded
    }

    private static func saveSlopes() {
        var pairs = Array(slopeCache)
        if pairs.count > 500 { pairs = Array(pairs.prefix(500)) }
        let trimmed = Dictionary(uniqueKeysWithValues: pairs)
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: "tf-slope-v1")
        }
    }
}

private struct CampCellCache: Codable {
    var fetchedAt: Date
    var camps: [DiscoveredTrailSnapshot]
}

enum CampCatalog {
    private static let ttl: TimeInterval = 24 * 60 * 60
    private static let storeKey = "tf-camp-cells-v1"

    static func isMapped(_ id: String) -> Bool {
        id.hasPrefix("osm-camp-") || id.hasPrefix("ridb-") || id.hasPrefix("usfs-rec-") || id.hasPrefix("blm-camp-")
    }

    static func sourceName(_ id: String) -> String {
        if id.hasPrefix("ridb-") { return "Recreation.gov" }
        if id.hasPrefix("usfs-rec-") { return "USFS" }
        if id.hasPrefix("blm-camp-") { return "BLM" }
        if id.hasPrefix("osm-camp-") { return "OpenStreetMap" }
        return "Mapped campsite"
    }

    static func latestStamp() -> Date? {
        loadCells().values.map(\.fetchedAt).max()
    }

    static func trails(around center: CLLocationCoordinate2D, force: Bool) async -> [OverlandTrail] {
        let key = cellKey(center)
        var cells = loadCells()
        if !force, let cached = cells[key], Date().timeIntervalSince(cached.fetchedAt) < ttl {
            return cached.camps.map(\.trail)
        }
        async let usfs = usfsCampgrounds(center)
        async let blm = blmCampgrounds(center)
        async let ridb = ridbCampgrounds(center)
        let loaded = await usfs + blm + ridb
        let unique = dedupe(loaded)
        cells[key] = CampCellCache(fetchedAt: Date(), camps: unique.map(DiscoveredTrailSnapshot.init))
        if cells.count > 24 {
            let extras = cells.sorted { $0.value.fetchedAt < $1.value.fetchedAt }.prefix(cells.count - 24).map(\.key)
            extras.forEach { cells.removeValue(forKey: $0) }
        }
        saveCells(cells)
        UserDefaults.standard.set(center.latitude, forKey: "tf-camp-lat")
        UserDefaults.standard.set(center.longitude, forKey: "tf-camp-lon")
        return unique
    }

    static func refreshSavedCenters() async {
        var centers: [CLLocationCoordinate2D] = []
        let lat = UserDefaults.standard.double(forKey: "tf-camp-lat")
        let lon = UserDefaults.standard.double(forKey: "tf-camp-lon")
        if abs(lat) > 0.01 || abs(lon) > 0.01 {
            centers.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        for pack in CockpitStore.loadPacks() {
            if let minLat = pack.minLat, let minLon = pack.minLon, let maxLat = pack.maxLat, let maxLon = pack.maxLon {
                centers.append(CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2))
            }
        }
        var merged = CockpitStore.loadDiscoveredTrails()
        for center in centers {
            let fresh = await trails(around: center, force: false)
            guard !fresh.isEmpty else { continue }
            var byID: [String: OverlandTrail] = [:]
            merged.forEach { byID[$0.id] = $0 }
            fresh.forEach { byID[$0.id] = $0 }
            merged = dedupe(Array(byID.values))
        }
        if !merged.isEmpty {
            CockpitStore.saveDiscoveredTrails(Array(merged.prefix(200)))
        }
    }

    static func dedupe(_ trails: [OverlandTrail]) -> [OverlandTrail] {
        let camps = trails.filter { rank($0) < 9 }.sorted { rank($0) < rank($1) }
        let roads = trails.filter { rank($0) >= 9 }
        var kept: [OverlandTrail] = []
        for camp in camps {
            let duplicate = kept.contains { prior in
                distance(prior, camp) < 400 && namesSimilar(prior.name, camp.name)
            }
            if !duplicate { kept.append(camp) }
        }
        return roads + kept
    }

    private static func rank(_ trail: OverlandTrail) -> Int {
        if trail.id.hasPrefix("ridb-") { return 1 }
        if trail.id.hasPrefix("usfs-rec-") { return 2 }
        if trail.id.hasPrefix("blm-camp-") { return 3 }
        if trail.id.hasPrefix("osm-camp-") { return 4 }
        return 9
    }

    private static func namesSimilar(_ left: String, _ right: String) -> Bool {
        let a = norm(left)
        let b = norm(right)
        guard a.count >= 4, b.count >= 4 else { return false }
        if a.contains(b) || b.contains(a) { return true }
        let tokens = a.split(separator: " ").filter { $0.count >= 4 }
        let other = Set(b.split(separator: " "))
        return tokens.contains { other.contains($0) }
    }

    private static func norm(_ name: String) -> String {
        let head = name.split(separator: "·").first.map(String.init) ?? name
        let lowered = head.lowercased()
        let cleaned = lowered.replacingOccurrences(of: "campground", with: " ")
            .replacingOccurrences(of: "campsite", with: " ")
            .replacingOccurrences(of: "camping", with: " ")
        return cleaned.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(String.init).joined()
            .split(separator: " ").joined(separator: " ")
    }

    private static func distance(_ left: OverlandTrail, _ right: OverlandTrail) -> CLLocationDistance {
        CLLocation(latitude: left.centerLat, longitude: left.centerLon)
            .distance(from: CLLocation(latitude: right.centerLat, longitude: right.centerLon))
    }

    private static func cellKey(_ center: CLLocationCoordinate2D) -> String {
        let lat = (center.latitude * 5).rounded() / 5
        let lon = (center.longitude * 5).rounded() / 5
        return String(format: "%.1f,%.1f", lat, lon)
    }

    private static func loadCells() -> [String: CampCellCache] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let cells = try? JSONDecoder().decode([String: CampCellCache].self, from: data) else { return [:] }
        return cells
    }

    private static func saveCells(_ cells: [String: CampCellCache]) {
        if let data = try? JSONEncoder().encode(cells) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private static func usfsCampgrounds(_ center: CLLocationCoordinate2D) async -> [OverlandTrail] {
        await arcgis(
            "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_RecreationOpportunities_01/MapServer/0/query",
            center: center,
            where: "markeractivity='Campground Camping'"
        ) { attributes in
            campTrail(
                id: "usfs-rec-\(text(attributes["recareaid"]) ?? text(attributes["objectid"]) ?? UUID().uuidString)",
                name: text(attributes["recareaname"]) ?? "",
                agency: "USFS",
                lat: number(attributes["latitude"]),
                lon: number(attributes["longitude"]),
                source: "USFS"
            )
        }
    }

    private static func blmCampgrounds(_ center: CLLocationCoordinate2D) async -> [OverlandTrail] {
        let facilities = await arcgis(
            "https://gis.blm.gov/arcgis/rest/services/recreation/BLM_Natl_Recreation_Sites_Facilities/MapServer/8/query",
            center: center,
            where: "1=1"
        ) { attributes in
            campTrail(
                id: "blm-camp-\(text(attributes["FacilityID"]) ?? text(attributes["OBJECTID"]) ?? UUID().uuidString)",
                name: text(attributes["FacilityName"]) ?? "",
                agency: "BLM",
                lat: number(attributes["FacilityLatitude"]),
                lon: number(attributes["FacilityLongitude"]),
                source: "BLM"
            )
        }
        let points = await arcgis(
            "https://gis.blm.gov/arcgis/rest/services/recreation/BLM_Natl_Recs_pts/MapServer/2/query",
            center: center,
            where: "1=1"
        ) { attributes in
            campTrail(
                id: "blm-camp-pt-\(text(attributes["OBJECTID"]) ?? UUID().uuidString)",
                name: text(attributes["FET_NAME"]) ?? "",
                agency: "BLM",
                lat: number(attributes["LAT"]),
                lon: number(attributes["LONG"]),
                source: "BLM"
            )
        }
        return facilities + points
    }

    private static func ridbCampgrounds(_ center: CLLocationCoordinate2D) async -> [OverlandTrail] {
        let key = (Bundle.main.object(forInfoDictionaryKey: "RIDBAPIKey") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        var parts = URLComponents(string: "https://ridb.recreation.gov/api/v1/facilities")
        parts?.queryItems = [
            URLQueryItem(name: "latitude", value: String(center.latitude)),
            URLQueryItem(name: "longitude", value: String(center.longitude)),
            URLQueryItem(name: "radius", value: "15"),
            URLQueryItem(name: "limit", value: "40"),
            URLQueryItem(name: "offset", value: "0")
        ]
        guard let url = parts?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 14
        request.setValue(key, forHTTPHeaderField: "apikey")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["RECDATA"] as? [[String: Any]] else { return [] }
        let facilities = rows.filter {
            let kind = (text($0["FacilityTypeDescription"]) ?? "") + " " + (text($0["FacilityName"]) ?? "")
            return kind.range(of: "camp", options: .caseInsensitive) != nil
        }.prefix(20)
        var trails: [OverlandTrail] = facilities.compactMap { row in
            campTrail(
                id: "ridb-\(text(row["FacilityID"]) ?? UUID().uuidString)",
                name: text(row["FacilityName"]) ?? "",
                agency: "Recreation.gov",
                lat: number(row["FacilityLatitude"]),
                lon: number(row["FacilityLongitude"]),
                source: "Recreation.gov"
            )
        }
        for row in facilities.prefix(3) where (text(row["FacilityTypeDescription"]) ?? "").localizedCaseInsensitiveContains("campground") {
            guard let id = text(row["FacilityID"]),
                  let siteURL = URL(string: "https://ridb.recreation.gov/api/v1/facilities/\(id)/campsites?limit=8&offset=0") else { continue }
            var siteRequest = URLRequest(url: siteURL)
            siteRequest.timeoutInterval = 12
            siteRequest.setValue(key, forHTTPHeaderField: "apikey")
            guard let (siteData, siteResponse) = try? await URLSession.shared.data(for: siteRequest),
                  let siteHTTP = siteResponse as? HTTPURLResponse, siteHTTP.statusCode == 200,
                  let siteRoot = try? JSONSerialization.jsonObject(with: siteData) as? [String: Any],
                  let sites = siteRoot["RECDATA"] as? [[String: Any]] else { continue }
            let facility = text(row["FacilityName"]) ?? "Camp"
            for site in sites {
                if let trail = campTrail(
                    id: "ridb-site-\(text(site["CampsiteID"]) ?? UUID().uuidString)",
                    name: "\(facility) \(text(site["CampsiteName"]) ?? "site")",
                    agency: "Recreation.gov",
                    lat: number(site["CampsiteLatitude"]),
                    lon: number(site["CampsiteLongitude"]),
                    source: "Recreation.gov"
                ) {
                    trails.append(trail)
                }
            }
        }
        return trails
    }

    private static func arcgis(
        _ raw: String,
        center: CLLocationCoordinate2D,
        where clause: String,
        read: ([String: Any]) -> OverlandTrail?
    ) async -> [OverlandTrail] {
        var parts = URLComponents(string: raw)
        parts?.queryItems = [
            URLQueryItem(name: "where", value: clause),
            URLQueryItem(name: "geometry", value: "\(center.longitude),\(center.latitude)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "distance", value: "18000"),
            URLQueryItem(name: "units", value: "esriSRUnit_Meter"),
            URLQueryItem(name: "outFields", value: "*"),
            URLQueryItem(name: "returnGeometry", value: "false"),
            URLQueryItem(name: "resultRecordCount", value: "40"),
            URLQueryItem(name: "f", value: "json")
        ]
        guard let url = parts?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 14
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }
        return features.compactMap { feature in
            let attributes = feature["attributes"] as? [String: Any] ?? [:]
            return read(attributes)
        }
    }

    private static func campTrail(id: String, name: String, agency: String, lat: Double?, lon: Double?, source: String) -> OverlandTrail? {
        guard let lat, let lon, abs(lat) <= 90, abs(lon) <= 180, !name.isEmpty else { return nil }
        if abs(lat) < 0.01 && abs(lon) < 0.01 { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        return OverlandTrail(
            id: id,
            name: name,
            region: "Camp",
            agency: agency,
            distanceMi: 0.1,
            peakElevFt: 0,
            reqClearanceIn: 8.6,
            minCanopyFt: 12.5,
            waterCrossingIn: 0,
            reqLocker: false,
            gateStatus: "CHECK",
            snotelSnowIn: 0,
            usgsFlowCfs: 0,
            state: USStateLocator.code(latitude: lat, longitude: lon, tagged: nil),
            centerLat: lat,
            centerLon: lon,
            coordinates: [coordinate],
            flatCamps: [(name: "\(name) · Mapped campsite · \(source) · slope unknown", lat: lat, lon: lon, slopeDeg: -1, starlinkPct: 0)],
            legalStatus: "agency"
        )
    }

    private static func text(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
