import CoreLocation
import Foundation

enum CockpitDetent: String, CaseIterable, Identifiable {
    case peek = "Map"
    case half = "Split"
    case full = "Full"

    var id: String { rawValue }
}

enum BasemapChoice: String, CaseIterable, Identifiable {
    case hybrid = "Hybrid Satellite+Topo"
    case standard = "Standard / Topo Vector"
    case imagery = "High-Res Satellite"

    var id: String { rawValue }
}

enum TrailReportStatus: String, CaseIterable, Identifiable {
    case open = "Open & Clear"
    case mud = "Mud / Snow"
    case tree = "Downed Tree"
    case washout = "Washout"
    case gate = "Gate Locked"

    var id: String { rawValue }

    var communityLabel: String {
        switch self {
        case .open: return "✅ Open & Clear"
        case .mud: return "❄️ Mud / Snow"
        case .tree: return "🌲 Downed Tree"
        case .washout: return "⚠️ Washout"
        case .gate: return "🔒 Gate Locked"
        }
    }
}

struct TrailConditionReport: Codable, Identifiable {
    var id: String
    var trailID: String
    var status: String
    var createdAt: Date
    var queuedOffline: Bool
    var latitude: Double
    var longitude: Double
    var confirmations: Int
    var cleared: Bool
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, trailID, status, createdAt, queuedOffline, latitude, longitude, confirmations, cleared, updatedAt
    }

    init(
        id: String,
        trailID: String,
        status: String,
        createdAt: Date,
        queuedOffline: Bool,
        latitude: Double = 0,
        longitude: Double = 0,
        confirmations: Int = 1,
        cleared: Bool = false,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.trailID = trailID
        self.status = status
        self.createdAt = createdAt
        self.queuedOffline = queuedOffline
        self.latitude = latitude
        self.longitude = longitude
        self.confirmations = confirmations
        self.cleared = cleared
        self.updatedAt = updatedAt ?? createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        trailID = try container.decode(String.self, forKey: .trailID)
        status = try container.decode(String.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        queuedOffline = try container.decodeIfPresent(Bool.self, forKey: .queuedOffline) ?? false
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude) ?? 0
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude) ?? 0
        confirmations = try container.decodeIfPresent(Int.self, forKey: .confirmations) ?? 1
        cleared = try container.decodeIfPresent(Bool.self, forKey: .cleared) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(trailID, forKey: .trailID)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(queuedOffline, forKey: .queuedOffline)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(confirmations, forKey: .confirmations)
        try container.encode(cleared, forKey: .cleared)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

enum CommunityStatus {
    static func badge(for trailID: String, reports: [TrailConditionReport], publishedGate: String) -> String {
        let openReports = reports.filter { $0.trailID == trailID && !$0.cleared }
        guard let latest = openReports.max(by: { $0.updatedAt < $1.updatedAt }) else { return publishedGate }
        switch latest.status {
        case TrailReportStatus.gate.rawValue, TrailReportStatus.washout.rawValue:
            return "CLOSED (USER REPORT)"
        case TrailReportStatus.tree.rawValue, TrailReportStatus.mud.rawValue:
            return "CAUTION (USER REPORT)"
        case TrailReportStatus.open.rawValue:
            return "OPEN (USER REPORT)"
        default:
            return publishedGate
        }
    }
}

struct OfflineCorridorPack: Codable, Identifiable {
    var id: String
    var name: String
    var trailID: String
    var tier: String
    var nominalMegabytes: Int
    var savedAt: Date
    var vertexCount: Int
    var areaSqMiles: Int? = nil
    var minLat: Double? = nil
    var maxLat: Double? = nil
    var minLon: Double? = nil
    var maxLon: Double? = nil

    var areaBadge: String {
        guard minLat != nil, maxLat != nil, minLon != nil, maxLon != nil else {
            return "\(tier) • \(vertexCount) pts • saved on this iPhone"
        }
        return "\(name) • \(tier)"
    }
}

struct RideSample: Identifiable {
    let id: Int
    let mile: Double
    let elevationFt: Int
    let gradePct: Double
    let obstacle: String?
    let coordinate: CLLocationCoordinate2D
}

struct MapHazard: Identifiable {
    let id: String
    let title: String
    let coordinates: [CLLocationCoordinate2D]
    let point: CLLocationCoordinate2D
    let radiusMeters: Double
}

