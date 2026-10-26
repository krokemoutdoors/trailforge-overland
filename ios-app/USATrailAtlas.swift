import CoreLocation
import Foundation

enum USATrailAtlas {
    static let all: [OverlandTrail] = specs.map(make)

    static var states: [String] {
        Array(Set(all.map(\.state))).sorted()
    }

    private static func make(_ spec: AtlasSpec) -> OverlandTrail {
        let seed = TrailGeometry.seed(for: spec.id)
        let coordinates = handRoutes[spec.id] ?? TrailGeometry.route(
            lat: spec.lat,
            lon: spec.lon,
            seed: seed,
            kilometers: spec.km
        )
        let camps = handCamps[spec.id] ?? TrailGeometry.pads(lat: spec.lat, lon: spec.lon, seed: seed)
        return OverlandTrail(
            id: spec.id,
            name: spec.name,
            region: spec.region,
            agency: spec.agency,
            distanceMi: spec.miles,
            peakElevFt: spec.elev,
            reqClearanceIn: spec.clearance,
            minCanopyFt: spec.canopy,
            waterCrossingIn: spec.water,
            reqLocker: spec.locker,
            gateStatus: spec.gate,
            snotelSnowIn: spec.snow,
            usgsFlowCfs: spec.flow,
            state: spec.state,
            centerLat: spec.lat,
            centerLon: spec.lon,
            coordinates: coordinates,
            flatCamps: camps
        )
    }
}

private struct AtlasSpec {
    var id: String
    var name: String
    var region: String
    var agency: String
    var state: String
    var lat: Double
    var lon: Double
    var miles: Double
    var elev: Int
    var clearance: Double
    var canopy: Double
    var water: Int
    var locker: Bool
    var gate: String = "OPEN"
    var snow: Double = 0
    var flow: Int = 0
    var km: Double = 18
}

