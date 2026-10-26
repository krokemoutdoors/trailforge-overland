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
    let streetAddress: String
    let sourceName: String
    let censusLabel: String

    var centerCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
    }

    var hasBoundary: Bool {
        boundaryCoordinates.count >= 4
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
        let size = acreage >= 0.05 ? acres : "address"
        switch ownershipType {
        case .publicUSFS:
            return "USFS • \(size)"
        case .publicBLM:
            return "BLM • \(size)"
        case .publicStateDNR:
            return "State • \(size)"
        case .publicNPS:
            return "NPS • \(size)"
        case .privateParcel:
            if let street = streetAddress.split(separator: ",").first, !street.isEmpty {
                return "\(street) • \(size)"
            }
            if ownerIsPublished, let token = Self.ownerToken(ownerName) {
                return "\(token) • \(size)"
            }
            return "Private • \(size)"
        }
    }

    private static func ownerToken(_ name: String) -> String? {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "," || $0 == "—" })
        guard let last = parts.last else { return nil }
        let cleaned = last.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count >= 2, cleaned.count <= 18 else { return nil }
        return cleaned
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard hasBoundary else { return false }
        return ParcelGeometry.contains(coordinate, in: boundaryCoordinates)
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
    @Published private(set) var inspectedCoordinate: CLLocationCoordinate2D?

    private var lastFetch: CLLocationCoordinate2D?
    private var generation = 0
    private var pendingInspect: CLLocationCoordinate2D?

    var selected: PropertyParcel? {
        parcels.first { $0.id == selectedID }
    }

    func refresh(around coordinate: CLLocationCoordinate2D, force: Bool = false) {
        if !force, let lastFetch, ParcelGeometry.meters(lastFetch, coordinate) < 900 {
            return
        }
        lastFetch = coordinate
        generation += 1
        let token = generation
        isLoading = true
        status = "Querying public land and address sources…"
        Task {
            let loaded = await ParcelGIS.load(around: coordinate)
            guard token == generation else { return }
            parcels = loaded
            if let pendingInspect {
                self.pendingInspect = nil
                inspectedCoordinate = pendingInspect
                if let hit = loaded.first(where: { $0.contains(pendingInspect) })
                    ?? loaded.first(where: { ParcelGeometry.meters($0.centerCoordinate, pendingInspect) < 8 })
                    ?? loaded.first(where: { $0.id.hasPrefix("addr-") }) {
                    selectedID = hit.id
                } else if let selectedID, !loaded.contains(where: { $0.id == selectedID }) {
                    self.selectedID = nil
                }
            } else if let selectedID, !loaded.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
            isLoading = false
            status = ParcelGIS.statusLine(for: loaded)
        }
    }

    func inspect(at coordinate: CLLocationCoordinate2D) {
        pendingInspect = coordinate
        inspectedCoordinate = coordinate
        if let hit = parcels.first(where: { $0.contains(coordinate) }) {
            selectedID = hit.id
        }
        refresh(around: coordinate, force: true)
    }

    func select(_ parcel: PropertyParcel?) {
        selectedID = parcel?.id
        if let parcel {
            inspectedCoordinate = parcel.centerCoordinate
        }
    }

    func replace(_ next: [PropertyParcel]) {
        parcels = Array(next.prefix(18))
        if let selectedID, !parcels.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    func parcel(at coordinate: CLLocationCoordinate2D) -> PropertyParcel? {
        parcels.first { $0.contains(coordinate) }
    }
}

private enum ParcelGIS {
    static func load(around coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        async let blm = fetchBLM(coordinate)
        async let clarkLots = fetchClarkTaxlots(coordinate)
        async let clarkPublic = fetchClarkPublic(coordinate)
        async let usfs = fetchUSFS(coordinate)
        async let parks = fetchParks(coordinate)
        async let padus = fetchPadus(coordinate)
        async let plss = fetchPLSS(coordinate)
        async let wilderness = fetchWilderness(coordinate)
        async let tribal = fetchTribal(coordinate)
        async let stateParcels = fetchStateParcels(coordinate)
        async let osm = fetchOverpass(coordinate)
        async let place = reverseGeocode(coordinate)
        async let census = fetchCensus(coordinate)
        let batch = await (blm, clarkLots, clarkPublic, usfs, parks, padus, plss, wilderness, tribal, stateParcels, osm, place, census)
        let placemark = batch.11
        let censusCard = batch.12

        var real: [PropertyParcel] = []
        var seen = Set<String>()
        let loaded = batch.9 + batch.1 + batch.2 + batch.3 + batch.4 + batch.5 + batch.6 + batch.7 + batch.8 + batch.0 + batch.10
        for parcel in loaded {
            if seen.insert(parcel.id).inserted {
                real.append(parcel)
            }
        }
        let ranked = real.sorted { lhs, rhs in
            let leftHit = lhs.contains(coordinate)
            let rightHit = rhs.contains(coordinate)
            if leftHit != rightHit { return leftHit }
            if leftHit && rightHit, abs(lhs.acreage - rhs.acreage) > 0.5 {
                return lhs.acreage < rhs.acreage
            }
            return ParcelGeometry.meters(lhs.centerCoordinate, coordinate) < ParcelGeometry.meters(rhs.centerCoordinate, coordinate)
        }
        var merged = Array(ranked.prefix(18))
        let covered = merged.contains { parcel in
            parcel.contains(coordinate) || ParcelGeometry.meters(parcel.centerCoordinate, coordinate) < 8
        }
        if !covered {
            if let card = addressCard(at: coordinate, placemark: placemark, census: censusCard) {
                merged.insert(card, at: 0)
            }
        }
        return Array(merged.prefix(18))
    }