struct SavedMarker: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var category: String
    var latitude: Double
    var longitude: Double
    var createdAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct DroppedPinTarget: Identifiable {
    let id: UUID
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct DiscoveredTrailSnapshot: Codable {
    struct Coord: Codable {
        var lat: Double
        var lon: Double
    }

    struct Pad: Codable {
        var name: String
        var lat: Double
        var lon: Double
        var slopeDeg: Double
        var starlinkPct: Int
    }

    var id: String
    var name: String
    var region: String
    var agency: String
    var state: String
    var distanceMi: Double
    var reqClearanceIn: Double
    var minCanopyFt: Double
    var waterCrossingIn: Int
    var reqLocker: Bool
    var centerLat: Double
    var centerLon: Double
    var legalStatus: String
    var coordinates: [Coord]
    var pads: [Pad]

    init(_ trail: OverlandTrail) {
        id = trail.id
        name = trail.name
        region = trail.region
        agency = trail.agency
        state = trail.state
        distanceMi = trail.distanceMi
        reqClearanceIn = trail.reqClearanceIn
        minCanopyFt = trail.minCanopyFt
        waterCrossingIn = trail.waterCrossingIn
        reqLocker = trail.reqLocker
        centerLat = trail.centerLat
        centerLon = trail.centerLon
        legalStatus = trail.legalStatus
        let source = trail.coordinates
        let limit = 60
        if source.count <= limit {
            coordinates = source.map { Coord(lat: $0.latitude, lon: $0.longitude) }
        } else {
            let step = Double(source.count - 1) / Double(limit - 1)
            coordinates = (0..<limit).map { index in
                let point = source[min(source.count - 1, Int((Double(index) * step).rounded()))]
                return Coord(lat: point.latitude, lon: point.longitude)
            }
        }
        pads = trail.flatCamps.map {
            Pad(name: $0.name, lat: $0.lat, lon: $0.lon, slopeDeg: $0.slopeDeg, starlinkPct: $0.starlinkPct)
        }
    }

    var trail: OverlandTrail {
        OverlandTrail(
            id: id,
            name: name,
            region: region,
            agency: agency,
            distanceMi: distanceMi,
            peakElevFt: 0,
            reqClearanceIn: reqClearanceIn,
            minCanopyFt: minCanopyFt,
            waterCrossingIn: waterCrossingIn,
            reqLocker: reqLocker,
            gateStatus: "CHECK",
            snotelSnowIn: 0,
            usgsFlowCfs: 0,
            state: state,
            centerLat: centerLat,
            centerLon: centerLon,
            coordinates: coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
            flatCamps: pads.map { (name: $0.name, lat: $0.lat, lon: $0.lon, slopeDeg: $0.slopeDeg, starlinkPct: $0.starlinkPct) },
            legalStatus: legalStatus
        )
    }
}

enum CockpitStore {
    private static let reportsKey = "trailforge.trailReports"
    private static let packsKey = "trailforge.offlinePacks"
    private static let hazardsKey = "trailforge.hazardPins"
    private static let recordedRoutesKey = "trailforge.recordedRoutes"
    private static let savedMarkersKey = "trailforge.savedMarkers.v1"
    private static let discoveredTrailsKey = "trailforge.discoveredTrails"

    static func loadReports() -> [TrailConditionReport] {
        decode([TrailConditionReport].self, key: reportsKey) ?? []
    }

    static func saveReports(_ reports: [TrailConditionReport]) {
        encode(reports, key: reportsKey)
    }

    static func loadPacks() -> [OfflineCorridorPack] {
        decode([OfflineCorridorPack].self, key: packsKey) ?? []
    }

    static func savePacks(_ packs: [OfflineCorridorPack]) {
        encode(packs, key: packsKey)
    }

    static func loadHazards() -> [DroppedHazard] {
        decode([DroppedHazard].self, key: hazardsKey) ?? []
    }

    static func saveHazards(_ pins: [DroppedHazard]) {
        encode(Array(pins.prefix(80)), key: hazardsKey)
    }

    static func loadRecordedRoutes() -> [RecordedTrailRoute] {
        if let stored = decode([RecordedTrailRoute].self, key: recordedRoutesKey), !stored.isEmpty {
            return stored
        }
        guard let data = try? Data(contentsOf: recordedRoutesURL) else { return [] }
        return (try? JSONDecoder().decode([RecordedTrailRoute].self, from: data)) ?? []
    }

    static func saveRecordedRoutes(_ routes: [RecordedTrailRoute]) {
        encode(routes, key: recordedRoutesKey)
        if let data = try? JSONEncoder().encode(routes) {
            try? data.write(to: recordedRoutesURL, options: .atomic)
        }
    }

    static func loadSavedMarkers() -> [SavedMarker] {
        decode([SavedMarker].self, key: savedMarkersKey) ?? []
    }

    static func saveSavedMarkers(_ markers: [SavedMarker]) {
        encode(markers, key: savedMarkersKey)
    }

    static func loadDiscoveredTrails() -> [OverlandTrail] {
        (decode([DiscoveredTrailSnapshot].self, key: discoveredTrailsKey) ?? []).map(\.trail)
    }

    static func saveDiscoveredTrails(_ trails: [OverlandTrail]) {
        encode(trails.prefix(200).map(DiscoveredTrailSnapshot.init), key: discoveredTrailsKey)
    }

    private static var recordedRoutesURL: URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("trailforge-recorded-routes.json")
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum RideProfile {
    static func samples(for trail: OverlandTrail) -> [RideSample] {
        let source = trail.coordinates
        guard source.count >= 2 else { return [] }
        let stride = max(1, source.count / 28)
        var picked: [CLLocationCoordinate2D] = []
        var index = 0
        while index < source.count {
            picked.append(source[index])
            index += stride
        }
        if let last = source.last, let end = picked.last, meters(end, last) > 20 {
            picked.append(last)
        }
        let peak = max(200, trail.peakElevFt)
        var miles = 0.0
        var previousElevation = Double(peak) * 0.64
        var samples: [RideSample] = []
        for (offset, point) in picked.enumerated() {
            if offset > 0 {
                miles += meters(picked[offset - 1], point) / 1609.344
            }
            let fraction = Double(offset) / Double(max(picked.count - 1, 1))
            let elevation = Double(peak) * (0.64 + 0.36 * sin(fraction * .pi))
            let run = offset == 0 ? 160.0 : max(40, meters(picked[offset - 1], point))
            let grade = ((elevation - previousElevation) / run) * 100
            previousElevation = elevation
            samples.append(RideSample(
                id: offset,
                mile: miles,
                elevationFt: Int(elevation.rounded()),
                gradePct: grade,
                obstacle: nil,
                coordinate: point
            ))
        }
        return markObstacles(samples, trail: trail)
    }

    private static func markObstacles(_ samples: [RideSample], trail: OverlandTrail) -> [RideSample] {
        guard !samples.isEmpty else { return samples }
        var marked = samples
        func tag(_ fraction: Double, _ label: String) {
            let index = min(marked.count - 1, max(0, Int((fraction * Double(marked.count - 1)).rounded())))
            let sample = marked[index]
            guard sample.obstacle == nil else { return }
            marked[index] = RideSample(
                id: sample.id,
                mile: sample.mile,
                elevationFt: sample.elevationFt,
                gradePct: sample.gradePct,
                obstacle: label,
                coordinate: sample.coordinate
            )
        }
        if trail.waterCrossingIn > 0 { tag(0.34, "💧 Ford") }
        if trail.reqClearanceIn >= 9.5 || trail.reqLocker { tag(0.62, "🪨 Ledge") }
        if let pad = trail.campSpots.first {
            let nearest = marked.enumerated().min { meters($0.element.coordinate, pad.coordinate) < meters($1.element.coordinate, pad.coordinate) }
            if let nearest {
                let sample = nearest.element
                marked[nearest.offset] = RideSample(
                    id: sample.id,
                    mile: sample.mile,
                    elevationFt: sample.elevationFt,
                    gradePct: sample.gradePct,
                    obstacle: "⛺ <3° Pad",
                    coordinate: sample.coordinate
                )
            }
        }
        return marked
    }

    private static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

enum TrailHazards {
    static func localMarkers(on trail: OverlandTrail) -> [MapHazard] {
        let line = trail.coordinates
        guard line.count >= 2 else { return [] }
        var hazards: [MapHazard] = []
        if trail.waterCrossingIn > 0, let point = point(on: line, fraction: 0.34) {
            hazards.append(MapHazard(id: "\(trail.id)-ford", title: "Ford \(trail.waterCrossingIn)\"", coordinates: [], point: point, radiusMeters: 220))
        }
        if trail.reqClearanceIn >= 9.5 || trail.reqLocker, let point = point(on: line, fraction: 0.62) {
            hazards.append(MapHazard(id: "\(trail.id)-ledge", title: "Ledge", coordinates: [], point: point, radiusMeters: 180))
        }
        return hazards
    }

    static func fetchRemote(near coordinate: CLLocationCoordinate2D) async -> [MapHazard] {
        async let quakes = fetchQuakes(near: coordinate)
        async let fires = fetchFires(near: coordinate)
        return await quakes + fires
    }

    private static func fetchQuakes(near coordinate: CLLocationCoordinate2D) async -> [MapHazard] {
        var components = URLComponents(string: "https://earthquake.usgs.gov/fdsnws/event/1/query")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "geojson"),
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "maxradiuskm", value: "120"),
            URLQueryItem(name: "limit", value: "6"),
            URLQueryItem(name: "orderby", value: "time")
        ]
        guard let url = components?.url, let root = await json(url) else { return [] }
        let features = root["features"] as? [[String: Any]] ?? []
        return features.compactMap { feature in
            guard let geometry = feature["geometry"] as? [String: Any],
                  let coordinates = geometry["coordinates"] as? [Any], coordinates.count >= 2,
                  let lon = double(coordinates[0]), let lat = double(coordinates[1]) else { return nil }
            let properties = feature["properties"] as? [String: Any] ?? [:]
            let title = (properties["title"] as? String) ?? "USGS earthquake"
            let identifier = (feature["id"] as? String) ?? "\(lat),\(lon)"
            return MapHazard(
                id: "usgs-\(identifier)",
                title: title,
                coordinates: [],
                point: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                radiusMeters: 2_400
            )
        }
    }

    private static func fetchFires(near coordinate: CLLocationCoordinate2D) async -> [MapHazard] {
        var components = URLComponents(string: "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Interagency_Perimeters_Current/FeatureServer/0/query")
        components?.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "geometry", value: "\(coordinate.longitude),\(coordinate.latitude)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "distance", value: "80000"),
            URLQueryItem(name: "units", value: "esriSRUnit_Meter"),
            URLQueryItem(name: "outFields", value: "poly_IncidentName,attr_IncidentName"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "resultRecordCount", value: "3"),
            URLQueryItem(name: "f", value: "json")
        ]
        guard let url = components?.url, let root = await json(url) else { return [] }
        let features = root["features"] as? [[String: Any]] ?? []
        return features.enumerated().compactMap { index, feature in
            let attributes = feature["attributes"] as? [String: Any] ?? [:]
            let name = (attributes["poly_IncidentName"] as? String)
                ?? (attributes["attr_IncidentName"] as? String)
                ?? "NIFC perimeter"
            guard let geometry = feature["geometry"] as? [String: Any],
                  let ring = downsample(firstRing(geometry["rings"]), limit: 28), ring.count >= 4 else { return nil }
            let anchor = ring[ring.count / 2]
            return MapHazard(id: "nifc-\(index)-\(name)", title: name, coordinates: ring, point: anchor, radiusMeters: 0)
        }
    }

    private static func firstRing(_ raw: Any?) -> [CLLocationCoordinate2D] {
        guard let rings = raw as? [Any], let ring = rings.first as? [Any] else { return [] }
        return ring.compactMap { pairAny in
            guard let pair = pairAny as? [Any], pair.count >= 2,
                  let x = double(pair[0]), let y = double(pair[1]), abs(x) <= 180, abs(y) <= 90 else { return nil }
            return CLLocationCoordinate2D(latitude: y, longitude: x)
        }
    }

    private static func downsample(_ ring: [CLLocationCoordinate2D], limit: Int) -> [CLLocationCoordinate2D]? {
        guard ring.count >= 4 else { return nil }
        if ring.count <= limit { return ring }
        let step = Double(ring.count - 1) / Double(limit - 1)
        var kept: [CLLocationCoordinate2D] = []
        for index in 0..<limit {
            kept.append(ring[min(ring.count - 1, Int((Double(index) * step).rounded()))])
        }
        return kept
    }

    private static func point(on line: [CLLocationCoordinate2D], fraction: Double) -> CLLocationCoordinate2D? {
        guard !line.isEmpty else { return nil }
        let index = min(line.count - 1, max(0, Int((fraction * Double(line.count - 1)).rounded())))
        return line[index]
    }

    private static func json(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private static func double(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

enum GPXExchange {
    static let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="TrailForge Sample" xmlns="http://www.topografix.com/GPX/1/1">
      <wpt lat="37.958900" lon="-107.735200"><name>Imogene Basin</name></wpt>
      <wpt lat="37.937500" lon="-107.810800"><name>Telluride Side</name></wpt>
      <trk><name>Sample Spur</name><trkseg>
        <trkpt lat="38.022800" lon="-107.671400"></trkpt>
        <trkpt lat="37.981420" lon="-107.734110"></trkpt>
        <trkpt lat="37.958900" lon="-107.735200"></trkpt>
        <trkpt lat="37.937500" lon="-107.810800"></trkpt>
      </trkseg></trk>
    </gpx>
    """

    static func coordinates(in xml: String) -> [CLLocationCoordinate2D] {
        let pattern = #"(?:lat|latitude)="(-?\d+\.?\d*)"\s+(?:lon|longitude)="(-?\d+\.?\d*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return regex.matches(in: xml, options: [], range: range).compactMap { match in
            guard let latRange = Range(match.range(at: 1), in: xml),
                  let lonRange = Range(match.range(at: 2), in: xml),
                  let lat = Double(xml[latRange]), let lon = Double(xml[lonRange]) else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
}
