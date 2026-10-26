import AVFoundation
import CoreImage
import CoreLocation
import Foundation
import UIKit
import UserNotifications

enum TrailLegal {
    static func status(agency: String, corridor: Bool) -> String {
        if corridor { return "corridor" }
        let upper = agency.uppercased()
        if upper.contains("USFS") || upper.contains("FOREST SERVICE") { return "mvum" }
        if upper.contains("BLM") || upper.contains("LAND MANAGEMENT") { return "blm" }
        return "local"
    }

    static func badge(for trail: OverlandTrail) -> String {
        switch trail.legalStatus {
        case "mvum", "blm":
            return "✅ USFS MVUM / BLM Verified • Seasonal Open Window • Gate \(trail.gateStatus)"
        case "osm":
            return "⚠️ Unverified OSM Track — Check Local MVUM & Gate Status"
        case "corridor":
            return "Public-road corridor • confirm the local MVUM before you roll"
        default:
            return "Listed route • confirm the local MVUM and gate status"
        }
    }

    static func isDashed(_ trail: OverlandTrail) -> Bool {
        trail.legalStatus == "osm"
    }
}

struct CruxPin: Identifiable {
    let id: String
    let title: String
    let detail: String
    let spoken: String
    let coordinate: CLLocationCoordinate2D
}

enum CruxCatalog {
    static func pins(for trail: OverlandTrail) -> [CruxPin] {
        let line = trail.coordinates
        guard line.count >= 2 else { return [] }
        var pins: [CruxPin] = []
        if trail.gateStatus != "OPEN" {
            pins.append(make(
                trail: trail,
                index: 1,
                fraction: 0.18,
                title: "⚠️ Gate",
                detail: "Listed gate status \(trail.gateStatus). Confirm it is open before you commit.",
                spoken: "Gate ahead. Listed status \(trail.gateStatus)."
            ))
        }
        if trail.waterCrossingIn > 0 {
            let depth = trail.waterCrossingIn
            pins.append(make(
                trail: trail,
                index: pins.count + 1,
                fraction: 0.42,
                title: "💧 \(depth)\" Creek Ford",
                detail: "Listed ford depth \(depth) in. Main line: check the USGS gauge. Bypass: use the signed high-water line if one is posted.",
                spoken: "Water crossing ahead. Listed depth \(depth) inches. Check the gauge and stay on the posted line."
            ))
        }
        if trail.reqClearanceIn >= 9 || trail.reqLocker {
            let height = Int(trail.reqClearanceIn.rounded())
            let main = trail.reqLocker ? "Caution — locker listed" : "Caution"
            pins.append(make(
                trail: trail,
                index: pins.count + 1,
                fraction: 0.68,
                title: "🪨 \(height)\" Rock Ledge",
                detail: "Main line: \(main). Bypass: walk it first. Listed clearance is \(height) inches from the trail record, not a fresh survey.",
                spoken: "Obstacle ahead. Listed clearance \(height) inches. \(main). Walk the bypass before you commit."
            ))
        }
        return pins
    }

    private static func make(
        trail: OverlandTrail,
        index: Int,
        fraction: Double,
        title: String,
        detail: String,
        spoken: String
    ) -> CruxPin {
        CruxPin(
            id: "\(trail.id)-crux-\(index)",
            title: "Obstacle #\(index): \(title)",
            detail: detail,
            spoken: spoken,
            coordinate: point(on: trail.coordinates, fraction: fraction)
        )
    }

    private static func point(on line: [CLLocationCoordinate2D], fraction: Double) -> CLLocationCoordinate2D {
        guard line.count >= 2 else { return line.first ?? CLLocationCoordinate2D(latitude: 0, longitude: 0) }
        let target = fraction * Double(line.count - 1)
        let index = min(line.count - 2, max(0, Int(target.rounded(.down))))
        let part = target - Double(index)
        let start = line[index]
        let end = line[index + 1]
        return CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * part,
            longitude: start.longitude + (end.longitude - start.longitude) * part
        )
    }
}

enum RangerDesk {
    struct Office {
        let forest: String
        let phone: String
    }

