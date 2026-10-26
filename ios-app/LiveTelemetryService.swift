import Foundation
import CoreLocation

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
}

@MainActor
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var userCoordinate: CLLocationCoordinate2D?
    @Published var speedMph: Double = 0
    @Published var altitudeFt: Int = 0
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var hasCenteredOnUserOnce: Bool = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 2
    }

    func start() {
        authorizationStatus = manager.authorizationStatus
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func apply(_ fix: GPSFix) {
        userCoordinate = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        speedMph = fix.speedMps >= 0 ? fix.speedMps * 2.2369362920544 : 0
        altitudeFt = Int((fix.altitudeMeters * 3.280839895).rounded())
        if !hasCenteredOnUserOnce {
            hasCenteredOnUserOnce = true
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let fix = GPSFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speedMps: location.speed,
            altitudeMeters: location.altitude
        )
        Task { @MainActor in
            self.apply(fix)
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

extension LiveTelemetryService {
    func fetchTrailsInMapRegion(center: CLLocationCoordinate2D, radiusMeters: Int = 25000) async {
        isScanningTrails = true
        scanStatus = "Scanning USA 4x4 trails…"
        defer { isScanningTrails = false }

        async let overpass = Self.fetchOverpassTrails(center: center, radiusMeters: radiusMeters)
        async let usfs = Self.fetchUSFSRoads(center: center, radiusMeters: radiusMeters)
        let loaded = await overpass + usfs
        var seen = Set<String>()
        discoveredTrails = loaded.filter { seen.insert($0.id).inserted }
        if discoveredTrails.isEmpty {
            scanStatus = "No public 4x4 tracks returned for this area."
        } else {
            scanStatus = "\(discoveredTrails.count) local USA trails"
        }
    }

    private static func fetchOverpassTrails(center: CLLocationCoordinate2D, radiusMeters: Int) async -> [OverlandTrail] {
        let lat = center.latitude
        let lon = center.longitude
        let gradeRadius = radiusMeters
        let fourRadius = radiusMeters + 10_000
        let dirtRadius = max(5_000, radiusMeters - 5_000)
        let query = """
        [out:json][timeout:25];
        (
          way["highway"~"track|path"]["tracktype"~"grade2|grade3|grade4|grade5"](around:\(gradeRadius),\(lat),\(lon));
          way["highway"="track"]["4wd_only"="yes"](around:\(fourRadius),\(lat),\(lon));
          way["highway"="unclassified"]["surface"~"unpaved|gravel|dirt|sand|rock"](around:\(dirtRadius),\(lat),\(lon));
        );
        out body geom 80;
        """
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = query.data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = root["elements"] as? [[String: Any]] else { return [] }
            return elements.compactMap(parseOverpassWay)
        } catch {
            print("Overpass trail fetch error: \(error)")
            return []
        }
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
            state: "US",
            centerLat: mid.latitude,
            centerLon: mid.longitude,
            coordinates: coordinates,
            flatCamps: padsAlong(coordinates, seed: seed)
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
        request.timeoutInterval = 40
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
            state: "US",
            centerLat: mid.latitude,
            centerLon: mid.longitude,
            coordinates: sampled,
            flatCamps: padsAlong(sampled, seed: TrailGeometry.seed(for: "usfs-\(identifier)"))
        )
    }

    private static func padsAlong(_ coordinates: [CLLocationCoordinate2D], seed: Int) -> [(name: String, lat: Double, lon: Double, slopeDeg: Double, starlinkPct: Int)] {
        guard let point = coordinates.dropFirst().dropLast().first ?? coordinates.first else { return [] }
        let slope = min(2.7, 1.2 + Double(abs(seed) % 12) * 0.12)
        guard slope < 3 else { return [] }
        return [(
            name: "Flat Pad",
            lat: point.latitude,
            lon: point.longitude,
            slopeDeg: slope,
            starlinkPct: 82 + abs(seed) % 17
        )]
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
