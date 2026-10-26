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
    @ObservedObject private var trailRecorder = TrailRouteRecorder.shared

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
    @StateObject private var parcelService = ParcelBoundaryService()
    @State private var showParcelLayer = true
    @State private var parcelsCollapsedForFollow = false
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
    @State private var offlineTier = "Standard Topo + Parcels"
    @AppStorage("trailforge.offlineArea") private var offlineArea = "corridor"
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
    @AppStorage("trailforge.parcelOpacity") private var parcelOpacity = 1.0
    @AppStorage("trailforge.trailOpacity") private var trailCorridorOpacity = 1.0
    @AppStorage("trailforge.campOpacity") private var campSlopeOpacity = 0.9
    @AppStorage("trailforge.hazardOpacity") private var hazardOverlayOpacity = 0.85
    @AppStorage("trailforge.starlinkOpacity") private var starlinkOverlayOpacity = 0.75
    @AppStorage("trailforge.nightVision") private var nightVision = false
    @State private var thermalSaver = false
    @AppStorage("trailforge.map3D") private var is3DMapsEnabled = true
    @State private var cameraPitch: Double = 45
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
            let corridorWords = trail.isBDR ? " BDR WABDR backcountry discovery route corridor" : ""
            let haystack = [trail.name, trail.region, trail.state, trail.alsoStates.joined(separator: " "), trail.agency, corridorWords].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
        func matchesFilter(_ trail: OverlandTrail) -> Bool {
            guard matchesQuery(trail) else { return false }
            switch regionFilter {
            case "all", "near":
                return true
            case "bdr":
                return trail.isBDR
            default:
                return trail.containsState(regionFilter)
            }
        }
        var seen = Set<String>()
        var trails = (USATrailAtlas.all + telemetry.discoveredTrails).filter { trail in
            matchesFilter(trail) && seen.insert(trail.id).inserted
        }
        guard regionFilter == "near", let user = locationTracker.userCoordinate else { return trails }
        trails.sort { miles(from: user, to: $0.centerCoordinate) < miles(from: user, to: $1.centerCoordinate) }
        let nearby = trails.filter { miles(from: user, to: $0.centerCoordinate) <= 250 }
        return nearby.isEmpty ? Array(trails.prefix(8)) : nearby
    }

    private var activeTrail: OverlandTrail {
        let catalog = USATrailAtlas.all + telemetry.discoveredTrails
        if let selected = catalog.first(where: { $0.id == selectedTrailID }) {
            return selected
        }
        if let visible = pickerTrails.first(where: { !$0.isBDR }) {
            return visible
        }
        return catalog.first(where: { !$0.isBDR }) ?? catalog[0]
    }

    private var mapTrails: [OverlandTrail] {
        guard activeRoute == nil else { return [activeTrail] }
        let activeID = selectedTrailID
        return pickerTrails.filter { !$0.isBDR || $0.id == activeID }
    }

    private var mapCampSpots: [CampSpot] {
        mapTrails.flatMap(\.campSpots)
    }

    private var mapCamps: [CampSpot] {
        activeRoute == nil ? mapCampSpots : Array(activeTrail.campSpots.prefix(3))
    }

    private var showRouteAlternates: Bool {
        showingRouteOverview && !followRoute && activeRoute != nil
    }

    private var drawnParcels: [PropertyParcel] {
        if followRoute && !showParcelLayer {
            if let selected = parcelService.selected { return [selected] }
            return []
        }
        guard showParcelLayer else { return [] }
        return Array(parcelService.parcels.prefix(48))
    }

    private var targetCoordinate: CLLocationCoordinate2D? {
        if let route = activeRoute { return route.destination.coordinate }
        if let parcel = parcelService.selected { return parcel.centerCoordinate }
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
        hasher.combine(selectedTrailDraw.count)
        hasher.combine(routeStartedFromGPS)
        hasher.combine(Int(rigStore.profile.tireInches))
        hasher.combine(rigStore.profile.hasRearLocker)
        if activeRoute == nil {
            hasher.combine(pickerTrails.map(\.id).joined(separator: ","))
            hasher.combine(telemetry.discoveredTrails.count)
        }
        hasher.combine(showParcelLayer)
        hasher.combine(parcelService.selectedID)
        hasher.combine(drawnParcels.map(\.id).joined(separator: ","))
        hasher.combine(basemapRaw)
        hasher.combine(Int(parcelOpacity * 20))
        hasher.combine(Int(trailCorridorOpacity * 20))
        hasher.combine(Int(campSlopeOpacity * 20))
        hasher.combine(Int(hazardOverlayOpacity * 20))
        hasher.combine(Int(starlinkOverlayOpacity * 20))
        hasher.combine(plotPoints.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }.joined(separator: "|"))
        hasher.combine(plotPoints.count)
        hasher.combine(plottedLine.count)
        hasher.combine(plotSegmentRoutes.count)
        hasher.combine(plotSegmentRoutes.values.reduce(0) { $0 + $1.count })
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
        hasher.combine(trailRecorder.activePoints.count)
        hasher.combine(trailRecorder.displayedRouteID?.uuidString)
        hasher.combine(trailRecorder.isRecording)
        hasher.combine(savedMarkers.map { "\($0.id.uuidString):\($0.name):\($0.category)" }.joined(separator: ","))
        if let droppedPin {
            hasher.combine(droppedPin.latitude)
            hasher.combine(droppedPin.longitude)
        }
        hasher.combine(offlineArea)
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
        return cameraPitch > 1 ? cameraPitch : 55
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
        return "\(shortFit(activeTrail)) • \(activeTrail.name)"
    }

    private var listedCamps: [CampSpot] {
        let pads = mapCampSpots
        guard let user = locationTracker.userCoordinate else {
            return pads.sorted { $0.slopeDeg < $1.slopeDeg }
        }
        return pads.sorted {
            miles(from: user, to: $0.coordinate) < miles(from: user, to: $1.coordinate)
        }
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
            }
        }
    }

    private var cockpitWithLifecycle: some View {
        cockpitCanvas
            .onChange(of: mode) { _, _ in
                if detent == .peek { detent = .half }
            }
            .onAppear {
                motionManager.startUpdates()
                locationTracker.start()
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
                    applyCameraPitch(cameraPitch > 1 ? cameraPitch : 45)
                }
                if offlineFirst {
                    parcelService.replace(CockpitStore.loadParcels())
                } else {
                    parcelService.refresh(around: locationTracker.userCoordinate ?? mapCenter, force: true)
                }
            }
            .onChange(of: locationTracker.hasCenteredOnUserOnce) { _, centered in
                guard centered, let coordinate = locationTracker.userCoordinate else { return }
                mapCenter = coordinate
                if offlineFirst {
                    parcelService.replace(CockpitStore.loadParcels())
                } else {
                    parcelService.refresh(around: coordinate, force: true)
                }
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
                    if showParcelLayer {
                        showParcelLayer = false
                        parcelsCollapsedForFollow = true
                    }
                } else if parcelsCollapsedForFollow {
                    showParcelLayer = true
                    parcelsCollapsedForFollow = false
                }
            }
            .onChange(of: trailQuery) { _, newValue in
                if regionFilter == "bdr" {
                    showTrailMenu = true
                } else if !pickerTrails.contains(where: { $0.id == selectedTrailID }),
                          let first = pickerTrails.first(where: { !$0.isBDR }) {
                    selectedTrailID = first.id
                }
                schedulePlaceSearch(newValue)
            }
            .onChange(of: telemetry.isScanningTrails) { _, scanning in
                guard !scanning else { return }
                refreshSelectedTrailDraw()
                guard regionFilter == "near", activeRoute == nil, !followRoute else { return }
                if pickerTrails.contains(where: { $0.id == selectedTrailID && $0.isBDR }) { return }
                if let first = pickerTrails.first(where: { !$0.isBDR }), selectedTrailID != first.id {
                    selectedTrailID = first.id
                }
            }
            .onChange(of: parcelService.status) { _, _ in
                CockpitStore.saveParcels(parcelService.parcels)
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
        let fit = rigStore.evaluate(trail: activeTrail)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(pickerTrails.isEmpty ? Color.gray : fitColor(activeTrail))
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pickerTrails.isEmpty ? "No routes for \(filterTitle)" : "\(fit.verdict.rawValue) • \(activeTrail.name)")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(bannerDetail(fitNotes: fit.notes))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    offlineSaved.toggle()
                } label: {
                    Label(offlineSaved ? "Offline" : "Save", systemImage: offlineSaved ? "checkmark.icloud.fill" : "arrow.down.circle.fill")
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.04, green: 0.12, blue: 0.22))
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
                trailRecorderCard
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
            regionFilter = tag
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
        let selected = miles(from: user, to: activeTrail.centerCoordinate)
        let nearest = pickerTrails.map { miles(from: user, to: $0.centerCoordinate) }.min() ?? selected
        return String(format: "%d ft · %.0f mph · %.1f mi to trail · %.1f mi nearest", locationTracker.altitudeFt, locationTracker.speedMph, selected, nearest)
    }

    private func bannerDetail(fitNotes: [String]) -> String {
        guard !pickerTrails.isEmpty else { return "Pick another state or tap Near Me." }
        let note = fitNotes.first ?? ""
        let gate = CommunityStatus.badge(for: activeTrail.id, reports: reports, publishedGate: activeTrail.gateStatus)
        if let user = locationTracker.userCoordinate {
            let away = miles(from: user, to: activeTrail.centerCoordinate)
            return String(format: "Gate: %@ • Ford: %d\" • %.1f mi • %@", gate, activeTrail.waterCrossingIn, away, note)
        }
        return "Gate: \(gate) • Ford: \(activeTrail.waterCrossingIn)\" • \(note)"
    }

    private func routeMenuLabel(_ trail: OverlandTrail) -> String {
        let fit = shortFit(trail)
        let clearance = String(format: "%.0f\"", trail.reqClearanceIn)
        guard let user = locationTracker.userCoordinate else {
            return "\(trail.state) · \(trail.name) · \(clearance) · \(fit)"
        }
        let away = String(format: "%.1f mi away", miles(from: user, to: trail.centerCoordinate))
        return "\(trail.state) · \(trail.name) · \(away) · \(clearance) · \(fit)"
    }

    private func routePillLabel(_ trail: OverlandTrail) -> String {
        guard let user = locationTracker.userCoordinate else { return trail.name }
        return String(format: "%@ · %.0f mi", trail.name, miles(from: user, to: trail.centerCoordinate))
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
        if regionFilter == "bdr" {
            showTrailMenu = true
            if detent == .peek { detent = .half }
            if let selected = pickerTrails.first(where: { $0.id == selectedTrailID && $0.isBDR }), !followRoute {
                focus(on: selected)
            }
        } else if pickerTrails.contains(where: { $0.id == selectedTrailID }) {
            if !followRoute, let selected = pickerTrails.first(where: { $0.id == selectedTrailID }) {
                focus(on: selected)
            }
        } else if let first = pickerTrails.first(where: { !$0.isBDR }) {
            if followRoute { skipNextFocus = true }
            selectedTrailID = first.id
        } else {
            showTrailMenu = true
            if detent == .peek { detent = .half }
        }
        guard scanIfNear, regionFilter == "near" else { return }
        let center = locationTracker.userCoordinate ?? mapCenter
        Task { await telemetry.fetchTrailsInMapRegion(center: center) }
    }

    private func selectNearMe() {
        followRoute = false
        if let coordinate = locationTracker.userCoordinate {
            mapCenter = coordinate
        }
        if regionFilter != "near" {
            regionFilter = "near"
        } else {
            applyFilterSelection(scanIfNear: true)
        }
    }

    private func scanMapCenter() {
        if offlineFirst {
            telemetry.scanStatus = "Offline-first • cached trails, corridors, and rig-fit stay on device"
            return
        }
        Task { await telemetry.fetchTrailsInMapRegion(center: mapCenter) }
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
        let origin = locationTracker.userCoordinate ?? trail.trailhead.coordinate
        isRouting = true
        let built = await CampRouteBuilder.make(
            from: origin,
            to: spot,
            trailCoordinates: trail.coordinates,
            trailhead: trail.trailhead.coordinate,
            originWasGPS: originWasGPS
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
            frame(built)
            return
        }
        isRouteConfirmed = true
        if refit {
            followRoute = false
            frame(built)
            announceRouteStart(built)
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
        for pin in CruxCatalog.pins(for: activeTrail) where !announcedCrux.contains(pin.id) {
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

    private func applyCameraPitch(_ pitch: Double) {
        let clamped = min(max(pitch, 0), 70)
        cameraPitch = clamped
        is3DMapsEnabled = clamped > 1
        let center = lastMapCamera?.centerCoordinate ?? visibleRegion.center
        let distance = lastMapCamera?.distance ?? cameraDistance(for: visibleRegion)
        pushCamera(.camera(MapCamera(
            centerCoordinate: center,
            distance: distance,
            heading: lastMapCamera?.heading ?? lastCameraHeading,
            pitch: clamped
        )))
    }

    private func toggle3DMaps() {
        if is3DMapsEnabled && cameraPitch > 1 {
            applyCameraPitch(0)
        } else {
            applyCameraPitch(55)
        }
    }

    private func noteMapCamera(_ camera: MapCamera) {
        let now = Date()
        let pitchChanged = abs(camera.pitch - cameraPitch) > 2
        let headingChanged = abs(camera.heading - lastCameraHeading) > 8
        guard pitchChanged || headingChanged || now.timeIntervalSince(lastCameraNote) > 0.45 else { return }
        lastCameraNote = now
        lastMapCamera = camera
        lastCameraHeading = camera.heading
        if pitchChanged {
            cameraPitch = camera.pitch
            if camera.pitch > 8 { is3DMapsEnabled = true }
            if camera.pitch < 1 { is3DMapsEnabled = false }
        }
    }

    private func handleCameraEnd(_ region: MKCoordinateRegion) {
        let span = max(region.span.latitudeDelta, region.span.longitudeDelta)
        let center = region.center
        if offlineFirst {
            if parcelService.parcels.isEmpty {
                parcelService.replace(CockpitStore.loadParcels())
            }
        } else {
            parcelService.refresh(around: center)
            refreshHazards(around: center)
        }
        screenCenter = center
        visibleRegion = region
        if meters(from: mapCenter, to: center) > 40 {
            mapCenter = center
        }
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
        if showParcelLayer {
            parcelService.inspect(at: hit.coordinate)
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
            mapStage(showGloveRow: false)
            cockpitSheet(expanded: detent != .peek)
                .frame(height: sheetHeight(size.height))
        }
    }

    private func dashCockpit(_ size: CGSize) -> some View {
        HStack(spacing: 0) {
            mapStage(showGloveRow: true)
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

    private func mapStage(showGloveRow: Bool) -> some View {
        ZStack {
            routeMap
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
                        .padding(.trailing, 46)
                }
                if showGloveRow {
                    gloveRow
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
            }
            .padding(.top, 24)
            .padding(.leading, 8)
            HStack {
                Spacer()
                rightRail(showGloveRow)
            }
            .padding(.trailing, 5)
            .padding(.top, 24)
        }
        .colorMultiply(nightVision ? Color(red: 0.86, green: 0.38, blue: 0.16) : Color.white)
    }

    private var routeMap: some View {
        StableRouteMap(
            cameraPosition: $cameraPosition,
            sceneToken: mapSceneToken,
            cameraCommand: cameraCommand,
            showAlternates: showRouteAlternates,
            routeStartedFromGPS: routeStartedFromGPS,
            routingActive: activeRoute != nil,
            selectedTrailID: selectedTrailID,
            trails: mapTrails,
            trailColors: visibleTrailColors,
            selectedTrailLine: selectedTrailDraw,
            camps: mapCamps,
            route: activeRoute,
            parcels: parcelOpacity > 0.02 ? drawnParcels : [],
            selectedParcelID: parcelService.selectedID,
            parcelInspectEnabled: showParcelLayer || plotMode,
            basemap: effectiveBasemap,
            flatBasemap: heatLimited,
            parcelOpacity: parcelOpacity,
            trailOpacity: trailCorridorOpacity,
            campSlopeOpacity: campSlopeOpacity,
            hazardOpacity: hazardOverlayOpacity,
            starlinkOpacity: starlinkOverlayOpacity,
            hazards: mapHazards,
            searchedPlace: searchedPlace,
            plotLine: plottedLine,
            plotMarkers: plotPoints,
            recordedLine: breadcrumbLine,
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
                Task { await beginRoute(to: spot, previewOnly: spot.kind == .pad) }
            },
            onInspect: { coordinate in
                if plotMode {
                    addPlotPoint(coordinate)
                } else {
                    inspectParcels(at: coordinate)
                }
            },
            onSelectParcel: { id in
                if let parcel = parcelService.parcels.first(where: { $0.id == id }) {
                    parcelService.select(parcel)
                }
            },
            onLongPress: { coordinate in
                handleMapLongPress(coordinate)
            },
            onMapCamera: { camera in
                noteMapCamera(camera)
            },
            onSelectMarker: { id in
                if let marker = savedMarkers.first(where: { $0.id == id }) {
                    editingMarker = marker
                    pinName = marker.name
                    pinCategory = marker.category
                }
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
                showLayers = true
            }
            .accessibilityLabel("Map layers")
            railButton("view.3d", active: is3DMapsEnabled && cameraPitch > 1) {
                toggle3DMaps()
            }
            .accessibilityLabel(is3DMapsEnabled && cameraPitch > 1 ? "Switch to top-down map" : "Tilt map to 3D")
            railButton("point.topleft.down.curvedto.point.bottomright.up", active: plotMode) {
                togglePlotter()
            }
            .accessibilityLabel("Custom route plotter")
            railButton("arrow.down.circle.fill", active: showOffline) {
                showOffline = true
            }
            .accessibilityLabel("Download 5-mile corridor")
            railButton("camera.fill", active: showHazardSheet) {
                showHazardSheet = true
            }
            .accessibilityLabel("Drop hazard pin")
            railButton(trailRecorder.isRecording ? "stop.circle.fill" : "record.circle", active: trailRecorder.isRecording) {
                trailRecorder.toggleFromRail()
            }
            .accessibilityLabel(showGloveRow ? "Record trail route, in dash" : "Record trail route")
            railButton("moon.fill", active: nightVision) {
                nightVision.toggle()
            }
            .accessibilityLabel("Night vision")
        }
        .padding(4)
        .background(Color.black.opacity(0.84))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private var topCluster: some View {
        HStack(spacing: 6) {
            Button {
                scanMapCenter()
            } label: {
                Text(telemetry.isScanningTrails ? "Scanning…" : "↻ Scan Area")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.72))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(telemetry.isScanningTrails)
            Button {
                toggleParcelLayer()
            } label: {
                Text(showParcelLayer ? "Parcels" : "Parcels Off")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(showParcelLayer ? Color.cyan : Color.black.opacity(0.72))
                    .foregroundColor(showParcelLayer ? .black : .white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Button {
                showOffline = true
            } label: {
                Text("Offline")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.72))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Button {
                trailRecorder.toggleFromRail()
            } label: {
                Text(trailRecorder.isRecording ? "Stop" : "Record")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(trailRecorder.isRecording ? Color.red : Color.black.opacity(0.72))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
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
            gloveButton("Parcels", system: showParcelLayer ? "square.split.2x2.fill" : "square.dashed") {
                toggleParcelLayer()
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
                        if showParcelLayer {
                            Button("Inspect Point Parcel") {
                                parcelService.inspect(at: locationTracker.userCoordinate ?? mapCenter)
                            }
                            .font(.caption.bold())
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                        if let parcel = parcelService.selected {
                            propertyCard(parcel)
                        }
                        cockpitModeBody(includeFieldCards: true)
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
                    if let parcel = parcelService.selected {
                        propertyCard(parcel)
                    }
                    trailRecorderCard
                    savedMarkersCard
                    cockpitModeBody(includeFieldCards: false)
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
                 ? "Offline-first is on. Cached trails, backcountry corridors, saved parcels, and rig-fit stay available with no cell signal."
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
                        Text("Map Layers & Opacity")
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
                    Text("3D Terrain & Tilt")
                        .font(.caption.bold())
                    HStack(spacing: 8) {
                        terrainPitchButton("0°", pitch: 0)
                        terrainPitchButton("45°", pitch: 45)
                        terrainPitchButton("60°", pitch: 60)
                    }
                    opacitySlider("Property Boundaries & Landowners", value: $parcelOpacity)
                    opacitySlider("USFS & BLM Legal Trail Corridors", value: $trailCorridorOpacity)
                    opacitySlider("<3° LIDAR Flat Camp Slope Shading", value: $campSlopeOpacity)
                    opacitySlider("NIFC Wildfire Perimeters & USGS Hazards", value: $hazardOverlayOpacity)
                    opacitySlider("Starlink Clear-Sky & Cell Coverage Mask", value: $starlinkOverlayOpacity)
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
                    Text("Offline Maps — Area Box & Route Corridor")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Close") { showOffline = false }
                        .font(.caption.bold())
                }
                Text("Pan the map. A 30, 100, or 250 sq mi box stays centered on the screen. Current Map View uses the exact bounds on screen.")
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
                if offlineArea == "corridor" {
                    Picker("Pack", selection: $offlineTier) {
                        Text("Route + USFS snapshot").tag("Route + USFS snapshot")
                        Text("Route + parcels + hazards").tag("Route + parcels + hazards")
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
    }

    private var offlineAreaPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AREA SIZE")
                .font(.caption2.bold())
                .foregroundColor(.secondary)
            ForEach(offlineAreaChoices, id: \.id) { choice in
                Button(choice.title) { offlineArea = choice.id }
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(offlineArea == choice.id ? Color.cyan : Color.white.opacity(0.12))
                    .foregroundColor(offlineArea == choice.id ? .black : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var offlineAreaChoices: [(id: String, title: String)] {
        let viewMiles = Int(OfflineAreaBox.visible(visibleRegion).squareMiles.rounded())
        return [
            ("corridor", "5-Mi Route Corridor"),
            ("sq30", "30 sq mi Area"),
            ("sq100", "100 sq mi Area"),
            ("sq250", "250 sq mi Area"),
            ("view", "Current Screen View (~\(viewMiles) sq mi)")
        ]
    }

    private var offlineDownloadTitle: String {
        guard let box = liveOfflineBox() else { return "Download 5-Mile Corridor" }
        if offlineArea == "view" {
            return "Download Current Screen View (~\(Int(box.squareMiles.rounded())) sq mi)"
        }
        return "Download \(offlineArea == "sq100" ? 100 : offlineArea == "sq250" ? 250 : 30) sq mi Area"
    }

    private var offlineEstimateLine: String {
        guard let box = liveOfflineBox() else {
            return "5-mile buffer along the selected trail or active GPS route. Route, camps, crux pins, and a USFS snapshot."
        }
        let zooms = offlineZooms(for: box)
        let tiles = OfflineAreaMath.tileCount(for: box, zooms: zooms)
        let lookups = parcelGridCount(for: box)
        let trails = trailsInside(box).count
        let mb = max(4, tiles * 18 / 1024)
        let label = offlineArea == "view"
            ? "Current Screen View (~\(Int(box.squareMiles.rounded())) sq mi)"
            : "\(offlineArea == "sq100" ? 100 : offlineArea == "sq250" ? 250 : 30) sq mi Area"
        return "\(label) · ~\(tiles) tiles · \(lookups) parcel lookups · \(trails) trails · ~\(mb) MB"
    }

    private func terrainPitchButton(_ title: String, pitch: Double) -> some View {
        let selected = abs(cameraPitch - pitch) < 6
        return Button(title) {
            applyCameraPitch(pitch)
        }
        .font(.caption.bold())
        .buttonStyle(.borderedProminent)
        .tint(selected ? .cyan : .gray)
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
            if activeTrail.isBDR {
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

    private var cruxList: some View {
        let pins = CruxCatalog.pins(for: activeTrail)
        return VStack(alignment: .leading, spacing: 4) {
            if pins.isEmpty {
                EmptyView()
            } else {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func opacitySlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .lineLimit(2)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundColor(.cyan)
            }
            Slider(value: value, in: 0...1)
                .tint(.cyan)
        }
    }

    private var breadcrumbLine: [CLLocationCoordinate2D] {
        if trailRecorder.isRecording || !trailRecorder.activePoints.isEmpty {
            return trailRecorder.activePoints.map(\.coordinate)
        }
        if let id = trailRecorder.displayedRouteID,
           let route = trailRecorder.saved.first(where: { $0.id == id }) {
            return route.coordinates
        }
        return []
    }

    private var trailRecorderCard: some View {
        let _ = trailRecorder.elapsedTick
        return VStack(alignment: .leading, spacing: 8) {
            Text("Trail Route Recorder")
                .font(.caption.bold())
                .foregroundColor(.white)
            TextField("Route name", text: $trailRecorder.draftName)
                .textFieldStyle(.roundedBorder)
            HStack {
                statPill("Distance", String(format: "%.2f mi", trailRecorder.liveDistanceMiles))
                statPill("Elapsed", mmss(trailRecorder.elapsedSeconds))
                statPill("Elev Gain", "+\(trailRecorder.liveElevationGainFt) ft")
                statPill("Points", "\(trailRecorder.activePoints.count)")
            }
            HStack {
                if trailRecorder.isRecording {
                    Button(trailRecorder.isPaused ? "Resume" : "Pause") { trailRecorder.pauseOrResume() }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                    Button("Stop & Save Route") { trailRecorder.stopAndSave() }
                        .font(.caption.bold())
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button("Start Recording") { trailRecorder.start() }
                        .font(.caption.bold())
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
            ForEach(trailRecorder.saved) { route in
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.name)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                    Text(String(format: "%.2f mi · %@ · +%d ft · %d pts", route.distanceMiles, mmss(route.durationSeconds), route.elevationGainFt, route.points.count))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    HStack {
                        Button("Show / Navigate") { showRecordedRoute(route) }
                            .font(.caption2.bold())
                        ShareLink(item: trailRecorder.gpxURL(for: route), preview: SharePreview(route.name)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.caption2.bold())
                        }
                        Button("Delete") { trailRecorder.delete(route.id) }
                            .font(.caption2.bold())
                            .foregroundColor(.red)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.93, green: 0.11, blue: 0.36).opacity(0.7), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var savedMarkersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Saved Markers / Waypoints")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                Spacer()
                if savedMarkers.count >= 2 {
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
                        editingMarker = marker
                        pinName = marker.name
                        pinCategory = marker.category
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
        droppedPin = pin
        pinCategory = "Waypoint"
        pinName = "Saved Pin \(savedMarkers.count + 1)"
        pinSummary = "Looking up this point…"
        if let parcel = parcelService.parcel(at: coordinate) {
            let owner = parcel.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
            pinSummary = owner.isEmpty ? parcel.apnLotNumber : "\(owner) · \(parcel.apnLotNumber)"
            if !owner.isEmpty { pinName = owner }
        }
        parcelService.inspect(at: coordinate)
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

    private func showRecordedRoute(_ route: RecordedTrailRoute) {
        guard route.points.count >= 2, let end = route.points.last else { return }
        trailRecorder.displayedRouteID = route.id
        let coords = route.coordinates
        let spot = CampSpot(
            id: "rec-\(route.id.uuidString)",
            trailID: activeTrail.id,
            name: route.name,
            lat: end.latitude,
            lon: end.longitude,
            slopeDeg: 0,
            starlinkPct: 0,
            kind: .trailhead
        )
        let distance = max(route.distanceMiles * 1609.344, 1)
        let option = NavOption(
            id: 0,
            title: "Recorded trail",
            expectedTravelTime: max(60, distance / 8),
            distanceMeters: distance,
            road: coords,
            steps: recordedSteps(coords, title: route.name)
        )
        activeRoute = ActiveCampRoute(
            destination: spot,
            options: [option],
            selectedIndex: 0,
            spur: [],
            originWasGPS: locationTracker.userCoordinate != nil
        )
        routeStartedFromGPS = true
        activeStepIndex = 0
        announcedApproachStep = nil
        announcedTurnStep = nil
        announcedArrival = false
        followRoute = true
        frame(optionRoute(option, spot: spot))
        startFollow()
    }

    private func optionRoute(_ option: NavOption, spot: CampSpot) -> ActiveCampRoute {
        ActiveCampRoute(destination: spot, options: [option], selectedIndex: 0, spur: [], originWasGPS: true)
    }

    private func recordedSteps(_ coords: [CLLocationCoordinate2D], title: String) -> [NavStep] {
        guard coords.count >= 2 else {
            return [NavStep(id: 0, instruction: "Follow \(title)", distanceMeters: 0, systemImage: "point.topleft.down.to.point.bottomright.curvepath", maneuver: coords.last)]
        }
        var steps: [NavStep] = []
        var legStart = 0
        var previousBearing = bearing(from: coords[0], to: coords[1])
        for index in 1..<coords.count {
            let nextBearing = index + 1 < coords.count ? bearing(from: coords[index], to: coords[index + 1]) : previousBearing
            let delta = signedTurn(from: previousBearing, to: nextBearing)
            let atEnd = index == coords.count - 1
            if abs(delta) > 40 || atEnd {
                let meters = polylineMeters(Array(coords[legStart...index]))
                let instruction: String
                let symbol: String
                if atEnd && abs(delta) <= 40 {
                    instruction = "Arrive at \(title)"
                    symbol = "flag.checkered"
                } else if delta > 20 {
                    instruction = "Turn right along \(title)"
                    symbol = "arrow.turn.up.right"
                } else if delta < -20 {
                    instruction = "Turn left along \(title)"
                    symbol = "arrow.turn.up.left"
                } else {
                    instruction = "Continue on \(title)"
                    symbol = "arrow.up"
                }
                steps.append(NavStep(id: steps.count, instruction: instruction, distanceMeters: meters, systemImage: symbol, maneuver: coords[index]))
                legStart = index
                previousBearing = nextBearing
            }
        }
        if steps.isEmpty {
            steps.append(NavStep(id: 0, instruction: "Follow \(title)", distanceMeters: polylineMeters(coords), systemImage: "point.topleft.down.to.point.bottomright.curvepath", maneuver: coords.last))
        }
        return steps
    }

    private func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private func signedTurn(from: Double, to: Double) -> Double {
        (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    private func mmss(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
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
                .font(.subheadline.bold())
                .frame(width: 34, height: 34)
                .background(active ? Color.cyan : Color.black.opacity(0.78))
                .foregroundColor(active ? .black : .white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
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
        if plotMode, detent == .peek {
            detent = .half
        }
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
                if let existing = plotSegmentRoutes[key], existing.count >= 3 {
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
                guard let road, road.count >= 2 else { continue }
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
        CockpitStore.saveParcels(parcelService.parcels)
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
        let preset = offlineArea == "sq100" ? 100 : offlineArea == "sq250" ? 250 : offlineArea == "sq30" ? 30 : miles
        let label = offlineArea == "view" ? "Current Screen View (~\(miles) sq mi)" : "\(preset) sq mi Area"
        let tier = (satellite ? "Satellite" : "Topo") + " + Parcels + Trails"
        let spec = OfflineAreaDownload(
            box: box,
            areaSqMiles: preset,
            label: label,
            satellite: satellite,
            gridColumns: offlineArea == "sq250" || box.squareMiles > 45 ? 4 : 3,
            trails: trailsInside(box),
            hazards: mapHazards.filter { box.contains($0.point) },
            dropped: hazardPins.filter { box.contains($0.coordinate) }
        )
        CorridorDownloader.shared.start(trail: activeTrail, track: activeTrail.coordinates, hazards: spec.dropped, tier: tier, area: spec) { pack in
            var packs = CockpitStore.loadPacks()
            packs.insert(pack, at: 0)
            CockpitStore.savePacks(Array(packs.prefix(12)))
            offlinePacks = Array(packs.prefix(12))
            let cached = CockpitStore.loadParcels()
            if !cached.isEmpty {
                parcelService.replace(cached, limit: 80)
            }
            downloadProgress = 1
            downloadRunning = false
        }
    }

    private func liveOfflineBox() -> OfflineAreaBox? {
        guard showOffline || downloadRunning else { return nil }
        switch offlineArea {
        case "sq30":
            return .square(center: screenCenter, squareMiles: 30)
        case "sq100":
            return .square(center: screenCenter, squareMiles: 100)
        case "sq250":
            return .square(center: screenCenter, squareMiles: 250)
        case "view":
            return .visible(visibleRegion)
        default:
            return nil
        }
    }

    private func offlineZooms(for box: OfflineAreaBox) -> [Int] {
        if offlineArea == "sq30" || box.squareMiles <= 45 { return [11, 12, 13, 14, 15] }
        return [11, 12, 13, 14]
    }

    private func parcelGridCount(for box: OfflineAreaBox) -> Int {
        let columns = offlineArea == "sq250" || box.squareMiles > 45 ? 4 : 3
        return columns * columns
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
    }

    private func focusPack(_ pack: OfflineCorridorPack) {
        guard let minLat = pack.minLat, let maxLat = pack.maxLat, let minLon = pack.minLon, let maxLon = pack.maxLon else { return }
        let box = OfflineAreaBox(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
        showOffline = false
        screenCenter = box.center
        visibleRegion = box.region
        pushCamera(regionCamera(center: box.region.center, span: box.region.span))
        if let parcels = CorridorDownloader.parcels(in: pack.id), !parcels.isEmpty {
            parcelService.replace(parcels, limit: 80)
            CockpitStore.saveParcels(parcels, limit: 80)
        }
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

    private var parcelLayerTitle: String {
        if parcelService.isLoading { return "Scanning parcels…" }
        return showParcelLayer ? "Parcels / Owners" : "Parcels Off"
    }

    private func toggleParcelLayer() {
        showParcelLayer.toggle()
        parcelsCollapsedForFollow = false
        if showParcelLayer {
            parcelService.refresh(around: locationTracker.userCoordinate ?? mapCenter)
        }
    }

    private func scanParcelsHere() {
        showParcelLayer = true
        parcelsCollapsedForFollow = false
        parcelService.refresh(around: locationTracker.userCoordinate ?? mapCenter, force: true)
    }

    private func inspectParcels(at coordinate: CLLocationCoordinate2D) {
        parcelService.inspect(at: coordinate)
        if detent == .peek { detent = .half }
    }

    private func routeToLot(_ parcel: PropertyParcel) {
        let spot = CampSpot(
            id: "parcel-\(parcel.id)",
            trailID: activeTrail.id,
            name: parcel.pinLabel,
            lat: parcel.centerLat,
            lon: parcel.centerLon,
            slopeDeg: 0,
            starlinkPct: 0,
            kind: .trailhead
        )
        Task { await beginRoute(to: spot) }
    }

    private func propertyCard(_ parcel: PropertyParcel) -> some View {
        let badge = parcelBadgeColor(parcel)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(parcel.accessBadge)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(badge.opacity(0.22))
                    .foregroundColor(badge)
                    .clipShape(Capsule())
                Spacer()
                Button("Route to Lot") { routeToLot(parcel) }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
            }
            Text(parcel.ownerName)
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .lineLimit(2)
            Text(parcel.apnLotNumber)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(2)
            Text(parcel.acreage >= 0.05
                 ? String(format: "%.1f acres • %@", parcel.acreage, parcel.zoningOrUse)
                 : "Acreage not published • \(parcel.zoningOrUse)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
            if !parcel.streetAddress.isEmpty {
                Text(parcel.streetAddress)
                    .font(.caption2)
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
            if !parcel.censusLabel.isEmpty {
                Text(parcel.censusLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Text(parcel.sourceName.isEmpty ? parcel.countyAndState : "\(parcel.sourceName) • \(parcel.countyAndState)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
            Text(parcel.subdivisionOrTract)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
            if parcel.ownershipType == .privateParcel {
                Text(parcel.assessedValueOrStatus)
                    .font(.caption2)
                    .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.18))
                    .lineLimit(2)
            } else if !parcel.assessedValueOrStatus.isEmpty {
                Text(parcel.assessedValueOrStatus)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Button {
                copyCoordinate(parcel.centerCoordinate, token: "parcel-\(parcel.id)")
            } label: {
                HStack {
                    Text(formatCoordinate(parcel.centerCoordinate))
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    Text(copiedToken == "parcel-\(parcel.id)" ? "Copied" : "Copy")
                        .font(.caption2.bold())
                }
                .foregroundColor(.cyan)
            }
            .buttonStyle(.plain)
            if !parcelService.status.isEmpty {
                Text(parcelService.status)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func parcelBadgeColor(_ parcel: PropertyParcel) -> Color {
        switch parcel.ownershipType {
        case .privateParcel:
            return Color(red: 1.0, green: 0.72, blue: 0.18)
        case .publicUSFS:
            return Color(red: 0.10, green: 0.65, blue: 0.35)
        case .publicBLM:
            return Color(red: 0.95, green: 0.75, blue: 0.15)
        case .publicStateDNR, .publicNPS:
            return Color(red: 0.35, green: 0.70, blue: 0.95)
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

private struct StableRouteMap: View, Equatable {
    @Binding var cameraPosition: MapCameraPosition
    var sceneToken: Int
    var cameraCommand: Int
    var showAlternates: Bool
    var routeStartedFromGPS: Bool
    var routingActive: Bool
    var selectedTrailID: String
    var trails: [OverlandTrail]
    var trailColors: [String: Color]
    var selectedTrailLine: [CLLocationCoordinate2D]
    var camps: [CampSpot]
    var route: ActiveCampRoute?
    var parcels: [PropertyParcel]
    var selectedParcelID: String?
    var parcelInspectEnabled: Bool
    var basemap: BasemapChoice
    var flatBasemap: Bool
    var parcelOpacity: Double
    var trailOpacity: Double
    var campSlopeOpacity: Double
    var hazardOpacity: Double
    var starlinkOpacity: Double
    var hazards: [MapHazard]
    var searchedPlace: PlaceHit?
    var plotLine: [CLLocationCoordinate2D]
    var plotMarkers: [CLLocationCoordinate2D]
    var recordedLine: [CLLocationCoordinate2D]
    var savedMarkers: [SavedMarker]
    var droppedPin: CLLocationCoordinate2D?
    var scrub: CLLocationCoordinate2D?
    var liveOfflineRing: [CLLocationCoordinate2D]
    var savedOfflineRings: [[CLLocationCoordinate2D]]
    var onCameraEnd: (MKCoordinateRegion) -> Void
    var onCameraPreview: (MKCoordinateRegion) -> Void
    var onSpot: (CampSpot) -> Void
    var onInspect: (CLLocationCoordinate2D) -> Void
    var onSelectParcel: (String) -> Void
    var onLongPress: (CLLocationCoordinate2D) -> Void
    var onMapCamera: (MapCamera) -> Void = { _ in }
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
    }

    var body: some View {
        MapReader { proxy in
            mapBody
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        guard parcelInspectEnabled, let coordinate = proxy.convert(value.location, from: .local) else { return }
                        onInspect(coordinate)
                    }
                )
                .overlay {
                    MapTapOverlayView(proxy: proxy, onLongPress: onLongPress)
                }
        }
    }

    private var mapBody: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
            UserAnnotation()
            if campSlopeOpacity > 0.02 {
                ForEach(Array(camps.prefix(12))) { spot in
                    MapCircle(center: spot.coordinate, radius: 140)
                        .foregroundStyle(Color.green.opacity(0.28 * campSlopeOpacity))
                }
            }
            if starlinkOpacity > 0.02 {
                ForEach(Array(camps.prefix(12))) { spot in
                    MapCircle(center: spot.coordinate, radius: 220)
                        .foregroundStyle(Color.cyan.opacity(0.22 * starlinkOpacity * Double(spot.starlinkPct) / 100))
                }
            }
            if hazardOpacity > 0.02 {
                ForEach(hazards) { hazard in
                    hazardOverlay(hazard)
                }
            }
            if let trail = trails.first(where: { $0.id == selectedTrailID }) {
                ForEach(CruxCatalog.pins(for: trail)) { pin in
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
            }
            if plotLine.count >= 2 {
                MapPolyline(coordinates: plotLine)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 5]))
            }
            if recordedLine.count >= 2 {
                MapPolyline(coordinates: recordedLine)
                    .stroke(Color(red: 0.93, green: 0.11, blue: 0.36), style: StrokeStyle(lineWidth: 5, lineCap: .round))
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
            ForEach(parcels) { parcel in
                parcelOverlay(parcel)
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
                if selectedTrailLine.count >= 2, trailOpacity > 0.02 {
                    let dashed = trails.first?.legalStatus == "osm"
                    MapPolyline(coordinates: selectedTrailLine)
                        .stroke(
                            (trailColors[selectedTrailID] ?? Color.green).opacity(trailOpacity),
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: dashed ? [7, 5] : [])
                        )
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
                ForEach(trails) { trail in
                    if trail.coordinates.count >= 2, trailOpacity > 0.02 {
                        MapPolyline(coordinates: trail.coordinates)
                            .stroke(
                                (trailColors[trail.id] ?? Color.orange).opacity(trailOpacity),
                                style: StrokeStyle(lineWidth: trail.id == selectedTrailID ? 6.0 : 3.5, lineCap: .round, dash: TrailLegal.isDashed(trail) ? [7, 5] : [])
                            )
                    }
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
            MapUserLocationButton()
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

    @MapContentBuilder
    private func parcelOverlay(_ parcel: PropertyParcel) -> some MapContent {
        let style = parcelStyle(parcel)
        if parcel.hasBoundary {
            MapPolygon(coordinates: parcel.boundaryCoordinates)
                .foregroundStyle(style.fill.opacity(style.fillOpacity))
            MapPolyline(coordinates: parcel.boundaryCoordinates)
                .stroke(style.stroke, lineWidth: style.lineWidth)
        }
        Annotation("", coordinate: parcel.centerCoordinate) {
            Button {
                onSelectParcel(parcel.id)
            } label: {
                Text(parcel.pinLabel)
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.72))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func parcelStyle(_ parcel: PropertyParcel) -> (fill: Color, fillOpacity: Double, stroke: Color, lineWidth: CGFloat) {
        let selected = parcel.id == selectedParcelID
        let base: Color
        let restingOpacity: Double
        switch parcel.ownershipType {
        case .publicUSFS:
            base = Color(red: 0.05, green: 0.62, blue: 0.32)
            restingOpacity = 0.10
        case .publicBLM:
            base = Color(red: 0.95, green: 0.75, blue: 0.12)
            restingOpacity = 0.12
        case .publicStateDNR, .publicNPS:
            base = Color(red: 0.35, green: 0.70, blue: 0.95)
            restingOpacity = 0.10
        case .privateParcel:
            base = Color(red: 1.0, green: 0.72, blue: 0.18)
            restingOpacity = 0.10
        }
        let scale = max(0.0, min(parcelOpacity, 1.0))
        if selected {
            return (Color.cyan, 0.24 * scale, Color.cyan, 2.6)
        }
        return (base, restingOpacity * scale, base.opacity(scale), CGFloat(max(1.0, 1.6 * scale)))
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
                .foregroundStyle(Color.red.opacity(0.18 * hazardOpacity))
            MapPolyline(coordinates: hazard.coordinates)
                .stroke(Color.red.opacity(hazardOpacity), lineWidth: 1.5)
        } else {
            MapCircle(center: hazard.point, radius: hazard.radiusMeters)
                .foregroundStyle(Color.orange.opacity(0.28 * hazardOpacity))
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
        originWasGPS: Bool
    ) async -> ActiveCampRoute {
        let entry = closestCoordinate(on: trailCoordinates, to: origin) ?? trailhead
        let direct = await appleRoutes(from: origin, to: spot.coordinate)
        let directHits = direct.filter { endsNear($0.road, spot.coordinate, within: 3_218) }
        if !directHits.isEmpty {
            return pack(directHits, spot: spot, originWasGPS: originWasGPS)
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
                return pack(stitched, spot: spot, originWasGPS: originWasGPS)
            }
        }

        if let osrmPad = await osrmRoutes(from: origin, to: spot.coordinate) {
            let nearPad = osrmPad.filter { endsNear($0.road, spot.coordinate, within: 4_828) }
            if !nearPad.isEmpty {
                let prepared = nearPad.enumerated().map { index, option in
                    stitchTrail(option, index: index, trail: trailCoordinates, destination: spot.coordinate, name: spot.name)
                }
                return pack(prepared, spot: spot, originWasGPS: originWasGPS)
            }
        }

        if meters(from: entry, to: spot.coordinate) > 200,
           let osrmEntry = await osrmRoutes(from: origin, to: entry) {
            let nearEntry = osrmEntry.filter { endsNear($0.road, entry, within: 3_218) }
            if !nearEntry.isEmpty {
                let stitched = nearEntry.enumerated().map { index, option in
                    stitchTrail(option, index: index, trail: trailCoordinates, destination: spot.coordinate, name: spot.name)
                }
                return pack(stitched, spot: spot, originWasGPS: originWasGPS)
            }
        }

        if let stepped = await steppedAppleRoute(from: origin, toward: entry, trail: trailCoordinates, spot: spot) {
            return pack([stepped], spot: spot, originWasGPS: originWasGPS)
        }

        return ActiveCampRoute(
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

    private static func pack(_ options: [NavOption], spot: CampSpot, originWasGPS: Bool) -> ActiveCampRoute {
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
            spur: simplifyCoordinates(cappedSpur(from: road, to: spot.coordinate), maxPoints: 40, minMeters: 18),
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
        let urlString = "https://router.project-osrm.org/route/v1/driving/\(origin.longitude),\(origin.latitude);\(destination.longitude),\(destination.latitude)?overview=full&geometries=geojson&steps=true&alternatives=true"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? String) == "Ok",
              let routes = root["routes"] as? [[String: Any]] else { return nil }
        let options = routes.enumerated().compactMap { index, route -> NavOption? in
            parseOSRM(route, index: index, startingNear: origin)
        }
        return options.isEmpty ? nil : options
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

private func cappedSpur(from road: [CLLocationCoordinate2D], to destination: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
    guard let last = road.last else { return [] }
    let gap = meters(from: last, to: destination)
    if gap < 30 || gap > 3_218 { return [] }
    return [last, destination]
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
        if road.count >= 2 { return road }
    }
    let urlString = "https://router.project-osrm.org/route/v1/driving/\(origin.longitude),\(origin.latitude);\(destination.longitude),\(destination.latitude)?overview=full&geometries=geojson"
    guard let url = URL(string: urlString) else { return nil }
    var urlRequest = URLRequest(url: url)
    urlRequest.timeoutInterval = 20
    guard let (data, _) = try? await URLSession.shared.data(for: urlRequest),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (root["code"] as? String) == "Ok",
          let routes = root["routes"] as? [[String: Any]],
          let geometry = routes.first?["geometry"] as? [String: Any] else { return nil }
    let road = parseCoordinates(geometry["coordinates"])
    return road.count >= 2 ? road : nil
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
