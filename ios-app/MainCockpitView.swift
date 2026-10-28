import SwiftUI
import MapKit
import StoreKit
import UIKit
import AVFoundation
import PhotosUI
import UserNotifications

enum CockpitMode: String, CaseIterable {
    case drive = "1. Go Drive"
    case camp  = "2. Flat Camp"
    case rig   = "3. My Rig"
}

struct NavStep: Identifiable {
    let id: Int
    let instruction: String
    let distanceMeters: Double
    let systemImage: String
    var maneuver: CLLocationCoordinate2D? = nil
}

struct NavOption: Identifiable {
    let id: Int
    let title: String
    let expectedTravelTime: TimeInterval
    let distanceMeters: Double
    let road: [CLLocationCoordinate2D]
    let steps: [NavStep]
}

struct PlaceHit: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct ActiveCampRoute {
    var destination: CampSpot
    var options: [NavOption]
    var selectedIndex: Int
    var spur: [CLLocationCoordinate2D]
    var originWasGPS: Bool

    var selected: NavOption {
        guard !options.isEmpty else {
            return NavOption(id: 0, title: "Route", expectedTravelTime: 0, distanceMeters: 0, road: [], steps: [])
        }
        return options[min(selectedIndex, options.count - 1)]
    }

    var spurMeters: Double { polylineMeters(spur) }

    var displaySteps: [NavStep] {
        var steps = selected.steps
        if spurMeters > 40 {
            steps.append(NavStep(
                id: 10_000,
                instruction: "Proceed on overland spur to \(destination.name)",
                distanceMeters: spurMeters,
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                maneuver: destination.coordinate
            ))
        }
        return steps
    }

    var roadAndSpur: [CLLocationCoordinate2D] {
        guard spur.count >= 2 else { return selected.road }
        return selected.road + spur.dropFirst()
    }
}