    static func office(for trail: OverlandTrail) -> Office? {
        let blob = "\(trail.name) \(trail.region) \(trail.agency)".lowercased()
        let specific: [(String, Office)] = [
            ("gifford", Office(forest: "Gifford Pinchot NF", phone: "3608915000")),
            ("nez perce", Office(forest: "Nez Perce-Clearwater NF", phone: "2089352513")),
            ("clearwater", Office(forest: "Nez Perce-Clearwater NF", phone: "2089352513")),
            ("eldorado", Office(forest: "Eldorado NF", phone: "5306225061")),
            ("inyo", Office(forest: "Inyo NF", phone: "7608732400")),
            ("coconino", Office(forest: "Coconino NF", phone: "9285273600")),
            ("humboldt", Office(forest: "Humboldt-Toiyabe NF", phone: "7753316444")),
            ("san juan", Office(forest: "San Juan NF", phone: "9702474874")),
            ("manti", Office(forest: "Manti-La Sal NF", phone: "4356363500")),
            ("boise", Office(forest: "Boise NF", phone: "2083734100")),
            ("bridger", Office(forest: "Bridger-Teton NF", phone: "3077395500")),
            ("cibola", Office(forest: "Cibola NF", phone: "5053463900")),
            ("black hills", Office(forest: "Black Hills NF", phone: "6056739200")),
            ("chattahoochee", Office(forest: "Chattahoochee-Oconee NF", phone: "7702973000")),
            ("pisgah", Office(forest: "National Forests in North Carolina", phone: "8282574200")),
            ("white mountain", Office(forest: "White Mountain NF", phone: "6035366100")),
            ("george washington", Office(forest: "George Washington & Jefferson NF", phone: "5402655100")),
            ("deschutes", Office(forest: "Deschutes NF", phone: "5413835300")),
            ("mount hood", Office(forest: "Mount Hood NF", phone: "5036681700")),
            ("ozark", Office(forest: "Ozark-St. Francis NF", phone: "5018020287")),
            ("superior", Office(forest: "Superior NF", phone: "2186264300")),
            ("chequamegon", Office(forest: "Chequamegon-Nicolet NF", phone: "7153621300")),
            ("ocala", Office(forest: "National Forests in Florida", phone: "8505238500")),
            ("monongahela", Office(forest: "Monongahela NF", phone: "3046361800")),
            ("dolly", Office(forest: "Monongahela NF", phone: "3046361800")),
            ("allegheny", Office(forest: "Allegheny NF", phone: "8147235150")),
            ("beaverhead", Office(forest: "Beaverhead-Deerlodge NF", phone: "4066833900"))
        ]
        if let match = specific.first(where: { blob.contains($0.0) }) {
            return match.1
        }
        let byState: [String: Office] = [
            "WA": Office(forest: "Gifford Pinchot NF", phone: "3608915000"),
            "OR": Office(forest: "Deschutes NF", phone: "5413835300"),
            "CA": Office(forest: "Inyo NF", phone: "7608732400"),
            "AZ": Office(forest: "Coconino NF", phone: "9285273600"),
            "NV": Office(forest: "Humboldt-Toiyabe NF", phone: "7753316444"),
            "CO": Office(forest: "San Juan NF", phone: "9702474874"),
            "UT": Office(forest: "Manti-La Sal NF", phone: "4356363500"),
            "ID": Office(forest: "Boise NF", phone: "2083734100"),
            "WY": Office(forest: "Bridger-Teton NF", phone: "3077395500"),
            "NM": Office(forest: "Cibola NF", phone: "5053463900"),
            "SD": Office(forest: "Black Hills NF", phone: "6056739200"),
            "GA": Office(forest: "Chattahoochee-Oconee NF", phone: "7702973000"),
            "NC": Office(forest: "National Forests in North Carolina", phone: "8282574200"),
            "NH": Office(forest: "White Mountain NF", phone: "6035366100"),
            "VA": Office(forest: "George Washington & Jefferson NF", phone: "5402655100"),
            "AR": Office(forest: "Ozark-St. Francis NF", phone: "5018020287"),
            "MN": Office(forest: "Superior NF", phone: "2186264300"),
            "WI": Office(forest: "Chequamegon-Nicolet NF", phone: "7153621300"),
            "FL": Office(forest: "National Forests in Florida", phone: "8505238500"),
            "WV": Office(forest: "Monongahela NF", phone: "3046361800"),
            "PA": Office(forest: "Allegheny NF", phone: "8147235150"),
            "MT": Office(forest: "Beaverhead-Deerlodge NF", phone: "4066833900")
        ]
        return byState[trail.state]
    }

