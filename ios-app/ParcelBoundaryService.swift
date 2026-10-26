import CoreLocation
import Foundation

enum OwnershipCategory: String, Hashable {
    case publicUSFS
    case publicBLM
    case publicStateDNR
    case publicNPS
    case privateParcel
}

struct PropertyParcel: Identifiable, Hashable {
    let id: String
    let apnLotNumber: String
    let ownerName: String
    let ownerIsPublished: Bool
    let ownershipType: OwnershipCategory
    let acreage: Double
    let subdivisionOrTract: String
    let zoningOrUse: String
    let assessedValueOrStatus: String
    let countyAndState: String
    let centerLat: Double
    let centerLon: Double
    let boundaryCoordinates: [CLLocationCoordinate2D]

    var centerCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
    }

    var accessBadge: String {
        switch ownershipType {
        case .privateParcel:
            return "PRIVATE PROPERTY"
        case .publicUSFS, .publicBLM:
            return "PUBLIC LAND • CAMPING OK"
        case .publicNPS:
            return "PUBLIC LAND • Park rules apply"
        case .publicStateDNR:
            return "PUBLIC LAND • Agency rules apply"
        }
    }

    var pinLabel: String {
        let acres = acreage >= 100 ? String(format: "%.0f ac", acreage) : String(format: "%.1f ac", acreage)
        switch ownershipType {
        case .publicUSFS:
            return "USFS • \(acres)"
        case .publicBLM:
            return "BLM • \(acres)"
        case .publicStateDNR:
            return "DNR • \(acres)"
        case .publicNPS:
            return "NPS • \(acres)"
        case .privateParcel:
            if ownerIsPublished, let token = Self.ownerToken(ownerName) {
                return "\(token) • \(acres)"
            }
            return "\(lotPhrase) • \(acres)"
        }
    }

    private var lotPhrase: String {
        if let range = apnLotNumber.range(of: #"Lot\s+\d+"#, options: .regularExpression) {
            return String(apnLotNumber[range])
        }
        return "Lot"
    }

    private static func ownerToken(_ name: String) -> String? {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "," })
        guard let last = parts.last else { return nil }
        let cleaned = last.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count >= 2, cleaned.count <= 14 else { return nil }
        return cleaned
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        ParcelGeometry.contains(coordinate, in: boundaryCoordinates)
    }

    static func == (lhs: PropertyParcel, rhs: PropertyParcel) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
final class ParcelBoundaryService: ObservableObject {
    @Published private(set) var parcels: [PropertyParcel] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var status = ""

    private var lastFetch: CLLocationCoordinate2D?
    private var generation = 0

    var selected: PropertyParcel? {
        parcels.first { $0.id == selectedID }
    }

    func refresh(around coordinate: CLLocationCoordinate2D, force: Bool = false) {
        if !force, let lastFetch, ParcelGeometry.meters(lastFetch, coordinate) < 1_300 {
            return
        }
        lastFetch = coordinate
        generation += 1
        let token = generation
        isLoading = true
        status = "Scanning parcels…"
        Task {
            let loaded = await ParcelGIS.load(around: coordinate)
            guard token == generation else { return }
            parcels = loaded
            if let selectedID, !loaded.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
            isLoading = false
            let estimated = loaded.filter { $0.id.hasPrefix("est-") }.count
            let published = loaded.count - estimated
            if loaded.isEmpty {
                status = "No parcels returned for this point."
            } else if estimated == 0 {
                status = "\(loaded.count) published parcels"
            } else if published == 0 {
                status = "\(loaded.count) estimated lots • confirm with the county assessor"
            } else {
                status = "\(published) published • \(estimated) estimated lots"
            }
        }
    }

    func select(_ parcel: PropertyParcel?) {
        selectedID = parcel?.id
    }

    func parcel(at coordinate: CLLocationCoordinate2D) -> PropertyParcel? {
        parcels.first { $0.contains(coordinate) }
    }
}

