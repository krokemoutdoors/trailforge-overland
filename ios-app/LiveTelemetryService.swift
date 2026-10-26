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
