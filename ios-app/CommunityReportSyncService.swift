import Foundation
import Network

struct CommunityFeed: Codable {
    var reports: [TrailConditionReport]
    var hazards: [DroppedHazard]

    static let empty = CommunityFeed(reports: [], hazards: [])
}

@MainActor
final class CommunityReportSyncService: ObservableObject {
    static let publishedFeed = URL(string: "https://krokemoutdoors.github.io/trailforge-overland/app/community-reports.json")!
    static let liveRelay = URL(string: "https://raw.githubusercontent.com/krokemoutdoors/trailforge-overland/main/docs/app/community-reports.json")!

    static let syncedPill = "☁️ Synced to All TrailForge Users"
    static let queuedPill = "📡 Queued Offline — Auto-Syncs on Signal / Convoy Mesh"

    @Published private(set) var reports: [TrailConditionReport] = []
    @Published private(set) var hazards: [DroppedHazard] = []
    @Published private(set) var online = false
    @Published private(set) var feedToken = 0

    private var pendingOutboundReports: Set<String> = []
    private var pendingOutboundHazards: Set<String> = []
    private var publishedReportIDs: Set<String> = []
    private var publishedHazardIDs: Set<String> = []
    private var simulateOffline = false
    private var lastRemoteAccepted = false
    private var started = false
    private var syncing = false
    private var syncAgain = false

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "trailforge.community.path")
    private let pendingReportsKey = "trailforge.pendingOutboundReportIDs"
    private let pendingHazardsKey = "trailforge.pendingOutboundHazardIDs"

    var syncPill: String {
        if !simulateOffline, online, lastRemoteAccepted, pendingOutboundReports.isEmpty, pendingOutboundHazards.isEmpty {
            return Self.syncedPill
        }
        return Self.queuedPill
    }

    func start() {
        guard !started else { return }
        started = true
        reports = CockpitStore.loadReports()
        hazards = CockpitStore.loadHazards()
        pendingOutboundReports = Set(UserDefaults.standard.stringArray(forKey: pendingReportsKey) ?? [])
        pendingOutboundHazards = Set(UserDefaults.standard.stringArray(forKey: pendingHazardsKey) ?? [])
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.online = satisfied
                if satisfied {
                    await self.syncNow()
                } else {
                    self.touch()
                }
            }
        }
        monitor.start(queue: monitorQueue)
        Task { await syncNow() }
    }

    func setOfflineSimulation(_ enabled: Bool) {
        simulateOffline = enabled
        if enabled {
            touch()
        } else {
            Task { await syncNow() }
        }
    }

    func submitReport(_ report: TrailConditionReport) {
        var outgoing = report
        outgoing.queuedOffline = true
        mergeReports([outgoing], queueOutbound: true)
    }

    func submitHazard(_ hazard: DroppedHazard) {
        mergeHazards([hazard], queueOutbound: true)
    }

    func confirmReport(_ id: String) {
        guard let index = reports.firstIndex(where: { $0.id == id }) else { return }
        reports[index].confirmations += 1
        reports[index].cleared = false
        reports[index].updatedAt = Date()
        reports[index].queuedOffline = true
        pendingOutboundReports.insert(id)
        persist()
        Task { await syncNow() }
    }

    func clearReport(_ id: String) {
        guard let index = reports.firstIndex(where: { $0.id == id }) else { return }
        reports[index].cleared = true
        reports[index].updatedAt = Date()
        reports[index].queuedOffline = true
        pendingOutboundReports.insert(id)
        persist()
        Task { await syncNow() }
    }

    func confirmHazard(_ id: String) {
        guard let index = hazards.firstIndex(where: { $0.id == id }) else { return }
        hazards[index].confirmations += 1
        hazards[index].cleared = false
        hazards[index].updatedAt = Date()
        pendingOutboundHazards.insert(id)
        persist()
        Task { await syncNow() }
    }

    func clearHazard(_ id: String) {
        guard let index = hazards.firstIndex(where: { $0.id == id }) else { return }
        hazards[index].cleared = true
        hazards[index].updatedAt = Date()
        pendingOutboundHazards.insert(id)
        persist()
        Task { await syncNow() }
    }

    func envelopeJSON() -> String {
        let feed = outboundFeed()
        guard let data = try? Self.networkEncoder.encode(feed),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"reports\":[],\"hazards\":[]}"
        }
        return text
    }

    func absorbRemote(_ json: String) {
        guard let data = json.data(using: .utf8), let feed = Self.decodeFeed(data) else { return }
        var queued = false
        for report in feed.reports where shouldQueue(report) {
            pendingOutboundReports.insert(report.id)
            queued = true
        }
        for hazard in feed.hazards where shouldQueue(hazard) {
            pendingOutboundHazards.insert(hazard.id)
            queued = true
        }
        mergeReports(feed.reports, queueOutbound: false)
        mergeHazards(feed.hazards, queueOutbound: false)
        guard queued else { return }
        for index in reports.indices where pendingOutboundReports.contains(reports[index].id) {
            reports[index].queuedOffline = true
        }
        persist()
        Task { await syncNow() }
    }

    func syncNow() async {
        guard !simulateOffline, online else { return }
        if syncing {
            syncAgain = true
            return
        }
        syncing = true
        defer {
            syncing = false
            if syncAgain {
                syncAgain = false
                Task { await self.syncNow() }
            }
        }

        var acceptedReports = Set<String>()
        var acceptedHazards = Set<String>()
        var sawFeed = false
        for url in [Self.publishedFeed, Self.liveRelay] {
            guard let feed = await fetchFeed(from: url) else { continue }
            sawFeed = true
            let remoteReportIDs = Set(feed.reports.map(\.id))
            let remoteHazardIDs = Set(feed.hazards.map(\.id))
            publishedReportIDs.formUnion(remoteReportIDs)
            publishedHazardIDs.formUnion(remoteHazardIDs)
            mergeReports(feed.reports, queueOutbound: false)
            mergeHazards(feed.hazards, queueOutbound: false)
            acceptedReports.formUnion(pendingOutboundReports.intersection(remoteReportIDs))
            acceptedHazards.formUnion(pendingOutboundHazards.intersection(remoteHazardIDs))
        }

        if !pendingOutboundReports.isEmpty || !pendingOutboundHazards.isEmpty {
            let payload = outboundFeed()
            for url in [Self.publishedFeed, Self.liveRelay] {
                if await pushFeed(payload, to: url) {
                    acceptedReports.formUnion(pendingOutboundReports)
                    acceptedHazards.formUnion(pendingOutboundHazards)
                    publishedReportIDs.formUnion(acceptedReports)
                    publishedHazardIDs.formUnion(acceptedHazards)
                    sawFeed = true
                    break
                }
            }
        }

        if sawFeed {
            lastRemoteAccepted = true
        }
        if !acceptedReports.isEmpty || !acceptedHazards.isEmpty {
            pendingOutboundReports.subtract(acceptedReports)
            pendingOutboundHazards.subtract(acceptedHazards)
            for index in reports.indices where !pendingOutboundReports.contains(reports[index].id) {
                reports[index].queuedOffline = false
            }
        }
        persist()
    }

    private func outboundFeed() -> CommunityFeed {
        let sharedHazards = hazards.prefix(40).map { pin -> DroppedHazard in
            var copy = pin
            copy.photoPath = nil
            copy.voicePath = nil
            return copy
        }
        return CommunityFeed(reports: Array(reports.prefix(40)), hazards: Array(sharedHazards))
    }

    private func mergeReports(_ incoming: [TrailConditionReport], queueOutbound: Bool) {
        var byID = Dictionary(uniqueKeysWithValues: reports.map { ($0.id, $0) })
        for item in incoming {
            if let existing = byID[item.id] {
                byID[item.id] = merged(existing, item)
            } else {
                byID[item.id] = item
            }
            if queueOutbound {
                pendingOutboundReports.insert(item.id)
            }
        }
        reports = byID.values.sorted { $0.updatedAt > $1.updatedAt }
        if reports.count > 40 {
            let dropped = reports.dropFirst(40).map(\.id)
            reports = Array(reports.prefix(40))
            pendingOutboundReports.subtract(dropped)
        }
        persist()
    }

    private func mergeHazards(_ incoming: [DroppedHazard], queueOutbound: Bool) {
        var byID = Dictionary(uniqueKeysWithValues: hazards.map { ($0.id, $0) })
        for item in incoming {
            if let existing = byID[item.id] {
                byID[item.id] = merged(existing, item)
            } else {
                byID[item.id] = item
            }
            if queueOutbound {
                pendingOutboundHazards.insert(item.id)
            }
        }
        hazards = byID.values.sorted { $0.updatedAt > $1.updatedAt }
        if hazards.count > 80 {
            let dropped = hazards.dropFirst(80).map(\.id)
            hazards = Array(hazards.prefix(80))
            pendingOutboundHazards.subtract(dropped)
        }
        persist()
    }

    private func shouldQueue(_ report: TrailConditionReport) -> Bool {
        if !publishedReportIDs.contains(report.id) { return true }
        guard let existing = reports.first(where: { $0.id == report.id }) else { return true }
        return report.updatedAt > existing.updatedAt
            || report.confirmations > existing.confirmations
            || report.cleared != existing.cleared
    }

    private func shouldQueue(_ hazard: DroppedHazard) -> Bool {
        if !publishedHazardIDs.contains(hazard.id) { return true }
        guard let existing = hazards.first(where: { $0.id == hazard.id }) else { return true }
        return hazard.updatedAt > existing.updatedAt
            || hazard.confirmations > existing.confirmations
            || hazard.cleared != existing.cleared
    }

    private func merged(_ local: TrailConditionReport, _ remote: TrailConditionReport) -> TrailConditionReport {
        var winner = remote.updatedAt >= local.updatedAt ? remote : local
        let older = remote.updatedAt >= local.updatedAt ? local : remote
        winner.confirmations = max(local.confirmations, remote.confirmations)
        if winner.updatedAt == older.updatedAt {
            winner.cleared = local.cleared || remote.cleared
        }
        if winner.latitude == 0, winner.longitude == 0 {
            winner.latitude = older.latitude
            winner.longitude = older.longitude
        }
        winner.queuedOffline = pendingOutboundReports.contains(winner.id)
        return winner
    }

    private func merged(_ local: DroppedHazard, _ remote: DroppedHazard) -> DroppedHazard {
        var winner = remote.updatedAt >= local.updatedAt ? remote : local
        let older = remote.updatedAt >= local.updatedAt ? local : remote
        winner.confirmations = max(local.confirmations, remote.confirmations)
        if winner.updatedAt == older.updatedAt {
            winner.cleared = local.cleared || remote.cleared
        }
        if winner.photoPath == nil { winner.photoPath = older.photoPath }
        if winner.voicePath == nil { winner.voicePath = older.voicePath }
        if winner.trailID.isEmpty { winner.trailID = older.trailID }
        if winner.note.isEmpty { winner.note = older.note }
        return winner
    }

    private func persist() {
        CockpitStore.saveReports(reports)
        CockpitStore.saveHazards(hazards)
        UserDefaults.standard.set(Array(pendingOutboundReports), forKey: pendingReportsKey)
        UserDefaults.standard.set(Array(pendingOutboundHazards), forKey: pendingHazardsKey)
        touch()
    }

    private func touch() {
        feedToken &+= 1
    }

    private func fetchFeed(from url: URL) async -> CommunityFeed? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return Self.decodeFeed(data)
    }

    private func pushFeed(_ feed: CommunityFeed, to url: URL) async -> Bool {
        if await send(feed, to: url, method: "POST") { return true }
        return await send(feed, to: url, method: "PUT")
    }

    private func send(_ feed: CommunityFeed, to url: URL, method: String) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? Self.networkEncoder.encode(feed)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return false }
        return true
    }

    private static let networkEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static func decodeFeed(_ data: Data) -> CommunityFeed? {
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        if let feed = try? iso.decode(CommunityFeed.self, from: data) { return feed }
        if let feed = try? JSONDecoder().decode(CommunityFeed.self, from: data) { return feed }
        return nil
    }
}