private let specs: [AtlasSpec] = [
    AtlasSpec(id: "rubicon", name: "Rubicon Trail", region: "Eldorado NF, CA", agency: "USFS / El Dorado County", state: "CA", lat: 38.990, lon: -120.250, miles: 22.0, elev: 7000, clearance: 12.0, canopy: 10.5, water: 22, locker: true, gate: "CAUTION", snow: 8, km: 28),
    AtlasSpec(id: "mojave-road", name: "Mojave Road", region: "Mojave National Preserve, CA", agency: "NPS / BLM", state: "CA", lat: 35.150, lon: -115.550, miles: 140.0, elev: 5400, clearance: 9.0, canopy: 14.0, water: 12, locker: false, km: 80),
    AtlasSpec(id: "mengel-pass", name: "Death Valley Mengel Pass", region: "Butte Valley, CA", agency: "NPS Death Valley", state: "CA", lat: 35.905, lon: -117.070, miles: 28.0, elev: 4300, clearance: 11.5, canopy: 14.0, water: 0, locker: true, gate: "CAUTION", km: 22),
    AtlasSpec(id: "usal", name: "Lost Coast Usal Rd", region: "Mendocino Coast, CA", agency: "BLM King Range", state: "CA", lat: 39.850, lon: -123.850, miles: 26.8, elev: 2840, clearance: 9.2, canopy: 7.4, water: 16, locker: false, gate: "CAUTION", flow: 68, km: 30),
    AtlasSpec(id: "coyote-flat", name: "Coyote Flat", region: "Bishop, CA", agency: "USFS / BLM", state: "CA", lat: 37.160, lon: -118.390, miles: 24.0, elev: 10500, clearance: 10.0, canopy: 12.0, water: 8, locker: false, snow: 6, km: 24),
    AtlasSpec(id: "imogene", name: "Imogene Pass", region: "Ouray to Telluride, CO", agency: "USFS Legal Dispersed", state: "CO", lat: 37.9589, lon: -107.7352, miles: 17.2, elev: 13114, clearance: 10.5, canopy: 8.5, water: 19, locker: true, snow: 4.2, flow: 12, km: 22),
    AtlasSpec(id: "black-bear", name: "Black Bear Pass", region: "Telluride, CO", agency: "USFS", state: "CO", lat: 37.910, lon: -107.760, miles: 10.5, elev: 12900, clearance: 12.0, canopy: 9.0, water: 18, locker: true, gate: "CAUTION", snow: 12, km: 14),
    AtlasSpec(id: "engineer", name: "Engineer Pass", region: "Alpine Loop, CO", agency: "USFS / BLM", state: "CO", lat: 37.975, lon: -107.610, miles: 15.0, elev: 12800, clearance: 10.0, canopy: 10.0, water: 14, locker: false, snow: 8, km: 20),
    AtlasSpec(id: "ophir", name: "Ophir Pass", region: "San Juan Mountains, CO", agency: "USFS", state: "CO", lat: 37.853, lon: -107.778, miles: 8.4, elev: 11789, clearance: 9.5, canopy: 11.0, water: 10, locker: false, snow: 6, km: 12),
    AtlasSpec(id: "whiterim", name: "White Rim Trail", region: "Canyonlands, UT", agency: "NPS", state: "UT", lat: 38.450, lon: -109.920, miles: 71.4, elev: 6180, clearance: 9.8, canopy: 14.0, water: 8, locker: false, flow: 420, km: 70),
    AtlasSpec(id: "shafer", name: "Shafer Trail", region: "Island in the Sky, UT", agency: "NPS", state: "UT", lat: 38.458, lon: -109.804, miles: 18.0, elev: 6200, clearance: 9.2, canopy: 14.0, water: 0, locker: false, km: 16),
    AtlasSpec(id: "hells-revenge", name: "Hell's Revenge", region: "Sand Flats, Moab, UT", agency: "BLM", state: "UT", lat: 38.573, lon: -109.549, miles: 6.5, elev: 4800, clearance: 11.0, canopy: 14.0, water: 0, locker: true, gate: "CAUTION", km: 8),
    AtlasSpec(id: "fins-things", name: "Fins & Things", region: "Sand Flats, Moab, UT", agency: "BLM", state: "UT", lat: 38.582, lon: -109.542, miles: 9.0, elev: 4700, clearance: 10.0, canopy: 14.0, water: 0, locker: false, km: 10),
    AtlasSpec(id: "cathedral", name: "Cathedral Valley", region: "Capitol Reef, UT", agency: "NPS", state: "UT", lat: 38.470, lon: -111.370, miles: 58.0, elev: 7000, clearance: 9.5, canopy: 14.0, water: 10, locker: false, km: 40),
    AtlasSpec(id: "elephant-hill", name: "Elephant Hill", region: "Needles, Canyonlands, UT", agency: "NPS", state: "UT", lat: 38.142, lon: -109.829, miles: 12.0, elev: 5600, clearance: 12.5, canopy: 12.0, water: 6, locker: true, gate: "CAUTION", km: 12),
    AtlasSpec(id: "schnebly", name: "Schnebly Hill", region: "Sedona, AZ", agency: "USFS Coconino", state: "AZ", lat: 34.848, lon: -111.740, miles: 12.0, elev: 6200, clearance: 9.0, canopy: 11.0, water: 8, locker: false, km: 14),
    AtlasSpec(id: "broken-arrow", name: "Broken Arrow", region: "Sedona, AZ", agency: "USFS", state: "AZ", lat: 34.847, lon: -111.770, miles: 3.4, elev: 4600, clearance: 10.5, canopy: 12.0, water: 0, locker: true, gate: "CAUTION", km: 6),
    AtlasSpec(id: "camino-diablo", name: "El Camino del Diablo", region: "Barry M. Goldwater / Cabeza Prieta, AZ", agency: "BLM / USFWS", state: "AZ", lat: 32.180, lon: -113.700, miles: 130.0, elev: 2500, clearance: 9.0, canopy: 14.0, water: 0, locker: false, km: 90),
    AtlasSpec(id: "crown-king", name: "Backway to Crown King", region: "Bradshaw Mountains, AZ", agency: "USFS Prescott", state: "AZ", lat: 34.210, lon: -112.340, miles: 28.0, elev: 5900, clearance: 9.4, canopy: 10.5, water: 12, locker: false, km: 24),
    AtlasSpec(id: "morrison", name: "Morrison Jeep Trail", region: "Bighorn NF, WY", agency: "USFS", state: "WY", lat: 44.320, lon: -107.250, miles: 18.0, elev: 9200, clearance: 10.0, canopy: 10.0, water: 14, locker: true, snow: 10, km: 16),
    AtlasSpec(id: "magruder", name: "Magruder Corridor", region: "Nez Perce-Clearwater, ID / MT", agency: "USFS", state: "ID", lat: 45.700, lon: -114.850, miles: 101.0, elev: 7600, clearance: 9.0, canopy: 11.0, water: 18, locker: false, km: 70),
    AtlasSpec(id: "lolo", name: "Lolo Motorway", region: "Clearwater NF, ID", agency: "USFS", state: "ID", lat: 46.450, lon: -115.350, miles: 90.0, elev: 7000, clearance: 9.2, canopy: 10.0, water: 12, locker: false, km: 60),
    AtlasSpec(id: "wabdr", name: "Washington Backcountry Discovery Route", region: "Cascades & Columbia Plateau, WA", agency: "USFS / DNR", state: "WA", lat: 47.100, lon: -120.600, miles: 580.0, elev: 5500, clearance: 8.5, canopy: 11.0, water: 12, locker: false, km: 40),
    AtlasSpec(id: "obdr", name: "Oregon Backcountry Discovery Route", region: "High Desert & Cascades, OR", agency: "USFS / BLM", state: "OR", lat: 44.100, lon: -119.400, miles: 750.0, elev: 7000, clearance: 8.5, canopy: 12.0, water: 10, locker: false, km: 40),
    AtlasSpec(id: "steens", name: "Steens Mountain Loop", region: "Steens Mountain, OR", agency: "BLM", state: "OR", lat: 42.670, lon: -118.580, miles: 59.0, elev: 9773, clearance: 8.8, canopy: 13.0, water: 8, locker: false, snow: 4, km: 40),
    AtlasSpec(id: "jarbidge", name: "Jarbidge Canyon", region: "Jarbidge Wilderness edge, NV", agency: "USFS Humboldt-Toiyabe", state: "NV", lat: 41.880, lon: -115.430, miles: 22.0, elev: 7800, clearance: 9.5, canopy: 10.5, water: 16, locker: false, km: 20),
    AtlasSpec(id: "titus", name: "Titus Canyon", region: "Death Valley, NV / CA", agency: "NPS", state: "NV", lat: 36.820, lon: -117.170, miles: 27.0, elev: 5200, clearance: 8.5, canopy: 14.0, water: 0, locker: false, km: 24),
    AtlasSpec(id: "chloride", name: "Chloride Canyon", region: "Gila / Black Range, NM", agency: "USFS", state: "NM", lat: 33.340, lon: -107.680, miles: 16.0, elev: 6800, clearance: 9.4, canopy: 11.0, water: 10, locker: false, km: 14),
    AtlasSpec(id: "river-road", name: "Big Bend River Road", region: "Big Bend, TX", agency: "NPS", state: "TX", lat: 29.180, lon: -103.050, miles: 51.0, elev: 2500, clearance: 8.5, canopy: 14.0, water: 6, locker: false, km: 40),
    AtlasSpec(id: "black-gap", name: "Black Gap Road", region: "Big Bend, TX", agency: "NPS", state: "TX", lat: 29.350, lon: -102.950, miles: 23.0, elev: 2800, clearance: 10.0, canopy: 14.0, water: 0, locker: true, gate: "CAUTION", km: 20),
    AtlasSpec(id: "ozark", name: "Ozark-St. Francis NF Loop", region: "Ozark NF, AR", agency: "USFS", state: "AR", lat: 35.750, lon: -93.200, miles: 42.0, elev: 2300, clearance: 8.6, canopy: 10.0, water: 14, locker: false, km: 30),
    AtlasSpec(id: "glade-top", name: "Glade Top Trail", region: "Mark Twain NF, MO", agency: "USFS", state: "MO", lat: 36.680, lon: -92.650, miles: 23.0, elev: 1400, clearance: 8.2, canopy: 10.5, water: 8, locker: false, km: 22),
    AtlasSpec(id: "hurricane", name: "Hurricane Creek", region: "Pisgah NF, NC", agency: "USFS", state: "NC", lat: 35.420, lon: -82.860, miles: 12.0, elev: 4200, clearance: 9.5, canopy: 9.5, water: 16, locker: false, km: 12),
    AtlasSpec(id: "dickey-bell", name: "Uwharrie Dickey Bell", region: "Uwharrie NF, NC", agency: "USFS", state: "NC", lat: 35.420, lon: -79.960, miles: 8.5, elev: 900, clearance: 9.0, canopy: 10.0, water: 12, locker: false, km: 10),
    AtlasSpec(id: "windrock", name: "Nemo Tunnel & Windrock", region: "Cumberland Plateau, TN", agency: "Private OHV / public connectors", state: "TN", lat: 36.140, lon: -84.330, miles: 14.0, elev: 2700, clearance: 10.5, canopy: 10.0, water: 18, locker: true, gate: "CAUTION", km: 12),
    AtlasSpec(id: "ga-traverse", name: "Georgia Traverse", region: "Chattahoochee NF, GA", agency: "USFS", state: "GA", lat: 34.720, lon: -83.850, miles: 350.0, elev: 4400, clearance: 8.8, canopy: 10.0, water: 14, locker: false, km: 36),
    AtlasSpec(id: "tray", name: "Tray Mountain Rd", region: "Chattahoochee NF, GA", agency: "USFS", state: "GA", lat: 34.810, lon: -83.680, miles: 11.0, elev: 4430, clearance: 8.6, canopy: 10.5, water: 8, locker: false, km: 12),
    AtlasSpec(id: "potts", name: "Potts Mountain Jeep Trail", region: "Jefferson NF, VA", agency: "USFS", state: "VA", lat: 37.600, lon: -80.150, miles: 13.0, elev: 3800, clearance: 9.6, canopy: 9.8, water: 12, locker: true, km: 14),
    AtlasSpec(id: "flagpole", name: "Flagpole Knob", region: "George Washington NF, VA", agency: "USFS", state: "VA", lat: 38.480, lon: -79.160, miles: 9.0, elev: 4380, clearance: 9.2, canopy: 10.0, water: 8, locker: false, km: 10),
    AtlasSpec(id: "bald-mtn", name: "Bald Mountain Jeep Trail", region: "Weiser State Forest, PA", agency: "State Forest", state: "PA", lat: 40.550, lon: -76.450, miles: 7.5, elev: 1800, clearance: 9.8, canopy: 10.0, water: 10, locker: true, gate: "CAUTION", km: 8),
    AtlasSpec(id: "dolly-sods", name: "Dolly Sods FR-75", region: "Monongahela NF, WV", agency: "USFS", state: "WV", lat: 38.990, lon: -79.360, miles: 18.0, elev: 4000, clearance: 8.8, canopy: 10.0, water: 12, locker: false, km: 16),
    AtlasSpec(id: "jericho", name: "Jericho Mountain", region: "Berlin, NH", agency: "NH State Park", state: "NH", lat: 44.480, lon: -71.280, miles: 12.0, elev: 2300, clearance: 9.0, canopy: 10.5, water: 8, locker: false, km: 10),
    AtlasSpec(id: "tnh", name: "Trans-New Hampshire Overland", region: "White Mountains, NH", agency: "USFS / State", state: "NH", lat: 43.950, lon: -71.450, miles: 220.0, elev: 3200, clearance: 8.5, canopy: 10.0, water: 12, locker: false, km: 30),
    AtlasSpec(id: "maine-woods", name: "North Maine Woods", region: "North Maine Woods, ME", agency: "North Maine Woods", state: "ME", lat: 46.500, lon: -69.250, miles: 80.0, elev: 1800, clearance: 8.4, canopy: 10.5, water: 16, locker: false, km: 40),
    AtlasSpec(id: "marblehead", name: "Drummond Island Marblehead", region: "Drummond Island, MI", agency: "State Forest", state: "MI", lat: 46.020, lon: -83.670, miles: 18.0, elev: 700, clearance: 8.8, canopy: 12.0, water: 6, locker: false, km: 16),
    AtlasSpec(id: "keweenaw", name: "Keweenaw Rocket Range", region: "Keweenaw Peninsula, MI", agency: "State / private connectors", state: "MI", lat: 47.430, lon: -87.900, miles: 10.0, elev: 900, clearance: 9.0, canopy: 12.5, water: 4, locker: false, km: 10),
    AtlasSpec(id: "wisconsin", name: "Pipeline & Trans-Wisconsin Trail", region: "Chequamegon-Nicolet, WI", agency: "USFS / State", state: "WI", lat: 45.550, lon: -89.700, miles: 120.0, elev: 1700, clearance: 8.4, canopy: 10.5, water: 12, locker: false, km: 36),
    AtlasSpec(id: "gunflint", name: "Gunflint Overland Loop", region: "Superior NF, MN", agency: "USFS", state: "MN", lat: 48.050, lon: -90.500, miles: 45.0, elev: 1900, clearance: 8.6, canopy: 10.5, water: 14, locker: false, km: 28),
    AtlasSpec(id: "ditch-creek", name: "Black Hills Ditch Creek", region: "Black Hills NF, SD", agency: "USFS", state: "SD", lat: 43.850, lon: -103.550, miles: 16.0, elev: 5600, clearance: 9.0, canopy: 11.0, water: 8, locker: false, km: 14),
    AtlasSpec(id: "ocala", name: "Ocala National Forest 4x4 Trail", region: "Ocala NF, FL", agency: "USFS", state: "FL", lat: 29.180, lon: -81.760, miles: 22.0, elev: 120, clearance: 8.5, canopy: 11.0, water: 10, locker: false, km: 18),
    AtlasSpec(id: "denali", name: "Denali Highway", region: "Paxson to Cantwell, AK", agency: "BLM / State", state: "AK", lat: 63.100, lon: -147.500, miles: 135.0, elev: 4000, clearance: 8.2, canopy: 14.0, water: 18, locker: false, snow: 6, km: 60),
    AtlasSpec(id: "dalton", name: "Dalton Highway", region: "Brooks Range, AK", agency: "State", state: "AK", lat: 67.150, lon: -150.200, miles: 414.0, elev: 4800, clearance: 8.0, canopy: 14.0, water: 20, locker: false, snow: 8, km: 50),
    AtlasSpec(id: "polihale", name: "Polihale & Waimea Canyon 4x4", region: "Kauai, HI", agency: "State Parks", state: "HI", lat: 22.080, lon: -159.730, miles: 16.0, elev: 3400, clearance: 8.8, canopy: 12.0, water: 6, locker: false, km: 14),
    AtlasSpec(id: "kentuck", name: "Kentuck ORV", region: "Bankhead NF, AL", agency: "USFS", state: "AL", lat: 34.310, lon: -87.350, miles: 18.0, elev: 900, clearance: 8.8, canopy: 10.5, water: 10, locker: false, km: 14),
    AtlasSpec(id: "pachaug", name: "Pachaug State Forest Roads", region: "Voluntown, CT", agency: "State Forest", state: "CT", lat: 41.600, lon: -71.880, miles: 12.0, elev: 400, clearance: 8.2, canopy: 11.0, water: 6, locker: false, km: 10),
    AtlasSpec(id: "redden", name: "Redden State Forest Roads", region: "Sussex County, DE", agency: "State Forest", state: "DE", lat: 38.740, lon: -75.410, miles: 9.0, elev: 50, clearance: 8.0, canopy: 11.0, water: 6, locker: false, km: 8),
    AtlasSpec(id: "garden-gods", name: "Garden of the Gods OHV", region: "Shawnee NF, IL", agency: "USFS", state: "IL", lat: 37.630, lon: -88.390, miles: 16.0, elev: 700, clearance: 8.6, canopy: 10.5, water: 8, locker: false, km: 12),
    AtlasSpec(id: "hickory-ridge", name: "Hickory Ridge Road", region: "Hoosier NF, IN", agency: "USFS", state: "IN", lat: 38.450, lon: -86.480, miles: 14.0, elev: 800, clearance: 8.4, canopy: 10.5, water: 8, locker: false, km: 12),
    AtlasSpec(id: "yellow-river", name: "Yellow River Forest Road", region: "Yellow River SF, IA", agency: "State Forest", state: "IA", lat: 43.160, lon: -91.220, miles: 11.0, elev: 900, clearance: 8.2, canopy: 11.0, water: 10, locker: false, km: 10),
    AtlasSpec(id: "kanopolis", name: "Kanopolis ORV", region: "Kanopolis, KS", agency: "State Park", state: "KS", lat: 38.700, lon: -98.160, miles: 10.0, elev: 1500, clearance: 8.4, canopy: 12.0, water: 4, locker: false, km: 8),
    AtlasSpec(id: "turkey-bay", name: "Turkey Bay OHV", region: "Land Between the Lakes, KY", agency: "USFS", state: "KY", lat: 36.790, lon: -88.050, miles: 22.0, elev: 500, clearance: 8.8, canopy: 11.0, water: 8, locker: false, km: 16),
    AtlasSpec(id: "kisatchie", name: "Kisatchie Hills Trail", region: "Kisatchie NF, LA", agency: "USFS", state: "LA", lat: 31.480, lon: -93.050, miles: 18.0, elev: 350, clearance: 8.4, canopy: 11.0, water: 8, locker: false, km: 14),
    AtlasSpec(id: "green-ridge", name: "Green Ridge State Forest", region: "Allegany, MD", agency: "State Forest", state: "MD", lat: 39.660, lon: -78.460, miles: 24.0, elev: 1800, clearance: 8.6, canopy: 10.5, water: 10, locker: false, km: 18),
    AtlasSpec(id: "october-mtn", name: "October Mountain Roads", region: "October Mountain SF, MA", agency: "State Forest", state: "MA", lat: 42.360, lon: -73.170, miles: 10.0, elev: 1600, clearance: 8.2, canopy: 10.5, water: 6, locker: false, km: 8),
    AtlasSpec(id: "black-creek", name: "Black Creek OHV", region: "De Soto NF, MS", agency: "USFS", state: "MS", lat: 30.950, lon: -89.050, miles: 20.0, elev: 200, clearance: 8.4, canopy: 11.0, water: 12, locker: false, km: 14),
    AtlasSpec(id: "garnet", name: "Garnet Range Backroad", region: "Garnet Range, MT", agency: "USFS / BLM", state: "MT", lat: 46.820, lon: -113.340, miles: 16.0, elev: 6200, clearance: 9.0, canopy: 11.0, water: 8, locker: false, km: 14),
    AtlasSpec(id: "toadstool", name: "Toadstool Road", region: "Oglala National Grassland, NE", agency: "USFS", state: "NE", lat: 42.850, lon: -103.580, miles: 12.0, elev: 4200, clearance: 8.2, canopy: 14.0, water: 0, locker: false, km: 10),
    AtlasSpec(id: "wharton", name: "Wharton State Forest Roads", region: "Pine Barrens, NJ", agency: "State Forest", state: "NJ", lat: 39.700, lon: -74.730, miles: 20.0, elev: 80, clearance: 8.2, canopy: 12.0, water: 8, locker: false, km: 16),
    AtlasSpec(id: "moose-river", name: "Moose River Plains", region: "Adirondacks, NY", agency: "State Forest", state: "NY", lat: 43.760, lon: -74.780, miles: 30.0, elev: 2000, clearance: 8.4, canopy: 10.5, water: 12, locker: false, km: 22),
    AtlasSpec(id: "little-missouri", name: "Little Missouri Grassland Road", region: "Little Missouri NG, ND", agency: "USFS", state: "ND", lat: 46.750, lon: -103.550, miles: 18.0, elev: 2600, clearance: 8.2, canopy: 14.0, water: 6, locker: false, km: 14),
    AtlasSpec(id: "wayne-nf", name: "Wayne National Forest Roads", region: "Hanging Rock, OH", agency: "USFS", state: "OH", lat: 39.300, lon: -82.400, miles: 16.0, elev: 900, clearance: 8.4, canopy: 10.5, water: 10, locker: false, km: 12),
    AtlasSpec(id: "winding-stair", name: "Winding Stair OHV", region: "Ouachita NF, OK", agency: "USFS", state: "OK", lat: 34.700, lon: -94.650, miles: 18.0, elev: 1600, clearance: 8.8, canopy: 10.5, water: 10, locker: false, km: 14),
    AtlasSpec(id: "arcadia", name: "Arcadia Management Area", region: "Arcadia, RI", agency: "State", state: "RI", lat: 41.570, lon: -71.720, miles: 8.0, elev: 400, clearance: 8.0, canopy: 11.0, water: 6, locker: false, km: 8),
    AtlasSpec(id: "francis-marion", name: "Francis Marion Forest Roads", region: "Francis Marion NF, SC", agency: "USFS", state: "SC", lat: 33.200, lon: -79.650, miles: 18.0, elev: 60, clearance: 8.2, canopy: 11.0, water: 10, locker: false, km: 14),
    AtlasSpec(id: "lincoln-gap", name: "Lincoln Gap Road", region: "Green Mountains, VT", agency: "Town / USFS", state: "VT", lat: 44.100, lon: -72.930, miles: 9.0, elev: 2420, clearance: 8.4, canopy: 10.5, water: 8, locker: false, km: 8)
]

