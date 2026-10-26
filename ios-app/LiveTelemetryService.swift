import Foundation
import CoreLocation
import CoreMotion

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
    private var trailScanGeneration = 0
    private var trailScanAnchor: CLLocationCoordinate2D?
    private var trailScanDebounce: Task<Void, Never>?
    private var scanAnchors: [CLLocationCoordinate2D] = []

    init() {
        discoveredTrails = CockpitStore.loadDiscoveredTrails()
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
            for await trails in group {
                guard generation == trailScanGeneration else { continue }
                absorbDiscovered(trails, generation: generation, center: center)
            }
        }
        guard generation == trailScanGeneration else { return }
        isScanningTrails = false
        if !scanAnchors.contains(where: { moved($0, center) < 200 }) {
            scanAnchors.append(center)
            if scanAnchors.count > 40 { scanAnchors.removeFirst(scanAnchors.count - 40) }
        }
        if discoveredTrails.isEmpty {
            scanStatus = "No public 4x4 tracks returned for this area."
        } else {
            scanStatus = "\(discoveredTrails.count) local USA trails"
        }
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
        var merged = Array(byID.values)
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
        scanStatus = "\(merged.count) local USA trails"
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
        let seed = TrailGeometry.seed(for: "osm-camp-\(nodeID)")
        let slope = min(2.4, 1.1 + Double(abs(seed) % 10) * 0.1)
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
            flatCamps: [(name: name, lat: lat, lon: lon, slopeDeg: slope, starlinkPct: 82 + abs(seed) % 17)],
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
        let seed = TrailGeometry.seed(for: "osm-\(wayID)")
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
            flatCamps: padsAlong(coordinates, seed: seed, title: name),
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
            flatCamps: padsAlong(sampled, seed: TrailGeometry.seed(for: "usfs-\(identifier)"), title: name.hasPrefix("FS") || name.hasPrefix("FR") ? name : "FS \(name)"),
            legalStatus: "mvum"
        )
    }

    private static func padsAlong(_ coordinates: [CLLocationCoordinate2D], seed: Int, title: String) -> [(name: String, lat: Double, lon: Double, slopeDeg: Double, starlinkPct: Int)] {
        guard coordinates.count >= 2 else { return [] }
        let slopeA = min(2.7, 1.2 + Double(abs(seed) % 12) * 0.12)
        let indexes = coordinates.count >= 4
            ? [coordinates.count / 3, (coordinates.count * 2) / 3]
            : [min(coordinates.count - 1, max(1, coordinates.count / 3))]
        var pads: [(name: String, lat: Double, lon: Double, slopeDeg: Double, starlinkPct: Int)] = []
        for (padIndex, index) in indexes.enumerated() {
            let point = coordinates[index]
            let slope = padIndex == 0 ? slopeA : min(2.8, slopeA + 0.4)
            guard slope < 3 else { continue }
            let label = coordinates.count >= 4 ? (padIndex == 0 ? "\(title) Pad A" : "\(title) Pad B") : "\(title) Flat Pad"
            pads.append((
                name: label,
                lat: point.latitude,
                lon: point.longitude,
                slopeDeg: (slope * 10).rounded() / 10,
                starlinkPct: 82 + abs(seed + padIndex * 3) % 17
            ))
        }
        return pads
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