struct MainCockpitView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var rigStore: RigProfileStore
    @EnvironmentObject var motionManager: ClinometerMotionManager
    @EnvironmentObject var storeKit: TrailForgeStoreKitManager
    @StateObject private var telemetry = LiveTelemetryService()
    @ObservedObject private var locationTracker = LocationTracker.shared

    @State private var mode: CockpitMode = .drive
    @State private var selectedTrailID: String = "imogene"
    @State private var showTrailMenu = false
    @State private var trailQuery: String = ""
    @State private var placeHits: [PlaceHit] = []
    @State private var placeSearchGeneration = 0
    @State private var placeSearchBusy = false
    @State private var placeSearchNote = ""
    @State private var searchedPlace: PlaceHit?
    @State private var regionFilter: String = "near"
    @State private var offlineSaved: Bool = true
    @State private var showProPaywall: Bool = false
    @State private var mapCenter = CLLocationCoordinate2D(latitude: 37.9589, longitude: -107.7352)
    private let bootCoordinate = CLLocationCoordinate2D(latitude: 37.9589, longitude: -107.7352)
    @State private var skipNextFocus = false
    @State private var activeRoute: ActiveCampRoute?
    @State private var followRoute = false
    @State private var showAllSteps = false
    @State private var isRouting = false
    @State private var routeGeneration = 0
    @State private var lastReroute = Date.distantPast
    @State private var lastMapLongPress = Date.distantPast
    @State private var isRouteConfirmed = false
    @State private var isVoiceGuidanceEnabled = true
    @State private var activeStepIndex = 0
    @State private var announcedApproachStep: Int?
    @State private var announcedTurnStep: Int?
    @State private var announcedArrival = false
    @State private var liveRemainingMiles: Double?
    @State private var liveRemainingSeconds: TimeInterval?
    @State private var liveNextStepDistanceText = ""
    @State private var showingRouteOverview = false
    @State private var routeStartedFromGPS = true
    @State private var selectedCampSpot: CampSpot?
    @State private var selectedTrailDraw: [CLLocationCoordinate2D] = []
    @State private var cameraCommand = 0
    @State private var copiedToken: String?
    @StateObject private var voiceGuide = VoiceNavigationAnnouncer()
    @StateObject private var cameraGate = CameraGate()
    @State private var detent: CockpitDetent = .half
    @State private var followHeading = false
    @State private var showLayers = false
    @State private var showOffline = false
    @State private var plotMode = false
    @State private var straightSpur = false
    @State private var nextSegmentFreehand = false
    @State private var segmentFreehand: [Bool] = []
    @State private var plotPoints: [CLLocationCoordinate2D] = []
    @State private var plotSegmentRoutes: [String: [CLLocationCoordinate2D]] = [:]
    @State private var plotRouteFetchToken = 0
    @State private var profileIndex: Int?
    @State private var reports: [TrailConditionReport] = []
    @State private var offlinePacks: [OfflineCorridorPack] = []
    @State private var downloadProgress: Double = 0
    @State private var downloadRunning = false
    @State private var offlineTier = "Route + USFS snapshot"
    @AppStorage("trailforge.offlineArea") private var offlineArea = "corridor"

    /// Saved 30, 100, and 250 sq mi choices, and any other unknown value, open as Current Map View.
    private var resolvedOfflineArea: String {
        switch offlineArea {
        case "view", "corridor":
            return offlineArea
        default:
            return "view"
        }
    }
    @State private var screenCenter = CLLocationCoordinate2D(latitude: 37.9589, longitude: -107.7352)
    @State private var visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.9589, longitude: -107.7352),
        span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.10)
    )
    @State private var gpxDraft = ""
    @State private var remoteHazards: [MapHazard] = []
    @State private var lastHazardFetch: CLLocationCoordinate2D?
    @AppStorage("trailforge.offlineFirst") private var offlineFirst = false
    @AppStorage("trailforge.dashMode") private var dashMode = "auto"
    @AppStorage("trailforge.basemap") private var basemapRaw = BasemapChoice.hybrid.rawValue
    @AppStorage("trailforge.trailOpacity") private var trailCorridorOpacity = 1.0
    @AppStorage("trailforge.blmOpacity") private var blmMaskOpacity = 0.70
    @AppStorage("trailforge.usfsOpacity") private var usfsMaskOpacity = 0.70
    @AppStorage("trailforge.stateOpacity") private var stateMaskOpacity = 0.70
    @AppStorage("trailforge.campOpacity") private var campSlopeOpacity = 0.9
    @AppStorage("trailforge.hazardOpacity") private var hazardOverlayOpacity = 0.85
    @AppStorage("trailforge.starlinkOpacity") private var starlinkOverlayOpacity = 0.75
    @State private var landRings: [LandMaskRing] = []
    @State private var landFetchGeneration = 0
    @AppStorage("trailforge.nightVision") private var nightVision = false
    @State private var thermalSaver = false
    @AppStorage("trailforge.map3D") private var is3DMapsEnabled = true
    @AppStorage("trailforge.safetyDisclaimerAccepted.v1") private var safetyDisclaimerAccepted = false
    @AppStorage("trailforge.safetyDisclaimerAcceptedAt.v1") private var safetyDisclaimerAcceptedAt = ""
    @State private var showSafetyDisclaimer = false
    @State private var showRouteStartNote = false
    @State private var routeNoteToken = 0
    @State private var cameraPitch: Double = 0
    @State private var reportedMapPitch: Double = 0
    @State private var pitchCeiling: Double = 0
    @State private var pitchGestureActive = false
    @State private var userOwnsPitch = false
    @State private var plotClearedByUser = false
    @State private var lastCameraHeading: Double = 0
    @State private var lastMapCamera: MapCamera?
    @State private var lastCameraNote = Date.distantPast
    @StateObject private var convoy = ConvoyMeshManager()
    @StateObject private var community = CommunityReportSyncService()
    @StateObject private var hazardRecorder = HazardNoteRecorder()
    @State private var hazardPins: [DroppedHazard] = []
    @State private var showHazardSheet = false
    @State private var showTripQR = false
    @State private var tripQRImage: UIImage?
    @State private var tripShareText = ""
    @State private var hazardCategory = HazardCatalog.categories[0]
    @State private var hazardPhotoItem: PhotosPickerItem?
    @State private var hazardPhoto: Data?
    @State private var pendingVoiceURL: URL?
    @State private var announcedCrux: Set<String> = []
    @State private var savedMarkers: [SavedMarker] = []
    @State private var droppedPin: DroppedPinTarget?
    @State private var pinName = ""
    @State private var pinCategory = "Waypoint"
    @State private var pinSummary = ""
    @State private var editingMarker: SavedMarker?
    private let markerCategories = ["Camp", "Waypoint", "Trailhead", "Hazard", "Viewpoint"]

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.9589, longitude: -107.7352),
            span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.10)
        )
    )

    private var pickerTrails: [OverlandTrail] {
        let query = trailQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        func matchesQuery(_ trail: OverlandTrail) -> Bool {
            if query.isEmpty { return true }
            let corridorWords = trail.isBDR ? " BDR backcountry discovery route corridor \(trail.id)" : ""
            let haystack = [trail.name, trail.region, trail.state, trail.alsoStates.joined(separator: " "), trail.agency, corridorWords].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
        func matchesFilter(_ trail: OverlandTrail) -> Bool {
            guard matchesQuery(trail) else { return false }
            switch regionFilter {
            case "near":
                return !isBackcountryCorridor(trail)
            case "all":
                return !isBackcountryCorridor(trail) || !query.isEmpty
            case "bdr":
                return isBackcountryCorridor(trail)
            default:
                return trail.containsState(regionFilter)
            }
        }
        var seen = Set<String>()
        let trails = (USATrailAtlas.all + telemetry.discoveredTrails).filter { trail in
            matchesFilter(trail) && seen.insert(trail.id).inserted
        }
        if regionFilter == "bdr" { return trails }
        let origin: CLLocationCoordinate2D
        if regionFilter == "near" {
            guard let anchor = nearAnchor else { return [] }
            origin = anchor
        } else if regionFilter == "all" {
            origin = locationTracker.userCoordinate ?? mapCenter
        } else {
            return trails
        }
        let ranked = trails
            .map { (trail: $0, away: nearestMiles(from: origin, to: $0)) }
            .sorted { $0.away < $1.away }
        guard regionFilter == "near" else { return ranked.map { $0.trail } }
        let nearby = ranked.filter { $0.away <= 100 }
        let chosen = nearby.isEmpty ? Array(ranked.prefix(20)) : nearby
        return chosen.map { $0.trail }
    }

    private var activeTrail: OverlandTrail {
        let catalog = USATrailAtlas.all + telemetry.discoveredTrails
        if let selected = catalog.first(where: { $0.id == selectedTrailID }) {
            return selected
        }
        if let visible = pickerTrails.first(where: { !isBackcountryCorridor($0) }) {
            return visible
        }
        return catalog.first(where: { !isBackcountryCorridor($0) }) ?? catalog[0]
    }

    private var mapTrails: [OverlandTrail] {
        guard activeRoute == nil else { return [activeTrail] }
        let activeID = selectedTrailID
        if regionFilter == "near" || regionFilter == "all" {
            return viewportTrails(activeID: activeID)
        }
        return pickerTrails.filter { !isBackcountryCorridor($0) || $0.id == activeID }
    }

    private var mapCampSpots: [CampSpot] {
        let pads = mapTrails.flatMap(\.campSpots)
        let origin = mapCenter
        let sorted = pads.sorted { miles(from: origin, to: $0.coordinate) < miles(from: origin, to: $1.coordinate) }
        return Array(sorted.prefix(80))
    }

    private var mapCamps: [CampSpot] {
        activeRoute == nil ? mapCampSpots : Array(activeTrail.campSpots.prefix(3))
    }

    private var showRouteAlternates: Bool {
        showingRouteOverview && !followRoute && activeRoute != nil
    }

    private var targetCoordinate: CLLocationCoordinate2D? {
        if let route = activeRoute { return route.destination.coordinate }
        if let camp = selectedCampSpot { return camp.coordinate }
        let trail = activeTrail
        if trail.trailhead.lat != 0 || trail.trailhead.lon != 0 {
            return trail.trailhead.coordinate
        }
        if trail.centerLat != 0 || trail.centerLon != 0 {
            return trail.centerCoordinate
        }
        return nil
    }

    private var visibleTrailColors: [String: Color] {
        var colors: [String: Color] = [:]
        for trail in mapTrails {
            colors[trail.id] = fitColor(trail)
        }
        return colors
    }

    private var mapSceneToken: Int {
        var hasher = Hasher()
        hasher.combine(activeRoute != nil)
        hasher.combine(activeRoute?.destination.id)
        hasher.combine(activeRoute?.selectedIndex)
        hasher.combine(activeRoute?.selected.road.count)
        hasher.combine(activeRoute?.options.count)
        hasher.combine(activeRoute?.spur.count)
        hasher.combine(selectedTrailID)
        hasher.combine(mapTrails.map(\.id).joined(separator: ","))
        hasher.combine(pertinentCruxPins.map(\.id).joined(separator: ","))
        hasher.combine(selectedTrailDraw.count)
        hasher.combine(routeStartedFromGPS)
        hasher.combine(Int(rigStore.profile.tireInches))
        hasher.combine(rigStore.profile.hasRearLocker)
        if activeRoute == nil {
            hasher.combine(pickerTrails.map(\.id).joined(separator: ","))
            hasher.combine(telemetry.discoveredTrails.count)
        }
        hasher.combine(plotMode)
        hasher.combine(basemapRaw)
        hasher.combine(Int((trailCorridorOpacity * 100).rounded()))
        hasher.combine(Int((blmMaskOpacity * 100).rounded()))
        hasher.combine(Int((usfsMaskOpacity * 100).rounded()))
        hasher.combine(Int((stateMaskOpacity * 100).rounded()))
        hasher.combine(Int((campSlopeOpacity * 100).rounded()))
        hasher.combine(Int((hazardOverlayOpacity * 100).rounded()))
        hasher.combine(Int((starlinkOverlayOpacity * 100).rounded()))
        hasher.combine(landRings.map(\.id).joined(separator: ","))
        hasher.combine(plotPoints.map { "\(Int($0.latitude * 100_000)):\(Int($0.longitude * 100_000))" }.joined(separator: ","))
        hasher.combine(plotPoints.count)
        hasher.combine(plottedLine.count)
        hasher.combine(plotSegmentRoutes.count)
        hasher.combine(plotSegmentRoutes.values.reduce(0) { $0 + $1.count })
        if let first = plottedLine.first, let last = plottedLine.last {
            hasher.combine(Int(first.latitude * 100_000))
            hasher.combine(Int(first.longitude * 100_000))
            hasher.combine(Int(last.latitude * 100_000))
            hasher.combine(Int(last.longitude * 100_000))
        }
        hasher.combine(straightSpur)
        hasher.combine(nextSegmentFreehand)
        hasher.combine(segmentFreehand.map { $0 ? "1" : "0" }.joined())
        hasher.combine(thermalSaver)
        hasher.combine(showOffline)
        hasher.combine(downloadRunning)
        hasher.combine(hazardPins.map { "\($0.id):\($0.confirmations):\($0.cleared)" }.joined(separator: ","))
        hasher.combine(reports.map { "\($0.id):\($0.status):\($0.confirmations):\($0.cleared)" }.joined(separator: ","))
        hasher.combine(community.feedToken)
        hasher.combine(profileIndex)
        hasher.combine(mapHazards.map(\.id).joined(separator: ","))
        hasher.combine(searchedPlace?.id)
        if let searchedPlace {
            hasher.combine(searchedPlace.latitude)
            hasher.combine(searchedPlace.longitude)
        }
        hasher.combine(savedMarkers.map { "\($0.id.uuidString):\($0.name):\($0.category)" }.joined(separator: ","))
        if let droppedPin {
            hasher.combine(droppedPin.latitude)
            hasher.combine(droppedPin.longitude)
        }
        hasher.combine(resolvedOfflineArea)
        if let box = liveOfflineBox() {
            hasher.combine(Int(box.minLat * 1000))
            hasher.combine(Int(box.maxLat * 1000))
            hasher.combine(Int(box.minLon * 1000))
            hasher.combine(Int(box.maxLon * 1000))
        }
        hasher.combine(offlinePacks.compactMap(\.minLat).map { String(format: "%.3f", $0) }.joined(separator: ","))
        return hasher.finalize()
    }

    private var basemap: BasemapChoice {
        BasemapChoice(rawValue: basemapRaw) ?? .hybrid
    }

    private var heatLimited: Bool {
        thermalSaver
    }

    private var activePitch: Double {
        guard is3DMapsEnabled else { return 0 }
        return min(75, max(0, cameraPitch))
    }

    private var effectiveBasemap: BasemapChoice {
        basemap
    }

    private var rideSamples: [RideSample] {
        RideProfile.samples(for: activeTrail)
    }

    private var scrubCoordinate: CLLocationCoordinate2D? {
        guard let profileIndex, rideSamples.indices.contains(profileIndex) else { return nil }
        return rideSamples[profileIndex].coordinate
    }

    private var plottedLine: [CLLocationCoordinate2D] {
        guard plotPoints.count >= 2 else { return plotPoints }
        var line: [CLLocationCoordinate2D] = []
        for index in 1..<plotPoints.count {
            let segment = resolvedPlotSegment(from: plotPoints[index - 1], to: plotPoints[index], segmentIndex: index - 1)
            guard segment.count >= 2 else { continue }
            if line.isEmpty {
                line.append(contentsOf: segment)
            } else {
                line.append(contentsOf: segment.dropFirst())
            }
        }
        return cappedPlot(line)
    }

    private func resolvedPlotSegment(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, segmentIndex: Int) -> [CLLocationCoordinate2D] {
        let freehand = segmentFreehand.indices.contains(segmentIndex) ? segmentFreehand[segmentIndex] : straightSpur
        if freehand { return [start, end] }
        let key = plotSegmentKey(start, end)
        if let cached = plotSegmentRoutes[key], cached.count >= 2 { return cached }
        return [start, end]
    }

    private var mapHazards: [MapHazard] {
        guard hazardOverlayOpacity > 0.02 else { return [] }
        let dropped = hazardPins.compactMap { pin -> MapHazard? in
            guard !pin.cleared else { return nil }
            return MapHazard(id: "userhazard-\(pin.id)", title: pin.category, coordinates: [], point: pin.coordinate, radiusMeters: 36)
        }
        let communityMarkers = reports.compactMap { report -> MapHazard? in
            guard !report.cleared, report.latitude != 0 || report.longitude != 0 else { return nil }
            let label = TrailReportStatus(rawValue: report.status)?.communityLabel ?? report.status
            return MapHazard(
                id: "community-\(report.id)",
                title: label,
                coordinates: [],
                point: CLLocationCoordinate2D(latitude: report.latitude, longitude: report.longitude),
                radiusMeters: 80
            )
        }
        let live = dropped + communityMarkers
        if heatLimited {
            return TrailHazards.localMarkers(on: activeTrail) + live
        }
        return TrailHazards.localMarkers(on: activeTrail) + remoteHazards + live
    }

    private var customRouteMiles: Double {
        polylineMeters(plottedLine) / 1609.344
    }

    private var customRouteFit: (verdict: RigFitVerdict, notes: [String]) {
        var fit = rigStore.evaluate(trail: activeTrail)
        if segmentFreehand.contains(true) || (straightSpur && plotPoints.count >= 2), fit.verdict == .fits {
            fit.notes.insert("A freehand segment leaves the mapped corridor.", at: 0)
            return (.caution, fit.notes)
        }
        return fit
    }

    private var cockpitSummary: String {
        if let route = activeRoute {
            let step = route.displaySteps.first?.instruction ?? "On route"
            let miles = liveRemainingMiles ?? (route.selected.distanceMeters / 1609.344)
            return String(format: "%@ • %.1f mi", step, miles)
        }
        return listHeadline
    }

    private var listedCamps: [CampSpot] {
        mapCampSpots
    }

    private var filterTitle: String {
        switch regionFilter {
        case "near": return "Near Me"
        case "all": return "All USA"
        case "bdr": return "Corridors"
        default: return regionFilter
        }
    }

    var body: some View {
        let _ = syncCameraGate()
        cockpitWithSheets
    }

    private var cockpitCanvas: some View {
        GeometryReader { geo in
            let dash = wantsDash(geo.size)
            ZStack {
                if dash {
                    dashCockpit(geo.size)
                } else {
                    portraitCockpit(geo.size)
                }
                if showLayers {
                    layersDrawer
                }
                if showOffline {
                    offlineDrawer
                }
                if showSafetyDisclaimer || !safetyDisclaimerAccepted {
                    safetyDisclaimerOverlay
                        .transition(.opacity)
                }
            }
        }
    }

    private var cockpitWithLifecycle: some View {
        cockpitCanvas
            .onChange(of: mode) { _, newMode in
                if detent == .peek || (newMode == .rig && detent == .full) { detent = .half }
            }
            .onAppear {
                if offlineArea != "view" && offlineArea != "corridor" {
                    offlineArea = "view"
                }
                scheduleLandFetch(visibleRegion)
                motionManager.startUpdates()
                locationTracker.requestLocation()
                refreshSelectedTrailDraw()
                community.start()
                community.setOfflineSimulation(offlineFirst)
                reports = community.reports
                hazardPins = community.hazards
                offlinePacks = CockpitStore.loadPacks()
                savedMarkers = CockpitStore.loadSavedMarkers()
                convoy.start()
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                if is3DMapsEnabled {
                    applyCameraPitch(cameraPitch, keepMode: true)
                }
            }
            .onChange(of: locationTracker.hasCenteredOnUserOnce) { _, centered in
                guard centered, let coordinate = locationTracker.userCoordinate else { return }
                mapCenter = coordinate
                if activeRoute == nil, regionFilter == "near" {
                    applyFilterSelection(scanIfNear: true)
                } else if activeRoute == nil {
                    pushCamera(userTrackingCamera(followsHeading: false))
                }
            }
            .onChange(of: locationTracker.locationRevision) { _, _ in
                handleLiveGPS()
            }
            .onChange(of: selectedTrailID) { _, newID in
                profileIndex = nil
                if selectedCampSpot?.trailID != newID {
                    selectedCampSpot = nil
                }
                refreshSelectedTrailDraw()
                if skipNextFocus {
                    skipNextFocus = false
                    return
                }
                guard !followRoute else { return }
                focus(on: activeTrail)
            }
            .onChange(of: regionFilter) { _, _ in
                applyFilterSelection(scanIfNear: true)
            }
    }

    private var cockpitWithSync: some View {
        cockpitWithLifecycle
            .onChange(of: followRoute) { _, following in
                if following {
                    detent = .peek
                }
            }
            .onChange(of: trailQuery) { _, newValue in
                if regionFilter == "bdr" {
                    showTrailMenu = true
                } else if !pickerTrails.contains(where: { $0.id == selectedTrailID }),
                          let first = pickerTrails.first(where: { !isBackcountryCorridor($0) }) {
                    selectedTrailID = first.id
                }
                schedulePlaceSearch(newValue)
            }
            .onChange(of: telemetry.isScanningTrails) { _, scanning in
                guard !scanning else { return }
                refreshSelectedTrailDraw()
            }
            .onChange(of: offlineFirst) { _, enabled in
                community.setOfflineSimulation(enabled)
            }
    }

    private var cockpitWithCommunity: some View {
        cockpitWithSync
            .onChange(of: community.feedToken) { _, _ in
                reports = community.reports
                hazardPins = community.hazards
            }
            .onChange(of: convoy.connectedRevision) { _, _ in
                convoy.sendCommunity(community.envelopeJSON())
            }
            .onChange(of: convoy.inboundCommunityToken) { _, _ in
                community.absorbRemote(convoy.inboundCommunityJSON)
                reports = community.reports
                hazardPins = community.hazards
            }
            .onChange(of: basemapRaw) { _, newValue in
                let choice = BasemapChoice(rawValue: newValue) ?? .hybrid
                if choice == .imagery || choice == .hybrid {
                    thermalSaver = false
                }
            }
            .onChange(of: hazardOverlayOpacity) { _, value in
                if value > 0.02 {
                    refreshHazards(around: mapCenter)
                } else {
                    remoteHazards = []
                }
            }
            .task {
                if !offlineFirst {
                    await telemetry.fetchUSGSStreamflow()
                    refreshTrails(around: mapCenter)
                }
                await storeKit.loadProducts()
            }
    }

    private var cockpitWithSheets: some View {
        cockpitWithCommunity
            .sheet(isPresented: $showHazardSheet) {
                hazardSheet
            }
            .sheet(isPresented: $showTripQR) {
                tripQRSheet
            }
            .sheet(isPresented: $showProPaywall) {
                TrailForgePaywallView()
                    .environmentObject(storeKit)
            }
            .sheet(item: $droppedPin) { pin in
                droppedPinSheet(pin)
            }
            .sheet(item: $editingMarker) { marker in
                savedMarkerSheet(marker)
            }
    }

    private var fitBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.gray.opacity(0.85))
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(listHeadline)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(listSubtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    toggleOfflineMaps()
                } label: {
                    Label(offlineSaved ? "Offline Maps" : "Save", systemImage: offlineSaved ? "checkmark.icloud.fill" : "arrow.down.circle.fill")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(offlineSaved ? Color.green.opacity(0.22) : Color.blue)
                        .foregroundColor(offlineSaved ? .green : .white)
                        .clipShape(Capsule())
                }
            }
            coordinatesBar(filled: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.06, green: 0.09, blue: 0.14))
    }

    private func navigationBanner(_ route: ActiveCampRoute) -> some View {
        let cue = nextCue(route)
        let remaining = (liveRemainingMiles ?? (route.selected.distanceMeters / 1609.344)) * 1609.344
        let seconds = liveRemainingSeconds ?? route.selected.expectedTravelTime
        let eta = Date().addingTimeInterval(seconds)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: cue.icon)
                    .font(.title2.bold())
                    .foregroundColor(.cyan)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isRouting ? "Recalculating route…" : cue.text)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .onTapGesture {
                            voiceGuide.speak(cue.text, enabled: true)
                        }
                    Text(route.destination.kind == .trailhead ? route.destination.name : String(format: "%@ • %.1f° • %d%% Starlink", route.destination.name, route.destination.slopeDeg, route.destination.starlinkPct))
                        .font(.caption)
                        .foregroundColor(.cyan)
                        .lineLimit(1)
                    Text("Gate: \(CommunityStatus.badge(for: activeTrail.id, reports: reports, publishedGate: activeTrail.gateStatus))")
                        .font(.caption2.bold())
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    isVoiceGuidanceEnabled.toggle()
                    if !isVoiceGuidanceEnabled { voiceGuide.stop() }
                } label: {
                    Image(systemName: isVoiceGuidanceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.title3)
                        .foregroundColor(isVoiceGuidanceEnabled ? .cyan : .white.opacity(0.7))
                }
                .accessibilityLabel(isVoiceGuidanceEnabled ? "Mute voice guidance" : "Unmute voice guidance")
                Button {
                    showAllSteps.toggle()
                } label: {
                    Image(systemName: showAllSteps ? "chevron.up.circle.fill" : "list.bullet.circle.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                }
            }
            if showAllSteps {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(route.displaySteps) { step in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: step.systemImage)
                                    .foregroundColor(.cyan)
                                    .frame(width: 18)
                                Text("\(formatDistance(step.distanceMeters)) • \(step.instruction)")
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            HStack(spacing: 8) {
                Text(formatDistance(remaining))
                Text("•")
                Text(formatDuration(seconds))
                Text(eta, style: .time)
                Spacer(minLength: 4)
                Button("End Route") { endRoute() }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
            .font(.caption.bold())
            .foregroundColor(.cyan)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.04, green: 0.12, blue: 0.22))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func routeCard(_ route: ActiveCampRoute) -> some View {
        let remaining = (liveRemainingMiles ?? (route.selected.distanceMeters / 1609.344)) * 1609.344
        let seconds = liveRemainingSeconds ?? route.selected.expectedTravelTime
        let eta = Date().addingTimeInterval(seconds)
        return VStack(alignment: .leading, spacing: 8) {
            Text(isRouteConfirmed ? destinationTitle(route.destination) : "Previewing Route to \(route.destination.name)")
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .lineLimit(2)
            Text(isRouteConfirmed
                ? formatCoordinate(route.destination.coordinate)
                : "\(formatDistance(remaining)) • \(formatDuration(seconds)) • \(String(format: "%.1f° Slope", route.destination.slopeDeg))")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.white.opacity(0.9))
            coordinatesBar(filled: false)
            HStack {
                Label(formatDuration(seconds), systemImage: "clock")
                Text(eta, style: .time)
                Spacer()
                Text("\(formatDistance(remaining)) left")
                    .font(.caption.monospacedDigit().bold())
            }
            .font(.caption.bold())
            .foregroundColor(.cyan)
            if route.options.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(route.options) { option in
                            Button {
                                selectAlternate(option.id)
                            } label: {
                                Text("\(option.title) • \(formatDuration(option.expectedTravelTime))")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(option.id == route.selectedIndex ? Color.cyan : Color.white.opacity(0.12))
                                    .foregroundColor(option.id == route.selectedIndex ? .black : .white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if isRouteConfirmed {
                HStack(spacing: 8) {
                    Button {
                        startFollow()
                    } label: {
                        Label("Follow GPS", systemImage: "location.north.line.fill")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(followRoute ? .green : .blue)
                    Button("Overview") { showOverview() }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                    mapsMenu(route.destination)
                    Button {
                        endRoute()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .padding(8)
                            .background(Color.red.opacity(0.85))
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("End Route")
                }
            } else {
                HStack(spacing: 8) {
                    Button("Start GPS Route") { startFollow() }
                        .font(.caption.bold())
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    Button("Overview") { showOverview() }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                    mapsMenu(route.destination)
                    Button("Cancel") { endRoute() }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.05, green: 0.08, blue: 0.12))
    }

    private func driveControls(includeFieldCards: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if plotMode || !plotPoints.isEmpty {
                plotterCard
            }
            if includeFieldCards {
                savedMarkersCard
            }
            HStack(spacing: 8) {
                TextField("Search trails, state, address, or store", text: $trailQuery)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { submitPlaceSearch() }
                Button("Search Address / Place") { submitPlaceSearch() }
                    .font(.caption2.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
            }
            if placeSearchBusy {
                Text("Searching addresses and stores…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if !placeSearchNote.isEmpty {
                Text(placeSearchNote)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            if !placeHits.isEmpty {
                Text("Places & Addresses")
                    .font(.caption.bold())
                    .foregroundColor(.cyan)
                VStack(spacing: 8) {
                    ForEach(placeHits) { hit in
                        placeResultRow(hit)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterPill("Near Me", tag: "near")
                    filterPill("All USA", tag: "all")
                    filterPill("Backcountry Corridors", tag: "bdr")
                    ForEach(USATrailAtlas.states, id: \.self) { state in
                        filterPill(state, tag: state)
                    }
                }
            }
            Button {
                showTrailMenu.toggle()
            } label: {
                HStack {
                    Text("\(filterTitle) • \(pickerTrails.count) \(pickerTrails.count == 1 ? "Route" : "Routes") ▾")
                        .font(.caption.bold())
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.cyan.opacity(0.18))
                .foregroundColor(.cyan)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            if showTrailMenu {
                VStack(spacing: 0) {
                    if pickerTrails.isEmpty {
                        Text("No matching routes")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    ForEach(pickerTrails) { trail in
                        Button {
                            selectTrail(trail)
                        } label: {
                            Text(routeMenuLabel(trail))
                                .font(.caption.bold())
                                .foregroundColor(trail.id == selectedTrailID ? .black : .white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(trail.id == selectedTrailID ? Color.cyan : Color.white.opacity(0.06))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pickerTrails) { trail in
                        Button {
                            selectTrail(trail)
                        } label: {
                            Text(routePillLabel(trail))
                                .font(.caption2.bold())
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(trail.id == selectedTrailID ? Color.cyan : Color.white.opacity(0.1))
                                .foregroundColor(trail.id == selectedTrailID ? .black : .white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            legalBadge
            cruxList
            tripShareRow
            convoyPills
            elevationProfileCard
            trailReportBar
            if !telemetry.scanStatus.isEmpty {
                Text(telemetry.scanStatus)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var campList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(listedCamps.isEmpty ? "No <3° pads in \(filterTitle)" : "Tap a pad to route")
                .font(.caption.bold())
                .foregroundColor(.green)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(listedCamps) { spot in
                        HStack(spacing: 8) {
                            Button {
                                selectedCampSpot = spot
                                Task { await beginRoute(to: spot, previewOnly: true) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(spot.name)
                                            .font(.subheadline.bold())
                                            .foregroundColor(.white)
                                        Text(String(format: "%.1f° Slope • %d%% Starlink • %@", spot.slopeDeg, spot.starlinkPct, trailName(for: spot)))
                                            .font(.caption2)
                                            .foregroundColor(.green)
                                            .lineLimit(1)
                                        Text(formatCoordinate(spot.coordinate))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundColor(.white.opacity(0.9))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                    }
                                    Spacer()
                                    Text("Route Here")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(Color.cyan)
                                        .foregroundColor(.black)
                                        .clipShape(Capsule())
                                }
                            }
                            .buttonStyle(.plain)
                            Button {
                                copyCoordinate(spot.coordinate, token: "camp-\(spot.id)")
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: copiedToken == "camp-\(spot.id)" ? "checkmark" : "doc.on.doc")
                                        .font(.caption.bold())
                                    if copiedToken == "camp-\(spot.id)" {
                                        Text("Copied")
                                            .font(.caption2.bold())
                                    }
                                }
                                .foregroundColor(.cyan)
                                .frame(width: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy \(spot.name) coordinates")
                        }
                    }
                }
            }
            .frame(maxHeight: 210)
        }
    }

    private func filterPill(_ title: String, tag: String) -> some View {
        Button {
            if tag == "near" {
                selectNearMe()
            } else {
                regionFilter = tag
            }
        } label: {
            Text(title)
                .font(.caption2.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(regionFilter == tag ? Color.cyan : Color.white.opacity(0.12))
                .foregroundColor(regionFilter == tag ? .black : .white)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func mapsMenu(_ spot: CampSpot) -> some View {
        Menu {
            Link("Apple Maps", destination: appleMapsURL(spot))
            Link("Google Maps", destination: googleMapsURL(spot))
            Button("Google Maps App") { openGoogleMapsApp(spot) }
        } label: {
            Label("Maps", systemImage: "arrow.triangle.turn.up.right.circle")
                .font(.caption.bold())
        }
    }

    private var gpsTelemetryLine: String {
        switch locationTracker.authorizationStatus {
        case .denied, .restricted:
            return "Location off — enable in Settings"
        default:
            break
        }
        guard let user = locationTracker.userCoordinate else { return "Waiting for GPS…" }
        let selected = nearestMiles(from: user, to: activeTrail)
        let nearest = pickerTrails.map { nearestMiles(from: user, to: $0) }.min() ?? selected
        return String(format: "%d ft · %.0f mph · %.1f mi to trail · %.1f mi nearest", locationTracker.altitudeFt, locationTracker.speedMph, selected, nearest)
    }

    private var listHeadline: String {
        if regionFilter == "near", nearAnchor == nil {
            return "Near Me • Locating you"
        }
        let count = pickerTrails.count
        if count == 0 { return "No routes for \(filterTitle)" }
        let noun = count == 1 ? "Route" : "Routes"
        return "\(filterTitle) • \(count) \(noun)"
    }

    private var listSubtitle: String {
        if regionFilter == "near", nearAnchor == nil {
            return "Waiting for GPS. Pan the map to browse another area."
        }
        if let anchor = nearAnchor, let gps = locationTracker.userCoordinate, miles(from: gps, to: anchor) < 1 {
            return "Closest trails from your location"
        }
        if regionFilter == "near" || regionFilter == "all" {
            return "Closest trails from the map center"
        }
        return "Pick a route below"
    }

    private var distanceOrigin: CLLocationCoordinate2D {
        if regionFilter == "near", let anchor = nearAnchor { return anchor }
        return locationTracker.userCoordinate ?? mapCenter
    }

    /// GPS when it exists, unless the map has been panned well away from it.
    /// The boot trailhead is not a Near Me anchor.
    private var nearAnchor: CLLocationCoordinate2D? {
        if let gps = locationTracker.userCoordinate {
            if miles(from: gps, to: mapCenter) > 30 { return mapCenter }
            return gps
        }
        if miles(from: mapCenter, to: bootCoordinate) > 15 { return mapCenter }
        return nil
    }

    private func isBackcountryCorridor(_ trail: OverlandTrail) -> Bool {
        if trail.isBDR { return true }
        if trail.id.range(of: "bdr", options: .caseInsensitive) != nil { return true }
        if trail.name.range(of: "backcountry discovery", options: .caseInsensitive) != nil { return true }
        if trail.name.range(of: "bdr", options: .caseInsensitive) != nil { return true }
        return false
    }

    private func nearestMiles(from origin: CLLocationCoordinate2D, to trail: OverlandTrail) -> Double {
        var best = miles(from: origin, to: trail.centerCoordinate)
        let coordinates = trail.coordinates
        guard !coordinates.isEmpty else { return best }
        let step = max(1, coordinates.count / 24)
        var index = 0
        while index < coordinates.count {
            best = min(best, miles(from: origin, to: coordinates[index]))
            index += step
        }
        if let last = coordinates.last {
            best = min(best, miles(from: origin, to: last))
        }
        return best
    }

    private func routeMenuLabel(_ trail: OverlandTrail) -> String {
        let fit = shortFit(trail)
        let clearance = String(format: "%.0f\"", trail.reqClearanceIn)
        let away = String(format: "%.1f mi away", nearestMiles(from: distanceOrigin, to: trail))
        return "\(trail.state) · \(trail.name) · \(away) · \(clearance) · \(fit)"
    }

    private func routePillLabel(_ trail: OverlandTrail) -> String {
        String(format: "%@ · %.0f mi", trail.name, nearestMiles(from: distanceOrigin, to: trail))
    }

    private func destinationTitle(_ spot: CampSpot) -> String {
        if spot.kind == .trailhead { return spot.name }
        return String(format: "%@ • %.1f° Slope • %d%% Starlink", spot.name, spot.slopeDeg, spot.starlinkPct)
    }

    private func trailName(for spot: CampSpot) -> String {
        USATrailAtlas.all.first(where: { $0.id == spot.trailID })?.name
            ?? telemetry.discoveredTrails.first(where: { $0.id == spot.trailID })?.name
            ?? "Trail"
    }

    private func shortFit(_ trail: OverlandTrail) -> String {
        switch rigStore.evaluate(trail: trail).verdict {
        case .fits: return "FITS"
        case .caution: return "CAUTION"
        case .noGo: return "NO-GO"
        }
    }

    private func fitColor(_ trail: OverlandTrail) -> Color {
        switch rigStore.evaluate(trail: trail).verdict {
        case .fits: return .green
        case .caution: return .orange
        case .noGo: return .red
        }
    }

    private func miles(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        meters(from: from, to: to) / 1609.344
    }

    private func viewportTrails(activeID: String) -> [OverlandTrail] {
        var seen = Set<String>()
        var pool: [OverlandTrail] = []
        for trail in USATrailAtlas.all + telemetry.discoveredTrails {
            guard seen.insert(trail.id).inserted else { continue }
            if isBackcountryCorridor(trail) && trail.id != activeID { continue }
            if trail.id == activeID || trailInView(trail) {
                pool.append(trail)
            }
        }
        let origin = mapCenter
        if pool.count < 12 {
            let extras = (USATrailAtlas.all + telemetry.discoveredTrails)
                .filter { trail in !isBackcountryCorridor(trail) && !pool.contains(where: { $0.id == trail.id }) }
                .sorted { miles(from: origin, to: $0.centerCoordinate) < miles(from: origin, to: $1.centerCoordinate) }
            for trail in extras {
                if pool.count >= 12 { break }
                pool.append(trail)
            }
        }
        pool.sort { miles(from: origin, to: $0.centerCoordinate) < miles(from: origin, to: $1.centerCoordinate) }
        var chosen = Array(pool.prefix(80))
        if !chosen.contains(where: { $0.id == activeID }),
           let active = (USATrailAtlas.all + telemetry.discoveredTrails).first(where: { $0.id == activeID }) {
            chosen.insert(active, at: 0)
        }
        return chosen
    }

    private func trailInView(_ trail: OverlandTrail) -> Bool {
        if coordinateInView(trail.centerCoordinate) { return true }
        let step = max(1, trail.coordinates.count / 12)
        var index = 0
        while index < trail.coordinates.count {
            if coordinateInView(trail.coordinates[index]) { return true }
            index += step
        }
        return false
    }

    private func coordinateInView(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let region = visibleRegion
        let latHalf = max(region.span.latitudeDelta, 0.25) * 1.15
        let lonHalf = max(region.span.longitudeDelta, 0.25) * 1.15
        let lat = region.center.latitude
        let lon = region.center.longitude
        return coordinate.latitude >= lat - latHalf && coordinate.latitude <= lat + latHalf
            && coordinate.longitude >= lon - lonHalf && coordinate.longitude <= lon + lonHalf
    }

    private func refreshTrails(around center: CLLocationCoordinate2D) {
        guard !offlineFirst else { return }
        telemetry.cancelScheduledTrailRefresh()
        Task { await telemetry.fetchTrailsInMapRegion(center: center) }
    }

    private func routeOrigin(toward destination: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let view = mapCenter
        if let gps = locationTracker.userCoordinate {
            let fromView = meters(from: gps, to: view)
            let fromDestination = meters(from: gps, to: destination)
            if fromView <= 500_000 || fromDestination <= 500_000 {
                return gps
            }
        }
        return view
    }

    private func allowsTrailStitch(_ spot: CampSpot) -> Bool {
        if spot.id.hasPrefix("place-") || spot.id.hasPrefix("pin-") || spot.id.hasPrefix("parcel-") {
            return false
        }
        return spot.kind == .pad || spot.kind == .trailhead
    }

    private func focus(on trail: OverlandTrail) {
        let points = trail.coordinates
        guard let first = points.first else { return }
        let minLat = points.reduce(first.latitude) { min($0, $1.latitude) }
        let maxLat = points.reduce(first.latitude) { max($0, $1.latitude) }
        let minLon = points.reduce(first.longitude) { min($0, $1.longitude) }
        let maxLon = points.reduce(first.longitude) { max($0, $1.longitude) }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let latDelta = max(0.22, (maxLat - minLat) * 1.25)
        let lonDelta = max(0.22, (maxLon - minLon) * 1.25)
        withAnimation {
            pushCamera(regionCamera(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
            ))
        }
    }

    private func selectTrail(_ trail: OverlandTrail) {
        selectedTrailID = trail.id
        showTrailMenu = false
    }

    private func applyFilterSelection(scanIfNear: Bool) {
        if regionFilter == "near" {
            locationTracker.requestLocation()
            if let gps = locationTracker.userCoordinate, !followRoute {
                mapCenter = gps
                pushCamera(userTrackingCamera(followsHeading: false))
            }
            if !pickerTrails.contains(where: { $0.id == selectedTrailID }),
               let first = pickerTrails.first {
                if !followRoute { skipNextFocus = true }
                selectedTrailID = first.id
            } else if pickerTrails.isEmpty {
                showTrailMenu = true
                if detent == .peek { detent = .half }
            }
            guard scanIfNear, let anchor = nearAnchor else { return }
            refreshTrails(around: anchor)
            return
        }
        if regionFilter == "bdr" {
            showTrailMenu = true
            if detent == .peek { detent = .half }
            if let selected = pickerTrails.first(where: { $0.id == selectedTrailID && isBackcountryCorridor($0) }), !followRoute {
                focus(on: selected)
            }
        } else if pickerTrails.contains(where: { $0.id == selectedTrailID }) {
            if !followRoute, let selected = pickerTrails.first(where: { $0.id == selectedTrailID }) {
                focus(on: selected)
            }
        } else if let first = pickerTrails.first(where: { !isBackcountryCorridor($0) }) {
            if followRoute { skipNextFocus = true }
            selectedTrailID = first.id
        } else {
            showTrailMenu = true
            if detent == .peek { detent = .half }
        }
    }

    private func selectNearMe() {
        followRoute = false
        locationTracker.requestLocation()
        if let coordinate = locationTracker.userCoordinate {
            mapCenter = coordinate
            pushCamera(userTrackingCamera(followsHeading: false))
        }
        if regionFilter != "near" {
            regionFilter = "near"
        } else {
            applyFilterSelection(scanIfNear: true)
        }
    }

    private func beginRoute(to spot: CampSpot, refit: Bool = true, previewOnly: Bool = false) async {
        routeGeneration += 1
        let generation = routeGeneration
        let originWasGPS = locationTracker.userCoordinate != nil
        if spot.kind == .pad {
            selectedCampSpot = spot
        } else {
            selectedCampSpot = nil
        }
        let trail = trail(for: spot) ?? activeTrail
        let origin = routeOrigin(toward: spot.coordinate)
        let stitchTrail = allowsTrailStitch(spot)
        if activeRoute?.destination.id != spot.id {
            activeRoute = nil
        }
        isRouting = true
        let built = await CampRouteBuilder.make(
            from: origin,
            to: spot,
            trailCoordinates: stitchTrail ? trail.coordinates : [],
            trailhead: stitchTrail ? trail.trailhead.coordinate : spot.coordinate,
            originWasGPS: originWasGPS,
            spurLimit: stitchTrail ? 3_218 : 250
        )
        guard generation == routeGeneration else { return }
        isRouting = false
        activeRoute = built
        routeStartedFromGPS = built.originWasGPS
        showAllSteps = false
        activeStepIndex = 0
        announcedApproachStep = nil
        announcedTurnStep = nil
        announcedArrival = false
        refreshSelectedTrailDraw()
        refreshLiveRouteMetrics()
        if spot.trailID != selectedTrailID {
            skipNextFocus = true
            selectedTrailID = spot.trailID
        }
        if previewOnly {
            isRouteConfirmed = false
            followRoute = false
            detent = .peek
            if built.selected.road.count >= 2 {
                frame(built)
            }
            return
        }
        isRouteConfirmed = true
        if refit {
            followRoute = false
            if built.selected.road.count >= 2 {
                frame(built)
                announceRouteStart(built)
            } else {
                pushCamera(regionCamera(
                    center: spot.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
                ))
            }
            skipStepsAlreadyReached()
        } else if followRoute {
            followUserCamera()
            skipStepsAlreadyReached()
            if let route = activeRoute {
                speakCurrentStep(route)
            }
        }
    }

    private func handleLiveGPS() {
        refreshLiveRouteMetrics()
        refreshTurnProgress()
        announceNearbyCrux()
        if followRoute, is3DMapsEnabled, let user = locationTracker.userCoordinate,
           Date().timeIntervalSince(lastCameraNote) > 0.8 {
            let distance = lastMapCamera?.distance ?? cameraDistance(for: visibleRegion)
            pushCamera(.camera(MapCamera(
                centerCoordinate: user,
                distance: distance,
                heading: lastCameraHeading,
                pitch: activePitch
            )))
        }
        guard let route = activeRoute, let user = locationTracker.userCoordinate else { return }
        if !routeStartedFromGPS {
            routeStartedFromGPS = true
            Task { await beginRoute(to: route.destination, refit: !followRoute, previewOnly: !isRouteConfirmed) }
            return
        }
        guard isRouteConfirmed, followRoute, Date().timeIntervalSince(lastReroute) > 25 else { return }
        guard offRouteMeters(user, route: route) > 450 else { return }
        lastReroute = Date()
        Task { await beginRoute(to: route.destination, refit: false) }
    }

    private func announceNearbyCrux() {
        guard isRouteConfirmed, activeRoute != nil, isVoiceGuidanceEnabled, let user = locationTracker.userCoordinate else { return }
        for pin in pertinentCruxPins where !announcedCrux.contains(pin.id) {
            let distance = meters(from: user, to: pin.coordinate)
            if distance <= 241 {
                announcedCrux.insert(pin.id)
                voiceGuide.speak(pin.spoken, enabled: true)
                break
            }
        }
    }

    private var currentTripGPX: String {
        let track = plotPoints.count >= 2 ? plottedLine : (activeRoute?.selected.road ?? activeTrail.coordinates)
        return TripPackageBuilder.gpx(trail: activeTrail, track: track, hazards: hazardPins)
    }

    private func recordHazardNote() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HazardNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(UUID().uuidString).m4a")
        do {
            try hazardRecorder.start(url: url)
            pendingVoiceURL = url
        } catch {
            pendingVoiceURL = nil
        }
        Task {
            try? await Task.sleep(nanoseconds: 5_200_000_000)
            hazardRecorder.stop()
        }
    }

    private func saveHazardPin() {
        guard let coordinate = locationTracker.userCoordinate else { return }
        hazardRecorder.stop()
        var photoPath: String?
        if let hazardPhoto {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HazardNotes", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(UUID().uuidString).jpg")
            try? hazardPhoto.write(to: url)
            photoPath = url.path
        }
        let voicePath = pendingVoiceURL?.path
        let pin = DroppedHazard(
            id: UUID().uuidString,
            category: hazardCategory,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            elevationFt: locationTracker.altitudeFt,
            note: "Dropped at live GPS",
            photoPath: photoPath,
            voicePath: voicePath,
            createdAt: Date(),
            trailID: activeTrail.id
        )
        community.submitHazard(pin)
        publishCommunity()
        hazardPhoto = nil
        hazardPhotoItem = nil
        pendingVoiceURL = nil
        showHazardSheet = false
    }

    private func selectAlternate(_ index: Int) {
        guard var route = activeRoute, route.options.contains(where: { $0.id == index }) else { return }
        route.selectedIndex = index
        route.spur = simplifyCoordinates(cappedSpur(from: route.selected.road, to: route.destination.coordinate), maxPoints: 40, minMeters: 18)
        activeRoute = route
        activeStepIndex = 0
        announcedApproachStep = nil
        announcedTurnStep = nil
        announcedArrival = false
        refreshLiveRouteMetrics()
        if isRouteConfirmed {
            announceRouteStart(route)
        }
        skipStepsAlreadyReached()
        if !followRoute { frame(route) }
    }

    private func startFollow() {
        isRouteConfirmed = true
        followRoute = true
        followHeading = true
        detent = .peek
        showingRouteOverview = false
        followUserCamera()
        skipStepsAlreadyReached()
        if let route = activeRoute {
            announceRouteStart(route)
        }
        flashRouteStartNote()
    }

    private func flashRouteStartNote() {
        routeNoteToken += 1
        let token = routeNoteToken
        showRouteStartNote = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if token == routeNoteToken {
                showRouteStartNote = false
            }
        }
    }

    private func followUserCamera() {
        cameraGate.ignoreFollowDisengageUntil = Date().addingTimeInterval(0.45)
        showingRouteOverview = false
        pushCamera(userTrackingCamera(followsHeading: true))
    }

    private func showOverview() {
        followRoute = false
        if let route = activeRoute { frame(route) }
    }

    private func endRoute() {
        routeGeneration += 1
        activeRoute = nil
        isRouteConfirmed = false
        followRoute = false
        showingRouteOverview = false
        showAllSteps = false
        isRouting = false
        activeStepIndex = 0
        liveRemainingMiles = nil
        liveRemainingSeconds = nil
        liveNextStepDistanceText = ""
        announcedApproachStep = nil
        announcedTurnStep = nil
        announcedArrival = false
        voiceGuide.stop()
    }

    private func frame(_ route: ActiveCampRoute) {
        var coords = route.roadAndSpur
        if let user = locationTracker.userCoordinate { coords.append(user) }
        coords.append(route.destination.coordinate)
        guard let minLat = coords.map(\.latitude).min(),
              let maxLat = coords.map(\.latitude).max(),
              let minLon = coords.map(\.longitude).min(),
              let maxLon = coords.map(\.longitude).max() else { return }
        let latDelta = max(0.03, (maxLat - minLat) * 1.45)
        let lonDelta = max(0.03, (maxLon - minLon) * 1.45)
        cameraGate.overviewSpan = max(latDelta, lonDelta)
        cameraGate.ignoreFollowDisengageUntil = Date().addingTimeInterval(0.45)
        showingRouteOverview = true
        withAnimation {
            pushCamera(regionCamera(
                center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
            ))
        }
    }

    private func nextCue(_ route: ActiveCampRoute) -> (text: String, icon: String) {
        let steps = route.displaySteps
        guard !steps.isEmpty else {
            return ("Head toward \(route.destination.name)", "arrow.up")
        }
        let index = min(activeStepIndex, steps.count - 1)
        let step = steps[index]
        if liveNextStepDistanceText.isEmpty {
            return (step.instruction, step.systemImage)
        }
        if liveNextStepDistanceText == "Arriving" {
            return ("Arriving at \(route.destination.name)", "flag.checkered")
        }
        if step.id == 10_000 {
            return ("Proceed \(liveNextStepDistanceText) on overland spur to \(route.destination.name)", step.systemImage)
        }
        return ("In \(liveNextStepDistanceText) • \(step.instruction)", step.systemImage)
    }

    private func offRouteMeters(_ user: CLLocationCoordinate2D, route: ActiveCampRoute) -> Double {
        let coords = route.roadAndSpur
        guard coords.count >= 2 else { return .greatestFiniteMagnitude }
        var best = Double.greatestFiniteMagnitude
        for index in 1..<coords.count {
            best = min(best, distanceToSegment(user, coords[index - 1], coords[index]).distance)
        }
        return best
    }

    private func trail(for spot: CampSpot) -> OverlandTrail? {
        USATrailAtlas.all.first(where: { $0.id == spot.trailID })
            ?? telemetry.discoveredTrails.first(where: { $0.id == spot.trailID })
            ?? pickerTrails.first(where: { $0.id == spot.trailID })
    }

    private func appleMapsURL(_ spot: CampSpot) -> URL {
        URL(string: "http://maps.apple.com/?daddr=\(spot.lat),\(spot.lon)&dirflg=d")!
    }

    private func googleMapsURL(_ spot: CampSpot) -> URL {
        URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(spot.lat),\(spot.lon)&travelmode=driving")!
    }

    private func openGoogleMapsApp(_ spot: CampSpot) {
        let app = URL(string: "comgooglemaps://?daddr=\(spot.lat),\(spot.lon)&directionsmode=driving")!
        if UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
        } else {
            UIApplication.shared.open(googleMapsURL(spot))
        }
    }

    private func refreshTurnProgress() {
        guard isRouteConfirmed, let route = activeRoute, let user = locationTracker.userCoordinate else { return }
        let steps = route.displaySteps
        guard !steps.isEmpty else { return }
        let index = min(activeStepIndex, steps.count - 1)
        let destinationDistance = meters(from: user, to: route.destination.coordinate)
        if destinationDistance <= 50 {
            if !announcedArrival {
                announcedArrival = true
                let arrival: String
                if route.destination.kind == .pad {
                    arrival = String(format: "You have arrived at %@. Slope is %.1f degrees.", route.destination.name, route.destination.slopeDeg)
                } else {
                    arrival = "You have arrived at \(route.destination.name)."
                }
                voiceGuide.speak(arrival, enabled: isVoiceGuidanceEnabled)
            }
            return
        }
        let step = steps[index]
        guard let maneuver = step.maneuver else { return }
        let away = meters(from: user, to: maneuver)
        if away <= 35, announcedTurnStep != step.id {
            announcedTurnStep = step.id
            announcedApproachStep = step.id
            var phrase = step.instruction
            if index + 1 < steps.count {
                let upcoming = steps[index + 1]
                phrase += ". Then in \(spokenDistance(upcoming.distanceMeters)), \(upcoming.instruction)"
            }
            voiceGuide.speak(phrase, enabled: isVoiceGuidanceEnabled)
            if index + 1 < steps.count {
                activeStepIndex = index + 1
            }
            return
        }
        if away <= 320, away > 80, announcedApproachStep != step.id {
            announcedApproachStep = step.id
            voiceGuide.speak("In \(spokenDistance(away)), \(step.instruction)", enabled: isVoiceGuidanceEnabled)
        }
    }

    private func announceRouteStart(_ route: ActiveCampRoute) {
        guard isRouteConfirmed else { return }
        let first = route.displaySteps.first?.instruction ?? "Follow the highlighted route"
        let distance = spokenDistance(route.selected.distanceMeters)
        var text = "Starting GPS route to \(route.destination.name). It's about \(distance), \(spokenDuration(route.selected.expectedTravelTime)). \(first)."
        if route.displaySteps.count > 1 {
            text += " Then, \(route.displaySteps[1].instruction)."
        }
        voiceGuide.speak(text, enabled: isVoiceGuidanceEnabled)
    }

    private func speakCurrentStep(_ route: ActiveCampRoute) {
        guard isRouteConfirmed else { return }
        let steps = route.displaySteps
        guard !steps.isEmpty else { return }
        let step = steps[min(activeStepIndex, steps.count - 1)]
        var phrase = step.instruction
        if let user = locationTracker.userCoordinate, let maneuver = step.maneuver {
            let away = meters(from: user, to: maneuver)
            if away > 40 {
                phrase = "In \(spokenDistance(away)), \(step.instruction)"
            }
        }
        voiceGuide.speak(phrase, enabled: isVoiceGuidanceEnabled)
    }

    /// Steps whose maneuver is already under the vehicle (a depart pin) are marked
    /// announced so the next GPS tick does not repeat them.
    private func skipStepsAlreadyReached() {
        guard let route = activeRoute, let user = locationTracker.userCoordinate else { return }
        let steps = route.displaySteps
        guard !steps.isEmpty else { return }
        var index = 0
        while index < steps.count - 1 {
            guard let maneuver = steps[index].maneuver else { break }
            if meters(from: user, to: maneuver) > 35 { break }
            announcedTurnStep = steps[index].id
            announcedApproachStep = steps[index].id
            index += 1
        }
        activeStepIndex = index
    }

    private func syncCameraGate() {
        cameraGate.followRoute = followRoute
        cameraGate.showingRouteOverview = showingRouteOverview
        cameraGate.userLatitude = locationTracker.userCoordinate?.latitude
        cameraGate.userLongitude = locationTracker.userCoordinate?.longitude
    }

    private func pushCamera(_ position: MapCameraPosition) {
        cameraCommand += 1
        cameraPosition = position
    }

    private func cameraDistance(for region: MKCoordinateRegion) -> CLLocationDistance {
        let latitudeMeters = max(region.span.latitudeDelta, region.span.longitudeDelta) * 111_320
        return min(max(latitudeMeters / 1.6, 400), 2_500_000)
    }

    private func regionCamera(center: CLLocationCoordinate2D, span: MKCoordinateSpan) -> MapCameraPosition {
        let pitch = activePitch
        let region = MKCoordinateRegion(center: center, span: span)
        guard pitch > 1 else { return .region(region) }
        return .camera(MapCamera(
            centerCoordinate: center,
            distance: cameraDistance(for: region),
            heading: lastCameraHeading,
            pitch: pitch
        ))
    }

    private func userTrackingCamera(followsHeading: Bool) -> MapCameraPosition {
        let center = locationTracker.userCoordinate ?? visibleRegion.center
        guard is3DMapsEnabled else {
            return .userLocation(followsHeading: followsHeading, fallback: .automatic)
        }
        let span = MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        return .camera(MapCamera(
            centerCoordinate: center,
            distance: lastMapCamera?.distance ?? cameraDistance(for: MKCoordinateRegion(center: center, span: span)),
            heading: lastCameraHeading,
            pitch: activePitch
        ))
    }

    private var horizonAssist: Double {
        guard is3DMapsEnabled, userOwnsPitch else { return 0 }
        let gap = cameraPitch - reportedMapPitch
        guard gap > 1, reportedMapPitch >= 8 else { return 0 }
        return min(gap, 15)
    }

    private func applyCameraPitch(_ pitch: Double, keepMode: Bool = false) {
        let clamped = min(max(pitch, 0), 75)
        cameraPitch = clamped
        if !keepMode {
            is3DMapsEnabled = clamped >= 5
            userOwnsPitch = is3DMapsEnabled && clamped > reportedMapPitch + 2
        }
        let center = lastMapCamera?.centerCoordinate ?? visibleRegion.center
        let distance = lastMapCamera?.distance ?? cameraDistance(for: visibleRegion)
        pushCamera(.camera(MapCamera(
            centerCoordinate: center,
            distance: distance,
            heading: lastMapCamera?.heading ?? lastCameraHeading,
            pitch: clamped
        )))
    }

    private func set3DMode(_ enabled: Bool) {
        is3DMapsEnabled = enabled
        userOwnsPitch = false
        if enabled {
            applyCameraPitch(cameraPitch >= 5 ? min(cameraPitch, 75) : 0, keepMode: true)
        } else {
            applyCameraPitch(0, keepMode: true)
        }
    }

    private func handleFingerPitch(_ pitch: Double, active: Bool) {
        guard is3DMapsEnabled else { return }
        pitchGestureActive = active
        userOwnsPitch = true
        applyCameraPitch(min(75, max(5, pitch)), keepMode: true)
    }

    private func noteMapCamera(_ camera: MapCamera) {
        let now = Date()
        let reported = min(max(camera.pitch, 0), 75)
        let previousReported = reportedMapPitch
        reportedMapPitch = reported
        if reported > pitchCeiling { pitchCeiling = reported }
        let headingChanged = abs(camera.heading - lastCameraHeading) > 2
        if pitchGestureActive || headingChanged || now.timeIntervalSince(lastCameraNote) > 0.45 {
            lastCameraNote = now
            lastMapCamera = camera
            lastCameraHeading = camera.heading
        }
        if pitchGestureActive { return }
        let nativeFlattened = reported < 1 && (previousReported > 8 || cameraPitch > 8)
        if nativeFlattened {
            is3DMapsEnabled = false
            userOwnsPitch = false
            cameraPitch = 0
            return
        }
        if userOwnsPitch && cameraPitch > reported + 2 { return }
        if reported > 1 {
            is3DMapsEnabled = true
            userOwnsPitch = false
            cameraPitch = reported
        }
    }

    private func leaveFullDetent() {
        if detent == .full { detent = .half }
    }

    private func handleCameraEnd(_ region: MKCoordinateRegion) {
        let span = max(region.span.latitudeDelta, region.span.longitudeDelta)
        let center = region.center
        if !offlineFirst {
            refreshHazards(around: center)
        }
        screenCenter = center
        visibleRegion = region
        if meters(from: mapCenter, to: center) > 40 {
            mapCenter = center
        }
        refreshTrails(around: center)
        scheduleLandFetch(region)
        if cameraGate.followRoute {
            if Date() < cameraGate.ignoreFollowDisengageUntil {
                cameraGate.followSpan = span
                return
            }
            let drifted: Bool
            if let latitude = cameraGate.userLatitude, let longitude = cameraGate.userLongitude {
                drifted = meters(from: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), to: center) > 160
            } else {
                drifted = false
            }
            let pinched = span > cameraGate.followSpan * 1.35 || span < cameraGate.followSpan * 0.72
            if drifted || pinched {
                followRoute = false
                showingRouteOverview = false
                pushCamera(regionCamera(center: region.center, span: region.span))
            }
            return
        }
        if cameraGate.showingRouteOverview, span < cameraGate.overviewSpan * 0.72 {
            showingRouteOverview = false
        }
    }

    private func refreshSelectedTrailDraw() {
        let line = activeTrail.coordinates
        selectedTrailDraw = line.count > 220 ? simplifyCoordinates(line, maxPoints: 220, minMeters: 18) : line
    }

    private func refreshLiveRouteMetrics() {
        guard let route = activeRoute else {
            liveRemainingMiles = nil
            liveRemainingSeconds = nil
            liveNextStepDistanceText = ""
            return
        }
        guard let user = locationTracker.userCoordinate else {
            liveRemainingMiles = route.selected.distanceMeters / 1609.344
            liveRemainingSeconds = route.selected.expectedTravelTime
            liveNextStepDistanceText = ""
            return
        }
        let total = polylineMeters(route.roadAndSpur)
        let remaining = max(0, total - traveledMeters(user: user, along: route.roadAndSpur))
        liveRemainingMiles = remaining / 1609.344
        let baseline = max(route.selected.distanceMeters + route.spurMeters, 1)
        liveRemainingSeconds = route.selected.expectedTravelTime * (remaining / baseline)
        if meters(from: user, to: route.destination.coordinate) <= 50 {
            liveNextStepDistanceText = "Arriving"
            return
        }
        let steps = route.displaySteps
        guard !steps.isEmpty else {
            liveNextStepDistanceText = ""
            return
        }
        let step = steps[min(activeStepIndex, steps.count - 1)]
        let target = step.maneuver ?? route.destination.coordinate
        liveNextStepDistanceText = formatDistance(meters(from: user, to: target))
    }

    private func placeResultRow(_ hit: PlaceHit) -> some View {
        let distance: String = {
            guard let user = locationTracker.userCoordinate else { return "" }
            return String(format: " · %.1f mi from MY GPS", miles(from: user, to: hit.coordinate))
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                openPlace(hit, route: true)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.name)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(hit.address + distance)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Button("Route Here") { openPlace(hit, route: true) }
                    .font(.caption2.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                Button("View on Map") { openPlace(hit, route: false) }
                    .font(.caption2.bold())
                    .buttonStyle(.bordered)
                mapsMenu(placeSpot(hit))
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func schedulePlaceSearch(_ raw: String) {
        placeSearchGeneration += 1
        let generation = placeSearchGeneration
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else {
            placeHits = []
            placeSearchBusy = false
            placeSearchNote = ""
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard generation == placeSearchGeneration else { return }
            await searchPlaces(query, generation: generation, routeFirst: false)
        }
    }

    private func submitPlaceSearch() {
        placeSearchGeneration += 1
        let generation = placeSearchGeneration
        let query = trailQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else {
            placeSearchNote = "Enter at least 3 characters to search an address or store."
            return
        }
        Task {
            await searchPlaces(query, generation: generation, routeFirst: true)
        }
    }

    private func searchPlaces(_ query: String, generation: Int, routeFirst: Bool) async {
        placeSearchBusy = true
        let hits = await PlaceLookup.fetch(
            query: query,
            near: locationTracker.userCoordinate ?? mapCenter,
            user: locationTracker.userCoordinate,
            nationwide: PlaceLookup.prefersNationwide(query)
        )
        guard generation == placeSearchGeneration else { return }
        placeSearchBusy = false
        placeHits = hits
        if hits.isEmpty {
            placeSearchNote = routeFirst ? "No address or store matched that search." : ""
            return
        }
        placeSearchNote = ""
        if routeFirst, let first = hits.first {
            openPlace(first, route: true)
        }
    }

    private func placeSpot(_ hit: PlaceHit) -> CampSpot {
        CampSpot(
            id: "place-\(hit.id)",
            trailID: activeTrail.id,
            name: hit.name,
            lat: hit.latitude,
            lon: hit.longitude,
            slopeDeg: 0,
            starlinkPct: 0,
            kind: .trailhead
        )
    }

    private func openPlace(_ hit: PlaceHit, route: Bool) {
        searchedPlace = hit
        selectedCampSpot = placeSpot(hit)
        followRoute = false
        withAnimation {
            pushCamera(regionCamera(
                center: hit.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ))
        }
        guard route else { return }
        let spot = placeSpot(hit)
        Task { await beginRoute(to: spot) }
    }

    private func coordinatesBar(filled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            coordinateLine(title: "MY GPS", coordinate: locationTracker.userCoordinate, token: "gps", fallback: "Acquiring GPS...")
            coordinateLine(title: "TARGET", coordinate: targetCoordinate, token: "target", fallback: "Choose a trail or pad")
        }
        .padding(.horizontal, filled ? 10 : 0)
        .padding(.vertical, filled ? 8 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(filled ? Color.black.opacity(0.82) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(filled ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1)
        )
    }

    private func coordinateLine(title: String, coordinate: CLLocationCoordinate2D?, token: String, fallback: String) -> some View {
        let text = coordinate.map(formatCoordinate) ?? fallback
        let copied = copiedToken == token
        return Button {
            guard let coordinate else { return }
            copyCoordinate(coordinate, token: token)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundColor(.cyan)
                    .frame(width: 54, alignment: .leading)
                Text(copied ? "Copied" : text)
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer(minLength: 4)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2.bold())
                    .foregroundColor(.cyan)
            }
        }
        .buttonStyle(.plain)
        .disabled(coordinate == nil)
        .accessibilityLabel(copied ? "Copied \(title)" : "\(title) \(text). Copy coordinates")
    }

    private func copyCoordinate(_ coordinate: CLLocationCoordinate2D, token: String) {
        UIPasteboard.general.string = formatCoordinate(coordinate)
        copiedToken = token
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedToken == token {
                copiedToken = nil
            }
        }
    }

    private func miniMapButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.bold())
                .padding(8)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
    }

    private func wantsDash(_ size: CGSize) -> Bool {
        if dashMode == "on" { return true }
        if dashMode == "off" { return false }
        return size.width > size.height
    }

    private func sheetHeight(_ total: CGFloat) -> CGFloat {
        switch detent {
        case .peek:
            return CGFloat(172)
        case .half:
            return max(CGFloat(300), total * 0.46)
        case .full:
            let preferred = max(CGFloat(460), total * 0.82)
            return min(preferred, total - 130)
        }
    }

    private func portraitCockpit(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            mapStage(showGloveRow: false, viewportHeight: size.height, mapHeight: size.height - sheetHeight(size.height))
            cockpitSheet(expanded: detent != .peek)
                .frame(height: sheetHeight(size.height))
        }
    }

    private func dashCockpit(_ size: CGSize) -> some View {
        HStack(spacing: 0) {
            mapStage(showGloveRow: true, viewportHeight: size.height, mapHeight: size.height)
                .frame(width: size.width * 0.65)
            dashColumn
                .frame(width: size.width * 0.35)
                .background(Color(red: 0.05, green: 0.08, blue: 0.12))
        }
    }

    private func routePreviewBanner(_ route: ActiveCampRoute) -> some View {
        let remaining = (liveRemainingMiles ?? (route.selected.distanceMeters / 1609.344)) * 1609.344
        let seconds = liveRemainingSeconds ?? route.selected.expectedTravelTime
        return VStack(alignment: .leading, spacing: 6) {
            Text("Previewing Route to \(route.destination.name)")
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .lineLimit(2)
            Text("\(formatDistance(remaining)) • \(formatDuration(seconds)) • \(String(format: "%.1f° Slope", route.destination.slopeDeg))")
                .font(.caption.bold())
                .foregroundColor(.cyan)
                .lineLimit(2)
            HStack(spacing: 8) {
                Button("Start GPS Route") { startFollow() }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                Button("Cancel") { endRoute() }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.04, green: 0.12, blue: 0.22).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func railColumnTop(showGloveRow: Bool, viewportHeight: CGFloat, mapHeight: CGFloat) -> CGFloat {
        let railFullHeight: CGFloat = 258
        if showGloveRow {
            return min(88, max(8, mapHeight - railFullHeight))
        }
        let fittedTop = max(8, mapHeight - railFullHeight)
        if detent == .peek {
            return min(viewportHeight * 0.50, max(88, fittedTop))
        }
        return fittedTop
    }

    private func mapStage(showGloveRow: Bool, viewportHeight: CGFloat, mapHeight: CGFloat) -> some View {
        ZStack {
            routeMap(showsUserLocationButton: !showGloveRow)
            if nightVision {
                Color.black.opacity(0.28)
                    .allowsHitTesting(false)
            }
            if !convoy.lastAlert.isEmpty {
                Text(convoy.lastAlert)
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.82))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 8) {
                if let route = activeRoute, followRoute {
                    navigationBanner(route)
                        .padding(.trailing, 70)
                }
                if showRouteStartNote {
                    Text("Obey posted signs, verify private property, and keep your eyes on the trail.")
                        .font(.caption2.bold())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.82))
                        .foregroundColor(Color(red: 1.0, green: 0.74, blue: 0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.trailing, 70)
                        .allowsHitTesting(false)
                }
                topCluster
                if plotMode {
                    Text(nextSegmentFreehand ? "Plotter • next segment is freehand" : "Plotter • next segment snaps to the trail")
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.72))
                        .foregroundColor(.cyan)
                        .clipShape(Capsule())
                }
                Spacer()
                if let route = activeRoute, !isRouteConfirmed {
                    routePreviewBanner(route)
                        .padding(.leading, 4)
                        .padding(.trailing, 70)
                }
                if showGloveRow {
                    gloveRow
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
            }
            .padding(.top, 24)
            .padding(.leading, 8)
        }
        .overlay(alignment: .topTrailing) {
            if detent != .full || showGloveRow {
                let top = railColumnTop(showGloveRow: showGloveRow, viewportHeight: viewportHeight, mapHeight: mapHeight)
                VStack(spacing: 0) {
                    Color.clear.frame(height: top)
                    ScrollView(.vertical, showsIndicators: false) {
                        rightRail(showGloveRow)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(width: 62, height: mapHeight, alignment: .top)
                .padding(.trailing, 5)
                .animation(.easeOut(duration: 0.2), value: detent)
            }
        }
        .colorMultiply(nightVision ? Color(red: 0.86, green: 0.38, blue: 0.16) : Color.white)
        .onChange(of: blmMaskOpacity) { _, _ in scheduleLandFetch(visibleRegion) }
        .onChange(of: usfsMaskOpacity) { _, _ in scheduleLandFetch(visibleRegion) }
        .onChange(of: stateMaskOpacity) { _, _ in scheduleLandFetch(visibleRegion) }
    }

    private func scheduleLandFetch(_ region: MKCoordinateRegion) {
        landFetchGeneration += 1
        let generation = landFetchGeneration
        let blm = blmMaskOpacity
        let usfs = usfsMaskOpacity
        let state = stateMaskOpacity
        if blm <= 0.02 && usfs <= 0.02 && state <= 0.02 {
            landRings = []
            return
        }
        Task {
            let rings = await LandViewportQuery.fetch(region: region, blm: blm, usfs: usfs, state: state)
            await MainActor.run {
                guard generation == landFetchGeneration else { return }
                landRings = rings
            }
        }
    }

    private func routeMap(showsUserLocationButton: Bool) -> some View {
        StableRouteMap(
            cameraPosition: $cameraPosition,
            sceneToken: mapSceneToken,
            cameraCommand: cameraCommand,
            showAlternates: showRouteAlternates,
            routeStartedFromGPS: routeStartedFromGPS,
            routingActive: activeRoute != nil,
            selectedTrailID: selectedTrailID,
            trails: mapTrails,
            cruxPins: pertinentCruxPins,
            trailColors: visibleTrailColors,
            selectedTrailLine: selectedTrailDraw,
            camps: mapCamps,
            route: activeRoute,
            plotMode: plotMode,
            basemap: effectiveBasemap,
            flatBasemap: heatLimited,
            trailOpacity: trailCorridorOpacity,
            landRings: landRings,
            blmOpacity: blmMaskOpacity,
            usfsOpacity: usfsMaskOpacity,
            stateOpacity: stateMaskOpacity,
            campSlopeOpacity: campSlopeOpacity,
            hazardOpacity: hazardOverlayOpacity,
            starlinkOpacity: starlinkOverlayOpacity,
            hazards: mapHazards,
            searchedPlace: searchedPlace,
            plotLine: plottedLine,
            plotMarkers: plotPoints,
            savedMarkers: savedMarkers,
            droppedPin: droppedPin?.coordinate,
            scrub: scrubCoordinate,
            liveOfflineRing: liveOfflineBox()?.ring ?? [],
            savedOfflineRings: savedOfflineRings,
            onCameraEnd: { region in
                handleCameraEnd(region)
            },
            onCameraPreview: { region in
                trackScreen(region)
            },
            onSpot: { spot in
                if plotMode {
                    addPlotPoint(spot.coordinate)
                    return
                }
                Task { await beginRoute(to: spot, previewOnly: spot.kind == .pad) }
            },
            onInspect: { coordinate in
                if plotMode {
                    addPlotPoint(coordinate)
                }
            },
            onLongPress: { coordinate in
                handleMapLongPress(coordinate)
            },
            onMapCamera: { camera in
                noteMapCamera(camera)
            },
            fingerPitch: cameraPitch,
            fingerPitchEnabled: is3DMapsEnabled,
            horizonAssist: horizonAssist,
            onFingerPitch: { pitch, active in
                handleFingerPitch(pitch, active: active)
            },
            showsUserLocationButton: showsUserLocationButton,
            onSelectMarker: { id in
                guard let marker = savedMarkers.first(where: { $0.id == id }) else { return }
                if plotMode {
                    addPlotPoint(marker.coordinate)
                    return
                }
                leaveFullDetent()
                editingMarker = marker
                pinName = marker.name
                pinCategory = marker.category
            },
            onDeletePlotPoint: { index in
                removePlotPoint(at: index)
            }
        )
        .equatable()
    }

    private func rightRail(_ showGloveRow: Bool) -> some View {
        VStack(spacing: 5) {
            railButton("square.3.layers.3d.down.right", active: showLayers) {
                leaveFullDetent()
                withAnimation(.easeOut(duration: 0.2)) {
                    showLayers.toggle()
                }
            }
            .accessibilityLabel("Map layers")
            railButton("point.topleft.down.curvedto.point.bottomright.up", active: plotMode) {
                togglePlotter()
            }
            .accessibilityLabel("Custom route plotter")
            railButton("arrow.down.circle.fill", active: showOffline) {
                toggleOfflineMaps()
            }
            .accessibilityLabel("Download 5-mile corridor")
            railButton("camera.fill", active: showHazardSheet) {
                leaveFullDetent()
                showHazardSheet = true
            }
            .accessibilityLabel("Drop hazard pin")
            railButton("moon.fill", active: nightVision) {
                nightVision.toggle()
            }
            .accessibilityLabel("Night vision")
        }
        .padding(4)
        .frame(width: 54)
        .background(Color.black.opacity(0.84))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private var topCluster: some View {
        HStack(spacing: 6) {
            Button {
                toggleOfflineMaps()
            } label: {
                Text("Offline Maps")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.72))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleOfflineMaps() {
        withAnimation(.easeOut(duration: 0.2)) {
            showOffline.toggle()
        }
        if showOffline {
            leaveFullDetent()
        }
    }

    private var gloveRow: some View {
        HStack(spacing: 8) {
            gloveButton("Recenter", system: "location.fill") { recenterGPS() }
            gloveButton(followHeading ? "Heading" : "North", system: followHeading ? "location.north.line.fill" : "location.north.line") {
                cycleCameraMode()
            }
            gloveButton("<3° Camps", system: "tent.fill") {
                mode = .camp
                if detent == .peek { detent = .half }
            }
        }
    }

    private func cockpitSheet(expanded: Bool) -> some View {
        VStack(spacing: 8) {
            sheetGrabber
            modePicker
            Text(cockpitSummary)
                .font(.caption.bold())
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if expanded {
                ScrollView {
                    VStack(spacing: 10) {
                        if let route = activeRoute {
                            routeCard(route)
                        } else {
                            fitBanner
                        }
                        cockpitModeBody(includeFieldCards: true)
                        safetyLegalButton
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 56)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.06, green: 0.09, blue: 0.14))
    }

    private var dashColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("In-Dash")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button(dashMode == "on" ? "Exit" : "Lock") { toggleDashLock() }
                    .font(.caption.bold())
            }
            modePicker
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    coordinatesBar(filled: true)
                    convoyPills
                    Text(nextTurnLine)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(3)
                    Text(cockpitSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    if let route = activeRoute {
                        routeCard(route)
                    } else {
                        fitBanner
                    }
                    savedMarkersCard
                    cockpitModeBody(includeFieldCards: false)
                    safetyLegalButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sheetGrabber: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.white.opacity(0.45))
                .frame(width: 48, height: 5)
                .padding(.top, 6)
                .accessibilityLabel("Drag to resize cockpit")
            HStack(spacing: 6) {
                ForEach(CockpitDetent.allCases) { item in
                    Button(item.rawValue) { detent = item }
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(detent == item ? Color.cyan : Color.white.opacity(0.12))
                        .foregroundColor(detent == item ? .black : .white)
                        .clipShape(Capsule())
                }
                Spacer(minLength: 4)
                Button(dashMode == "on" ? "In-Dash On" : "In-Dash") { toggleDashLock() }
                    .font(.caption2.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(dashMode == "on" ? Color.cyan : Color.white.opacity(0.12))
                    .foregroundColor(dashMode == "on" ? .black : .white)
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
        .gesture(sheetDrag)
    }

    private var sheetDrag: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                if value.translation.height > 42 {
                    detent = detent == .full ? .half : .peek
                } else if value.translation.height < -42 {
                    detent = detent == .peek ? .half : .full
                }
            }
    }

    private var safetyLegalButton: some View {
        Button {
            showSafetyDisclaimer = true
        } label: {
            Text("Safety & Legal Disclaimer / Terms of Use")
                .font(.caption.bold())
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .background(Color(red: 0.14, green: 0.10, blue: 0.04))
                .foregroundColor(Color(red: 1.0, green: 0.74, blue: 0.18))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Safety and legal disclaimer, terms of use")
    }

    private var safetyDisclaimerOverlay: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Safety, Assumption of Risk & Liability Disclaimer")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Read this before you use the map. TrailForge Overland is a reference tool from SE Media LLC (d/b/a Krokem Outdoors), Edward Shin, and their members, officers, affiliates, and licensors, not a survey, a land-agency decision, or a promise that a road is open or legal.")
                        .font(.caption)
                        .foregroundColor(Color(red: 0.83, green: 0.89, blue: 0.94))
                    safetyBlock(
                        "Informational Reference Only — No Guarantee of Map or Boundary Accuracy",
                        "Trail routes, difficulty ratings, GPX tracks, MVUM/USFS/BLM/State/Park land ownership masks, water crossings, SNOTEL snow depth, wildfire perimeters, 3D terrain pitch/slope shading, and clearance warnings are crowd and agency estimates for situational reference only. Map boundaries and routes may contain errors, omissions, or outdated data. Do not use them to decide legal property boundaries or whether a road is legal to drive."
                    )
                    privatePropertyBlock
                    safetyBlock(
                        "Assumption of Risk & Backcountry Responsibility",
                        "Off-road driving, overlanding, and backcountry travel can severely damage a vehicle, strand you, injure you, or kill you. You assume 100% of the risk of the route you choose and the travel you make. Verify road status with the local land manager, obey posted signs, gates, and seasonal closures, carry emergency satellite communication and recovery gear, and do not trespass."
                    )
                    safetyBlock(
                        "Do Not Operate While Driving",
                        "Do not touch map controls, plot a route, or open sheets while the vehicle is moving. Pull over in a safe place before you change a route or a setting."
                    )
                    safetyBlock(
                        "No Emergency, SOS, or Search-and-Rescue Service",
                        "TrailForge Overland is not an emergency beacon, a satellite SOS communicator, or a search-and-rescue dispatch service. Never rely on it as a life-safety device. Carry a dedicated satellite communicator, such as a Garmin inReach or Apple Emergency SOS via satellite, in the backcountry."
                    )
                    safetyBlock(
                        "Vehicle Clinometer, Clearance & Water/Snow Gauges",
                        "Device-sensor pitch and roll angles, vehicle-build clearance comparisons, obstacle crux ratings, and USGS and SNOTEL water and snow readings are uncalibrated informational estimates. They never guarantee rollover safety, vehicle clearance, or a safe water-crossing depth."
                    )
                    safetyBlock(
                        "\"AS IS\" No Warranty, Limitation of Liability & Indemnification",
                        "TrailForge Overland is provided by SE Media LLC (d/b/a Krokem Outdoors), Edward Shin, and their members, officers, affiliates, and licensors strictly \"AS IS\" and \"AS AVAILABLE,\" without warranties of any kind, express or implied. To the fullest extent permitted by law, SE Media LLC (d/b/a Krokem Outdoors), Edward Shin, and their members, officers, affiliates, and licensors are not liable for any direct, indirect, incidental, consequential, or special damages — including vehicle damage, towing or recovery costs, citations, fines, property damage, personal injury, or death — arising out of or related to your use of the app. Their total aggregate liability for any claim shall not exceed the greater of $0.00 USD or the amount you actually paid for the App in the twelve (12) months before the claim. You agree to indemnify and hold them harmless from claims arising from your backcountry travel."
                    )
                    safetyBlock(
                        "Dispute Resolution, Binding Individual Arbitration & Class-Action Waiver",
                        "All disputes arising out of these terms or the App shall be resolved exclusively by binding individual arbitration under the Federal Arbitration Act. You waive any right to participate in a class, collective, or representative action, and you waive any right to a jury trial. If a court finds any part of these terms unenforceable, the rest remains in effect."
                    )
                    Button {
                        safetyDisclaimerAccepted = true
                        safetyDisclaimerAcceptedAt = ISO8601DateFormatter().string(from: Date())
                        withAnimation(.easeOut(duration: 0.2)) {
                            showSafetyDisclaimer = false
                        }
                    } label: {
                        Text("I Understand & Agree — Enter TrailForge")
                            .font(.subheadline.bold())
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 10)
                            .background(Color(red: 0.24, green: 0.86, blue: 0.52))
                            .foregroundColor(Color(red: 0.02, green: 0.08, blue: 0.05))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Link("Terms of Use & Privacy Policy", destination: URL(string: "https://krokemoutdoors.github.io/trailforge-overland/#terms")!)
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
                .background(Color(red: 0.05, green: 0.08, blue: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(16)
            }
        }
        .zIndex(20)
    }

    private var privatePropertyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Private Property, Land Ownership & No Trespassing")
                .font(.caption.bold())
                .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.35))
            Text("You are 100% responsible for verifying that any trail, road, dispersed campsite, waypoint, or off-road area you enter is legally open to public motorized use and is not private property.")
            Text("BLM, USFS, NPS, State Trust, and other land-shading overlays are generalized agency datasets. They do not replace an official cadastral land survey. Public lands frequently contain unmarked private inholdings, patented mining claims, private ranch roads, locked gates, or roads with no legal public right-of-way or easement.")
            Text("Map lines, routed paths, and colored land masks never grant permission to cross private land or to bypass a gate, fence, “No Trespassing” sign, or seasonal closure. Signs and gates on the ground govern. When in doubt, turn around.")
            Text("SE Media LLC (d/b/a Krokem Outdoors), Edward Shin, and their members, officers, affiliates, and licensors are not responsible or liable for trespass claims, fines, citations, towing, impoundment, or legal disputes that result from entering private, restricted, or closed property.")
        }
        .font(.caption)
        .foregroundColor(Color(red: 0.83, green: 0.89, blue: 0.94))
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.55), lineWidth: 1))
    }

    private func safetyBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(Color(red: 1.0, green: 0.74, blue: 0.18))
            Text(body)
                .font(.caption)
                .foregroundColor(Color(red: 0.83, green: 0.89, blue: 0.94))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 6) {
            ForEach(CockpitMode.allCases, id: \.self) { item in
                Button {
                    mode = item
                    if detent == .peek {
                        detent = .half
                    }
                } label: {
                    Text(item.rawValue)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(mode == item ? Color.cyan : Color.white.opacity(0.12))
                        .foregroundColor(mode == item ? .black : .white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func cockpitModeBody(includeFieldCards: Bool) -> some View {
        if mode == .drive {
            driveControls(includeFieldCards: includeFieldCards)
        } else if mode == .camp {
            campList
        } else {
            rigPanel
        }
    }

    private var rigPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Stepper("Tires: \(Int(rigStore.profile.tireInches))\"", value: $rigStore.profile.tireInches, in: 29...37, step: 1)
                Toggle("Locker", isOn: $rigStore.profile.hasRearLocker)
                    .labelsHidden()
            }
            .font(.caption.bold())
            Toggle("Offline-First / No-Signal Simulation", isOn: $offlineFirst)
                .font(.caption.bold())
                .tint(.cyan)
            Button("TrailForge Pro") { showProPaywall = true }
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            Text(offlineFirst
                 ? "Offline-first is on. Cached trails, backcountry corridors, and rig-fit stay available with no cell signal."
                 : "Turn this on to keep navigation on the saved atlas, backcountry corridors, corridor packs, and rig-fit math when the radio is dark.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var layersDrawer: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { showLayers = false }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Map Layers")
                            .font(.headline)
                        Spacer()
                        Button("Close") { showLayers = false }
                            .font(.caption.bold())
                    }
                    Picker("Basemap", selection: $basemapRaw) {
                        ForEach(BasemapChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("3D Mode")
                        .font(.caption.bold())
                    Picker("3D Mode", selection: Binding(
                        get: { is3DMapsEnabled },
                        set: { set3DMode($0) }
                    )) {
                        Text("Off").tag(false)
                        Text("On").tag(true)
                    }
                    .pickerStyle(.segmented)
                    maskToggleButton("Rig-Fit Trail Lines", color: LandMask.slopeFlat, extra: [LandMask.slopeMid, LandMask.slopeSteep], value: $trailCorridorOpacity, onValue: 1.0, fill: false)
                    maskToggleButton("BLM Public Land", color: LandMask.blm, value: $blmMaskOpacity, onValue: 0.75)
                    maskToggleButton("USFS National Forest", color: LandMask.usfs, value: $usfsMaskOpacity, onValue: 0.75)
                    maskToggleButton("State Trust Land", color: LandMask.stateTrust, value: $stateMaskOpacity, onValue: 0.75)
                    Text("Land shading is approximate and not a legal survey. Always verify private property boundaries, easements, and posted signs on the ground—never trespass.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    maskToggleButton("<3° Slope Shading", color: LandMask.slopeFlat, extra: [LandMask.slopeMid, LandMask.slopeSteep], value: $campSlopeOpacity, onValue: 0.85)
                    maskToggleButton("Wildfires & Hazards", color: LandMask.slopeSteep, extra: [LandMask.slopeMid], value: $hazardOverlayOpacity, onValue: 0.85)
                    maskToggleButton("Cell & Starlink Sky", color: LandMask.cell, value: $starlinkOverlayOpacity, onValue: 0.80)
                    Toggle("🌡️ Thermal Saver", isOn: $thermalSaver)
                        .font(.caption.bold())
                    Toggle("🌙 Night Vision", isOn: $nightVision)
                        .font(.caption.bold())
                    Text(heatLimited
                         ? "Thermal Saver is on. Terrain stays flat and live hazard refreshes pause until you turn it off."
                         : "3D terrain stays on. Thermal Saver flattens elevation and pauses live hazard refreshes.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("NIFC perimeters and USGS quakes load when a signal is available. Fords and ledges stay on the cached route. Starlink shading uses each pad's sky view, not a live carrier map.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(" Maps • © OpenStreetMap contributors • USGS, USFS, BLM, and county GIS layers are public data. TrailForge is not affiliated with those agencies.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(USATrailAtlas.corridorDisclaimer)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(16)
            }
            .frame(maxWidth: 360)
            .background(.ultraThinMaterial)
        }
    }

    private var offlineDrawer: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Offline Maps")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Close") { showOffline = false }
                        .font(.caption.bold())
                }
                Text("Current Map View uses the exact bounds on screen. The 5-mile corridor follows the selected trail or active GPS route.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Saved on-device in TrailForge local storage (offline-ready, zero cell required)")
                    .font(.caption2)
                    .foregroundColor(.cyan)
                offlineAreaPicker
                Text(offlineEstimateLine)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.cyan)
                    .fixedSize(horizontal: false, vertical: true)
                if resolvedOfflineArea == "corridor" {
                    Picker("Pack", selection: $offlineTier) {
                        Text("Route + USFS snapshot").tag("Route + USFS snapshot")
                        Text("Route + hazards").tag("Route + hazards")
                    }
                    .pickerStyle(.segmented)
                }
                Button(downloadRunning ? "Saving offline pack…" : offlineDownloadTitle) {
                    downloadOffline()
                }
                .font(.headline)
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(downloadRunning)
                ProgressView(value: downloadRunning ? downloadProgress : (offlinePacks.isEmpty ? 0.0 : 1.0))
                    .tint(.cyan)
                if offlinePacks.isEmpty {
                    Text("No saved offline packs yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(offlinePacks) { pack in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.name)
                                    .font(.caption.bold())
                                    .lineLimit(2)
                                Text(pack.areaBadge)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(3)
                            }
                            Spacer(minLength: 8)
                            VStack(spacing: 6) {
                                if pack.minLat != nil {
                                    Button("Focus on Map") { focusPack(pack) }
                                        .font(.caption2.bold())
                                }
                                Button("Remove") { removePack(pack.id) }
                                    .font(.caption2.bold())
                            }
                        }
                    }
                }
            }
            .padding(16)
            }
            .frame(maxHeight: 520)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding()
        }
        .onAppear {
            if offlineArea != resolvedOfflineArea {
                offlineArea = "view"
            }
        }
    }

    private var offlineAreaPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AREA SIZE")
                .font(.caption2.bold())
                .foregroundColor(.secondary)
            ForEach(offlineAreaChoices, id: \.id) { choice in
                Button {
                    offlineArea = choice.id
                } label: {
                    Text(choice.title)
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(resolvedOfflineArea == choice.id ? Color.cyan : Color.white.opacity(0.12))
                        .foregroundColor(resolvedOfflineArea == choice.id ? .black : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var offlineAreaChoices: [(id: String, title: String)] {
        let viewMiles = Int(OfflineAreaBox.visible(visibleRegion).squareMiles.rounded())
        return [
            ("corridor", "5-Mi Route Corridor"),
            ("view", "Current Screen View (~\(viewMiles) sq mi)")
        ]
    }

    private var offlineDownloadTitle: String {
        guard resolvedOfflineArea == "view", let box = liveOfflineBox() else { return "Download 5-Mile Corridor" }
        return "Download Current Screen View (~\(Int(box.squareMiles.rounded())) sq mi)"
    }

    private var offlineEstimateLine: String {
        guard let box = liveOfflineBox() else {
            return "5-mile buffer along the selected trail or active GPS route. Route, camps, crux pins, and a USFS snapshot."
        }
        let zooms = offlineZooms(for: box)
        let tiles = OfflineAreaMath.tileCount(for: box, zooms: zooms)
        let trails = trailsInside(box).count
        let mb = max(4, tiles * 18 / 1024)
        let label = "Current Screen View (~\(Int(box.squareMiles.rounded())) sq mi)"
        return "\(label) · ~\(tiles) tiles · \(trails) trails · ~\(mb) MB"
    }

    private var savedOfflineRings: [[CLLocationCoordinate2D]] {
        guard showOffline || downloadRunning else { return [] }
        return offlinePacks.compactMap { pack in
            guard let minLat = pack.minLat, let maxLat = pack.maxLat, let minLon = pack.minLon, let maxLon = pack.maxLon else { return nil }
            return OfflineAreaBox(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon).ring
        }
    }

    private var elevationProfileCard: some View {
        let samples = rideSamples
        return VStack(alignment: .leading, spacing: 6) {
            Text("Elevation & Obstacles")
                .font(.caption.bold())
                .foregroundColor(.cyan)
            Text("High point is this route's listed peak. Drag to scrub the milepost on the map.")
                .font(.caption2)
                .foregroundColor(.secondary)
            if samples.count < 2 {
                Text("This route has no profile yet.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                GeometryReader { bar in
                    ZStack(alignment: .bottomLeading) {
                        profilePath(samples, size: bar.size)
                        ForEach(samples) { sample in
                            if let obstacle = sample.obstacle {
                                Text(obstacle)
                                    .font(.system(size: 9, weight: .bold))
                                    .position(x: profileX(sample, samples: samples, width: bar.size.width), y: 10)
                            }
                        }
                        if let profileIndex, samples.indices.contains(profileIndex) {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 2, height: bar.size.height)
                                .position(x: profileX(samples[profileIndex], samples: samples, width: bar.size.width), y: bar.size.height / 2)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let fraction = min(1, max(0, value.location.x / max(bar.size.width, 1)))
                                profileIndex = Int((fraction * Double(samples.count - 1)).rounded())
                            }
                    )
                }
                .frame(height: 72)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if let profileIndex, samples.indices.contains(profileIndex) {
                    let sample = samples[profileIndex]
                    Text(profileReadout(sample))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.white)
                } else {
                    Text("Drag the profile to scrub elevation, grade, and obstacles.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var legalBadge: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TrailLegal.badge(for: activeTrail))
                .font(.caption.bold())
                .foregroundColor(activeTrail.legalStatus == "osm" ? .orange : .green)
                .fixedSize(horizontal: false, vertical: true)
            if isBackcountryCorridor(activeTrail) {
                Text(USATrailAtlas.corridorDisclaimer)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let office = RangerDesk.office(for: activeTrail), let url = RangerDesk.telURL(office) {
                Button(RangerDesk.phoneLabel(office)) {
                    openURL(url)
                }
                .font(.caption.bold())
            } else if activeTrail.legalStatus == "mvum" || activeTrail.legalStatus == "blm" || activeTrail.legalStatus == "corridor" {
                Button("Look up the ranger district") {
                    if let url = URL(string: "https://www.fs.usda.gov/visit") {
                        openURL(url)
                    }
                }
                .font(.caption.bold())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pertinentCruxPins: [CruxPin] {
        var seenTrails = Set<String>()
        var seenPins = Set<String>()
        var pins: [CruxPin] = []
        for trail in mapTrails + USATrailAtlas.all + telemetry.discoveredTrails {
            guard seenTrails.insert(trail.id).inserted, trailIsNearContext(trail) else { continue }
            for pin in CruxCatalog.pins(for: trail) where cruxPinIsPertinent(pin) {
                if seenPins.insert(pin.id).inserted {
                    pins.append(pin)
                }
            }
        }
        return pins
    }

    private func trailIsNearContext(_ trail: OverlandTrail) -> Bool {
        if trailInView(trail) { return true }
        if meters(from: mapCenter, to: trail.centerCoordinate) <= 40_000 { return true }
        if let gps = locationTracker.userCoordinate, meters(from: gps, to: trail.centerCoordinate) <= 40_000 { return true }
        return false
    }

    private func cruxPinIsPertinent(_ pin: CruxPin) -> Bool {
        if coordinateInView(pin.coordinate) { return true }
        if meters(from: mapCenter, to: pin.coordinate) <= 40_000 { return true }
        if let gps = locationTracker.userCoordinate, meters(from: gps, to: pin.coordinate) <= 40_000 { return true }
        return false
    }

    @ViewBuilder
    private var cruxList: some View {
        let pins = pertinentCruxPins
        if !pins.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Crux Obstacles")
                    .font(.caption.bold())
                    .foregroundColor(.orange)
                ForEach(pins) { pin in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pin.title)
                            .font(.caption.bold())
                            .foregroundColor(.white)
                        Text(pin.detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tripShareRow: some View {
        HStack(spacing: 8) {
            ShareLink(item: tripShareText.isEmpty ? currentTripGPX : tripShareText) {
                Label("Share Trip Package (AirDrop / QR)", systemImage: "square.and.arrow.up")
                    .font(.caption.bold())
            }
            Button("QR") {
                tripShareText = currentTripGPX
                tripQRImage = TripPackageBuilder.qrImage(TripPackageBuilder.qrText(for: activeTrail, hazards: hazardPins))
                showTripQR = true
            }
            .font(.caption.bold())
        }
    }

    private var convoyPills: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(convoy.connectedPeers.isEmpty ? "Convoy mesh • no peers in range" : "Convoy • \(convoy.connectedPeers.joined(separator: ", "))")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ConvoyQuickStatus.allCases) { status in
                        Button(status.pill) { convoy.broadcast(status) }
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private var hazardSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drop Hazard Pin")
                .font(.headline)
            Text(locationTracker.userCoordinate.map { "MY GPS \(formatCoordinate($0)) • \(locationTracker.altitudeFt) ft" } ?? "Waiting for GPS")
                .font(.caption.monospacedDigit())
            Picker("Hazard", selection: $hazardCategory) {
                ForEach(HazardCatalog.categories, id: \.self) { item in
                    Text(item).tag(item)
                }
            }
            PhotosPicker(selection: $hazardPhotoItem, matching: .images) {
                Label(hazardPhoto == nil ? "Add Photo" : "Photo attached", systemImage: "photo")
            }
            .onChange(of: hazardPhotoItem) { _, item in
                guard let item else { return }
                Task {
                    hazardPhoto = try? await item.loadTransferable(type: Data.self)
                }
            }
            Button(hazardRecorder.isRecording ? "Recording 5 seconds…" : "🎙️ Record 5-second voice note") {
                recordHazardNote()
            }
            .disabled(hazardRecorder.isRecording)
            Button("Save pin at MY GPS") { saveHazardPin() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            Button("Close") { showHazardSheet = false }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.06, green: 0.08, blue: 0.1))
    }

    private var tripQRSheet: some View {
        VStack(spacing: 12) {
            Text(activeTrail.name)
                .font(.headline)
            Text("Scan at the trailhead. AirDrop sends the full GPX 1.1 package.")
                .font(.caption)
                .multilineTextAlignment(.center)
            if let tripQRImage {
                Image(uiImage: tripQRImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
            }
            ShareLink(item: tripShareText.isEmpty ? currentTripGPX : tripShareText) {
                Label("AirDrop / Share GPX", systemImage: "square.and.arrow.up")
            }
            Text(USATrailAtlas.corridorDisclaimer)
                .font(.caption2)
                .foregroundColor(.secondary)
            Button("Close") { showTripQR = false }
        }
        .padding(20)
    }

    private var trailReportBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Report Trail Status")
                .font(.caption.bold())
                .foregroundColor(.orange)
            Text(community.syncPill)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.1))
                .foregroundColor(.cyan)
                .clipShape(Capsule())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TrailReportStatus.allCases) { status in
                        Button(status.communityLabel) { logReport(status) }
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
            }
            ForEach(activeCommunityReports) { report in
                communityReportCard(report)
            }
            ForEach(activeCommunityHazards) { pin in
                communityHazardCard(pin)
            }
        }
    }

    private var activeCommunityReports: [TrailConditionReport] {
        reports
            .filter { $0.trailID == activeTrail.id }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var activeCommunityHazards: [DroppedHazard] {
        hazardPins
            .filter { pin in
                if pin.trailID == activeTrail.id { return true }
                guard pin.trailID.isEmpty else { return false }
                return meters(from: pin.coordinate, to: activeTrail.centerCoordinate) < 8_000
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func communityReportCard(_ report: TrailConditionReport) -> some View {
        let label = TrailReportStatus(rawValue: report.status)?.communityLabel ?? report.status
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(report.cleared ? "\(label) • re-opened" : label)
                    .font(.caption.bold())
                Spacer()
                Text(report.updatedAt, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button("👍 Confirm Still Here (\(report.confirmations))") {
                    community.confirmReport(report.id)
                    publishCommunity()
                }
                Button("✅ Mark Cleared / Re-Opened") {
                    community.clearReport(report.id)
                    publishCommunity()
                }
            }
            .font(.caption2.bold())
            .buttonStyle(.bordered)
            .tint(.cyan)
        }
        .padding(8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func communityHazardCard(_ pin: DroppedHazard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(pin.cleared ? "\(pin.category) • cleared" : pin.category)
                    .font(.caption.bold())
                Spacer()
                Text(pin.updatedAt, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button("👍 Confirm Still Here (\(pin.confirmations))") {
                    community.confirmHazard(pin.id)
                    publishCommunity()
                }
                Button("✅ Mark Cleared / Re-Opened") {
                    community.clearHazard(pin.id)
                    publishCommunity()
                }
            }
            .font(.caption2.bold())
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .padding(8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func publishCommunity() {
        reports = community.reports
        hazardPins = community.hazards
        convoy.sendCommunity(community.envelopeJSON())
    }

    private var plotterCard: some View {
        let fit = customRouteFit
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Custom Route")
                    .font(.caption.bold())
                    .foregroundColor(.cyan)
                Spacer()
                if !plotPoints.isEmpty {
                    Button("Undo Last") { undoLastPlotPoint() }
                        .font(.caption2.bold())
                    Button("Delete All Waypoints") {
                        plotPoints = []
                        segmentFreehand = []
                        plotClearedByUser = true
                        refreshPlotRoutes()
                    }
                    .font(.caption2.bold())
                    .foregroundColor(.red)
                }
            }
            HStack(spacing: 8) {
                Button("🧲 Snap to Trail") {
                    nextSegmentFreehand = false
                    straightSpur = false
                }
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .tint(nextSegmentFreehand ? .gray : .cyan)
                Button("✏️ Freehand / Wash Bridge") {
                    nextSegmentFreehand = true
                    straightSpur = true
                }
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .tint(nextSegmentFreehand ? .orange : .gray)
            }
            Text(nextSegmentFreehand ? "The next segment is a freehand wash or lakebed bridge." : "The next segment snaps to the selected trail when one is close.")
                .font(.caption2)
                .foregroundColor(.secondary)
            if savedMarkers.count >= 2 {
                Button("Connect Saved Waypoints") {
                    connectSavedWaypoints()
                }
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            Text(String(format: "%.1f mi • %d waypoints • %@", customRouteMiles, plotPoints.count, fit.verdict.rawValue))
                .font(.caption.bold())
                .foregroundColor(fit.verdict == .noGo ? .red : (fit.verdict == .caution ? .orange : .green))
            if !plotPoints.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(plotPoints.enumerated()), id: \.offset) { index, point in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Waypoint \(index + 1)")
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                Text(formatCoordinate(point))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button {
                                removePlotPoint(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.red)
                            .accessibilityLabel("Delete Waypoint \(index + 1)")
                        }
                    }
                }
            }
            if let note = fit.notes.first {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            ShareLink(item: currentGPX) {
                Label("Export / Share GPX 1.1", systemImage: "square.and.arrow.up")
                    .font(.caption.bold())
            }
            .disabled(plotPoints.count < 2)
            Button("Copy GPX 1.1") {
                UIPasteboard.general.string = currentGPX
                copiedToken = "gpx"
            }
            .font(.caption.bold())
            .disabled(plotPoints.count < 2)
            Button("Import sample GPX") { importGPX(GPXExchange.sample) }
                .font(.caption.bold())
            TextField("Paste GPX 1.1", text: $gpxDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Button("Import pasted GPX") { importGPX(gpxDraft) }
                .font(.caption.bold())
                .disabled(gpxDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func maskToggleButton(_ title: String, color: Color, extra: [Color] = [], value: Binding<Double>, onValue: Double, fill: Bool = true) -> some View {
        let active = value.wrappedValue > 0.02
        let filled = active && fill
        let ink = Color(red: 0.06, green: 0.12, blue: 0.04)
        return Button {
            value.wrappedValue = active ? 0 : onValue
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.35), lineWidth: 1))
                ForEach(Array(extra.enumerated()), id: \.offset) { _, swatch in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(swatch)
                        .frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.35), lineWidth: 1))
                }
                Text(title)
                    .font(.caption.bold())
                    .lineLimit(2)
                    .foregroundColor(filled ? ink : .white)
                Spacer(minLength: 8)
                Text(active ? "ON" : "OFF")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(filled ? Color.black.opacity(0.16) : color.opacity(0.22))
                    .foregroundColor(filled ? ink : color)
                    .clipShape(Capsule())
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(filled ? color : (active ? color.opacity(0.24) : Color.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? color : color.opacity(0.45), lineWidth: active ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var savedMarkersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Saved Markers / Waypoints")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                Spacer()
                if savedMarkers.count >= 2 {
                    Button("Connect Saved Waypoints") {
                        connectSavedWaypoints()
                    }
                    .font(.caption2.bold())
                    .foregroundColor(.orange)
                    Button("Delete All") { deleteAllMarkers() }
                        .font(.caption2.bold())
                        .foregroundColor(.red)
                }
            }
            if savedMarkers.isEmpty {
                Text("Tap and hold the map to drop a pin, then save it.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            ForEach(savedMarkers) { marker in
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        if plotMode {
                            addPlotPoint(marker.coordinate)
                        } else {
                            leaveFullDetent()
                            editingMarker = marker
                            pinName = marker.name
                            pinCategory = marker.category
                        }
                    } label: {
                        HStack {
                            Text(markerSymbol(marker.category))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(marker.name)
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                Text("\(marker.category) · \(formatCoordinate(marker.coordinate))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                        }
                    }
                    .buttonStyle(.plain)
                    Button {
                        deleteMarker(marker)
                    } label: {
                        Label("Delete Waypoint", systemImage: "trash")
                            .font(.caption2.bold())
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statPill(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption2.monospacedDigit().bold())
                .foregroundColor(.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.cyan.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func droppedPinSheet(_ pin: DroppedPinTarget) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(formatCoordinate(pin.coordinate))
                    .font(.headline.monospacedDigit())
                Text(pinSummary)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("Marker name", text: $pinName)
                    .textFieldStyle(.roundedBorder)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(markerCategories, id: \.self) { category in
                            Button(category) { pinCategory = category }
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(pinCategory == category ? Color.cyan : Color.white.opacity(0.12))
                                .foregroundColor(pinCategory == category ? .black : .white)
                                .clipShape(Capsule())
                        }
                    }
                }
                Button("Route Here (GPS Destination)") {
                    startRouting(toTitle: pinName.isEmpty ? "Dropped Pin" : pinName, coordinate: pin.coordinate)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                Button("Save Marker") { saveDroppedPin() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                HStack {
                    Link("Apple Maps", destination: URL(string: "http://maps.apple.com/?daddr=\(pin.latitude),\(pin.longitude)&dirflg=d")!)
                    Link("Google Maps", destination: URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(pin.latitude),\(pin.longitude)&travelmode=driving")!)
                }
                .font(.caption.bold())
                Spacer()
            }
            .padding(16)
            .navigationTitle("Dropped Pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { droppedPin = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func savedMarkerSheet(_ marker: SavedMarker) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(formatCoordinate(marker.coordinate))
                    .font(.headline.monospacedDigit())
                TextField("Name", text: $pinName)
                    .textFieldStyle(.roundedBorder)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(markerCategories, id: \.self) { category in
                            Button(category) { pinCategory = category }
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(pinCategory == category ? Color.cyan : Color.white.opacity(0.12))
                                .foregroundColor(pinCategory == category ? .black : .white)
                                .clipShape(Capsule())
                        }
                    }
                }
                Button("Route Here (GPS)") {
                    startRouting(toTitle: pinName.isEmpty ? marker.name : pinName, coordinate: marker.coordinate)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                Button("Rename") { renameMarker(marker) }
                    .buttonStyle(.bordered)
                ShareLink(item: markerShareURL(marker), preview: SharePreview(marker.name)) {
                    Label("Share Coordinates/GPX", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    deleteMarker(marker)
                } label: {
                    Label("Delete Waypoint", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Spacer()
            }
            .padding(16)
            .navigationTitle(marker.category)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { editingMarker = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func handleMapLongPress(_ coordinate: CLLocationCoordinate2D) {
        let now = Date()
        guard now.timeIntervalSince(lastMapLongPress) > 0.8 else { return }
        lastMapLongPress = now
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let pin = DroppedPinTarget(id: UUID(), latitude: coordinate.latitude, longitude: coordinate.longitude)
        leaveFullDetent()
        droppedPin = pin
        pinCategory = "Waypoint"
        pinName = "Saved Pin \(savedMarkers.count + 1)"
        pinSummary = "Looking up this point…"
        Task {
            let place = await ReversePlace.lookup(coordinate)
            guard droppedPin?.id == pin.id else { return }
            if let place, !place.isEmpty {
                if pinSummary.hasPrefix("Looking") {
                    pinSummary = place
                } else if !pinSummary.contains(place) {
                    pinSummary = "\(place) · \(pinSummary)"
                }
                if pinName.hasPrefix("Saved Pin") { pinName = place }
            } else if pinSummary.hasPrefix("Looking") {
                pinSummary = formatCoordinate(coordinate)
            }
        }
    }

    private func startRouting(toTitle title: String, coordinate: CLLocationCoordinate2D) {
        let spot = CampSpot(
            id: "pin-\(UUID().uuidString)",
            trailID: activeTrail.id,
            name: title,
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            slopeDeg: 0,
            starlinkPct: 0,
            kind: .trailhead
        )
        droppedPin = nil
        editingMarker = nil
        Task { await beginRoute(to: spot) }
    }

    private func saveDroppedPin() {
        guard let pin = droppedPin else { return }
        let trimmed = pinName.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = SavedMarker(
            id: UUID(),
            name: trimmed.isEmpty ? "Saved Pin \(savedMarkers.count + 1)" : trimmed,
            category: pinCategory,
            latitude: pin.latitude,
            longitude: pin.longitude,
            createdAt: Date()
        )
        savedMarkers.insert(marker, at: 0)
        plotClearedByUser = false
        CockpitStore.saveSavedMarkers(savedMarkers)
        droppedPin = nil
    }

    private func renameMarker(_ marker: SavedMarker) {
        guard let index = savedMarkers.firstIndex(where: { $0.id == marker.id }) else { return }
        let trimmed = pinName.trimmingCharacters(in: .whitespacesAndNewlines)
        savedMarkers[index].name = trimmed.isEmpty ? marker.name : trimmed
        savedMarkers[index].category = pinCategory
        CockpitStore.saveSavedMarkers(savedMarkers)
        editingMarker = savedMarkers[index]
    }

    private func deleteMarker(_ marker: SavedMarker) {
        savedMarkers.removeAll { $0.id == marker.id }
        CockpitStore.saveSavedMarkers(savedMarkers)
        editingMarker = nil
    }

    private func deleteAllMarkers() {
        savedMarkers = []
        CockpitStore.saveSavedMarkers(savedMarkers)
        editingMarker = nil
    }

    private func markerSymbol(_ category: String) -> String {
        switch category {
        case "Camp": return "⛺"
        case "Trailhead": return "⚑"
        case "Hazard": return "⚠"
        case "Viewpoint": return "👁"
        default: return "📍"
        }
    }

    private func markerShareURL(_ marker: SavedMarker) -> URL {
        let safe = marker.name.replacingOccurrences(of: "&", with: "and").replacingOccurrences(of: "<", with: "")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="TrailForge Overland" xmlns="http://www.topografix.com/GPX/1/1">
          <wpt lat="\(String(format: "%.6f", marker.latitude))" lon="\(String(format: "%.6f", marker.longitude))">
            <name>\(safe)</name>
            <type>\(marker.category)</type>
            <desc>\(formatCoordinate(marker.coordinate))</desc>
          </wpt>
        </gpx>
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TrailForge-marker-\(marker.id.uuidString).gpx")
        try? xml.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private func railButton(_ system: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 19, weight: .bold))
                .frame(width: 44, height: 44)
                .background(active ? Color.cyan : Color.black.opacity(0.78))
                .foregroundColor(active ? .black : .white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func gloveButton(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: system)
                    .font(.title3.bold())
                Text(title)
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(Color.black.opacity(0.78))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func profilePath(_ samples: [RideSample], size: CGSize) -> some View {
        let elevations = samples.map { Double($0.elevationFt) }
        let low = elevations.min() ?? 0
        let high = max((elevations.max() ?? 1), low + 1)
        return Path { path in
            for (index, sample) in samples.enumerated() {
                let x = profileX(sample, samples: samples, width: size.width)
                let y = size.height - 8 - CGFloat((Double(sample.elevationFt) - low) / (high - low)) * (size.height - 20)
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        .stroke(Color.cyan, lineWidth: 2)
    }

    private func profileX(_ sample: RideSample, samples: [RideSample], width: CGFloat) -> CGFloat {
        guard let last = samples.last, last.mile > 0 else { return width / 2 }
        return CGFloat(sample.mile / last.mile) * width
    }

    private func profileReadout(_ sample: RideSample) -> String {
        var text = String(format: "Mile %.1f • %d ft • %.0f%% grade", sample.mile, sample.elevationFt, sample.gradePct)
        if let obstacle = sample.obstacle {
            text += " • \(obstacle)"
        }
        return text
    }

    private var nextTurnLine: String {
        if let route = activeRoute, !isRouteConfirmed {
            return "Previewing Route to \(route.destination.name)"
        }
        guard let route = activeRoute, !route.displaySteps.isEmpty else { return "Next turn • no active route" }
        let index = min(activeStepIndex, route.displaySteps.count - 1)
        let step = route.displaySteps[index]
        return "Next turn • \(step.instruction)"
    }

    private var currentGPX: String {
        let waypoints = plotPoints.enumerated().map { index, point in
            GPXWaypoint(
                id: UUID(),
                name: "Waypoint \(index + 1)",
                latitude: point.latitude,
                longitude: point.longitude,
                elevationMeters: 0,
                slopeDegrees: 0,
                starlinkSkyPct: 0,
                sym: "Flag"
            )
        }
        return GPXTrackManager().exportGPXString(
            trailName: "TrailForge \(activeTrail.name)",
            waypoints: waypoints,
            track: plottedLine
        )
    }

    private func toggleDashLock() {
        dashMode = dashMode == "on" ? "off" : "on"
    }

    private func cycleCameraMode() {
        followHeading.toggle()
        if followHeading {
            pushCamera(userTrackingCamera(followsHeading: true))
        } else {
            followRoute = false
            pushCamera(userTrackingCamera(followsHeading: false))
        }
    }

    private func recenterGPS() {
        followHeading = false
        followRoute = false
        showingRouteOverview = false
        pushCamera(userTrackingCamera(followsHeading: false))
    }

    private func togglePlotter() {
        plotMode.toggle()
        if plotMode {
            leaveFullDetent()
            if detent == .peek { detent = .half }
            if !plotClearedByUser, plotPoints.count < 2, savedWaypointCoordinates().count >= 2 {
                connectSavedWaypoints()
            }
        }
    }

    private func savedWaypointCoordinates() -> [CLLocationCoordinate2D] {
        let center = visibleRegion.center
        let limit = 50 * 1609.344
        let near = savedMarkers.filter { marker in
            meters(from: center, to: marker.coordinate) <= limit
        }
        return near.sorted { $0.createdAt < $1.createdAt }.map(\.coordinate)
    }

    private func connectSavedWaypoints() {
        plotClearedByUser = false
        let coordinates = savedWaypointCoordinates()
        plotMode = true
        leaveFullDetent()
        if detent == .peek { detent = .half }
        guard coordinates.count >= 2 else { return }
        plotPoints = coordinates
        segmentFreehand = Array(repeating: nextSegmentFreehand, count: max(0, coordinates.count - 1))
        refreshPlotRoutes()
    }

    private func addPlotPoint(_ coordinate: CLLocationCoordinate2D) {
        let snapped: CLLocationCoordinate2D
        if straightSpur {
            snapped = coordinate
        } else if let nearest = closestCoordinate(on: activeTrail.coordinates, to: coordinate),
                  meters(from: nearest, to: coordinate) < 500 {
            snapped = nearest
        } else {
            snapped = coordinate
        }
        if !plotPoints.isEmpty {
            segmentFreehand.append(nextSegmentFreehand)
        }
        plotPoints.append(snapped)
        refreshPlotRoutes()
    }

    private func undoLastPlotPoint() {
        guard !plotPoints.isEmpty else { return }
        removePlotPoint(at: plotPoints.count - 1)
    }

    private func removePlotPoint(at index: Int) {
        guard plotPoints.indices.contains(index) else { return }
        plotPoints.remove(at: index)
        if index == 0 {
            if !segmentFreehand.isEmpty { segmentFreehand.removeFirst() }
        } else if index - 1 < segmentFreehand.count {
            segmentFreehand.remove(at: index - 1)
        }
        let keep = max(0, plotPoints.count - 1)
        if segmentFreehand.count > keep {
            segmentFreehand = Array(segmentFreehand.prefix(keep))
        }
        refreshPlotRoutes()
    }

    private func refreshPlotRoutes() {
        plotRouteFetchToken += 1
        let token = plotRouteFetchToken
        var cache: [String: [CLLocationCoordinate2D]] = [:]
        var pending: [(key: String, start: CLLocationCoordinate2D, end: CLLocationCoordinate2D)] = []
        if plotPoints.count >= 2 {
            let directTrails = plotCandidateTrails
            for index in 1..<plotPoints.count {
                let start = plotPoints[index - 1]
                let end = plotPoints[index]
                let key = plotSegmentKey(start, end)
                let freehand = segmentFreehand.indices.contains(index - 1) ? segmentFreehand[index - 1] : straightSpur
                if freehand {
                    cache[key] = [start, end]
                    continue
                }
                let slice = bestTrailSlice(from: start, to: end, trails: directTrails)
                if slice.count >= 3 {
                    cache[key] = slice
                    continue
                }
                if let existing = plotSegmentRoutes[key], existing.count >= 3, !isStraightCrowLine(existing) {
                    cache[key] = existing
                    continue
                }
                cache[key] = slice.count >= 2 ? slice : [start, end]
                pending.append((key, start, end))
            }
        }
        plotSegmentRoutes = cache
        guard !pending.isEmpty else { return }
        Task { @MainActor in
            for item in pending {
                if token != plotRouteFetchToken { return }
                let road = await plotRoadGeometry(from: item.start, to: item.end)
                if token != plotRouteFetchToken { return }
                guard let road, road.count >= 2, !isStraightCrowLine(road) else { continue }
                var updated = plotSegmentRoutes
                updated[item.key] = road
                plotSegmentRoutes = updated
            }
        }
    }

    private var plotCandidateTrails: [OverlandTrail] {
        var seen = Set<String>()
        var trails: [OverlandTrail] = []
        for trail in [activeTrail] + USATrailAtlas.all + telemetry.discoveredTrails {
            if seen.insert(trail.id).inserted {
                trails.append(trail)
            }
        }
        return trails
    }

    private func bestTrailSlice(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, trails: [OverlandTrail]) -> [CLLocationCoordinate2D] {
        let direct = max(meters(from: start, to: end), 1)
        var options: [(closeness: Double, line: [CLLocationCoordinate2D])] = []
        for trail in trails {
            let coordinates = trail.coordinates
            guard coordinates.count >= 2, trailBoxContains(coordinates, start, end, limitMeters: 1_200) else { continue }
            guard let projected = projectedTrailSlice(from: start, to: end, trail: coordinates, maxDistance: 1_200) else { continue }
            let length = polylineMeters(projected.line)
            guard length <= direct * 8 else { continue }
            options.append((projected.closeness, projected.line))
        }
        options.sort { $0.closeness < $1.closeness }
        return options.first?.line ?? []
    }

    private func cappedPlot(_ line: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        line.count > 800 ? simplifyCoordinates(line, maxPoints: 800, minMeters: 8) : line
    }

    private func importGPX(_ xml: String) {
        let coordinates = GPXExchange.coordinates(in: xml)
        guard !coordinates.isEmpty else { return }
        plotPoints = coordinates
        segmentFreehand = Array(repeating: false, count: max(0, coordinates.count - 1))
        nextSegmentFreehand = false
        straightSpur = false
        plotMode = true
        refreshPlotRoutes()
        if detent == .peek { detent = .half }
    }

    private func logReport(_ status: TrailReportStatus) {
        let coordinate = locationTracker.userCoordinate ?? activeTrail.centerCoordinate
        community.submitReport(TrailConditionReport(
            id: UUID().uuidString,
            trailID: activeTrail.id,
            status: status.rawValue,
            createdAt: Date(),
            queuedOffline: offlineFirst || !community.online,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ))
        publishCommunity()
    }

    private func downloadOffline() {
        if let box = liveOfflineBox() {
            downloadArea(box)
        } else {
            downloadCorridor()
        }
    }

    private func downloadCorridor() {
        guard !downloadRunning else { return }
        downloadRunning = true
        downloadProgress = 0.15
        let tier = offlineTier
        let trail = activeTrail
        let track = activeRoute?.selected.road ?? trail.coordinates
        let hazards = tier.contains("hazard") ? hazardPins : []
        CorridorDownloader.shared.start(trail: trail, track: track, hazards: hazards, tier: tier) { pack in
            var packs = CockpitStore.loadPacks()
            packs.insert(pack, at: 0)
            CockpitStore.savePacks(packs)
            offlinePacks = packs
            downloadProgress = 1
            downloadRunning = false
        }
    }

    private func downloadArea(_ box: OfflineAreaBox) {
        guard !downloadRunning else { return }
        downloadRunning = true
        downloadProgress = 0.2
        let satellite = basemap != .standard
        let miles = Int(box.squareMiles.rounded())
        let preset = miles
        let label = "Current Screen View (~\(miles) sq mi)"
        let tier = (satellite ? "Satellite" : "Topo") + " + Trails"
        let spec = OfflineAreaDownload(
            box: box,
            areaSqMiles: preset,
            label: label,
            satellite: satellite,
            trails: trailsInside(box),
            hazards: mapHazards.filter { box.contains($0.point) },
            dropped: hazardPins.filter { box.contains($0.coordinate) }
        )
        CorridorDownloader.shared.start(trail: activeTrail, track: activeTrail.coordinates, hazards: spec.dropped, tier: tier, area: spec) { pack in
            var packs = CockpitStore.loadPacks()
            packs.insert(pack, at: 0)
            CockpitStore.savePacks(Array(packs.prefix(12)))
            offlinePacks = Array(packs.prefix(12))
            downloadProgress = 1
            downloadRunning = false
        }
    }

    private func liveOfflineBox() -> OfflineAreaBox? {
        guard showOffline || downloadRunning else { return nil }
        switch resolvedOfflineArea {
        case "view":
            return .visible(visibleRegion)
        default:
            return nil
        }
    }

    private func offlineZooms(for box: OfflineAreaBox) -> [Int] {
        if box.squareMiles <= 45 { return [11, 12, 13, 14, 15] }
        return [11, 12, 13, 14]
    }

    private func trailsInside(_ box: OfflineAreaBox) -> [OverlandTrail] {
        Array(USATrailAtlas.all.filter { trail in
            box.contains(trail.centerCoordinate) || trail.coordinates.contains(where: box.contains)
        }.prefix(40))
    }

    private func trackScreen(_ region: MKCoordinateRegion) {
        let moved = meters(from: screenCenter, to: region.center)
        screenCenter = region.center
        visibleRegion = region
        if moved > 40 {
            mapCenter = region.center
        }
        if !offlineFirst {
            telemetry.scheduleTrailRefresh(around: region.center)
        }
    }

    private func focusPack(_ pack: OfflineCorridorPack) {
        guard let minLat = pack.minLat, let maxLat = pack.maxLat, let minLon = pack.minLon, let maxLon = pack.maxLon else { return }
        let box = OfflineAreaBox(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
        showOffline = false
        screenCenter = box.center
        visibleRegion = box.region
        pushCamera(regionCamera(center: box.region.center, span: box.region.span))
    }

    private func removePack(_ id: String) {
        offlinePacks.removeAll { $0.id == id }
        CockpitStore.savePacks(offlinePacks)
    }

    private func refreshHazards(around coordinate: CLLocationCoordinate2D) {
        guard hazardOverlayOpacity > 0.02, !offlineFirst, !heatLimited else { return }
        if let lastHazardFetch, meters(from: lastHazardFetch, to: coordinate) < 2_000 { return }
        lastHazardFetch = coordinate
        Task {
            remoteHazards = Array(await TrailHazards.fetchRemote(near: coordinate).prefix(8))
        }
    }

    private func mapButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.bold())
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 230, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
        }
    }
}

@MainActor
private final class CameraGate: ObservableObject {
    var followRoute = false
    var showingRouteOverview = false
    var ignoreFollowDisengageUntil = Date.distantPast
    var followSpan = 0.012
    var overviewSpan = 0.25
    var userLatitude: Double?
    var userLongitude: Double?
}

private enum PlaceLookup {
    static func prefersNationwide(_ query: String) -> Bool {
        if query.contains(",") { return true }
        if query.range(of: #"\b\d{5}(?:-\d{4})?\b"#, options: .regularExpression) != nil { return true }
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        if let last = tokens.last, last.count == 2, stateCodes.contains(last.uppercased()) {
            return true
        }
        let lower = query.lowercased()
        return stateNames.contains { lower.contains($0) }
    }

    static func fetch(query: String, near: CLLocationCoordinate2D, user: CLLocationCoordinate2D?, nationwide: Bool) async -> [PlaceHit] {
        let mapHits = await mapKitHits(query: query, near: near, nationwide: nationwide)
        let resolved = mapHits.isEmpty ? await geocoderHits(query: query) : mapHits
        let hits = resolved.isEmpty ? await nominatimHits(query: query) : resolved
        return Array(ranked(hits, user: user).prefix(6))
    }

    private static func mapKitHits(query: String, near: CLLocationCoordinate2D, nationwide: Bool) async -> [PlaceHit] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if !nationwide {
            request.region = MKCoordinateRegion(
                center: near,
                span: MKCoordinateSpan(latitudeDelta: 1.4, longitudeDelta: 1.4)
            )
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.enumerated().compactMap { index, item in
                let placemark = item.placemark
                let coordinate = placemark.coordinate
                guard abs(coordinate.latitude) > 0.01 || abs(coordinate.longitude) > 0.01 else { return nil }
                let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
                let cityLine = [placemark.locality, placemark.administrativeArea, placemark.postalCode].compactMap { $0 }.joined(separator: " ")
                let address = [street, cityLine].filter { !$0.isEmpty }.joined(separator: ", ")
                let name = item.name ?? placemark.name ?? (address.isEmpty ? "Place" : address)
                return PlaceHit(
                    id: "mapkit-\(index)-\(String(format: "%.4f-%.4f", coordinate.latitude, coordinate.longitude))",
                    name: name,
                    address: address.isEmpty ? name : address,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            }
        } catch {
            return []
        }
    }

    private static func geocoderHits(query: String) async -> [PlaceHit] {
        do {
            let marks = try await CLGeocoder().geocodeAddressString(query)
            return marks.enumerated().compactMap { index, placemark in
                guard let coordinate = placemark.location?.coordinate else { return nil }
                let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
                let cityLine = [placemark.locality, placemark.administrativeArea, placemark.postalCode].compactMap { $0 }.joined(separator: " ")
                let address = [street, cityLine].filter { !$0.isEmpty }.joined(separator: ", ")
                let name = placemark.name ?? (address.isEmpty ? query : address)
                return PlaceHit(
                    id: "geo-\(index)-\(String(format: "%.4f-%.4f", coordinate.latitude, coordinate.longitude))",
                    name: name,
                    address: address.isEmpty ? name : address,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            }
        } catch {
            return []
        }
    }

    private static func nominatimHits(query: String) async -> [PlaceHit] {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "limit", value: "6"),
            URLQueryItem(name: "countrycodes", value: "us"),
            URLQueryItem(name: "q", value: query)
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("TrailForgeOverland/1.0 (address search)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return rows.enumerated().compactMap { index, row in
                guard let lat = doubleValue(row["lat"]), let lon = doubleValue(row["lon"]) else { return nil }
                let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let display = (row["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = (name?.isEmpty == false ? name! : display.components(separatedBy: ",").first) ?? query
                return PlaceHit(
                    id: "osm-\(index)-\(String(format: "%.4f-%.4f", lat, lon))",
                    name: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    address: display.isEmpty ? title : display,
                    latitude: lat,
                    longitude: lon
                )
            }
        } catch {
            return []
        }
    }

    private static func ranked(_ hits: [PlaceHit], user: CLLocationCoordinate2D?) -> [PlaceHit] {
        var unique: [PlaceHit] = []
        for hit in hits {
            let duplicate = unique.contains { existing in
                abs(existing.latitude - hit.latitude) < 0.0015 && abs(existing.longitude - hit.longitude) < 0.0015
            }
            if !duplicate { unique.append(hit) }
        }
        guard let user else { return unique }
        return unique.sorted { lhs, rhs in
            CLLocation(latitude: user.latitude, longitude: user.longitude).distance(
                from: CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            ) < CLLocation(latitude: user.latitude, longitude: user.longitude).distance(
                from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
            )
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static let stateCodes: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS",
        "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY",
        "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV",
        "WI", "WY", "DC"
    ]

    private static let stateNames = [
        "alabama", "alaska", "arizona", "arkansas", "california", "colorado", "connecticut", "delaware",
        "florida", "georgia", "hawaii", "idaho", "illinois", "indiana", "iowa", "kansas", "kentucky",
        "louisiana", "maine", "maryland", "massachusetts", "michigan", "minnesota", "mississippi",
        "missouri", "montana", "nebraska", "nevada", "new hampshire", "new jersey", "new mexico",
        "new york", "north carolina", "north dakota", "ohio", "oklahoma", "oregon", "pennsylvania",
        "rhode island", "south carolina", "south dakota", "tennessee", "texas", "utah", "vermont",
        "virginia", "washington", "west virginia", "wisconsin", "wyoming"
    ]
}

struct LandMaskRing: Identifiable, Equatable {
    let id: String
    let kind: String
    let coordinates: [CLLocationCoordinate2D]

    static func == (lhs: LandMaskRing, rhs: LandMaskRing) -> Bool { lhs.id == rhs.id }
}

private enum LandViewportQuery {
    static func fetch(region: MKCoordinateRegion, blm: Double, usfs: Double, state: Double) async -> [LandMaskRing] {
        let wanted = [("blm", 22, blm), ("usfs", 24, usfs), ("state", 29, state)].filter { $0.2 > 0.02 }
        if wanted.isEmpty { return [] }
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2
        return await withTaskGroup(of: [LandMaskRing].self) { group in
            for item in wanted {
                group.addTask {
                    await load(kind: item.0, layer: item.1, minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat)
                }
            }
            var rings: [LandMaskRing] = []
            for await batch in group { rings.append(contentsOf: batch) }
            return rings
        }
    }

    static func contains(_ ring: LandMaskRing, _ point: CLLocationCoordinate2D) -> Bool {
        let coords = ring.coordinates
        guard coords.count >= 3 else { return false }
        var inside = false
        var previous = coords.count - 1
        for index in coords.indices {
            let yi = coords[index].latitude
            let xi = coords[index].longitude
            let yj = coords[previous].latitude
            let xj = coords[previous].longitude
            let crosses = (yi > point.latitude) != (yj > point.latitude)
            if crosses {
                let x = (xj - xi) * (point.latitude - yi) / ((yj - yi) == 0 ? 1e-12 : (yj - yi)) + xi
                if point.longitude < x { inside.toggle() }
            }
            previous = index
        }
        return inside
    }

    private struct Query: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable { let rings: [[[Double]]]? }
            let geometry: Geometry?
        }
        let features: [Feature]?
    }

    private static func load(kind: String, layer: Int, minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) async -> [LandMaskRing] {
        let geometry = "\(minLon),\(minLat),\(maxLon),\(maxLat)"
        var parts = URLComponents(string: "https://gis.blm.gov/arcgis/rest/services/lands/BLM_Natl_SMA_LimitedScale/MapServer/\(layer)/query")
        parts?.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "geometry", value: geometry),
            URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "maxAllowableOffset", value: "0.002"),
            URLQueryItem(name: "f", value: "json")
        ]
        guard let url = parts?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let query = try? JSONDecoder().decode(Query.self, from: data) else { return [] }
        var ranked: [(area: Double, coordinates: [CLLocationCoordinate2D])] = []
        for feature in query.features ?? [] {
            for ring in feature.geometry?.rings ?? [] {
                guard ring.count >= 3 else { continue }
                var west = Double.greatestFiniteMagnitude
                var east = -Double.greatestFiniteMagnitude
                var south = Double.greatestFiniteMagnitude
                var north = -Double.greatestFiniteMagnitude
                var coordinates: [CLLocationCoordinate2D] = []
                coordinates.reserveCapacity(ring.count)
                for pair in ring where pair.count >= 2 {
                    let lon = pair[0]
                    let lat = pair[1]
                    west = min(west, lon)
                    east = max(east, lon)
                    south = min(south, lat)
                    north = max(north, lat)
                    coordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                }
                guard coordinates.count >= 3 else { continue }
                let hits = east >= minLon && west <= maxLon && north >= minLat && south <= maxLat
                guard hits else { continue }
                ranked.append((area: max(0, east - west) * max(0, north - south), coordinates: downsample(coordinates)))
            }
        }
        ranked.sort { $0.area > $1.area }
        return ranked.prefix(40).enumerated().map { index, item in
            LandMaskRing(id: "\(kind)-\(index)", kind: kind, coordinates: item.coordinates)
        }
    }

    private static func downsample(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 80 else { return coordinates }
        let step = Int((Double(coordinates.count) / 80).rounded(.up))
        var reduced: [CLLocationCoordinate2D] = []
        var index = 0
        while index < coordinates.count {
            reduced.append(coordinates[index])
            index += step
        }
        if let first = coordinates.first, let last = reduced.last, first.latitude != last.latitude || first.longitude != last.longitude {
            reduced.append(first)
        }
        return reduced
    }
}

enum LandMask {
    static let blm = Color(red: 245.0 / 255, green: 230.0 / 255, blue: 66.0 / 255)
    static let usfs = Color(red: 20.0 / 255, green: 145.0 / 255, blue: 90.0 / 255)
    static let stateTrust = Color(red: 56.0 / 255, green: 189.0 / 255, blue: 248.0 / 255)
    static let slopeFlat = Color(red: 61.0 / 255, green: 220.0 / 255, blue: 132.0 / 255)
    static let slopeMid = Color(red: 255.0 / 255, green: 159.0 / 255, blue: 26.0 / 255)
    static let slopeSteep = Color(red: 255.0 / 255, green: 77.0 / 255, blue: 77.0 / 255)
    static let cell = Color(red: 62.0 / 255, green: 203.0 / 255, blue: 255.0 / 255)
}

private struct StableRouteMap: View, Equatable {
    @Binding var cameraPosition: MapCameraPosition
    var sceneToken: Int
    var cameraCommand: Int
    var showAlternates: Bool
    var routeStartedFromGPS: Bool
    var routingActive: Bool
    var selectedTrailID: String
    var trails: [OverlandTrail]
    var cruxPins: [CruxPin]
    var trailColors: [String: Color]
    var selectedTrailLine: [CLLocationCoordinate2D]
    var camps: [CampSpot]
    var route: ActiveCampRoute?
    var plotMode: Bool
    var basemap: BasemapChoice
    var flatBasemap: Bool
    var trailOpacity: Double
    var landRings: [LandMaskRing]
    var blmOpacity: Double
    var usfsOpacity: Double
    var stateOpacity: Double
    var campSlopeOpacity: Double
    var hazardOpacity: Double
    var starlinkOpacity: Double
    var hazards: [MapHazard]
    var searchedPlace: PlaceHit?
    var plotLine: [CLLocationCoordinate2D]
    var plotMarkers: [CLLocationCoordinate2D]
    var savedMarkers: [SavedMarker]
    var droppedPin: CLLocationCoordinate2D?
    var scrub: CLLocationCoordinate2D?
    var liveOfflineRing: [CLLocationCoordinate2D]
    var savedOfflineRings: [[CLLocationCoordinate2D]]
    var onCameraEnd: (MKCoordinateRegion) -> Void
    var onCameraPreview: (MKCoordinateRegion) -> Void
    var onSpot: (CampSpot) -> Void
    var onInspect: (CLLocationCoordinate2D) -> Void
    var onLongPress: (CLLocationCoordinate2D) -> Void
    var onMapCamera: (MapCamera) -> Void = { _ in }
    var fingerPitch: Double = 0
    var fingerPitchEnabled: Bool = false
    var horizonAssist: Double = 0
    var onFingerPitch: (Double, Bool) -> Void = { _, _ in }
    var showsUserLocationButton: Bool = false
    var onSelectMarker: (UUID) -> Void
    var onDeletePlotPoint: (Int) -> Void

    static func == (lhs: StableRouteMap, rhs: StableRouteMap) -> Bool {
        lhs.sceneToken == rhs.sceneToken
            && lhs.cameraCommand == rhs.cameraCommand
            && lhs.showAlternates == rhs.showAlternates
            && lhs.routeStartedFromGPS == rhs.routeStartedFromGPS
            && lhs.routingActive == rhs.routingActive
            && lhs.basemap == rhs.basemap
            && lhs.flatBasemap == rhs.flatBasemap
            && lhs.showsUserLocationButton == rhs.showsUserLocationButton
            && lhs.fingerPitchEnabled == rhs.fingerPitchEnabled
            && Int(lhs.fingerPitch.rounded()) == Int(rhs.fingerPitch.rounded())
            && Int(lhs.horizonAssist.rounded()) == Int(rhs.horizonAssist.rounded())
    }

    private struct PaintedTrail: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let fade: Double
    }

    private struct PaintedRing: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let fade: Double
    }

    private struct FitLine: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let width: Double
        let dashed: Bool
    }

    private struct KeyedSpot: Identifiable {
        let id: String
        let spot: CampSpot
    }

    private struct KeyedHazard: Identifiable {
        let id: String
        let hazard: MapHazard
    }

    private var paintedRings: [PaintedRing] {
        landRings.compactMap { ring in
            let fade: Double
            let color: Color
            switch ring.kind {
            case "blm":
                fade = blmOpacity
                color = LandMask.blm
            case "usfs":
                fade = usfsOpacity
                color = LandMask.usfs
            case "state":
                fade = stateOpacity
                color = LandMask.stateTrust
            default:
                return nil
            }
            guard fade > 0.02, ring.coordinates.count >= 3 else { return nil }
            let bucket = Int((fade * 100).rounded())
            return PaintedRing(id: "land-\(ring.id)-\(bucket)", coordinates: ring.coordinates, color: color, fade: fade)
        }
    }

    private var paintedTrails: [PaintedTrail] {
        trails.compactMap { trail in
            guard trail.coordinates.count >= 2, let tint = corridorTint(trail) else { return nil }
            let bucket = Int((tint.fade * 100).rounded())
            return PaintedTrail(id: "mask-\(trail.id)-\(bucket)", coordinates: trail.coordinates, color: tint.color, fade: tint.fade)
        }
    }

    private var fitLines: [FitLine] {
        guard trailOpacity > 0.02 else { return [] }
        let bucket = Int((trailOpacity * 100).rounded())
        let alpha = 0.15 + trailOpacity * 0.85
        let scale = 0.6 + trailOpacity * 0.7
        if routingActive {
            guard selectedTrailLine.count >= 2 else { return [] }
            let dashed = trails.first?.legalStatus == "osm"
            return [FitLine(
                id: "fit-\(selectedTrailID)-\(bucket)",
                coordinates: selectedTrailLine,
                color: (trailColors[selectedTrailID] ?? Color.green).opacity(alpha),
                width: max(1.5, 3.5 * scale),
                dashed: dashed
            )]
        }
        return trails.compactMap { trail in
            guard trail.coordinates.count >= 2 else { return nil }
            let base = trail.id == selectedTrailID ? 6.0 : 3.5
            return FitLine(
                id: "fit-\(trail.id)-\(bucket)",
                coordinates: trail.coordinates,
                color: (trailColors[trail.id] ?? Color.orange).opacity(alpha),
                width: max(1.5, base * scale),
                dashed: TrailLegal.isDashed(trail)
            )
        }
    }

    private var slopeSpots: [KeyedSpot] {
        let bucket = Int((campSlopeOpacity * 100).rounded())
        return Array(camps.prefix(12)).map { KeyedSpot(id: "slope-\($0.id)-\(bucket)", spot: $0) }
    }

    private var cellSpots: [KeyedSpot] {
        let bucket = Int((starlinkOpacity * 100).rounded())
        return Array(camps.prefix(12)).map { KeyedSpot(id: "cell-\($0.id)-\(bucket)", spot: $0) }
    }

    private var keyedHazards: [KeyedHazard] {
        let bucket = Int((hazardOpacity * 100).rounded())
        return hazards.map { KeyedHazard(id: "hazard-\($0.id)-\(bucket)", hazard: $0) }
    }

    @MapContentBuilder
    private var corridorMasks: some MapContent {
        ForEach(paintedRings) { ring in
            MapPolygon(coordinates: ring.coordinates)
                .foregroundStyle(ring.color.opacity(0.08 + ring.fade * 0.50))
            MapPolyline(coordinates: ring.coordinates)
                .stroke(ring.color.opacity(0.30 + ring.fade * 0.65), lineWidth: 1.0 + ring.fade * 2.2)
        }
        ForEach(paintedTrails) { item in
            MapPolyline(coordinates: item.coordinates)
                .stroke(
                    item.color.opacity(0.18 + item.fade * 0.74),
                    style: StrokeStyle(lineWidth: 8 + item.fade * 16, lineCap: .round, lineJoin: .round)
                )
        }
    }

    private func corridorTint(_ trail: OverlandTrail) -> (color: Color, fade: Double)? {
        let kind = landKind(trail)
        switch kind {
        case "blm":
            return blmOpacity > 0.02 ? (LandMask.blm, blmOpacity) : nil
        case "state":
            return stateOpacity > 0.02 ? (LandMask.stateTrust, stateOpacity) : nil
        case "usfs":
            return usfsOpacity > 0.02 ? (LandMask.usfs, usfsOpacity) : nil
        default:
            return nil
        }
    }

    private func landKind(_ trail: OverlandTrail) -> String {
        let agency = trail.agency.lowercased()
        let text = (trail.name + " " + trail.region).lowercased()
        if agency.contains("blm") || agency.contains("bureau of land") { return "blm" }
        if agency.contains("state trust") || agency.contains("dnr") || agency.contains("state forest") { return "state" }
        if trail.isBDR || agency.contains("usfs") || agency.contains("forest service") || agency.contains("national forest") { return "usfs" }
        if text.contains("forest") || text.contains(" fs ") || text.contains(" nf") || text.hasPrefix("fs ") { return "usfs" }
        if text.contains("state") || text.contains("dnr") { return "state" }
        if text.contains("blm") || text.contains("canyon") || text.contains("desert") { return "blm" }
        let mid = trail.coordinates.isEmpty ? trail.centerCoordinate : trail.coordinates[trail.coordinates.count / 2]
        if let hit = landRings.first(where: { LandViewportQuery.contains($0, mid) }) {
            return hit.kind
        }
        let active = [("blm", blmOpacity), ("usfs", usfsOpacity), ("state", stateOpacity)].filter { $0.1 > 0.02 }.map(\.0)
        guard !active.isEmpty else { return "" }
        var hash = 0
        for byte in trail.id.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return active[abs(hash) % active.count]
    }

    var body: some View {
        MapReader { proxy in
            tiltedMap
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        guard plotMode, let coordinate = proxy.convert(value.location, from: .local) else { return }
                        onInspect(coordinate)
                    }
                )
                .overlay {
                    MapTapOverlayView(
                        proxy: proxy,
                        onLongPress: onLongPress,
                        pitchEnabled: fingerPitchEnabled,
                        pitch: fingerPitch,
                        horizonAssist: horizonAssist,
                        onPitch: onFingerPitch
                    )
                }
        }
    }

    private var tiltedMap: some View {
        let extra = min(max(horizonAssist, 0), 15)
        return mapBody
            .rotation3DEffect(
                .degrees(extra),
                axis: (x: 1, y: 0, z: 0),
                anchor: .bottom,
                perspective: 0.42
            )
            .scaleEffect(1 + CGFloat(extra) / 48, anchor: .bottom)
    }

    private var mapBody: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
            UserAnnotation()
            corridorMasks
            if campSlopeOpacity > 0.02 {
                ForEach(slopeSpots) { item in
                    MapCircle(center: item.spot.coordinate, radius: 120 + campSlopeOpacity * 80)
                        .foregroundStyle(LandMask.slopeFlat.opacity(0.12 + campSlopeOpacity * 0.62))
                }
            }
            if starlinkOpacity > 0.02 {
                ForEach(cellSpots) { item in
                    MapCircle(center: item.spot.coordinate, radius: 160 + starlinkOpacity * 140)
                        .foregroundStyle(LandMask.cell.opacity(0.1 + starlinkOpacity * 0.55))
                }
            }
            if hazardOpacity > 0.02 {
                ForEach(keyedHazards) { item in
                    hazardOverlay(item.hazard)
                }
            }
            ForEach(cruxPins) { pin in
                Annotation("", coordinate: pin.coordinate) {
                    Text(pin.title)
                        .font(.system(size: 9, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.78))
                        .foregroundColor(.orange)
                        .clipShape(Capsule())
                }
            }
            if plotLine.count >= 2 {
                MapPolyline(coordinates: plotLine)
                    .stroke(
                        Color(red: 0.984, green: 0.749, blue: 0.141),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
                    )
            }
            ForEach(savedOfflineRings.indices, id: \.self) { index in
                MapPolyline(coordinates: savedOfflineRings[index])
                    .stroke(Color.yellow.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [4, 6]))
            }
            if liveOfflineRing.count >= 4 {
                MapPolygon(coordinates: liveOfflineRing)
                    .foregroundStyle(Color.cyan.opacity(0.14))
                MapPolyline(coordinates: liveOfflineRing)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            }
            if let droppedPin {
                Annotation("Dropped Pin", coordinate: droppedPin) {
                    Text("📍")
                        .font(.title2)
                }
            }
            ForEach(savedMarkers) { marker in
                Annotation(marker.name, coordinate: marker.coordinate) {
                    Button {
                        onSelectMarker(marker.id)
                    } label: {
                        Text(marker.category == "Camp" ? "⛺" : marker.category == "Hazard" ? "⚠️" : "📍")
                            .font(.title3)
                            .padding(4)
                            .background(Color.black.opacity(0.72))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(plotMarkers.indices, id: \.self) { index in
                Annotation("", coordinate: plotMarkers[index]) {
                    Button {
                        onDeletePlotPoint(index)
                    } label: {
                        Text("\(index + 1)")
                            .font(.caption2.bold())
                            .frame(width: 22, height: 22)
                            .background(Color.white)
                            .foregroundColor(.black)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete waypoint \(index + 1)")
                }
            }
            if let scrub {
                Annotation("", coordinate: scrub) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.cyan, lineWidth: 3))
                }
            }
            if let place = searchedPlace {
                Annotation(place.name, coordinate: place.coordinate) {
                    VStack(spacing: 2) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .orange)
                        Text(place.name)
                            .font(.caption2.bold())
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.82))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
            }
            if let route {
                routeStroke(route)
            }
            if routingActive {
                ForEach(fitLines) { line in
                    MapPolyline(coordinates: line.coordinates)
                        .stroke(line.color, style: StrokeStyle(lineWidth: line.width, lineCap: .round, dash: line.dashed ? [7, 5] : []))
                }
                if let trail = trails.first {
                    Annotation(trail.trailhead.name, coordinate: trail.trailhead.coordinate) {
                        trailheadButton(trail.trailhead)
                    }
                }
                ForEach(Array(camps.prefix(3))) { spot in
                    Annotation(spot.name, coordinate: spot.coordinate) {
                        campButton(spot)
                    }
                }
            } else {
                ForEach(fitLines) { line in
                    MapPolyline(coordinates: line.coordinates)
                        .stroke(line.color, style: StrokeStyle(lineWidth: line.width, lineCap: .round, dash: line.dashed ? [7, 5] : []))
                }
                ForEach(trails) { trail in
                    Annotation(trail.trailhead.name, coordinate: trail.trailhead.coordinate) {
                        trailheadButton(trail.trailhead)
                    }
                }
                ForEach(camps) { spot in
                    Annotation(spot.name, coordinate: spot.coordinate) {
                        campButton(spot)
                    }
                }
            }
        }
        .mapStyle(basemapStyle)
        .id(basemap.rawValue + (flatBasemap ? "-flat" : ""))
        .mapControls {
            if showsUserLocationButton {
                MapUserLocationButton()
            }
            MapCompass()
            MapPitchToggle()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            onCameraPreview(context.region)
            onMapCamera(context.camera)
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            onCameraEnd(context.region)
            onMapCamera(context.camera)
        }
    }

    private var basemapStyle: MapStyle {
        let elevation: MapStyle.Elevation = flatBasemap ? .flat : .realistic
        switch basemap {
        case .hybrid:
            return .hybrid(elevation: elevation)
        case .standard:
            return .standard(elevation: elevation)
        case .imagery:
            return .imagery(elevation: elevation)
        }
    }

    @MapContentBuilder
    private func hazardOverlay(_ hazard: MapHazard) -> some MapContent {
        if hazard.coordinates.count >= 4 {
            MapPolygon(coordinates: hazard.coordinates)
                .foregroundStyle(LandMask.slopeSteep.opacity(0.12 + hazardOpacity * 0.55))
            MapPolyline(coordinates: hazard.coordinates)
                .stroke(LandMask.slopeSteep.opacity(0.35 + hazardOpacity * 0.6), lineWidth: 1.5 + hazardOpacity * 3.5)
        } else {
            MapCircle(center: hazard.point, radius: hazard.radiusMeters * (0.7 + hazardOpacity * 0.6))
                .foregroundStyle(LandMask.slopeMid.opacity(0.14 + hazardOpacity * 0.6))
            if hazard.id.hasPrefix("community-") || hazard.id.hasPrefix("userhazard-") {
                Annotation("", coordinate: hazard.point) {
                    Text(hazard.title)
                        .font(.system(size: 9, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.78))
                        .foregroundColor(.orange)
                        .clipShape(Capsule())
                }
            }
        }
    }

    @MapContentBuilder
    private func routeStroke(_ route: ActiveCampRoute) -> some MapContent {
        let stroke = Color(red: 0.08, green: 0.62, blue: 1.0)
        if showAlternates {
            ForEach(route.options) { option in
                if option.id != route.selectedIndex, option.road.count >= 2 {
                    MapPolyline(coordinates: option.road)
                        .stroke(stroke.opacity(0.45), lineWidth: 2.2)
                }
            }
        }
        let road = route.selected.road
        if road.count >= 2 {
            MapPolyline(coordinates: road)
                .stroke(stroke, lineWidth: 3.5)
        }
        if route.spur.count >= 2 {
            MapPolyline(coordinates: route.spur)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 4]))
        }
        if !routeStartedFromGPS, let start = road.first {
            Annotation("Start", coordinate: start) {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color.green, lineWidth: 1))
            }
        }
        Annotation("Destination", coordinate: route.destination.coordinate) {
            Image(systemName: "flag.checkered")
                .font(.caption.bold())
                .padding(6)
                .background(Color.blue)
                .foregroundColor(.white)
                .clipShape(Circle())
        }
    }

    private func trailheadButton(_ spot: CampSpot) -> some View {
        Button {
            onSpot(spot)
        } label: {
            Image(systemName: "flag.fill")
                .font(.caption.bold())
                .padding(7)
                .background(Color.white)
                .foregroundColor(.blue)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func campButton(_ spot: CampSpot) -> some View {
        Button {
            onSpot(spot)
        } label: {
            Text(String(format: "⛺ %.1f°", spot.slopeDeg))
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(spot.slopeDeg < 2 ? Color.green : Color.yellow)
                .foregroundColor(.black)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(route?.destination.id == spot.id ? Color.white : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }
}

private enum CampRouteBuilder {
    static func make(
        from origin: CLLocationCoordinate2D,
        to spot: CampSpot,
        trailCoordinates: [CLLocationCoordinate2D],
        trailhead: CLLocationCoordinate2D,
        originWasGPS: Bool,
        spurLimit: Double = 3_218
    ) async -> ActiveCampRoute {
        let stitch = !trailCoordinates.isEmpty
        let direct = await appleRoutes(from: origin, to: spot.coordinate)
        if !stitch {
            if !direct.isEmpty {
                let near = direct.filter { endsNear($0.road, spot.coordinate, within: 4_828) }
                return pack(near.isEmpty ? direct : near, spot: spot, originWasGPS: originWasGPS, spurLimit: spurLimit)
            }
            if let osrmPad = await osrmRoutes(from: origin, to: spot.coordinate) {
                let nearPad = osrmPad.filter { endsNear($0.road, spot.coordinate, within: 4_828) }
                return pack(nearPad.isEmpty ? osrmPad : nearPad, spot: spot, originWasGPS: originWasGPS, spurLimit: spurLimit)
            }
            return missingRoad(spot: spot, originWasGPS: originWasGPS)
        }

        let entry = closestCoordinate(on: trailCoordinates, to: origin) ?? trailhead
        let directHits = direct.filter { endsNear($0.road, spot.coordinate, within: 3_218) }
        if !directHits.isEmpty {
            return pack(directHits, spot: spot, originWasGPS: originWasGPS, spurLimit: spurLimit)
        }

        var entryTargets = [entry]
        if meters(from: entry, to: trailhead) > 400 {
            entryTargets.append(trailhead)
        }
        for target in entryTargets {
            let roads = await appleRoutes(from: origin, to: target)
            let hits = roads.filter { endsNear($0.road, target, within: 3_218) }
            if !hits.isEmpty {
                let stitched = hits.enumerated().map { index, option in
                    stitchTrail(option, index: index, trail: trailCoordinates, destination: spot.coordinate, name: spot.name)
                }
                return pack(stitched, spot: spot, originWasGPS: originWasGPS, spurLimit: spurLimit)
            }
        }

        if let osrmPad = await osrmRoutes(from: origin, to: spot.coordinate) {
            let nearPad = osrmPad.filter { endsNear($0.road, spot.coordinate, within: 4_828) }
            if !nearPad.isEmpty {
                let prepared = nearPad.enumerated().map { index, option in
                    stitchTrail(option, index: index, trail: trailCoordinates, destination: spot.coordinate, name: spot.name)
                }
                return pack(prepared, spot: spot, originWasGPS: originWasGPS, spurLimit: spurLimit)
            }
        }

        if meters(from: entry, to: spot.coordinate) > 200,
           let osrmEntry = await osrmRoutes(from: origin, to: entry) {
            let nearEntry = osrmEntry.filter { endsNear($0.road, entry, within: 3_218) }
            if !nearEntry.isEmpty {
                let stitched = nearEntry.enumerated().map { index, option in
                    stitchTrail(option, index: index, trail: trailCoordinates, destination: spot.coordinate, name: spot.name)
                }
                return pack(stitched, spot: spot, originWasGPS: originWasGPS, spurLimit: spurLimit)
            }
        }

        if let stepped = await steppedAppleRoute(from: origin, toward: entry, trail: trailCoordinates, spot: spot) {
            return pack([stepped], spot: spot, originWasGPS: originWasGPS, spurLimit: spurLimit)
        }

        return missingRoad(spot: spot, originWasGPS: originWasGPS)
    }

    private static func missingRoad(spot: CampSpot, originWasGPS: Bool) -> ActiveCampRoute {
        ActiveCampRoute(
            destination: spot,
            options: [NavOption(
                id: 0,
                title: "No road route",
                expectedTravelTime: 0,
                distanceMeters: 0,
                road: [],
                steps: [NavStep(id: 0, instruction: "No drivable road route yet. Check the signal and try again.", distanceMeters: 0, systemImage: "exclamationmark.triangle")]
            )],
            selectedIndex: 0,
            spur: [],
            originWasGPS: originWasGPS
        )
    }

    private static func pack(_ options: [NavOption], spot: CampSpot, originWasGPS: Bool, spurLimit: Double) -> ActiveCampRoute {
        let renumbered = options.enumerated().map { index, option in
            let pins = option.steps.compactMap(\.maneuver)
            let rawDistance = option.distanceMeters > 1 ? option.distanceMeters : polylineMeters(option.road)
            let road = simplifyCoordinates(option.road, maxPoints: 220, minMeters: 18, keep: pins)
            return NavOption(
                id: index,
                title: option.title,
                expectedTravelTime: option.expectedTravelTime,
                distanceMeters: rawDistance,
                road: road,
                steps: option.steps
            )
        }
        let road = renumbered.first?.road ?? []
        return ActiveCampRoute(
            destination: spot,
            options: renumbered,
            selectedIndex: 0,
            spur: simplifyCoordinates(cappedSpur(from: road, to: spot.coordinate, limit: spurLimit), maxPoints: 40, minMeters: 18),
            originWasGPS: originWasGPS
        )
    }

    private static func appleRoutes(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async -> [NavOption] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        let directions = MKDirections(request: request)
        guard let response = try? await directions.calculate() else { return [] }
        return response.routes.enumerated().compactMap { index, route in
            let road = coordinates(of: route.polyline)
            guard isDrivableRoad(road, startingNear: origin) else { return nil }
            return navOption(index: index, route: route, road: road)
        }
    }

    private static func navOption(index: Int, route: MKRoute, road: [CLLocationCoordinate2D]) -> NavOption {
        var steps: [NavStep] = []
        for step in route.steps {
            let instruction = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { continue }
            let maneuver = coordinates(of: step.polyline).last
            steps.append(NavStep(
                id: steps.count,
                instruction: instruction,
                distanceMeters: step.distance,
                systemImage: maneuverIcon(instruction),
                maneuver: maneuver
            ))
        }
        if steps.isEmpty {
            steps.append(NavStep(id: 0, instruction: "Continue on the road", distanceMeters: route.distance, systemImage: "arrow.up", maneuver: road.last))
        }
        return NavOption(
            id: index,
            title: "Route \(index + 1)",
            expectedTravelTime: route.expectedTravelTime,
            distanceMeters: route.distance,
            road: road,
            steps: steps
        )
    }

    private static func osrmRoutes(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async -> [NavOption]? {
        for url in drivingRouteURLs(from: origin, to: destination, steps: true) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["code"] as? String) == "Ok",
                  let routes = root["routes"] as? [[String: Any]] else { continue }
            let options = routes.enumerated().compactMap { index, route -> NavOption? in
                parseOSRM(route, index: index, startingNear: origin)
            }
            if !options.isEmpty { return options }
        }
        return nil
    }

    private static func parseOSRM(_ route: [String: Any], index: Int, startingNear origin: CLLocationCoordinate2D) -> NavOption? {
        guard let geometry = route["geometry"] as? [String: Any] else { return nil }
        let road = downsample(parseCoordinates(geometry["coordinates"]), limit: 700)
        guard isDrivableRoad(road, startingNear: origin) else { return nil }
        let distance = (route["distance"] as? NSNumber)?.doubleValue ?? polylineMeters(road)
        let duration = (route["duration"] as? NSNumber)?.doubleValue ?? (distance / 1609.344) / 35.0 * 3600
        var steps: [NavStep] = []
        let legs = route["legs"] as? [[String: Any]] ?? []
        for leg in legs {
            let rawSteps = leg["steps"] as? [[String: Any]] ?? []
            for raw in rawSteps {
                guard let maneuver = raw["maneuver"] as? [String: Any] else { continue }
                let type = maneuver["type"] as? String ?? "continue"
                if type == "arrive" { continue }
                let modifier = maneuver["modifier"] as? String
                let name = (raw["name"] as? String) ?? ""
                let instruction = osrmInstruction(type: type, modifier: modifier, name: name)
                let location = parseCoordinatePair(maneuver["location"])
                let stepDistance = (raw["distance"] as? NSNumber)?.doubleValue ?? 0
                steps.append(NavStep(
                    id: steps.count,
                    instruction: instruction,
                    distanceMeters: stepDistance,
                    systemImage: maneuverIcon(instruction),
                    maneuver: location
                ))
            }
        }
        if steps.isEmpty {
            steps.append(NavStep(id: 0, instruction: "Continue on the road", distanceMeters: distance, systemImage: "arrow.up", maneuver: road.last))
        }
        return NavOption(
            id: index,
            title: "Route \(index + 1)",
            expectedTravelTime: duration,
            distanceMeters: distance,
            road: road,
            steps: steps
        )
    }

    private static func steppedAppleRoute(
        from origin: CLLocationCoordinate2D,
        toward entry: CLLocationCoordinate2D,
        trail: [CLLocationCoordinate2D],
        spot: CampSpot
    ) async -> NavOption? {
        var best: NavOption?
        var bestGap = Double.greatestFiniteMagnitude
        for fraction in [0.75, 0.50, 0.25] {
            let point = interpolate(origin, entry, fraction)
            let roads = await appleRoutes(from: origin, to: point)
            for option in roads where endsNear(option.road, point, within: 3_218) {
                guard let end = option.road.last else { continue }
                let gap = min(meters(from: end, to: entry), meters(from: end, to: spot.coordinate))
                if gap < bestGap {
                    bestGap = gap
                    best = stitchTrail(option, index: 0, trail: trail, destination: spot.coordinate, name: spot.name)
                }
            }
        }
        return best
    }

    private static func stitchTrail(_ option: NavOption, index: Int, trail: [CLLocationCoordinate2D], destination: CLLocationCoordinate2D, name: String) -> NavOption {
        var road = option.road
        var steps = option.steps
        if let end = road.last, meters(from: end, to: destination) > 80 {
            let slice = trailSlice(from: end, to: destination, trail: trail)
            if let first = slice.first, slice.count >= 2, meters(from: end, to: first) <= 3_218 {
                let joined = joinRoads(road, slice)
                let trailDistance = polylineMeters(slice)
                steps.append(NavStep(
                    id: steps.count,
                    instruction: "Continue on the trail toward \(name)",
                    distanceMeters: trailDistance,
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    maneuver: slice.last
                ))
                road = joined
            }
        }
        let duration = option.expectedTravelTime + (polylineMeters(road) - option.distanceMeters) / 1609.344 / 12.0 * 3600
        return NavOption(
            id: index,
            title: option.title,
            expectedTravelTime: max(option.expectedTravelTime, duration),
            distanceMeters: polylineMeters(road),
            road: road,
            steps: steps
        )
    }
}

@MainActor
final class VoiceNavigationAnnouncer: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var prepared = false

    func speak(_ text: String, enabled: Bool) {
        guard enabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        prepare()
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.bestNaturalVoice()
        utterance.rate = 0.49
        utterance.pitchMultiplier = 1.03
        utterance.preUtteranceDelay = 0.04
        utterance.postUtteranceDelay = 0.08
        synthesizer.speak(utterance)
    }

    private static func bestNaturalVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let english = voices.filter { $0.language.lowercased().hasPrefix("en") }
        let unitedStates = english.filter { $0.language.lowercased().hasPrefix("en-us") }
        let pool = unitedStates.isEmpty ? english : unitedStates
        let novelty = [
            "albert", "bad news", "bahh", "bells", "boing", "bubbles", "cellos", "fred",
            "good news", "jester", "organ", "superstar", "trinoids", "whisper", "wobble",
            "zarvox", "ralph", "kathy", "junior"
        ]
        let naturalNames = ["ava", "samantha", "evan", "allison", "zoe", "nicky", "siri", "premium", "enhanced"]
        func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
            let blob = (voice.name + " " + voice.identifier).lowercased()
            return novelty.contains { token in
                blob.contains(token) || blob.contains(token.replacingOccurrences(of: " ", with: ""))
            }
        }
        func score(_ voice: AVSpeechSynthesisVoice) -> Int {
            if isNovelty(voice) { return -1 }
            var value = 0
            if voice.quality == .premium { value += 500 }
            else if voice.quality == .enhanced { value += 300 }
            let blob = (voice.name + " " + voice.identifier).lowercased()
            if naturalNames.contains(where: { blob.contains($0) }) { value += 80 }
            if voice.language.lowercased() == "en-us" { value += 20 }
            return value
        }
        if let best = pool.max(by: { score($0) < score($1) }), score(best) > 0 {
            return best
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func prepare() {
        guard !prepared else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try? session.setActive(true)
        }
        prepared = true
    }
}

private func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
    let count = polyline.pointCount
    guard count > 0 else { return [] }
    var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0), count: count)
    polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
    return coords
}