    static func phoneLabel(_ office: Office) -> String {
        let digits = office.phone
        guard digits.count == 10 else { return office.forest }
        let area = digits.prefix(3)
        let mid = digits.dropFirst(3).prefix(3)
        let last = digits.suffix(4)
        return "Call \(office.forest) • (\(area)) \(mid)-\(last)"
    }

    static func telURL(_ office: Office) -> URL? {
        URL(string: "tel://\(office.phone)")
    }
}

struct DroppedHazard: Codable, Identifiable {
    var id: String
    var category: String
    var latitude: Double
    var longitude: Double
    var elevationFt: Int
    var note: String
    var photoPath: String?
    var voicePath: String?
    var createdAt: Date
    var trailID: String
    var confirmations: Int
    var cleared: Bool
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, category, latitude, longitude, elevationFt, note, photoPath, voicePath, createdAt, trailID, confirmations, cleared, updatedAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(
        id: String,
        category: String,
        latitude: Double,
        longitude: Double,
        elevationFt: Int,
        note: String,
        photoPath: String? = nil,
        voicePath: String? = nil,
        createdAt: Date,
        trailID: String = "",
        confirmations: Int = 1,
        cleared: Bool = false,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.elevationFt = elevationFt
        self.note = note
        self.photoPath = photoPath
        self.voicePath = voicePath
        self.createdAt = createdAt
        self.trailID = trailID
        self.confirmations = confirmations
        self.cleared = cleared
        self.updatedAt = updatedAt ?? createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(String.self, forKey: .category)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        elevationFt = try container.decode(Int.self, forKey: .elevationFt)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        photoPath = try container.decodeIfPresent(String.self, forKey: .photoPath)
        voicePath = try container.decodeIfPresent(String.self, forKey: .voicePath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        trailID = try container.decodeIfPresent(String.self, forKey: .trailID) ?? ""
        confirmations = try container.decodeIfPresent(Int.self, forKey: .confirmations) ?? 1
        cleared = try container.decodeIfPresent(Bool.self, forKey: .cleared) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(category, forKey: .category)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(elevationFt, forKey: .elevationFt)
        try container.encode(note, forKey: .note)
        try container.encodeIfPresent(photoPath, forKey: .photoPath)
        try container.encodeIfPresent(voicePath, forKey: .voicePath)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(trailID, forKey: .trailID)
        try container.encode(confirmations, forKey: .confirmations)
        try container.encode(cleared, forKey: .cleared)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

enum HazardCatalog {
    static let categories = [
        "🪨 Rock Ledge",
        "💧 Deep Ford",
        "🌲 Downed Tree",
        "⛺ Verified <3° Pad",
        "🔒 Locked Gate"
    ]
}

enum TripPackageBuilder {
    static func gpx(
        trail: OverlandTrail,
        track: [CLLocationCoordinate2D],
        hazards: [DroppedHazard]
    ) -> String {
        let line = track.count >= 2 ? track : trail.coordinates
        var waypoints: [GPXWaypoint] = trail.campSpots.map { spot in
            GPXWaypoint(
                id: UUID(),
                name: xml(spot.name),
                latitude: spot.lat,
                longitude: spot.lon,
                elevationMeters: 0,
                slopeDegrees: spot.slopeDeg,
                starlinkSkyPct: spot.starlinkPct,
                sym: "Campground"
            )
        }
        for pin in CruxCatalog.pins(for: trail) {
            waypoints.append(GPXWaypoint(
                id: UUID(),
                name: xml(pin.title),
                latitude: pin.coordinate.latitude,
                longitude: pin.coordinate.longitude,
                elevationMeters: 0,
                slopeDegrees: 0,
                starlinkSkyPct: 0,
                sym: "Danger"
            ))
        }
        for hazard in hazards {
            waypoints.append(GPXWaypoint(
                id: UUID(),
                name: xml("\(hazard.category) \(hazard.note)"),
                latitude: hazard.latitude,
                longitude: hazard.longitude,
                elevationMeters: Double(hazard.elevationFt) * 0.3048,
                slopeDegrees: 0,
                starlinkSkyPct: 0,
                sym: "Flag"
            ))
        }
        return GPXTrackManager().exportGPXString(
            trailName: xml(trail.name),
            waypoints: waypoints,
            track: Array(simplify(line).prefix(180))
        )
    }

    static func qrText(for trail: OverlandTrail, hazards: [DroppedHazard]) -> String {
        let start = trail.coordinates.first
        let end = trail.coordinates.last
        let crux = CruxCatalog.pins(for: trail).map(\.title).joined(separator: " | ")
        let drops = hazards.prefix(6).map { "\($0.category) \(String(format: "%.4f", $0.latitude)),\(String(format: "%.4f", $0.longitude))" }.joined(separator: " | ")
        var text = "\(trail.name) | \(trail.state) | \(String(format: "%.4f", start?.latitude ?? trail.centerLat)),\(String(format: "%.4f", start?.longitude ?? trail.centerLon)) -> \(String(format: "%.4f", end?.latitude ?? trail.centerLat)),\(String(format: "%.4f", end?.longitude ?? trail.centerLon)) | \(crux) | \(drops)"
        if text.utf8.count > 900 {
            text = String(text.prefix(900))
        }
        return text
    }

    static func qrImage(_ text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func xml(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func simplify(_ line: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard line.count > 80 else { return line }
        let step = Double(line.count - 1) / 79
        var kept: [CLLocationCoordinate2D] = []
        var last = -1
        for index in 0..<80 {
            let source = min(line.count - 1, Int((Double(index) * step).rounded()))
            if source == last { continue }
            kept.append(line[source])
            last = source
        }
        return kept
    }
}

final class HazardNoteRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    private var recorder: AVAudioRecorder?

    func start(url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.record(forDuration: 5)
        self.recorder = recorder
        isRecording = true
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false
    }
}

final class CorridorDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = CorridorDownloader()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.edwardshin.trailforge.corridor")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var completion: ((Bool) -> Void)?
    private var packFolder: URL?
    private var packRecord: OfflineCorridorPack?

    func start(
        trail: OverlandTrail,
        track: [CLLocationCoordinate2D],
        hazards: [DroppedHazard],
        tier: String,
        done: @escaping (OfflineCorridorPack) -> Void
    ) {
        let folder = Self.directory().appendingPathComponent("\(trail.id)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let gpx = TripPackageBuilder.gpx(trail: trail, track: track, hazards: hazards)
        try? gpx.data(using: .utf8)?.write(to: folder.appendingPathComponent("route.gpx"))
        let record = OfflineCorridorPack(
            id: folder.lastPathComponent,
            name: trail.name,
            trailID: trail.id,
            tier: tier,
            nominalMegabytes: max(1, gpx.utf8.count / (1024 * 1024)),
            savedAt: Date(),
            vertexCount: min(220, track.count)
        )
        packFolder = folder
        packRecord = record
        completion = { _ in
            done(record)
        }
        let center = trail.centerCoordinate
        var components = URLComponents(string: "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_ForestSystemBoundaries_01/MapServer/0/query")
        components?.queryItems = [
            URLQueryItem(name: "geometry", value: "\(center.longitude),\(center.latitude)"),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: "forestname,gis_acres"),
            URLQueryItem(name: "returnGeometry", value: "false"),
            URLQueryItem(name: "f", value: "json")
        ]
        guard let url = components?.url else {
            finish(success: true)
            return
        }
        let task = session.downloadTask(with: url)
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let folder = packFolder {
            let destination = folder.appendingPathComponent("usfs-boundary.json")
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: location, to: destination)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(success: true)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {}

    private func finish(success: Bool) {
        let callback = completion
        completion = nil
        notify()
        DispatchQueue.main.async {
            callback?(success)
        }
    }

    private func notify() {
        let content = UNMutableNotificationContent()
        content.title = "Corridor pack ready"
        content.body = "\(packRecord?.name ?? "Route") is saved on this iPhone."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Corridors", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
