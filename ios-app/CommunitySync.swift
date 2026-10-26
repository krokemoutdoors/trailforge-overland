import Foundation
import Network

struct CommunityReport: Codable, Identifiable, Equatable {
    var id: String
    var trailId: String
    var lat: Double
    var lon: Double
    var status: String
    var kind: String
    var rig: String
    var time: Double
    var confirmCount: Int
    var cleared: Bool
    var note: String

    var coordinateLatitude: Double { lat }
    var coordinateLongitude: Double { lon }
}

struct CommunityBanner: Equatable {
    var text: String
    var gate: Bool
}

@MainActor
final class CommunitySync: ObservableObject {
    static let syncedBadge = "☁️ Synced to All TrailForge Users"
    static let queuedBadge = "📡 Queued Offline — Auto-Syncs on Signal"
    static let feedURL = URL(string: "https://krokemoutdoors.github.io/trailforge-overland/app/community-reports.json")!
    static let relayURL = URL(string: "https://ntfy.sh/trailforge-overland-community/json?poll=1&since=all")!
    static let postURL = URL(string: "https://ntfy.sh/trailforge-overland-community")!

    @Published private(set) var reports: [CommunityReport] = []
    @Published private(set) var notice = ""

    var relayMesh: ((String) -> Void)?

    private var opIds = Set<String>()
    private var queue: [[String: Any]] = []
    private var flushing = false
    private var online = true
    private let monitor = NWPathMonitor()
    private let defaults = UserDefaults.standard