private func formatCoordinate(_ coord: CLLocationCoordinate2D) -> String {
    let latitudeHemisphere = coord.latitude >= 0 ? "N" : "S"
    let longitudeHemisphere = coord.longitude >= 0 ? "E" : "W"
    return String(format: "%.5f° %@, %.5f° %@", abs(coord.latitude), latitudeHemisphere, abs(coord.longitude), longitudeHemisphere)
}

private func simplifyCoordinates(
    _ coords: [CLLocationCoordinate2D],
    maxPoints: Int = 220,
    minMeters: Double = 18.0,
    keep: [CLLocationCoordinate2D] = []
) -> [CLLocationCoordinate2D] {
    guard coords.count > 2, maxPoints >= 2 else { return coords }
    var pinned = Set<Int>([0, coords.count - 1])
    for pin in keep {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, point) in coords.enumerated() {
            let distance = meters(from: pin, to: point)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        pinned.insert(best)
    }
    var radial: [CLLocationCoordinate2D] = []
    var radialPinned: [CLLocationCoordinate2D] = []
    radial.reserveCapacity(min(coords.count, maxPoints * 3))
    for (index, point) in coords.enumerated() {
        let isPinned = pinned.contains(index)
        if radial.isEmpty || isPinned || meters(from: radial[radial.count - 1], to: point) >= minMeters {
            if !radial.isEmpty, let last = radial.last, meters(from: last, to: point) < 1, !isPinned {
                continue
            }
            radial.append(point)
            if isPinned { radialPinned.append(point) }
        }
    }
    if let last = coords.last {
        if radial.isEmpty {
            radial = [coords[0], last]
        } else if meters(from: radial[radial.count - 1], to: last) > 1 {
            radial.append(last)
        } else {
            radial[radial.count - 1] = last
        }
        if radialPinned.last.map({ meters(from: $0, to: last) > 1 }) ?? true {
            radialPinned.append(last)
        }
    }
    if radial.first.map({ meters(from: $0, to: coords[0]) > 1 }) ?? true {
        radial.insert(coords[0], at: 0)
    }
    if radial.count <= maxPoints { return radial }
    var epsilon = minMeters
    var simplified = radial
    var passes = 0
    while simplified.count > maxPoints, epsilon < 20_000, passes < 18 {
        epsilon *= 1.7
        simplified = douglasPeucker(radial, epsilon: epsilon, keep: radialPinned)
        passes += 1
    }
    if simplified.count > maxPoints {
        simplified = capPreservingPins(simplified, maxPoints: maxPoints, keep: radialPinned)
    }
    return simplified
}