private enum ParcelGIS {
    static func load(around coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        async let blm = fetchBLM(coordinate)
        async let clark = fetchClark(coordinate)
        async let osm = fetchOverpass(coordinate)
        async let place = reverseGeocode(coordinate)
        let (blmParcels, clarkParcels, osmParcels, placemark) = await (blm, clark, osm, place)

        var real: [PropertyParcel] = []
        var seen = Set<String>()
        for parcel in clarkParcels + blmParcels + osmParcels {
            if seen.insert(parcel.id).inserted {
                real.append(parcel)
            }
        }
        real = Array(real.prefix(18))

        var merged = real
        if merged.count < 8 {
            let grid = estimatedGrid(around: coordinate, placemark: placemark, avoiding: real)
            for parcel in grid where merged.count < 16 {
                merged.append(parcel)
            }
        }
        return Array(merged.prefix(18))
    }

    private static func fetchBLM(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let delta = 0.05
        var components = URLComponents(string: "https://gis.blm.gov/arcgis/rest/services/lands/BLM_Natl_SMA_Cached_without_PriUnk/MapServer/identify")
        components?.queryItems = [
            URLQueryItem(name: "geometry", value: "\(lon),\(lat)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "sr", value: "4326"),
            URLQueryItem(name: "layers", value: "all"),
            URLQueryItem(name: "tolerance", value: "8"),
            URLQueryItem(name: "mapExtent", value: "\(lon - delta),\(lat - delta),\(lon + delta),\(lat + delta)"),
            URLQueryItem(name: "imageDisplay", value: "400,400,96"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "f", value: "json")
        ]
        guard let url = components?.url else { return [] }
        guard let root = await json(url: url) else { return [] }
        let rows = root["results"] as? [[String: Any]] ?? []
        return rows.prefix(4).compactMap { row in
            makeEsriParcel(row, near: coordinate, source: "blm", defaultOwner: .publicBLM)
        }
    }

    private static func fetchClark(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        guard lat >= 45.55, lat <= 46.00, lon >= -122.85, lon <= -122.25 else { return [] }
        var components = URLComponents(string: "https://gis.clark.wa.gov/gishome/rest/services/Maps/Assessor/MapServer/0/query")
        components?.queryItems = [
            URLQueryItem(name: "geometry", value: "\(lon),\(lat)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: "*"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "f", value: "json")
        ]
        guard let url = components?.url else { return [] }
        guard let root = await json(url: url) else { return [] }
        let rows = root["features"] as? [[String: Any]] ?? []
        return rows.prefix(4).compactMap { row in
            makeEsriParcel(row, near: coordinate, source: "clark", defaultOwner: .privateParcel)
        }
    }

    private static func fetchOverpass(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let query = """
        [out:json][timeout:12];
        (
          way["place"="plot"](around:900,\(lat),\(lon));
          way["boundary"="lot"](around:900,\(lat),\(lon));
          way["landuse"~"residential|farmland|forest|meadow|industrial"](around:900,\(lat),\(lon));
          way["leisure"~"nature_reserve|park"](around:900,\(lat),\(lon));
          way["addr:housenumber"](around:900,\(lat),\(lon));
        );
        out geom 8;
        """
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = query.data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = root["elements"] as? [[String: Any]] else { return [] }
            return elements.prefix(8).compactMap { element in
                makeOverpassParcel(element, near: coordinate)
            }
        } catch {
            return []
        }
    }

    private static func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> CLPlacemark? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let places = try? await geocoder.reverseGeocodeLocation(location)
        return places?.first
    }

