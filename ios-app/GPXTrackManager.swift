import Foundation
import CoreLocation

struct RecordedTrackPoint: Codable, Identifiable, Hashable {
    var id: UUID
    var latitude: Double
    var longitude: Double
    var altitudeFt: Int
    var speedMph: Double
    var timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct RecordedTrailRoute: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var durationSeconds: TimeInterval
    var distanceMiles: Double
    var elevationGainFt: Int
    var maxElevationFt: Int
    var points: [RecordedTrackPoint]

    var coordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate)
    }
}

@MainActor
final class TrailRouteRecorder: ObservableObject {
    static let shared = TrailRouteRecorder()

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var activePoints: [RecordedTrackPoint] = []
    @Published var draftName: String = ""
    @Published var saved: [RecordedTrailRoute] = []
    @Published var displayedRouteID: UUID?
    @Published var elapsedTick: Int = 0

    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var timer: Timer?

    var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        let end = isPaused ? (pausedAt ?? Date()) : Date()
        return max(0, end.timeIntervalSince(startedAt) - pausedAccumulated)
    }

    var liveDistanceMiles: Double { Self.distanceMiles(activePoints) }
    var liveElevationGainFt: Int { Self.elevationGain(activePoints) }

    private init() {
        saved = CockpitStore.loadRecordedRoutes()
    }

    func toggleFromRail() {
        if isRecording {
            stopAndSave()
        } else {
            start()
        }
    }

    func start() {
        isRecording = true
        isPaused = false
        activePoints = []
        startedAt = Date()
        pausedAt = nil
        pausedAccumulated = 0
        if draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftName = Self.defaultName(Date())
        }
        startTimer()
    }

    func pauseOrResume() {
        guard isRecording else { return }
        if isPaused {
            if let pausedAt {
                pausedAccumulated += Date().timeIntervalSince(pausedAt)
            }
            pausedAt = nil
            isPaused = false
        } else {
            pausedAt = Date()
            isPaused = true
        }
        elapsedTick += 1
    }

    @discardableResult
    func stopAndSave() -> RecordedTrailRoute? {
        guard isRecording else { return nil }
        if isPaused, let pausedAt {
            pausedAccumulated += Date().timeIntervalSince(pausedAt)
        }
        let route = makeRoute()
        isRecording = false
        isPaused = false
        pausedAt = nil
        stopTimer()
        activePoints = []
        startedAt = nil
        pausedAccumulated = 0
        draftName = ""
        guard route.points.count >= 2 else { return nil }
        saved.insert(route, at: 0)
        CockpitStore.saveRecordedRoutes(saved)
        displayedRouteID = route.id
        return route
    }

    func delete(_ id: UUID) {
        saved.removeAll { $0.id == id }
        if displayedRouteID == id { displayedRouteID = nil }
        CockpitStore.saveRecordedRoutes(saved)
    }

    func capture(latitude: Double, longitude: Double, altitudeFt: Int, speedMph: Double, timestamp: Date) {
        guard isRecording, !isPaused else { return }
        if let last = activePoints.last {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: latitude, longitude: longitude))
            if moved < 1 { return }
        }
        activePoints.append(RecordedTrackPoint(
            id: UUID(),
            latitude: latitude,
            longitude: longitude,
            altitudeFt: altitudeFt,
            speedMph: speedMph,
            timestamp: timestamp
        ))
    }

    func gpxURL(for route: RecordedTrailRoute) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrailForge-\(route.id.uuidString).gpx")
        let xml = GPXTrackManager().exportRecordedRouteGPX(route)
        try? xml.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private func makeRoute() -> RecordedTrailRoute {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultName(startedAt ?? Date())
            : draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return RecordedTrailRoute(
            id: UUID(),
            name: name,
            createdAt: Date(),
            durationSeconds: elapsedSeconds,
            distanceMiles: Self.distanceMiles(activePoints),
            elevationGainFt: Self.elevationGain(activePoints),
            maxElevationFt: activePoints.map(\.altitudeFt).max() ?? 0,
            points: activePoints
        )
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedTick += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsedTick += 1
    }

    static func defaultName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, h:mm a"
        return "Trail Run • \(formatter.string(from: date))"
    }

    static func distanceMiles(_ points: [RecordedTrackPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var meters = 0.0
        for index in 1..<points.count {
            let start = CLLocation(latitude: points[index - 1].latitude, longitude: points[index - 1].longitude)
            let end = CLLocation(latitude: points[index].latitude, longitude: points[index].longitude)
            meters += start.distance(from: end)
        }
        return meters / 1609.344
    }

    static func elevationGain(_ points: [RecordedTrackPoint]) -> Int {
        guard points.count >= 2 else { return 0 }
        var gain = 0
        for index in 1..<points.count {
            let delta = points[index].altitudeFt - points[index - 1].altitudeFt
            if delta > 0 { gain += delta }
        }
        return gain
    }
}

struct GPXWaypoint: Identifiable, Codable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var elevationMeters: Double
    var slopeDegrees: Double
    var starlinkSkyPct: Int
    var sym: String
}

final class GPXTrackManager: NSObject, ObservableObject, XMLParserDelegate {
    @Published var waypoints: [GPXWaypoint] = []
    @Published var trackPoints: [CLLocationCoordinate2D] = []

    /// Exports current trail track and dispersed campsite pads to standard GPX 1.1 XML
    func exportGPXString(trailName: String, waypoints: [GPXWaypoint], track: [CLLocationCoordinate2D]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="TrailForge Overland iOS" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(trailName)</name>
            <desc>Exported from TrailForge Overland with Rig-Fit &lt;3 deg Flat Boondocking Pads</desc>
          </metadata>
        """
        for wpt in waypoints {
            xml += """
            
              <wpt lat="\(String(format: "%.6f", wpt.latitude))" lon="\(String(format: "%.6f", wpt.longitude))">
                <ele>\(String(format: "%.1f", wpt.elevationMeters))</ele>
                <name>\(wpt.name)</name>
                <desc>Slope: \(wpt.slopeDegrees) deg | Starlink Sky: \(wpt.starlinkSkyPct)%</desc>
                <sym>\(wpt.sym)</sym>
              </wpt>
            """
        }
        xml += "\n  <trk>\n    <name>\(trailName) Track</name>\n    <trkseg>"
        for pt in track {
            xml += "\n      <trkpt lat=\"\(String(format: "%.6f", pt.latitude))\" lon=\"\(String(format: "%.6f", pt.longitude))\"></trkpt>"
        }
        xml += "\n    </trkseg>\n  </trk>\n</gpx>\n"
        return xml
    }

    func exportRecordedRouteGPX(_ route: RecordedTrailRoute) -> String {
        let name = xmlEscape(route.name)
        let formatter = ISO8601DateFormatter()
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="TrailForge Overland" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(name)</name>
            <desc>Recorded trail route from TrailForge phone GPS. \(String(format: "%.2f", route.distanceMiles)) mi, +\(route.elevationGainFt) ft.</desc>
            <time>\(formatter.string(from: route.createdAt))</time>
          </metadata>
          <trk>
            <name>\(name)</name>
            <trkseg>
        """
        for point in route.points {
            xml += """
            
              <trkpt lat="\(String(format: "%.6f", point.latitude))" lon="\(String(format: "%.6f", point.longitude))">
                <ele>\(String(format: "%.1f", Double(point.altitudeFt) / 3.280839895))</ele>
                <time>\(formatter.string(from: point.timestamp))</time>
              </trkpt>
            """
        }
        xml += "\n    </trkseg>\n  </trk>\n</gpx>\n"
        return xml
    }

    private func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