private func douglasPeucker(_ points: [CLLocationCoordinate2D], epsilon: Double, keep: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    let count = points.count
    guard count > 2 else { return points }
    var keepIndex = Array(repeating: false, count: count)
    keepIndex[0] = true
    keepIndex[count - 1] = true
    if !keep.isEmpty {
        for index in 0..<count {
            let point = points[index]
            if keep.contains(where: { meters(from: $0, to: point) <= 25 }) {
                keepIndex[index] = true
            }
        }
    }
    var stack: [(Int, Int)] = [(0, count - 1)]
    while let range = stack.popLast() {
        let start = range.0
        let end = range.1
        guard end > start + 1 else { continue }
        var maxDistance = 0.0
        var maxIndex = start
        var pinnedBetween = -1
        for index in (start + 1)..<end {
            if pinnedBetween < 0, keepIndex[index] { pinnedBetween = index }
            let distance = perpendicularMeters(points[index], points[start], points[end])
            if distance > maxDistance {
                maxDistance = distance
                maxIndex = index
            }
        }
        if maxDistance > epsilon {
            keepIndex[maxIndex] = true
            stack.append((start, maxIndex))
            stack.append((maxIndex, end))
        } else if pinnedBetween >= 0 {
            stack.append((start, pinnedBetween))
            stack.append((pinnedBetween, end))
        }
    }
    var result: [CLLocationCoordinate2D] = []
    result.reserveCapacity(min(count, 240))
    for index in 0..<count where keepIndex[index] {
        result.append(points[index])
    }
    return result
}