    private static func json(url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private static func makeEsriParcel(
        _ row: [String: Any],
        near: CLLocationCoordinate2D,
        source: String,
        defaultOwner: OwnershipCategory
    ) -> PropertyParcel? {
        let attributes = row["attributes"] as? [String: Any] ?? [:]
        let geometry = row["geometry"] as? [String: Any]
        guard let ring = ParcelGeometry.bestRing(geometry?["rings"], near: near) else { return nil }
        let anchor = ring.first ?? near
        let fallback = String(format: "%.4f-%.4f", anchor.latitude, anchor.longitude)
        let identifier = text(attributes, keys: ["OBJECTID", "objectid", "APN", "PIN", "ACCT", "GLOBALID", "SMA_CODE", "UNIT_ID"]) ?? fallback
        return assemble(
            id: "\(source)-\(identifier)",
            ring: ring,
            near: near,
            attributes: attributes,
            tags: [:],
            defaultOwner: defaultOwner,
            placemark: nil,
            estimated: false
        )
    }

    private static func makeOverpassParcel(_ element: [String: Any], near: CLLocationCoordinate2D) -> PropertyParcel? {
        guard let geometry = element["geometry"] as? [[String: Any]] else { return nil }
        let ring: [CLLocationCoordinate2D] = geometry.compactMap { point in
            guard let lat = double(from: point["lat"]), let lon = double(from: point["lon"]) else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        guard ring.count >= 4, ParcelGeometry.meters(ring[0], ring[ring.count - 1]) < 40 else { return nil }
        let tags = stringMap(element["tags"])
        let wayID = (element["id"] as? NSNumber)?.stringValue ?? (element["id"] as? String) ?? UUID().uuidString
        return assemble(
            id: "osm-\(wayID)",
            ring: ring,
            near: near,
            attributes: [:],
            tags: tags,
            defaultOwner: .privateParcel,
            placemark: nil,
            estimated: false
        )
    }

    private static func assemble(
        id: String,
        ring: [CLLocationCoordinate2D],
        near: CLLocationCoordinate2D,
        attributes: [String: Any],
        tags: [String: String],
        defaultOwner: OwnershipCategory,
        placemark: CLPlacemark?,
        estimated: Bool
    ) -> PropertyParcel? {
        let sourceAcres = acresValue(attributes)
        let measured = ParcelGeometry.acreage(of: ring)
        let acres = sourceAcres ?? measured
        if !estimated, acres > 200_000 || acres < 0.05 { return nil }

        var displayRing = ring
        var outlineNote = ""
        if acres > 2_500 {
            displayRing = ParcelGeometry.localSquare(around: near, halfSpan: 0.006)
            outlineNote = "Map outline clipped from a larger source polygon."
        }
        let simplified = ParcelGeometry.simplify(displayRing, limit: 30)
        guard simplified.count >= 4 else { return nil }
        let center = ParcelGeometry.centroid(simplified)

        let publishedOwner = text(attributes, keys: ["OWNER", "OWNERNAME", "OWNER_NAME", "OWN_NAME", "TAXPAYER", "AGENCY", "ADMIN_AGENCY", "SMA_NAME", "UNIT_NAME", "LOCAL_NAME", "NAME"])
            ?? tags["owner"]
            ?? tags["operator"]
            ?? tags["name"]
        let agencyBlob = [
            publishedOwner,
            text(attributes, keys: ["AGENCY", "ADMIN_AGENCY", "SMA_NAME", "UNIT_NAME", "LANDUSE", "ZONING", "OWNER"]),
            tags["landuse"], tags["leisure"], tags["boundary"], tags["operator"], tags["owner"], tags["name"]
        ].compactMap { $0 }.joined(separator: " ")
        var ownership = classify(agencyBlob, fallback: defaultOwner)
        if publishedOwner == nil, tags["landuse"] == "forest" || tags["leisure"] == "nature_reserve" {
            ownership = tags["operator"]?.localizedCaseInsensitiveContains("BLM") == true ? .publicBLM : .publicUSFS
        }
        if tags["leisure"] == "park", ownership == .privateParcel {
            ownership = tags["operator"]?.localizedCaseInsensitiveContains("National") == true ? .publicNPS : .publicStateDNR
        }

        let ownerIsPublished = publishedOwner != nil
        let ownerName: String
        if let publishedOwner {
            ownerName = publishedOwner
        } else if ownership == .privateParcel {
            ownerName = "Private owner • name not published"
        } else {
            ownerName = fallbackAgencyName(ownership)
        }

        let apn = text(attributes, keys: ["APN", "PIN", "ACCT", "PARCEL", "PARCELID", "PARCEL_ID", "TAXLOT"])
            ?? tags["addr:housenumber"].map { "House \($0)" }
            ?? id
        let tract = text(attributes, keys: ["SUBDIVISION", "TRACT", "LEGAL", "SUBNAME", "QSEC"])
            ?? tags["addr:street"]
            ?? (estimated ? "Estimated street grid" : "Published parcel")
        let zoning = text(attributes, keys: ["ZONING", "LANDUSE", "USE_CODE", "USECODE", "PROP_USE"])
            ?? tags["landuse"]
            ?? tags["leisure"]
            ?? (estimated ? "Estimated lot grid • confirm with the county assessor" : "See county assessor")
        let value = text(attributes, keys: ["ASSESSED", "TOTALVALUE", "MARKET", "VALUE"])
        let county = text(attributes, keys: ["COUNTY", "COUNTY_NAME"])
            ?? placemark?.subAdministrativeArea
            ?? placemark?.locality
            ?? "USA"
        let state = text(attributes, keys: ["STATE", "STATE_CODE"])
            ?? placemark?.administrativeArea
            ?? USStateLocator.code(latitude: center.latitude, longitude: center.longitude)
        let countyAndState = county.contains(state) ? county : "\(county), \(state)"

        var status = value ?? ""
        if ownership == .privateParcel, status.isEmpty {
            status = "Private Property • Permission Required"
        }
        if !outlineNote.isEmpty {
            status = status.isEmpty ? outlineNote : "\(status) • \(outlineNote)"
        }
        if estimated, ownership == .privateParcel {
            status = "Private Property • Permission Required • Estimated lot grid • confirm with the county assessor"
        }

        return PropertyParcel(
            id: id,
            apnLotNumber: apn,
            ownerName: ownerName,
            ownerIsPublished: ownerIsPublished,
            ownershipType: ownership,
            acreage: max(0.1, (sourceAcres ?? ParcelGeometry.acreage(of: simplified))),
            subdivisionOrTract: tract,
            zoningOrUse: zoning,
            assessedValueOrStatus: status,
            countyAndState: countyAndState,
            centerLat: center.latitude,
            centerLon: center.longitude,
            boundaryCoordinates: simplified
        )
    }

    private static func estimatedGrid(
        around coordinate: CLLocationCoordinate2D,
        placemark: CLPlacemark?,
        avoiding real: [PropertyParcel]
    ) -> [PropertyParcel] {
        let step = 0.002
        let state = USStateLocator.code(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            tagged: placemark?.administrativeArea
        )
        let agency = agencyHint(placemark)
        var cells: [PropertyParcel] = []
        var seen = Set<String>()
        for band in [2, 3] {
            let start = -(band - 1)
            let originLat = floor(coordinate.latitude / step) * step
            let originLon = floor(coordinate.longitude / step) * step
            for row in start..<(start + band * 2) {
                for col in start..<(start + band * 2) {
                    if band == 3, abs(row) < 2, abs(col) < 2 { continue }
                    let south = originLat + Double(row) * step
                    let west = originLon + Double(col) * step
                    let center = CLLocationCoordinate2D(latitude: south + step / 2, longitude: west + step / 2)
                    if real.contains(where: { ParcelGeometry.meters($0.centerCoordinate, center) < 400 }) {
                        continue
                    }
                    let latIndex = Int((south / step).rounded())
                    let lonIndex = Int((west / step).rounded())
                    let cellID = "est-\(latIndex)-\(lonIndex)"
                    if !seen.insert(cellID).inserted { continue }
                    let lot = abs((latIndex * 17 &+ lonIndex) % 90) + 1
                    let ring = [
                        CLLocationCoordinate2D(latitude: south, longitude: west),
                        CLLocationCoordinate2D(latitude: south, longitude: west + step),
                        CLLocationCoordinate2D(latitude: south + step, longitude: west + step),
                        CLLocationCoordinate2D(latitude: south + step, longitude: west),
                        CLLocationCoordinate2D(latitude: south, longitude: west)
                    ]
                    let street = [placemark?.subThoroughfare, placemark?.thoroughfare].compactMap { $0 }.joined(separator: " ")
                    let locality = placemark?.subLocality ?? placemark?.locality
                    var tract = street.isEmpty ? "Estimated street grid" : "\(street) • estimated lot"
                    if let locality, !tract.localizedCaseInsensitiveContains(locality) {
                        tract = "\(tract) • \(locality)"
                    }
                    if state == "OR" || state == "WA" {
                        tract += " • approximate cadastral grid, not a surveyed description"
                        if abs(coordinate.latitude - 45.519) < 2, abs(coordinate.longitude + 122.745) < 2 {
                            tract += " • Willamette meridian reference only"
                        }
                    }
                    let ownership = agency?.type ?? .privateParcel
                    let ownerName = agency?.name ?? "Private owner • name not published"
                    let published = agency != nil
                    let acres = ParcelGeometry.acreage(of: ring)
                    let county = placemark?.subAdministrativeArea ?? placemark?.locality ?? "Local"
                    let admin = placemark?.administrativeArea ?? state
                    cells.append(PropertyParcel(
                        id: cellID,
                        apnLotNumber: "APN EST-\(latIndex)-\(lonIndex) • Lot \(lot)",
                        ownerName: ownerName,
                        ownerIsPublished: published,
                        ownershipType: ownership,
                        acreage: acres,
                        subdivisionOrTract: tract,
                        zoningOrUse: "Estimated lot grid • confirm with the county assessor",
                        assessedValueOrStatus: published
                            ? "Estimated boundary • agency name from Apple Maps"
                            : "Private Property • Permission Required • Estimated lot grid • confirm with the county assessor",
                        countyAndState: "\(county), \(admin)",
                        centerLat: center.latitude,
                        centerLon: center.longitude,
                        boundaryCoordinates: ring
                    ))
                    if cells.count >= 16 { return cells }
                }
            }
            if cells.count >= 8 { break }
        }
        return cells
    }

    private static func agencyHint(_ placemark: CLPlacemark?) -> (name: String, type: OwnershipCategory)? {
        let interests = placemark?.areasOfInterest ?? []
        for interest in interests {
            let kind = classify(interest, fallback: .privateParcel)
            if kind != .privateParcel {
                return (interest, kind)
            }
        }
        return nil
    }

    private static func classify(_ text: String, fallback: OwnershipCategory) -> OwnershipCategory {
        let upper = text.uppercased()
        if upper.contains("BLM") || upper.contains("BUREAU OF LAND") { return .publicBLM }
        if upper.contains("NATIONAL PARK") || upper.contains("NPS") || upper.contains("PARK SERVICE") { return .publicNPS }
        if upper.contains("STATE PARK") || upper.contains("STATE FOREST") || upper.contains("DNR") || upper.contains("NATURAL RESOURCES") {
            return .publicStateDNR
        }
        if upper.contains("NATIONAL FOREST") || upper.contains("USFS") || upper.contains("FOREST SERVICE") {
            return .publicUSFS
        }
        if upper.contains("PRIVATE") || upper.contains("PVT") { return .privateParcel }
        return fallback
    }

    private static func fallbackAgencyName(_ ownership: OwnershipCategory) -> String {
        switch ownership {
        case .publicUSFS: return "U.S. Forest Service"
        case .publicBLM: return "Bureau of Land Management (BLM)"
        case .publicStateDNR: return "State land agency"
        case .publicNPS: return "National Park Service"
        case .privateParcel: return "Private owner • name not published"
        }
    }

    private static func text(_ attributes: [String: Any], keys: [String]) -> String? {
        let lowered = Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        for key in keys {
            if let value = lowered[key.lowercased()] {
                let raw = string(from: value).trimmingCharacters(in: .whitespacesAndNewlines)
                let upper = raw.uppercased()
                if !raw.isEmpty, upper != "NULL", upper != "<NULL>", upper != "NONE", raw != "0" {
                    return raw
                }
            }
        }
        return nil
    }

    private static func acresValue(_ attributes: [String: Any]) -> Double? {
        let lowered = Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        for key in ["acres", "gis_acres", "acreage", "calc_acres", "land_acres"] {
            if let number = double(from: lowered[key]), number > 0.05, number < 5_000_000 {
                return number
            }
        }
        if let shape = double(from: lowered["shape_area"] ?? lowered["shape.area"]), shape > 1_000 {
            let acres = shape / 4_046.8564224
            if acres > 0.05, acres < 5_000_000 { return acres }
        }
        return nil
    }

    private static func string(from value: Any) -> String {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }

    private static func double(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return Double(text.replacingOccurrences(of: ",", with: ""))
        default:
            return nil
        }
    }

    private static func stringMap(_ value: Any?) -> [String: String] {
        guard let raw = value as? [String: Any] else { return [:] }
        var map: [String: String] = [:]
        for (key, item) in raw {
            let text = string(from: item)
            if !text.isEmpty { map[key] = text }
        }
        return map
    }
}

private enum ParcelGeometry {
    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func bestRing(_ raw: Any?, near: CLLocationCoordinate2D) -> [CLLocationCoordinate2D]? {
        guard let rings = raw as? [Any] else { return nil }
        let candidates: [[CLLocationCoordinate2D]] = rings.compactMap { ringAny in
            guard let ring = ringAny as? [Any] else { return nil }
            let coords: [CLLocationCoordinate2D] = ring.compactMap { pairAny in
                guard let pair = pairAny as? [Any], pair.count >= 2 else { return nil }
                guard let x = coordinateValue(pair[0]), let y = coordinateValue(pair[1]), abs(x) <= 180, abs(y) <= 90 else { return nil }
                return CLLocationCoordinate2D(latitude: y, longitude: x)
            }
            return coords.count >= 4 ? coords : nil
        }
        let containing = candidates.filter { contains(near, in: $0) }
        let pool = containing.isEmpty ? candidates : containing
        return pool.min { acreage(of: $0) < acreage(of: $1) }
    }