    static func statusLine(for loaded: [PropertyParcel]) -> String {
        if loaded.isEmpty {
            return "No published parcel or public-land polygon at this point."
        }
        let sources = Array(Set(loaded.map(\.sourceName).filter { !$0.isEmpty })).sorted().joined(separator: ", ")
        if sources.isEmpty {
            return "\(loaded.count) published shapes"
        }
        return "\(loaded.count) published shapes • \(sources)"
    }

    private static func fetchBLM(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let delta = 0.05
        guard let root = await json(urlString: "https://gis.blm.gov/arcgis/rest/services/lands/BLM_Natl_SMA_Cached_without_PriUnk/MapServer/identify", query: [
            URLQueryItem(name: "geometry", value: "\(lon),\(lat)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "sr", value: "4326"),
            URLQueryItem(name: "layers", value: "all"),
            URLQueryItem(name: "tolerance", value: "8"),
            URLQueryItem(name: "mapExtent", value: "\(lon - delta),\(lat - delta),\(lon + delta),\(lat + delta)"),
            URLQueryItem(name: "imageDisplay", value: "400,400,96"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "f", value: "json")
        ]) else { return [] }
        let rows = root["results"] as? [[String: Any]] ?? []
        return rows.prefix(3).compactMap { row in
            makeEsriParcel(row, near: coordinate, source: "blm", sourceName: "BLM SMA", defaultOwner: .publicBLM, census: "")
        }
    }

    private static func fetchClarkTaxlots(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        guard coordinate.latitude >= 45.55, coordinate.latitude <= 46.05, coordinate.longitude >= -122.90, coordinate.longitude <= -122.20 else {
            return []
        }
        let span = 0.012
        guard let root = await json(urlString: "https://gis.clark.wa.gov/arcgisfed/rest/services/ClarkView_Public/TaxlotsPublic/MapServer/0/query", query: envelopeQuery(coordinate, span: span)) else {
            return []
        }
        let rows = root["features"] as? [[String: Any]] ?? []
        return rows.prefix(10).compactMap { row in
            makeEsriParcel(row, near: coordinate, source: "clark", sourceName: "Clark County taxlots", defaultOwner: .privateParcel, census: "")
        }
    }

    private static func fetchClarkPublic(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        guard coordinate.latitude >= 45.55, coordinate.latitude <= 46.05, coordinate.longitude >= -122.90, coordinate.longitude <= -122.20 else {
            return []
        }
        async let state = layer(
            "https://gis.clark.wa.gov/arcgisfed/rest/services/ClarkView_Public/PublicLandState/MapServer/0/query",
            coordinate,
            source: "clark-public",
            sourceName: "Clark County public land",
            owner: .publicStateDNR
        )
        async let county = layer(
            "https://gis.clark.wa.gov/arcgisfed/rest/services/ClarkView_Public/CountyLandsbyOwner/MapServer/0/query",
            coordinate,
            source: "clark-county",
            sourceName: "Clark County lands",
            owner: .publicStateDNR
        )
        let (stateRows, countyRows) = await (state, county)
        return stateRows + countyRows
    }

    private static func fetchUSFS(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        guard let root = await json(urlString: "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_ForestSystemBoundaries_01/MapServer/0/query", query: pointQuery(coordinate, offset: 0.02)) else {
            return []
        }
        let rows = root["features"] as? [[String: Any]] ?? []
        return rows.prefix(2).compactMap { row in
            makeEsriParcel(row, near: coordinate, source: "usfs", sourceName: "USFS forest boundaries", defaultOwner: .publicUSFS, census: "")
        }
    }

    private static func fetchParks(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        guard let root = await json(urlString: "https://services.arcgis.com/P3ePLMYs2RVChkJx/arcgis/rest/services/USA_Parks/FeatureServer/0/query", query: pointQuery(coordinate, offset: 0.02)) else {
            return []
        }
        let rows = root["features"] as? [[String: Any]] ?? []
        return rows.prefix(2).compactMap { row in
            makeEsriParcel(row, near: coordinate, source: "parks", sourceName: "Esri USA Parks", defaultOwner: .publicNPS, census: "")
        }
    }

    private static func layer(
        _ url: String,
        _ coordinate: CLLocationCoordinate2D,
        source: String,
        sourceName: String,
        owner: OwnershipCategory,
        offset: Double = 0.004,
        fields: String = "*",
        limit: Int = 2
    ) async -> [PropertyParcel] {
        guard let root = await json(urlString: url, query: pointQuery(coordinate, offset: offset, fields: fields, limit: limit)) else { return [] }
        let rows = root["features"] as? [[String: Any]] ?? []
        return rows.prefix(limit).compactMap { row in
            makeEsriParcel(row, near: coordinate, source: source, sourceName: sourceName, defaultOwner: owner, census: "")
        }
    }

    private static func fetchPadus(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        await layer(
            "https://services.arcgis.com/v01gqwM5QqNysAAi/arcgis/rest/services/Manager_Name_PADUS/FeatureServer/0/query",
            coordinate,
            source: "padus",
            sourceName: "USGS PAD-US",
            owner: .publicStateDNR,
            offset: 0.05,
            fields: "Own_Type,Own_Name,Mang_Type,Mang_Name,Des_Tp,Unit_Nm,Loc_Nm,State_Nm,GIS_Acres"
        )
    }

    private static func fetchPLSS(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        async let aliquots = layer(
            "https://gis.blm.gov/arcgis/rest/services/Cadastral/BLM_Natl_PLSS_CadNSDI/MapServer/3/query",
            coordinate,
            source: "plss",
            sourceName: "BLM PLSS CadNSDI",
            owner: .privateParcel,
            offset: 0.002,
            fields: "PLSSID,TWNSHPLAB,FRSTDIVLAB,SECDIVLAB,SECDIVTXT,RECRDAREATX,GISACRE,STEWARD",
            limit: 3
        )
        async let sections = layer(
            "https://gis.blm.gov/arcgis/rest/services/Cadastral/BLM_Natl_PLSS_CadNSDI/MapServer/2/query",
            coordinate,
            source: "plss-sec",
            sourceName: "BLM PLSS sections",
            owner: .privateParcel,
            offset: 0.01,
            fields: "PLSSID,TWNSHPLAB,FRSTDIVLAB,GISACRE,STEWARD",
            limit: 2
        )
        let (aliquotRows, sectionRows) = await (aliquots, sections)
        return aliquotRows + sectionRows
    }

    private static func fetchWilderness(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        await layer(
            "https://services1.arcgis.com/ERdCHt0sNM6dENSD/arcgis/rest/services/Wilderness_Areas_in_the_United_States/FeatureServer/0/query",
            coordinate,
            source: "wilderness",
            sourceName: "National Wilderness Areas",
            owner: .publicUSFS,
            offset: 0.05
        )
    }

    private static func fetchTribal(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        await layer(
            "https://services2.arcgis.com/FiaPA4ga0iQKduv3/arcgis/rest/services/AIANNHA_v1/FeatureServer/0/query",
            coordinate,
            source: "tribal",
            sourceName: "Census AIANNHA tribal lands",
            owner: .publicStateDNR,
            offset: 0.05
        )
    }

    private struct ParcelEndpoint {
        var state: String
        var url: String
        var source: String
        var sourceName: String
        var owner: OwnershipCategory = .privateParcel
        var minLat: Double = -90
        var maxLat: Double = 90
        var minLon: Double = -180
        var maxLon: Double = 180
        var fallbackURL: String? = nil
    }

    private static let stateParcelCatalog: [ParcelEndpoint] = [
        ParcelEndpoint(state: "WA", url: "https://services.arcgis.com/jsIt88o09Q0r1j8h/ArcGIS/rest/services/Current_Parcels/FeatureServer/0/query", source: "wa", sourceName: "Washington current parcels"),
        ParcelEndpoint(state: "CO", url: "https://gis.colorado.gov/public/rest/services/Address_and_Parcel/Colorado_Public_Parcels/FeatureServer/0/query", source: "co", sourceName: "Colorado public parcels"),
        ParcelEndpoint(state: "MT", url: "https://services.arcgis.com/qnjIrwR8z5Izc0ij/arcgis/rest/services/Cadastral_Application_Support/FeatureServer/5/query", source: "mt", sourceName: "Montana cadastral"),
        ParcelEndpoint(state: "WY", url: "https://services3.arcgis.com/r0iJ85SKZ4zAzz3P/arcgis/rest/services/Wyoming_Parcels_for_2026/FeatureServer/0/query", source: "wy", sourceName: "Wyoming parcels"),
        ParcelEndpoint(state: "ID", url: "https://services2.arcgis.com/dgGjZc6xAH5m5JyP/arcgis/rest/services/Parcels/FeatureServer/5/query", source: "id-ada", sourceName: "Ada County parcels", minLat: 43.25, maxLat: 43.85, minLon: -116.65, maxLon: -115.95),
        ParcelEndpoint(state: "OR", url: "https://services2.arcgis.com/McQ0OlIABe29rJJy/arcgis/rest/services/Taxlots_with_Right_of_Way_Public/FeatureServer/3/query", source: "or-metro", sourceName: "Portland Metro taxlots", minLat: 45.20, maxLat: 45.75, minLon: -123.20, maxLon: -122.15),
        ParcelEndpoint(state: "NV", url: "https://wcgisweb.washoecounty.us/arcgis/rest/services/OpenData/OpenData/MapServer/0/query", source: "nv-washoe", sourceName: "Washoe County parcels", minLat: 39.15, maxLat: 41.99, minLon: -120.60, maxLon: -119.00),
        ParcelEndpoint(state: "AZ", url: "https://gis.maricopa.gov/arcgis/rest/services/IndividualService/Parcel/MapServer/1/query", source: "az-maricopa", sourceName: "Maricopa County parcels", minLat: 32.50, maxLat: 34.10, minLon: -113.35, maxLon: -111.00),
        ParcelEndpoint(state: "NM", url: "https://services.arcgis.com/CWv1abTnC3urn4bV/arcgis/rest/services/berncoparcels_forIDO/FeatureServer/0/query", source: "nm-bern", sourceName: "Bernalillo County parcels", minLat: 34.70, maxLat: 35.40, minLon: -107.15, maxLon: -106.15),
        ParcelEndpoint(state: "NC", url: "https://services.nconemap.gov/secure/rest/services/NC1Map_Parcels/MapServer/1/query", source: "nc", sourceName: "North Carolina parcels"),
        ParcelEndpoint(state: "NY", url: "https://services6.arcgis.com/EbVsqZ18sv1kVJ3k/arcgis/rest/services/NYS_Tax_Parcels_Public/FeatureServer/1/query", source: "ny", sourceName: "New York tax parcels"),
        ParcelEndpoint(state: "NJ", url: "https://services2.arcgis.com/XVOqAjTOJ5P6ngMu/arcgis/rest/services/Parcels_Composite_NJ_WM/FeatureServer/0/query", source: "nj", sourceName: "New Jersey parcels"),
        ParcelEndpoint(state: "IN", url: "https://gisdata.in.gov/server/rest/services/Hosted/Parcel_Boundaries_of_Indiana_Current/FeatureServer/0/query", source: "in", sourceName: "Indiana parcels"),
        ParcelEndpoint(state: "VA", url: "https://vginmaps.vdem.virginia.gov/arcgis/rest/services/VA_Base_Layers/VA_Parcels/FeatureServer/0/query", source: "va", sourceName: "Virginia parcels"),
        ParcelEndpoint(state: "WV", url: "https://services.wvgis.wvu.edu/arcgis/rest/services/Planning_Cadastre/WV_Parcels/MapServer/0/query", source: "wv", sourceName: "West Virginia parcels"),
        ParcelEndpoint(state: "MD", url: "https://mdgeodata.md.gov/imap/rest/services/PlanningCadastre/MD_ParcelBoundaries/MapServer/0/query", source: "md", sourceName: "Maryland parcels"),
        ParcelEndpoint(state: "MA", url: "https://services1.arcgis.com/hGdibHYSPO59RG1h/arcgis/rest/services/Massachusetts_Property_Tax_Parcels/FeatureServer/0/query", source: "ma", sourceName: "Massachusetts tax parcels"),
        ParcelEndpoint(state: "ME", url: "https://services1.arcgis.com/RbMX0mRVOFNTdLzd/arcgis/rest/services/Maine_Parcels_Organized_Towns/FeatureServer/10/query", source: "me", sourceName: "Maine parcels"),
        ParcelEndpoint(state: "VT", url: "https://services1.arcgis.com/BkFxaEFNwHqX3tAw/arcgis/rest/services/FS_VCGI_OPENDATA_Cadastral_VTPARCELS_poly_standardized_parcels_SP_v1/FeatureServer/0/query", source: "vt", sourceName: "Vermont parcels"),
        ParcelEndpoint(state: "CT", url: "https://services3.arcgis.com/3FL1kr7L4LvwA2Kb/arcgis/rest/services/Connecticut_CAMA_and_Parcel_Layer/FeatureServer/0/query", source: "ct", sourceName: "Connecticut parcels"),
        ParcelEndpoint(state: "NH", url: "https://nhgeodata.unh.edu/hosting/rest/services/Hosted/CAD_ParcelMosaic/FeatureServer/1/query", source: "nh", sourceName: "New Hampshire parcels"),
        ParcelEndpoint(state: "DE", url: "https://enterprise.firstmap.delaware.gov/arcgis/rest/services/PlanningCadastre/DE_StateParcels/FeatureServer/0/query", source: "de", sourceName: "Delaware parcels"),
        ParcelEndpoint(state: "ND", url: "https://services1.arcgis.com/GOcSXpzwBHyk2nog/arcgis/rest/services/NDGISHUB_Parcels/FeatureServer/0/query", source: "nd", sourceName: "North Dakota parcels"),
        ParcelEndpoint(state: "MN", url: "https://enterprise.gisdata.mn.gov/aghost/rest/services/us_mn_state_mngeo/plan_parcels_open/FeatureServer/1/query", source: "mn", sourceName: "Minnesota parcels"),
        ParcelEndpoint(state: "AR", url: "https://gis.arkansas.gov/arcgis/rest/services/FEATURESERVICES/Planning_Cadastre/FeatureServer/6/query", source: "ar", sourceName: "Arkansas parcels"),
        ParcelEndpoint(state: "AK", url: "https://services1.arcgis.com/7HDiw78fcUiM2BWn/arcgis/rest/services/AK_Parcels/FeatureServer/0/query", source: "ak", sourceName: "Alaska parcels"),
        ParcelEndpoint(state: "HI", url: "https://geodata.hawaii.gov/arcgis/rest/services/ParcelsZoning/MapServer/25/query", source: "hi", sourceName: "Hawaii parcels"),
        ParcelEndpoint(state: "PA", url: "https://services3.arcgis.com/SP47Tddf7RK32lBU/arcgis/rest/services/Bucks_County_Parcels/FeatureServer/0/query", source: "pa-bucks", sourceName: "Bucks County parcels", minLat: 40.05, maxLat: 40.60, minLon: -75.40, maxLon: -74.70),
        ParcelEndpoint(state: "PA", url: "https://services.arcgis.com/G4S1dGvn7PIgYd6Y/arcgis/rest/services/Parcels_owners/FeatureServer/0/query", source: "pa-chester", sourceName: "Chester County parcels", minLat: 39.72, maxLat: 40.25, minLon: -76.15, maxLon: -75.35),
        ParcelEndpoint(state: "PA", url: "https://services1.arcgis.com/kOChldNuKsox8qZD/arcgis/rest/services/Montgomery_County_Parcels/FeatureServer/0/query", source: "pa-mont", sourceName: "Montgomery County parcels", minLat: 40.00, maxLat: 40.50, minLon: -75.70, maxLon: -74.95),
        ParcelEndpoint(state: "TX", url: "https://feature.geographic.texas.gov/arcgis/rest/services/Parcels/stratmap24_land_parcels_48/MapServer/0/query", source: "tx", sourceName: "Texas StratMap parcels", fallbackURL: "https://feature.geographic.texas.gov/arcgis/rest/services/Parcels/stratmap_land_parcels/MapServer/0/query")
    ]

    private static func fetchStateParcels(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        let state = USStateLocator.code(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let matches = stateParcelCatalog.filter { item in
            item.state == state
                && coordinate.latitude >= item.minLat && coordinate.latitude <= item.maxLat
                && coordinate.longitude >= item.minLon && coordinate.longitude <= item.maxLon
        }
        guard !matches.isEmpty else { return [] }
        return await withTaskGroup(of: [PropertyParcel].self) { group in
            for item in matches {
                group.addTask {
                    var rows = await layer(item.url, coordinate, source: item.source, sourceName: item.sourceName, owner: item.owner)
                    if rows.isEmpty, let fallback = item.fallbackURL {
                        rows = await layer(fallback, coordinate, source: item.source + "-fb", sourceName: item.sourceName, owner: item.owner)
                    }
                    return rows
                }
            }
            var merged: [PropertyParcel] = []
            for await rows in group {
                merged.append(contentsOf: rows)
            }
            return merged
        }
    }

    private static func fetchOverpass(_ coordinate: CLLocationCoordinate2D) async -> [PropertyParcel] {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let query = """
        [out:json][timeout:18];
        (
          way["building"](around:450,\(lat),\(lon));
          way["addr:housenumber"](around:450,\(lat),\(lon));
          way["boundary"="lot"](around:700,\(lat),\(lon));
          way["landuse"~"residential|farmland|forest|meadow|industrial|orchard"](around:700,\(lat),\(lon));
          way["amenity"](around:450,\(lat),\(lon));
          way["leisure"~"park|nature_reserve|garden"](around:700,\(lat),\(lon));
          way["boundary"~"protected_area|national_park"](around:1200,\(lat),\(lon));
        );
        out geom 14;
        """
        let endpoints = [
            "https://overpass-api.de/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter"
        ]
        for endpoint in endpoints {
            if let parcels = await overpassRequest(endpoint, query: query, near: coordinate) {
                return parcels
            }
        }
        return []
    }

    /// `nil` means the mirror failed or timed out and the caller should try the next host.
    private static func overpassRequest(_ endpoint: String, query: String, near coordinate: CLLocationCoordinate2D) async -> [PropertyParcel]? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 18
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("TrailForgeOverland/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = query.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let elements = root["elements"] as? [[String: Any]] ?? []
            return elements.prefix(14).compactMap { element in
                makeOverpassParcel(element, near: coordinate)
            }
        } catch {
            return nil
        }
    }

    private static func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> CLPlacemark? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let places = try? await geocoder.reverseGeocodeLocation(location)
        return places?.first
    }