private func capPreservingPins(_ points: [CLLocationCoordinate2D], maxPoints: Int, keep: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    guard points.count > maxPoints, maxPoints >= 2 else { return points }
    var required = Set<Int>([0, points.count - 1])
    for (index, point) in points.enumerated() where keep.contains(where: { meters(from: $0, to: point) <= 25 }) {
        required.insert(index)
    }
    if required.count >= maxPoints {
        let sorted = required.sorted()
        let step = Double(sorted.count - 1) / Double(maxPoints - 1)
        var picked: [Int] = (0..<maxPoints).map { slot in
            sorted[min(sorted.count - 1, Int((Double(slot) * step).rounded()))]
        }
        picked[0] = sorted[0]
        picked[maxPoints - 1] = sorted[sorted.count - 1]
        var unique: [Int] = []
        for index in picked where unique.last != index {
            unique.append(index)
        }
        return unique.map { points[$0] }
    }
    let optional = points.indices.filter { !required.contains($0) }
    let slots = maxPoints - required.count
    var chosen = required
    if slots > 0, !optional.isEmpty {
        let step = Double(optional.count) / Double(slots)
        for slot in 0..<slots {
            chosen.insert(optional[min(optional.count - 1, Int((Double(slot) + 0.5) * step))])
        }
    }
    return chosen.sorted().map { points[$0] }
}