    init() {
        if let data = defaults.data(forKey: "trailforge.community.reports"),
           let saved = try? JSONDecoder().decode([CommunityReport].self, from: data) {
            reports = saved
        }
        if let savedOps = defaults.stringArray(forKey: "trailforge.community.ops") {
            opIds = Set(savedOps)
        }
        if let queued = defaults.data(forKey: "trailforge.community.queue"),
           let parsed = try? JSONSerialization.jsonObject(with: queued) as? [[String: Any]] {
            queue = parsed
        }
        notice = defaults.string(forKey: "trailforge.community.notice") ?? ""
        absorbBundle()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.online = satisfied
                if satisfied { self.flush() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "trailforge.community"))
    }

    func refresh() {
        absorbBundle()
        guard online else { return }
        Task {
            async let feed = Self.fetchText(Self.feedURL)
            async let relay = Self.fetchText(Self.relayURL)
            if let text = try? await feed, let data = text.data(using: .utf8),
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = body["reports"] as? [[String: Any]] {
                rows.forEach { absorbReport($0) }
            }
            if let text = try? await relay {
                absorbRelay(text)
            }
            persist()
        }
    }

    func banner(for trailID: String) -> CommunityBanner? {
        let rows = reports.filter { $0.trailId == trailID && !$0.cleared }
        if rows.contains(where: { $0.status == "Gate Locked" }) {
            return CommunityBanner(text: "🔒 GATE LOCKED (USER REPORT)", gate: true)
        }
        if rows.contains(where: { $0.status != "Open & Clear" && !$0.status.contains("Pad") }) {
            return CommunityBanner(text: "⚠️ OBSTACLE REPORTED", gate: false)
        }
        return nil
    }

    func active(on trailID: String) -> [CommunityReport] {
        reports
            .filter { $0.trailId == trailID && !$0.cleared }
            .sorted { $0.time > $1.time }
    }

    func publishCondition(trailID: String, status: String, lat: Double, lon: Double, rig: String) {
        let now = Date().timeIntervalSince1970 * 1000
        let report = CommunityReport(
            id: "r-\(Int(now))-\(Int.random(in: 1000...9999))",
            trailId: trailID,
            lat: lat,
            lon: lon,
            status: canonical(status),
            kind: "condition",
            rig: rig.isEmpty ? "Overland rig" : rig,
            time: now,
            confirmCount: 1,
            cleared: false,
            note: ""
        )
        if canonical(status) == "Open & Clear" {
            reports.filter { $0.trailId == trailID && !$0.cleared }.forEach { row in
                send(event: ["v": 1, "op": "clear", "opId": "open-\(report.id)-\(row.id)", "id": row.id, "time": now])
            }
        }
        send(event: ["v": 1, "op": "upsert", "opId": report.id, "report": dictionary(report)])
    }

    func publishHazard(id: String, trailID: String, status: String, lat: Double, lon: Double, rig: String, note: String) {
        let report = CommunityReport(
            id: id,
            trailId: trailID,
            lat: lat,
            lon: lon,
            status: status,
            kind: "hazard",
            rig: rig.isEmpty ? "Overland rig" : rig,
            time: Date().timeIntervalSince1970 * 1000,
            confirmCount: 1,
            cleared: false,
            note: String(note.prefix(140))
        )
        send(event: ["v": 1, "op": "upsert", "opId": "hz-\(id)", "report": dictionary(report)])
    }

    func confirm(_ id: String) {
        send(event: ["v": 1, "op": "confirm", "opId": "c-\(Int(Date().timeIntervalSince1970 * 1000))-\(id.prefix(12))", "id": id])
    }

    func clear(_ id: String) {
        send(event: ["v": 1, "op": "clear", "opId": "x-\(Int(Date().timeIntervalSince1970 * 1000))-\(id.prefix(12))", "id": id, "time": Date().timeIntervalSince1970 * 1000])
    }

    func ingestMesh(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        apply(event)
        persist()
    }

    func absorbGPX(_ xml: String) {
        guard let regex = try? NSRegularExpression(pattern: "<wpt lat=\"([-0-9.]+)\" lon=\"([-0-9.]+)\"[\\s\\S]*?<name>([^<]*)</name>", options: []) else { return }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        regex.matches(in: xml, options: [], range: range).forEach { match in
            guard let latRange = Range(match.range(at: 1), in: xml),
                  let lonRange = Range(match.range(at: 2), in: xml),
                  let nameRange = Range(match.range(at: 3), in: xml) else { return }
            let name = xml[nameRange].replacingOccurrences(of: "&amp;", with: "&")
            let parts = name.split(separator: "|").map(String.init)
            guard parts.count >= 5, parts[0] == "TFCR",
                  let lat = Double(xml[latRange]),
                  let lon = Double(xml[lonRange]),
                  let count = Int(parts[3]) else { return }
            absorbReport([
                "id": "gpx-\(parts[2])-\(parts[1])-\(lat)",
                "trailId": parts[2],
                "lat": lat,
                "lon": lon,
                "status": parts[1],
                "kind": "hazard",
                "rig": "Trip package",
                "time": Date().timeIntervalSince1970 * 1000,
                "confirmCount": count,
                "cleared": parts[4] == "1",
                "note": "From a trip package"
            ])
        }
        persist()
    }

    private func send(event: [String: Any]) {
        apply(event)
        persist()
        if let data = try? JSONSerialization.data(withJSONObject: event),
           let json = String(data: data, encoding: .utf8) {
            relayMesh?(json)
        }
        if online {
            queue.append(event)
            persistQueue()
            flush()
        } else {
            queue.append(event)
            persistQueue()
            setNotice(Self.queuedBadge)
        }
    }

    private func flush() {
        guard online, !flushing, !queue.isEmpty else { return }
        flushing = true
        let event = queue[0]
        Task {
            do {
                try await Self.post(event)
                if !queue.isEmpty { queue.removeFirst() }
                persistQueue()
                setNotice(Self.syncedBadge)
                flushing = false
                flush()
            } catch {
                flushing = false
                setNotice(Self.queuedBadge)
            }
        }
    }

    private func apply(_ event: [String: Any]) {
        guard let opId = event["opId"] as? String, !opIds.contains(opId) else { return }
        opIds.insert(opId)
        let op = event["op"] as? String ?? ""
        if op == "upsert", let raw = event["report"] as? [String: Any] {
            absorbReport(raw)
        } else if op == "confirm", let id = event["id"] as? String, let index = reports.firstIndex(where: { $0.id == id }) {
            reports[index].confirmCount += 1
        } else if op == "clear", let id = event["id"] as? String, let index = reports.firstIndex(where: { $0.id == id }) {
            reports[index].cleared = true
            if let time = Self.number(event["time"]) {
                reports[index].time = max(reports[index].time, time)
            }
        }
        if reports.count > 240 { reports = Array(reports.prefix(240)) }
    }

    private func absorbReport(_ raw: [String: Any]) {
        guard let item = report(from: raw) else { return }
        if let index = reports.firstIndex(where: { $0.id == item.id }) {
            let older = reports[index]
            let newer = item.time >= older.time ? item : older
            let previous = newer.id == item.id ? older : item
            reports[index] = CommunityReport(
                id: older.id,
                trailId: newer.trailId,
                lat: newer.lat,
                lon: newer.lon,
                status: newer.status,
                kind: newer.kind.isEmpty ? previous.kind : newer.kind,
                rig: newer.rig.isEmpty ? previous.rig : newer.rig,
                time: max(older.time, item.time),
                confirmCount: max(older.confirmCount, item.confirmCount),
                cleared: older.cleared || item.cleared,
                note: newer.note.isEmpty ? previous.note : newer.note
            )
        } else {
            reports.insert(item, at: 0)
        }
    }

    private func absorbBundle() {
        guard let url = Bundle.main.url(forResource: "community-reports", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = body["reports"] as? [[String: Any]] else { return }
        rows.forEach { absorbReport($0) }
        persist()
    }

    private func absorbRelay(_ text: String) {
        text.split(separator: "\n").forEach { line in
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (row["event"] as? String) == "message",
                  let message = row["message"] as? String,
                  let payload = message.data(using: .utf8),
                  var event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
            if event["opId"] == nil, let id = row["id"] as? String {
                event["opId"] = "ntfy-\(id)"
            }
            apply(event)
        }
    }

    private func report(from raw: [String: Any]) -> CommunityReport? {
        guard let id = raw["id"] as? String, let trailId = raw["trailId"] as? String else { return nil }
        guard let lat = Self.number(raw["lat"]), let lon = Self.number(raw["lon"]), lat.isFinite, lon.isFinite else { return nil }
        let status = String((raw["status"] as? String ?? "").prefix(40))
        let kind = (raw["kind"] as? String) == "hazard" ? "hazard" : "condition"
        let known = ["Open & Clear", "Mud/Snow", "Downed Tree", "Washout", "Gate Locked"].contains(status)
        guard known || kind == "hazard" else { return nil }
        return CommunityReport(
            id: String(id.prefix(80)),
            trailId: String(trailId.prefix(80)),
            lat: lat,
            lon: lon,
            status: status,
            kind: kind,
            rig: String(((raw["rig"] as? String) ?? "Overland rig").prefix(60)),
            time: Self.number(raw["time"]) ?? Date().timeIntervalSince1970 * 1000,
            confirmCount: max(0, Int(Self.number(raw["confirmCount"]) ?? 0)),
            cleared: (raw["cleared"] as? Bool) ?? false,
            note: String(((raw["note"] as? String) ?? "").prefix(140))
        )
    }

    private func dictionary(_ report: CommunityReport) -> [String: Any] {
        [
            "id": report.id,
            "trailId": report.trailId,
            "lat": report.lat,
            "lon": report.lon,
            "status": report.status,
            "kind": report.kind,
            "rig": report.rig,
            "time": report.time,
            "confirmCount": report.confirmCount,
            "cleared": report.cleared,
            "note": report.note
        ]
    }

    private func canonical(_ status: String) -> String {
        status.replacingOccurrences(of: "Mud / Snow", with: "Mud/Snow")
    }

    private func setNotice(_ text: String) {
        notice = text
        defaults.set(text, forKey: "trailforge.community.notice")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(reports) {
            defaults.set(data, forKey: "trailforge.community.reports")
        }
        let keys = Array(opIds)
        defaults.set(Array(keys.suffix(400)), forKey: "trailforge.community.ops")
        if keys.count > 400 { opIds = Set(keys.suffix(400)) }
    }

    private func persistQueue() {
        if let data = try? JSONSerialization.data(withJSONObject: queue) {
            defaults.set(data, forKey: "trailforge.community.queue")
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }

    private static func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func post(_ event: [String: Any]) async throws {
        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: event)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