    private static func fetchCensus(_ coordinate: CLLocationCoordinate2D) async -> String {
        guard let root = await json(urlString: "https://geocoding.geo.census.gov/geocoder/geographies/coordinates", query: [
            URLQueryItem(name: "x", value: String(coordinate.longitude)),
            URLQueryItem(name: "y", value: String(coordinate.latitude)),
            URLQueryItem(name: "benchmark", value: "Public_AR_Current"),
            URLQueryItem(name: "vintage", value: "Current_Current"),
            URLQueryItem(name: "format", value: "json")
        ]) else { return "" }
        let result = root["result"] as? [String: Any]
        let geos = result?["geographies"] as? [String: Any] ?? [:]
        let county = firstName(geos["Counties"])
        let tract = firstName(geos["Census Tracts"])
        let blockKey = geos.keys.first { $0.localizedCaseInsensitiveContains("Block") }
        let block = blockKey.flatMap { firstName(geos[$0]) }
        return [county, tract, block].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }

    private static func addressCard(at coordinate: CLLocationCoordinate2D, placemark: CLPlacemark?, census: String) -> PropertyParcel? {
        let address = formattedAddress(placemark)
        guard !address.isEmpty || !census.isEmpty else { return nil }
        let state = placemark?.administrativeArea ?? USStateLocator.code(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let county = placemark?.subAdministrativeArea ?? censusCounty(census) ?? "County not in the geocoder response"
        let countyAndState = county.contains(state) ? county : "\(county), \(state)"
        let label: String
        if address.isEmpty {
            label = "Private land — owner name not published"
        } else {
            label = "Private Residential Lot — \(address)"
        }
        let id = String(format: "addr-%.4f-%.4f", coordinate.latitude, coordinate.longitude)
        return PropertyParcel(
            id: id,
            apnLotNumber: census.isEmpty ? "No published parcel ID at this point" : census,
            ownerName: label,
            ownerIsPublished: false,
            ownershipType: .privateParcel,
            acreage: 0,
            subdivisionOrTract: address.isEmpty ? "Address not returned" : address,
            zoningOrUse: "Land use not in the public response",
            assessedValueOrStatus: "No county polygon at this coordinate. Address is from Apple Maps and the U.S. Census geocoder.",
            countyAndState: countyAndState,
            centerLat: coordinate.latitude,
            centerLon: coordinate.longitude,
            boundaryCoordinates: [],
            streetAddress: address,
            sourceName: "Apple Maps + Census",
            censusLabel: census
        )
    }

    private static func pointQuery(_ coordinate: CLLocationCoordinate2D, offset: Double, fields: String = "*", limit: Int = 2) -> [URLQueryItem] {
        [
            URLQueryItem(name: "geometry", value: "\(coordinate.longitude),\(coordinate.latitude)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: fields),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "maxAllowableOffset", value: String(offset)),
            URLQueryItem(name: "resultRecordCount", value: String(limit)),
            URLQueryItem(name: "f", value: "json")
        ]
    }

    private static func envelopeQuery(_ coordinate: CLLocationCoordinate2D, span: Double) -> [URLQueryItem] {
        let west = coordinate.longitude - span
        let south = coordinate.latitude - span
        let east = coordinate.longitude + span
        let north = coordinate.latitude + span
        return [
            URLQueryItem(name: "geometry", value: "\(west),\(south),\(east),\(north)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: "*"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "maxAllowableOffset", value: "0.00035"),
            URLQueryItem(name: "resultRecordCount", value: "10"),
            URLQueryItem(name: "f", value: "json")
        ]
    }

    private static func json(urlString: String, query: [URLQueryItem]) async -> [String: Any]? {
        var components = URLComponents(string: urlString)
        components?.queryItems = query
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 16
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
        sourceName: String,
        defaultOwner: OwnershipCategory,
        census: String
    ) -> PropertyParcel? {
        let attributes = row["attributes"] as? [String: Any] ?? [:]
        let geometry = row["geometry"] as? [String: Any]
        guard let ring = ParcelGeometry.bestRing(geometry?["rings"], near: near) else { return nil }
        let anchor = ring.first ?? near
        let fallback = String(format: "%.4f-%.4f", anchor.latitude, anchor.longitude)
        let identifier = text(attributes, keys: ["OBJECTID", "objectid", "Prop_id", "APN", "PIN", "ACCT", "GLOBALID", "SMA_ID", "adminforestid", "FID", "PARCEL_ID_NR", "parcel_id", "parcelnb", "parno", "PRINT_KEY", "PAMS_PIN", "state_parcel_id", "PARCELID", "GISPID", "ACCTID", "MAP_PAR_ID", "STATE_ID", "SPAN", "Parcel_ID", "UniqueGISID", "state_pin", "tmk_txt", "UPC", "PLSSID"]) ?? fallback
        return assemble(
            id: "\(source)-\(identifier)",
            ring: ring,
            near: near,
            attributes: attributes,
            tags: [:],
            defaultOwner: defaultOwner,
            sourceName: sourceName,
            census: census
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
            sourceName: "OpenStreetMap",
            census: ""
        )
    }

    private static func assemble(
        id: String,
        ring: [CLLocationCoordinate2D],
        near: CLLocationCoordinate2D,
        attributes: [String: Any],
        tags: [String: String],
        defaultOwner: OwnershipCategory,
        sourceName: String,
        census: String
    ) -> PropertyParcel? {
        let measured = ParcelGeometry.acreage(of: ring)
        let sourceAcres = acresValue(attributes)
        let acres = sourceAcres ?? measured
        let containsQuery = ParcelGeometry.contains(near, in: ring)
        let gisAddress = situsAddress(attributes) ?? tagAddress(tags)
        let publishedOwner = publishedEntity(attributes, tags: tags)
        var ownership = classify(
            [publishedOwner, text(attributes, keys: ["ADMIN_AGENCY_CODE", "FEATTYPE", "PubLandGroup", "PropertyUseClass", "LANDUSE", "Own_Type", "Mang_Type", "Des_Tp", "Unit_Nm", "Own_Name", "Mang_Name", "Loc_Nm"]), tags["landuse"], tags["leisure"], tags["boundary"], tags["operator"]].compactMap { $0 }.joined(separator: " "),
            fallback: defaultOwner
        )
        if tags["boundary"] == "national_park" || (tags["boundary"] == "protected_area" && ownership == .privateParcel) {
            ownership = tags["operator"]?.localizedCaseInsensitiveContains("BLM") == true ? .publicBLM : .publicUSFS
        }
        if tags["landuse"] == "forest", ownership == .privateParcel {
            ownership = .publicUSFS
        }
        if let feature = text(attributes, keys: ["FEATTYPE"]), feature.localizedCaseInsensitiveContains("forest") {
            ownership = .publicUSFS
        }
        if defaultOwner != .privateParcel, publishedOwner == nil {
            ownership = defaultOwner
        }
        let publicLand = ownership != .privateParcel
        if !publicLand, acres > 20_000 || acres < 0.02 { return nil }
        if publicLand, acres < 0.05 { return nil }
        let simplified = ParcelGeometry.simplify(ring, limit: 40)
        guard simplified.count >= 4 else { return nil }
        let center = containsQuery ? near : ParcelGeometry.centroid(simplified)
        let street = gisAddress ?? ""
        let useClass = text(attributes, keys: ["PropertyUseClass", "ZoneDesc", "Description", "FEATTYPE", "ADMIN_UNIT_TYPE"])
            ?? tags["landuse"]
            ?? tags["leisure"]
            ?? tags["building"]
        let ownerName: String
        let ownerIsPublished: Bool
        if let publishedOwner {
            ownerName = agencyPrefix(publishedOwner, ownership: ownership)
            ownerIsPublished = true
        } else if publicLand {
            ownerName = fallbackAgencyName(ownership)
            ownerIsPublished = true
        } else if !street.isEmpty {
            ownerName = "\(privateKind(useClass)) — \(street)"
            ownerIsPublished = false
        } else {
            ownerName = "Private land — owner name not published"
            ownerIsPublished = false
        }
        let plssLegal = ["TWNSHPLAB", "FRSTDIVLAB", "SECDIVLAB", "SECDIVTXT"].compactMap { text(attributes, keys: [$0]) }
        let plssLine = plssLegal.isEmpty ? nil : plssLegal.joined(separator: " ")
        let apn = text(attributes, keys: ["Prop_id", "APN", "PIN", "ACCT", "PARCEL", "PARCELID", "PARCEL_ID", "LandProp_id", "PARCEL_ID_NR", "parcel_id", "parcelnb", "parno", "PRINT_KEY", "PAMS_PIN", "state_parcel_id", "GISPID", "ACCTID", "MAP_PAR_ID", "STATE_ID", "SPAN", "Parcel_ID", "UniqueGISID", "state_pin", "tmk_txt", "UPC", "PLSSID", "SECDIVLAB"])
            ?? tags["addr:housenumber"].map { "OSM house \($0)" }
            ?? id
        let tract = text(attributes, keys: ["PlatName", "LegalShort", "SUBDIVISION", "TRACT", "Nbrhd", "legal", "LEGALDESC", "LegalDesc"])
            ?? plssLine
            ?? tags["addr:street"]
            ?? sourceName
        let zoning = useClass ?? "See the publishing agency"
        let value = assessedText(attributes)
        let county = text(attributes, keys: ["COUNTY", "COUNTY_NAME", "CountyName", "county", "SitusCity"])
            ?? (sourceName.contains("Clark") ? "Clark County" : nil)
            ?? "USA"
        let state = text(attributes, keys: ["ADMIN_ST", "STATE", "STATE_CODE"])
            ?? (sourceName.contains("Clark") ? "WA" : nil)
            ?? USStateLocator.code(latitude: center.latitude, longitude: center.longitude)
        let countyAndState: String
        if county.localizedCaseInsensitiveContains("county") {
            countyAndState = county.contains(state) ? county : "\(county), \(state)"
        } else if sourceName.contains("Clark") {
            countyAndState = "Clark County, WA"
        } else {
            countyAndState = "\(county), \(state)"
        }
        var censusLabel = census
        if let tractID = text(attributes, keys: ["CensusTract"]), !tractID.isEmpty {
            let tractLine = "Census tract \(tractID)"
            censusLabel = censusLabel.isEmpty ? tractLine : "\(tractLine) • \(censusLabel)"
        }
        var status = value ?? sourceName
        if ownership == .privateParcel, value == nil {
            status = "Owner name is not in this public layer. \(sourceName)."
        }
        if publicLand {
            status = "Managing agency from \(sourceName)."
        }
        return PropertyParcel(
            id: id,
            apnLotNumber: apn,
            ownerName: ownerName,
            ownerIsPublished: ownerIsPublished,
            ownershipType: ownership,
            acreage: acres,
            subdivisionOrTract: tract,
            zoningOrUse: zoning,
            assessedValueOrStatus: status,
            countyAndState: countyAndState,
            centerLat: center.latitude,
            centerLon: center.longitude,
            boundaryCoordinates: simplified,
            streetAddress: street,
            sourceName: sourceName,
            censusLabel: censusLabel
        )
    }

    private static func publishedEntity(_ attributes: [String: Any], tags: [String: String]) -> String? {
        let raw = text(attributes, keys: [
            "PubLandOwner", "OwnerName", "ownname", "ownername1", "ownername", "PRIMARY_OWNER", "OWNER", "owner", "DEEDHOLDER", "Own_Name", "Mang_Name", "Unit_Nm", "Loc_Nm", "PACSOwner", "forestname", "ADMIN_AGENCY_CODE", "NAME", "AGENCY", "ADMIN_AGENCY", "SMA_NAME", "UNIT_NAME", "STEWARD"
        ]) ?? tags["owner"] ?? tags["operator"]
        guard let raw else { return nil }
        let upper = raw.uppercased()
        if upper == "NULL" || upper == "PRIVATE" || upper == "UNKNOWN" || upper == "NONE" || upper == "NOT AVAILABLE" {
            return nil
        }
        if raw.allSatisfy({ $0.isNumber }) { return nil }
        if upper == "USFS" { return "U.S. Forest Service (USFS)" }
        if upper == "BLM" { return "Bureau of Land Management (BLM)" }
        if upper == "NPS" { return "National Park Service" }
        return raw
    }

    private static func agencyPrefix(_ name: String, ownership: OwnershipCategory) -> String {
        let upper = name.uppercased()
        switch ownership {
        case .publicUSFS:
            if upper.contains("FOREST SERVICE") || upper.contains("USFS") { return name }
            return "U.S. Forest Service (USFS) • \(name)"
        case .publicBLM:
            if upper.contains("LAND MANAGEMENT") || upper.contains("BLM") { return name }
            return "Bureau of Land Management (BLM) • \(name)"
        case .publicNPS:
            if upper.contains("PARK SERVICE") || upper.contains("NPS") { return name }
            return "National Park Service • \(name)"
        case .publicStateDNR:
            if upper.contains("DNR") || upper.contains("COUNTY") || upper.contains("STATE") || upper.contains("CITY") { return name }
            return "State or local agency • \(name)"
        case .privateParcel:
            return name
        }
    }

    private static func privateKind(_ use: String?) -> String {
        let upper = (use ?? "").uppercased()
        if upper.contains("FARM") || upper.contains("AGRI") || upper.contains("ORCHARD") || upper.contains("VACANT") {
            return "Private Agricultural Lot"
        }
        if upper.contains("COMM") || upper.contains("INDUST") || upper.contains("BUSINESS") {
            return "Private Parcel"
        }
        return "Private Residential Lot"
    }

    private static func situsAddress(_ attributes: [String: Any]) -> String? {
        if let full = text(attributes, keys: ["SitusAddrsFull"]) {
            let cityLine = text(attributes, keys: ["SitusCityStateZip"]) ?? ""
            if cityLine.isEmpty { return titleCaseAddress(full) }
            if full.localizedCaseInsensitiveContains("WA") || full.contains(",") {
                let street = text(attributes, keys: ["SitusAddrs"]) ?? full
                let city = text(attributes, keys: ["SitusCity"]) ?? ""
                let zip = text(attributes, keys: ["SitusZip1"]) ?? ""
                return joinAddress(street: street, city: city, state: "WA", zip: zip)
            }
            return titleCaseAddress(full)
        }
        if let line = text(attributes, keys: ["addr_line1"]) {
            let city = text(attributes, keys: ["City", "addr_city"]) ?? ""
            let state = text(attributes, keys: ["State"]) ?? "WA"
            let zip = text(attributes, keys: ["zip"]) ?? ""
            return joinAddress(street: line, city: city, state: state, zip: zip)
        }
        if let full = text(attributes, keys: ["SITUS_ADDRESS", "locationad", "PARCEL_ADDR", "PROP_LOC", "SITUSADD", "PropertyFullStreetAddress", "SITEADDR", "ADDRESS", "SitusAddress", "FULLADDR"]) {
            return titleCaseAddress(full)
        }
        return nil
    }

    private static func tagAddress(_ tags: [String: String]) -> String? {
        let house = tags["addr:housenumber"] ?? ""
        let street = tags["addr:street"] ?? ""
        let city = tags["addr:city"] ?? ""
        let state = tags["addr:state"] ?? ""
        let zip = tags["addr:postcode"] ?? ""
        let line = [house, street].filter { !$0.isEmpty }.joined(separator: " ")
        guard !line.isEmpty || !city.isEmpty else { return nil }
        return joinAddress(street: line, city: city, state: state, zip: zip)
    }

    private static func joinAddress(street: String, city: String, state: String, zip: String) -> String {
        let place = [titleCaseAddress(city), state.uppercased()].filter { !$0.isEmpty }.joined(separator: ", ")
        return [titleCaseAddress(street), place, zip].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func titleCaseAddress(_ raw: String) -> String {
        raw.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            if lower == "nw" || lower == "ne" || lower == "sw" || lower == "se" { return lower.uppercased() }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private static func formattedAddress(_ placemark: CLPlacemark?) -> String {
        guard let placemark else { return "" }
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let city = placemark.locality ?? ""
        let state = placemark.administrativeArea ?? ""
        let zip = placemark.postalCode ?? ""
        return joinAddress(street: street, city: city, state: state, zip: zip)
    }

    private static func censusCounty(_ census: String) -> String? {
        let parts = census.split(separator: "•").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.first { $0.localizedCaseInsensitiveContains("county") }
    }

    private static func assessedText(_ attributes: [String: Any]) -> String? {
        let map = lowered(attributes)
        let keys = ["taxtotval", "mkttotval", "full_market_val", "parval", "actualvalu", "total_value", "totalval", "totalvalue", "assessed", "market", "value"]
        for key in keys {
            if let total = double(from: map[key]), total > 1 {
                let formatted = NumberFormatter.localizedString(from: NSNumber(value: total), number: .currency)
                return "County assessed value \(formatted)"
            }
        }
        return nil
    }

    private static func classify(_ text: String, fallback: OwnershipCategory) -> OwnershipCategory {
        let upper = text.uppercased()
        if upper.contains("BLM") || upper.contains("BUREAU OF LAND") { return .publicBLM }
        if upper.contains("NATIONAL PARK") || upper.contains("NPS") || upper.contains("PARK SERVICE") { return .publicNPS }
        if upper.contains("STATE PARK") || upper.contains("STATE FOREST") || upper.contains("DNR") || upper.contains("NATURAL RESOURCES") || upper.contains("COUNTY") || upper.contains("CITY OF") {
            return .publicStateDNR
        }
        if upper.contains("WILDERNESS") || upper.contains("NATIONAL FOREST") || upper.contains("USFS") || upper.contains("FOREST SERVICE") || upper.contains("FOREST") {
            return .publicUSFS
        }
        if upper.contains("TRIBAL") || upper.contains("RESERVATION") || upper.contains("INDIAN") || upper.contains(" BIA") || upper.contains("NATIVE") {
            return .publicStateDNR
        }
        if upper.contains("PRIVATE") || upper.contains("PVT") || upper.contains("RESIDENTIAL") { return .privateParcel }
        return fallback
    }

    private static func fallbackAgencyName(_ ownership: OwnershipCategory) -> String {
        switch ownership {
        case .publicUSFS: return "U.S. Forest Service (USFS)"
        case .publicBLM: return "Bureau of Land Management (BLM)"
        case .publicStateDNR: return "State or local public land"
        case .publicNPS: return "National Park Service"
        case .privateParcel: return "Private land — owner name not published"
        }
    }

    private static func lowered(_ attributes: [String: Any]) -> [String: Any] {
        Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private static func text(_ attributes: [String: Any], keys: [String]) -> String? {
        let map = lowered(attributes)
        for key in keys {
            if let value = map[key.lowercased()] {
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
        let map = lowered(attributes)
        for key in ["gisac", "gisacre", "acres", "gis_acres", "gisacres", "acreage", "calc_acres", "land_acres", "landgrossa", "recrdareatx"] {
            if let number = double(from: map[key]), number > 0.02, number < 8_000_000 {
                return number
            }
        }
        if let sqmi = double(from: map["sqmi"]), sqmi > 0.001 {
            return sqmi * 640
        }
        if let shape = double(from: map["gissqft"] ?? map["assrsqft"]), shape > 200 {
            return shape / 43_560
        }
        return nil
    }

    private static func firstName(_ value: Any?) -> String? {
        guard let rows = value as? [[String: Any]], let row = rows.first else { return nil }
        let name = string(from: row["NAME"] ?? "")
        return name.isEmpty ? nil : name
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