private func perpendicularMeters(_ point: CLLocationCoordinate2D, _ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D) -> Double {
    let lonScale = 111_320.0 * cos(point.latitude * .pi / 180)
    let latScale = 111_320.0
    let ax = start.longitude * lonScale
    let ay = start.latitude * latScale
    let bx = end.longitude * lonScale
    let by = end.latitude * latScale
    let px = point.longitude * lonScale
    let py = point.latitude * latScale
    let dx = bx - ax
    let dy = by - ay
    let length = sqrt(dx * dx + dy * dy)
    if length < 1 { return meters(from: point, to: start) }
    return abs((px - ax) * dy - (py - ay) * dx) / length
}

private func cappedSpur(from road: [CLLocationCoordinate2D], to destination: CLLocationCoordinate2D, limit: Double = 3_218) -> [CLLocationCoordinate2D] {
    guard let last = road.last else { return [] }
    let gap = meters(from: last, to: destination)
    if gap < 30 || gap > limit { return [] }
    return [last, destination]
}

private func drivingRouteURLs(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, steps: Bool) -> [URL] {
    let query = steps
        ? "overview=full&geometries=geojson&steps=true&alternatives=true"
        : "overview=full&geometries=geojson&steps=true"
    let path = "\(origin.longitude),\(origin.latitude);\(destination.longitude),\(destination.latitude)?\(query)"
    return [
        "https://router.project-osrm.org/route/v1/driving/",
        "https://routing.openstreetmap.de/routed-car/route/v1/driving/"
    ].compactMap { URL(string: $0 + path) }
}