    static func acreage(of ring: [CLLocationCoordinate2D]) -> Double {
        let unique = opened(ring)
        guard unique.count >= 3 else { return 0 }
        let lat0 = unique[0].latitude * .pi / 180
        let metersPerLat = 111_320.0
        let metersPerLon = max(20_000.0, 111_320.0 * cos(lat0))
        var sum = 0.0
        for index in 0..<unique.count {
            let a = unique[index]
            let b = unique[(index + 1) % unique.count]
            sum += (a.longitude * metersPerLon) * (b.latitude * metersPerLat)
            sum -= (b.longitude * metersPerLon) * (a.latitude * metersPerLat)
        }
        return abs(sum / 2) / 4_046.8564224
    }

    static func simplify(_ ring: [CLLocationCoordinate2D], limit: Int) -> [CLLocationCoordinate2D] {
        let unique = opened(ring)
        guard unique.count > limit - 1 else { return close(unique) }
        let step = Double(unique.count - 1) / Double(limit - 2)
        var kept: [CLLocationCoordinate2D] = []
        var lastIndex = -1
        for index in 0..<(limit - 1) {
            let source = min(unique.count - 1, Int((Double(index) * step).rounded()))
            if source == lastIndex { continue }
            kept.append(unique[source])
            lastIndex = source
        }
        if let last = unique.last, kept.last.map({ meters($0, last) > 1 }) ?? true {
            kept.append(last)
        }
        return close(kept)
    }