private let handRoutes: [String: [CLLocationCoordinate2D]] = [
    "imogene": [
        CLLocationCoordinate2D(latitude: 38.02280, longitude: -107.67140),
        CLLocationCoordinate2D(latitude: 37.98142, longitude: -107.73411),
        CLLocationCoordinate2D(latitude: 37.95890, longitude: -107.73520),
        CLLocationCoordinate2D(latitude: 37.93268, longitude: -107.73694),
        CLLocationCoordinate2D(latitude: 37.93750, longitude: -107.81080)
    ],
    "rubicon": [
        CLLocationCoordinate2D(latitude: 39.002, longitude: -120.228),
        CLLocationCoordinate2D(latitude: 38.990, longitude: -120.250),
        CLLocationCoordinate2D(latitude: 38.978, longitude: -120.285),
        CLLocationCoordinate2D(latitude: 38.970, longitude: -120.315)
    ],
    "whiterim": [
        CLLocationCoordinate2D(latitude: 38.480, longitude: -109.820),
        CLLocationCoordinate2D(latitude: 38.450, longitude: -109.900),
        CLLocationCoordinate2D(latitude: 38.420, longitude: -109.960),
        CLLocationCoordinate2D(latitude: 38.520, longitude: -110.000)
    ],
    "usal": [
        CLLocationCoordinate2D(latitude: 39.820, longitude: -123.820),
        CLLocationCoordinate2D(latitude: 39.850, longitude: -123.850),
        CLLocationCoordinate2D(latitude: 39.900, longitude: -123.900),
        CLLocationCoordinate2D(latitude: 39.960, longitude: -123.980)
    ],
    "black-bear": [
        CLLocationCoordinate2D(latitude: 37.937, longitude: -107.812),
        CLLocationCoordinate2D(latitude: 37.920, longitude: -107.780),
        CLLocationCoordinate2D(latitude: 37.899, longitude: -107.738)
    ],
    "hells-revenge": [
        CLLocationCoordinate2D(latitude: 38.572, longitude: -109.555),
        CLLocationCoordinate2D(latitude: 38.576, longitude: -109.548),
        CLLocationCoordinate2D(latitude: 38.568, longitude: -109.540)
    ]
]

private let handCamps: [String: [(name: String, lat: Double, lon: Double, slopeDeg: Double, starlinkPct: Int)]] = [
    "imogene": [
        (name: "Upper Basin Pad", lat: 37.98142, lon: -107.73411, slopeDeg: 1.4, starlinkPct: 96),
        (name: "Imogene Basin Pad", lat: 37.94185, lon: -107.73598, slopeDeg: 2.1, starlinkPct: 99)
    ]
]