private func isDrivableRoad(_ road: [CLLocationCoordinate2D], startingNear origin: CLLocationCoordinate2D) -> Bool {
    guard road.count > 2, let first = road.first else { return false }
    guard meters(from: first, to: origin) < 5_000 else { return false }
    return !isStraightCrowLine(road)
}

private func isStraightCrowLine(_ road: [CLLocationCoordinate2D]) -> Bool {
    guard let first = road.first, let last = road.last, road.count >= 2 else { return true }
    let direct = meters(from: first, to: last)
    if direct < 800 { return false }
    if road.count <= 3, direct > 1_500 { return true }
    let path = polylineMeters(road)
    return path < direct * 1.08 && direct > 3_000 && road.count < 12
}

private func endsNear(_ road: [CLLocationCoordinate2D], _ target: CLLocationCoordinate2D, within limit: Double) -> Bool {
    guard let last = road.last else { return false }
    return meters(from: last, to: target) <= limit
}

private func closestCoordinate(on trail: [CLLocationCoordinate2D], to point: CLLocationCoordinate2D) -> CLLocationCoordinate2D? {
    guard !trail.isEmpty else { return nil }
    return trail[nearestVertex(point, on: trail)]
}

private func interpolate(_ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D, _ fraction: Double) -> CLLocationCoordinate2D {
    let t = min(1, max(0, fraction))
    return CLLocationCoordinate2D(
        latitude: start.latitude + (end.latitude - start.latitude) * t,
        longitude: start.longitude + (end.longitude - start.longitude) * t
    )
}