    static func localSquare(around center: CLLocationCoordinate2D, halfSpan: Double) -> [CLLocationCoordinate2D] {
        let lat = center.latitude
        let lon = center.longitude
        return [
            CLLocationCoordinate2D(latitude: lat - halfSpan, longitude: lon - halfSpan),
            CLLocationCoordinate2D(latitude: lat - halfSpan, longitude: lon + halfSpan),
            CLLocationCoordinate2D(latitude: lat + halfSpan, longitude: lon + halfSpan),
            CLLocationCoordinate2D(latitude: lat + halfSpan, longitude: lon - halfSpan),
            CLLocationCoordinate2D(latitude: lat - halfSpan, longitude: lon - halfSpan)
        ]
    }

    static func centroid(_ ring: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        let unique = opened(ring)
        guard !unique.isEmpty else {
            return ring.first ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        let lat = unique.reduce(0.0) { $0 + $1.latitude } / Double(unique.count)
        let lon = unique.reduce(0.0) { $0 + $1.longitude } / Double(unique.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func contains(_ point: CLLocationCoordinate2D, in ring: [CLLocationCoordinate2D]) -> Bool {
        let unique = opened(ring)
        guard unique.count >= 3 else { return false }
        var inside = false
        var j = unique.count - 1
        for i in 0..<unique.count {
            let a = unique[i]
            let b = unique[j]
            let intersects = (a.latitude > point.latitude) != (b.latitude > point.latitude)
            if intersects {
                let x = (b.longitude - a.longitude) * (point.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
                if point.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func coordinateValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func opened(_ ring: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard ring.count >= 2, meters(ring[0], ring[ring.count - 1]) < 1 else { return ring }
        return Array(ring.dropLast())
    }

    private static func close(_ ring: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard let first = ring.first else { return ring }
        if let last = ring.last, meters(first, last) < 1 { return ring }
        return ring + [first]
    }
}