private func plotSegmentKey(_ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D) -> String {
    func rounded5(_ value: Double) -> Double { (value * 100_000).rounded() / 100_000 }
    return "\(rounded5(start.latitude)),\(rounded5(start.longitude))->\(rounded5(end.latitude)),\(rounded5(end.longitude))"
}

private func trailBoxContains(_ trail: [CLLocationCoordinate2D], _ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D, limitMeters: Double) -> Bool {
    guard let first = trail.first else { return false }
    var minLat = first.latitude
    var maxLat = first.latitude
    var minLon = first.longitude
    var maxLon = first.longitude
    for point in trail {
        minLat = min(minLat, point.latitude)
        maxLat = max(maxLat, point.latitude)
        minLon = min(minLon, point.longitude)
        maxLon = max(maxLon, point.longitude)
    }
    let midLat = (start.latitude + end.latitude) / 2
    let dLat = limitMeters / 111_320
    let dLon = limitMeters / (111_320 * max(0.2, cos(midLat * .pi / 180)))
    func inside(_ point: CLLocationCoordinate2D) -> Bool {
        point.latitude >= minLat - dLat && point.latitude <= maxLat + dLat
            && point.longitude >= minLon - dLon && point.longitude <= maxLon + dLon
    }
    return inside(start) && inside(end)
}

private func projectOntoSegment(_ point: CLLocationCoordinate2D, _ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D) -> (coordinate: CLLocationCoordinate2D, distance: Double) {
    let lonScale = 111_320.0 * cos(point.latitude * .pi / 180)
    let latScale = 111_320.0
    let ax = start.longitude * lonScale
    let ay = start.latitude * latScale
    let bx = end.longitude * lonScale
    let by = end.latitude * latScale
    let px = point.longitude * lonScale
    let py = point.latitude * latScale
    let dx = bx - ax
    let dy = by - ay
    let length2 = dx * dx + dy * dy
    let t = length2 > 1 ? max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / length2)) : 0
    let coordinate = CLLocationCoordinate2D(
        latitude: start.latitude + (end.latitude - start.latitude) * t,
        longitude: start.longitude + (end.longitude - start.longitude) * t
    )
    return (coordinate, meters(from: point, to: coordinate))
}

private func projectOntoTrail(_ point: CLLocationCoordinate2D, trail: [CLLocationCoordinate2D]) -> (segmentIndex: Int, coordinate: CLLocationCoordinate2D, distance: Double)? {
    guard trail.count >= 2 else { return nil }
    var bestIndex = 0
    var bestCoordinate = trail[0]
    var bestDistance = Double.greatestFiniteMagnitude
    for index in 0..<(trail.count - 1) {
        let hit = projectOntoSegment(point, trail[index], trail[index + 1])
        if hit.distance < bestDistance {
            bestDistance = hit.distance
            bestIndex = index
            bestCoordinate = hit.coordinate
        }
    }
    return (bestIndex, bestCoordinate, bestDistance)
}

private func projectedTrailSlice(from startPoint: CLLocationCoordinate2D, to endPoint: CLLocationCoordinate2D, trail: [CLLocationCoordinate2D], maxDistance: Double) -> (line: [CLLocationCoordinate2D], closeness: Double)? {
    guard let startHit = projectOntoTrail(startPoint, trail: trail),
          let endHit = projectOntoTrail(endPoint, trail: trail),
          startHit.distance <= maxDistance,
          endHit.distance <= maxDistance else { return nil }
    var line: [CLLocationCoordinate2D] = [startPoint, startHit.coordinate]
    if startHit.segmentIndex < endHit.segmentIndex {
        let lower = startHit.segmentIndex + 1
        let upper = endHit.segmentIndex
        if lower <= upper {
            line.append(contentsOf: trail[lower...upper])
        }
    } else if startHit.segmentIndex > endHit.segmentIndex {
        let lower = endHit.segmentIndex + 1
        let upper = startHit.segmentIndex
        if lower <= upper {
            line.append(contentsOf: trail[lower...upper].reversed())
        }
    }
    line.append(endHit.coordinate)
    line.append(endPoint)
    let cleaned = dedupedCoordinates(line)
    guard cleaned.count >= 2 else { return nil }
    return (cleaned, startHit.distance + endHit.distance)
}

private func dedupedCoordinates(_ line: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    var result: [CLLocationCoordinate2D] = []
    result.reserveCapacity(line.count)
    for point in line {
        if let last = result.last, meters(from: last, to: point) < 8 { continue }
        result.append(point)
    }
    return result
}

private func plotRoadGeometry(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D]? {
    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
    request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
    request.transportType = .automobile
    if let response = try? await MKDirections(request: request).calculate(),
       let route = response.routes.first {
        let road = coordinates(of: route.polyline)
        if road.count >= 2, !isStraightCrowLine(road), let first = road.first, meters(from: first, to: origin) < 5_000 {
            return road
        }
    }
    for url in drivingRouteURLs(from: origin, to: destination, steps: true) {
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: urlRequest),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? String) == "Ok",
              let routes = root["routes"] as? [[String: Any]],
              let geometry = routes.first?["geometry"] as? [String: Any] else { continue }
        let road = parseCoordinates(geometry["coordinates"])
        if road.count >= 2, !isStraightCrowLine(road), let first = road.first, meters(from: first, to: origin) < 5_000 {
            return road
        }
    }
    return nil
}

private func trailSlice(from startPoint: CLLocationCoordinate2D, to endPoint: CLLocationCoordinate2D, trail: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    guard trail.count >= 2 else { return [] }
    let start = nearestVertex(startPoint, on: trail)
    let end = nearestVertex(endPoint, on: trail)
    if start == end { return [] }
    if start < end { return Array(trail[start...end]) }
    return Array(trail[end...start].reversed())
}

private func joinRoads(_ road: [CLLocationCoordinate2D], _ extra: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    guard let last = road.last, let first = extra.first else { return road }
    let gap = meters(from: last, to: first)
    if gap > 3_218 { return road }
    if gap < 40 { return road + extra.dropFirst() }
    return road + extra
}

private func parseCoordinates(_ raw: Any?) -> [CLLocationCoordinate2D] {
    guard let pairs = raw as? [Any] else { return [] }
    return pairs.compactMap { parseCoordinatePair($0) }
}

private func parseCoordinatePair(_ raw: Any?) -> CLLocationCoordinate2D? {
    guard let pair = raw as? [Any], pair.count >= 2 else { return nil }
    guard let lat = (pair[1] as? NSNumber)?.doubleValue,
          let lon = (pair[0] as? NSNumber)?.doubleValue else { return nil }
    guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

private func osrmInstruction(type: String, modifier: String?, name: String) -> String {
    let road = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch type {
    case "depart":
        return road.isEmpty ? "Follow the road" : "Follow \(road)"
    case "merge", "on ramp":
        return road.isEmpty ? "Merge" : "Merge onto \(road)"
    case "off ramp":
        return road.isEmpty ? "Take the exit" : "Take the exit onto \(road)"
    case "fork":
        let keepRight = modifier == "right" || modifier == "slight right" || modifier == "sharp right"
        let action = keepRight ? "Keep right" : "Keep left"
        return road.isEmpty ? action : "\(action) onto \(road)"
    case "roundabout", "rotary", "exit roundabout", "roundabout turn":
        return road.isEmpty ? "Enter the roundabout" : "Enter the roundabout onto \(road)"
    case "turn", "end of road":
        return turnPhrase(modifier: modifier, road: road)
    default:
        return road.isEmpty ? "Continue" : "Continue onto \(road)"
    }
}

private func turnPhrase(modifier: String?, road: String) -> String {
    let action: String
    switch modifier {
    case "uturn": action = "Make a U-turn"
    case "sharp right": action = "Turn sharp right"
    case "right": action = "Turn right"
    case "slight right": action = "Turn slight right"
    case "sharp left": action = "Turn sharp left"
    case "left": action = "Turn left"
    case "slight left": action = "Turn slight left"
    case "straight": action = "Continue straight"
    default: action = "Continue"
    }
    return road.isEmpty ? action : "\(action) onto \(road)"
}

private func downsample(_ coordinates: [CLLocationCoordinate2D], limit: Int) -> [CLLocationCoordinate2D] {
    guard coordinates.count > limit, limit >= 2 else { return coordinates }
    let step = Double(coordinates.count - 1) / Double(limit - 1)
    return (0..<limit).map { index in
        coordinates[min(coordinates.count - 1, Int((Double(index) * step).rounded()))]
    }
}

private func spokenDuration(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int((seconds / 60).rounded()))
    if minutes < 60 {
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
    let hours = minutes / 60
    let remainder = minutes % 60
    let hourWord = hours == 1 ? "1 hour" : "\(hours) hours"
    if remainder == 0 { return hourWord }
    let minuteWord = remainder == 1 ? "1 minute" : "\(remainder) minutes"
    return "\(hourWord) \(minuteWord)"
}

private func spokenDistance(_ metersValue: Double) -> String {
    let miles = metersValue / 1609.344
    if miles < 0.1 {
        let feet = max(1, Int((metersValue * 3.28084).rounded()))
        return feet == 1 ? "1 foot" : "\(feet) feet"
    }
    if miles < 0.16 { return "an eighth of a mile" }
    if miles < 0.28 { return "a fifth of a mile" }
    if miles < 0.4 { return "a third of a mile" }
    if miles < 0.65 { return "half a mile" }
    if miles < 0.85 { return "three quarters of a mile" }
    if miles < 1.2 { return "a mile" }
    if miles < 1.4 { return "a mile and a quarter" }
    if miles < 1.65 { return "a mile and a half" }
    if miles < 1.85 { return "a mile and three quarters" }
    if miles < 10 {
        let whole = Int(miles.rounded(.down))
        let fraction = miles - Double(whole)
        if fraction < 0.15 { return whole == 1 ? "a mile" : "\(whole) miles" }
        if fraction < 0.4 { return "\(whole) and a quarter miles" }
        if fraction < 0.65 { return "\(whole) and a half miles" }
        if fraction < 0.85 { return "\(whole) and three quarters miles" }
        return "\(whole + 1) miles"
    }
    return "\(Int(miles.rounded())) miles"
}

private func nearestVertex(_ point: CLLocationCoordinate2D, on trail: [CLLocationCoordinate2D]) -> Int {
    var best = 0
    var bestDistance = Double.greatestFiniteMagnitude
    for (index, vertex) in trail.enumerated() {
        let distance = meters(from: point, to: vertex)
        if distance < bestDistance {
            bestDistance = distance
            best = index
        }
    }
    return best
}

private func meters(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
    CLLocation(latitude: from.latitude, longitude: from.longitude)
        .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
}

private func polylineMeters(_ coordinates: [CLLocationCoordinate2D]) -> Double {
    guard coordinates.count >= 2 else { return 0 }
    var total = 0.0
    for index in 1..<coordinates.count {
        total += meters(from: coordinates[index - 1], to: coordinates[index])
    }
    return total
}

private func traveledMeters(user: CLLocationCoordinate2D, along coordinates: [CLLocationCoordinate2D]) -> Double {
    guard coordinates.count >= 2 else { return 0 }
    var best = Double.greatestFiniteMagnitude
    var traveled = 0.0
    var running = 0.0
    for index in 1..<coordinates.count {
        let segment = meters(from: coordinates[index - 1], to: coordinates[index])
        let hit = distanceToSegment(user, coordinates[index - 1], coordinates[index])
        if hit.distance < best {
            best = hit.distance
            traveled = running + segment * hit.fraction
        }
        running += segment
    }
    return traveled
}

private func distanceToSegment(_ point: CLLocationCoordinate2D, _ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D) -> (distance: Double, fraction: Double) {
    let lonScale = 111_320.0 * cos(point.latitude * .pi / 180)
    let latScale = 111_320.0
    let bx = (end.longitude - start.longitude) * lonScale
    let by = (end.latitude - start.latitude) * latScale
    let px = (point.longitude - start.longitude) * lonScale
    let py = (point.latitude - start.latitude) * latScale
    let length2 = bx * bx + by * by
    let fraction = length2 < 1 ? 0 : min(1, max(0, (px * bx + py * by) / length2))
    let dx = px - bx * fraction
    let dy = py - by * fraction
    return (sqrt(dx * dx + dy * dy), fraction)
}

private func maneuverIcon(_ instruction: String) -> String {
    let text = instruction.lowercased()
    if text.contains("u-turn") || text.contains("uturn") { return "arrow.uturn.left" }
    if text.contains("slight right") { return "arrow.up.right" }
    if text.contains("slight left") { return "arrow.up.left" }
    if text.contains("sharp right") || text.contains("right") { return "arrow.turn.up.right" }
    if text.contains("sharp left") || text.contains("left") { return "arrow.turn.up.left" }
    if text.contains("roundabout") { return "arrow.triangle.turn.up.right.circle" }
    if text.contains("arriv") || text.contains("destination") { return "flag.checkered" }
    if text.contains("overland") || text.contains("spur") { return "point.topleft.down.to.point.bottomright.curvepath" }
    return "arrow.up"
}

private func formatDistance(_ metersValue: Double) -> String {
    let miles = metersValue / 1609.344
    if miles < 0.1 {
        return String(format: "%.0f ft", metersValue * 3.28084)
    }
    return String(format: "%.1f mi", miles)
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int(seconds / 60))
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
}
