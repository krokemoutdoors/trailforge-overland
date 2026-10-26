import SwiftUI
import MapKit
import StoreKit
import UIKit
import AVFoundation

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
    @EnvironmentObject var rigStore: RigProfileStore
    @EnvironmentObject var motionManager: ClinometerMotionManager
    @EnvironmentObject var storeKit: TrailForgeStoreKitManager
    @StateObject private var telemetry = LiveTelemetryService()
    @StateObject private var locationTracker = LocationTracker()

    @State private var mode: CockpitMode = .drive
    @State private var selectedTrailID: String = "imogene"
    @State private var trailQuery: String = ""
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

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.9589, longitude: -107.7352),
            span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.10)
        )
    )

    private var pickerTrails: [OverlandTrail] {
        let query = trailQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        func matchesQuery(_ trail: OverlandTrail) -> Bool {
            query.isEmpty || [trail.name, trail.region, trail.state, trail.alsoStates.joined(separator: " "), trail.agency].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
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
        pickerTrails.first(where: { $0.id == selectedTrailID })
            ?? pickerTrails.first
            ?? USATrailAtlas.all[0]
    }

    private var mapCampSpots: [CampSpot] {
        pickerTrails.flatMap(\.campSpots)
    }

    private var mapTrails: [OverlandTrail] {
        activeRoute == nil ? pickerTrails : [activeTrail]
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
        return Array(parcelService.parcels.prefix(18))
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
        return hasher.finalize()
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
        case "bdr": return "BDR"
        default: return regionFilter
        }
    }

    var body: some View {
        let _ = syncCameraGate()
        VStack(spacing: 0) {
            if let route = activeRoute {
                navigationBanner(route)
            } else {
                fitBanner
            }

            ZStack {
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
                    parcels: drawnParcels,
                    selectedParcelID: parcelService.selectedID,
                    parcelInspectEnabled: showParcelLayer,
                    onCameraEnd: { region in
                        handleCameraEnd(region)
                    },
                    onSpot: { spot in
                        Task { await beginRoute(to: spot) }
                    },
                    onInspect: { coordinate in
                        inspectParcels(at: coordinate)
                    },
                    onSelectParcel: { id in
                        if let parcel = parcelService.parcels.first(where: { $0.id == id }) {
                            parcelService.select(parcel)
                        }
                    }
                )
                .equatable()

                VStack {
                    HStack {
                        if activeRoute == nil {
                            VStack(alignment: .leading, spacing: 8) {
                                mapButton("Center on My GPS", systemImage: "location.fill") {
                                    followRoute = false
                                    showingRouteOverview = false
                                    pushCamera(.userLocation(fallback: .automatic))
                                }
                                mapButton("Near My GPS", systemImage: "location.circle.fill") {
                                    selectNearMe()
                                }
                                mapButton(telemetry.isScanningTrails ? "Scanning…" : "Scan Area for All USA 4x4 Trails", systemImage: "binoculars.fill") {
                                    scanMapCenter()
                                }
                                .disabled(telemetry.isScanningTrails)
                                mapButton(parcelLayerTitle, systemImage: showParcelLayer ? "square.split.2x2.fill" : "square.dashed") {
                                    toggleParcelLayer()
                                }
                                if showParcelLayer {
                                    mapButton(parcelService.isLoading ? "Scanning parcels…" : "Scan Parcels Here", systemImage: "map.fill") {
                                        scanParcelsHere()
                                    }
                                    .disabled(parcelService.isLoading)
                                }
                            }
                        } else {
                            HStack(spacing: 6) {
                                miniMapButton("location.fill") {
                                    followRoute = false
                                    showingRouteOverview = false
                                    pushCamera(.userLocation(fallback: .automatic))
                                }
                                miniMapButton("location.circle.fill") { selectNearMe() }
                                miniMapButton(telemetry.isScanningTrails ? "hourglass" : "binoculars.fill") { scanMapCenter() }
                                    .disabled(telemetry.isScanningTrails)
                                miniMapButton(showParcelLayer ? "square.split.2x2.fill" : "square.dashed") { toggleParcelLayer() }
                                if showParcelLayer {
                                    miniMapButton("map.fill") { scanParcelsHere() }
                                        .disabled(parcelService.isLoading)
                                }
                            }
                        }
                        Spacer()
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        coordinatesBar(filled: true)
                        Text(gpsTelemetryLine)
                            .font(.caption.monospacedDigit().bold())
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                        HStack(spacing: 16) {
                            let psi = rigStore.recommendedAirDownPSI(surface: "rock", beadlocks: false)
                            Label("Roll \(Int(motionManager.rollDegrees))° / Pitch \(Int(motionManager.pitchDegrees))°", systemImage: "gyroscope")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundColor(abs(motionManager.rollDegrees) >= 25 ? .red : .cyan)
                            Divider().frame(height: 14)
                            Text("Air Down: \(psi.front)F / \(psi.rear)R PSI")
                                .font(.caption.bold())
                                .foregroundColor(.mint)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                    .padding(.bottom, 10)
                }
                .padding(.top, 10)
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: .infinity)

            if let route = activeRoute {
                routeCard(route)
            }

            VStack(spacing: 10) {
                if let parcel = parcelService.selected {
                    propertyCard(parcel)
                }
                Picker("Mode", selection: $mode) {
                    ForEach(CockpitMode.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if mode == .drive {
                    driveControls
                } else if mode == .camp {
                    campList
                } else {
                    HStack {
                        Stepper("Tires: \(Int(rigStore.profile.tireInches))\"", value: $rigStore.profile.tireInches, in: 29...37, step: 1)
                        Toggle("Locker", isOn: $rigStore.profile.hasRearLocker)
                            .labelsHidden()
                    }
                    .font(.caption.bold())
                }
            }
            .padding(14)
            .background(Color(red: 0.06, green: 0.09, blue: 0.14))
        }
        .onAppear {
            motionManager.startUpdates()
            locationTracker.start()
            refreshSelectedTrailDraw()
            parcelService.refresh(around: locationTracker.userCoordinate ?? mapCenter, force: true)
        }
        .onChange(of: locationTracker.hasCenteredOnUserOnce) { _, centered in
            guard centered, let coordinate = locationTracker.userCoordinate else { return }
            mapCenter = coordinate
            parcelService.refresh(around: coordinate, force: true)
            if activeRoute == nil, regionFilter == "near" {
                applyFilterSelection(scanIfNear: true)
            } else if activeRoute == nil {
                pushCamera(.userLocation(fallback: .automatic))
            }
        }
        .onChange(of: locationTracker.locationRevision) { _, _ in
            handleLiveGPS()
        }
        .onChange(of: selectedTrailID) { _, newID in
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
        .onChange(of: followRoute) { _, following in
            if following {
                if showParcelLayer {
                    showParcelLayer = false
                    parcelsCollapsedForFollow = true
                }
            } else if parcelsCollapsedForFollow {
                showParcelLayer = true
                parcelsCollapsedForFollow = false
            }
        }
        .onChange(of: trailQuery) { _, _ in
            guard !pickerTrails.contains(where: { $0.id == selectedTrailID }), let first = pickerTrails.first else { return }
            selectedTrailID = first.id
        }
        .onChange(of: telemetry.isScanningTrails) { _, scanning in
            guard !scanning else { return }
            refreshSelectedTrailDraw()
            guard regionFilter == "near", activeRoute == nil, !followRoute, let first = pickerTrails.first else { return }
            if selectedTrailID != first.id {
                selectedTrailID = first.id
            }
        }
        .task {
            await telemetry.fetchUSGSStreamflow()
            await storeKit.loadProducts()
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
            Text(destinationTitle(route.destination))
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .lineLimit(2)
            Text(formatCoordinate(route.destination.coordinate))
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.05, green: 0.08, blue: 0.12))
    }

    private var driveControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search trails or state", text: $trailQuery)
                .textFieldStyle(.roundedBorder)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterPill("Near Me", tag: "near")
                    filterPill("All USA", tag: "all")
                    filterPill("BDR Routes", tag: "bdr")
                    ForEach(USATrailAtlas.states, id: \.self) { state in
                        filterPill(state, tag: state)
                    }
                }
            }
            Menu {
                if pickerTrails.isEmpty {
                    Button("No matching routes") {}
                        .disabled(true)
                }
                ForEach(pickerTrails) { trail in
                    Button {
                        selectedTrailID = trail.id
                    } label: {
                        Text(routeMenuLabel(trail))
                    }
                }
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pickerTrails) { trail in
                        Button {
                            selectedTrailID = trail.id
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
                                Task { await beginRoute(to: spot) }
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
        if let user = locationTracker.userCoordinate {
            let away = miles(from: user, to: activeTrail.centerCoordinate)
            return String(format: "Gate: %@ • Ford: %d\" • %.1f mi • %@", activeTrail.gateStatus, activeTrail.waterCrossingIn, away, note)
        }
        return "Gate: \(activeTrail.gateStatus) • Ford: \(activeTrail.waterCrossingIn)\" • \(note)"
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
            pushCamera(.region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
            )))
        }
    }

    private func applyFilterSelection(scanIfNear: Bool) {
        if let first = pickerTrails.first {
            if selectedTrailID != first.id {
                if followRoute { skipNextFocus = true }
                selectedTrailID = first.id
            } else if !followRoute {
                focus(on: first)
            }
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
        Task { await telemetry.fetchTrailsInMapRegion(center: mapCenter) }
    }

    private func beginRoute(to spot: CampSpot, refit: Bool = true) async {
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
        guard let route = activeRoute, let user = locationTracker.userCoordinate else { return }
        if !routeStartedFromGPS {
            routeStartedFromGPS = true
            Task { await beginRoute(to: route.destination, refit: !followRoute) }
            return
        }
        guard followRoute, Date().timeIntervalSince(lastReroute) > 25 else { return }
        guard offRouteMeters(user, route: route) > 450 else { return }
        lastReroute = Date()
        Task { await beginRoute(to: route.destination, refit: false) }
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
        announceRouteStart(route)
        skipStepsAlreadyReached()
        if !followRoute { frame(route) }
    }

    private func startFollow() {
        followRoute = true
        showingRouteOverview = false
        followUserCamera()
        if let route = activeRoute {
            announceRouteStart(route)
        }
    }

    private func followUserCamera() {
        let center = locationTracker.userCoordinate ?? mapCenter
        cameraGate.ignoreFollowDisengageUntil = Date().addingTimeInterval(0.45)
        showingRouteOverview = false
        pushCamera(.userLocation(
            followsHeading: true,
            fallback: .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            ))
        ))
    }

    private func showOverview() {
        followRoute = false
        if let route = activeRoute { frame(route) }
    }

    private func endRoute() {
        routeGeneration += 1
        activeRoute = nil
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
            pushCamera(.region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
            )))
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
        guard let route = activeRoute, let user = locationTracker.userCoordinate else { return }
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
            voiceGuide.speak("In point two miles, \(step.instruction)", enabled: isVoiceGuidanceEnabled)
        }
    }

    private func announceRouteStart(_ route: ActiveCampRoute) {
        let first = route.displaySteps.first?.instruction ?? "Follow the route"
        var text = "Route to \(route.destination.name), \(spokenDuration(route.selected.expectedTravelTime)). \(first)."
        if route.displaySteps.count > 1 {
            text += " Then \(route.displaySteps[1].instruction)."
        }
        voiceGuide.speak(text, enabled: isVoiceGuidanceEnabled)
    }

    private func speakCurrentStep(_ route: ActiveCampRoute) {
        let steps = route.displaySteps
        guard !steps.isEmpty else { return }
        let step = steps[min(activeStepIndex, steps.count - 1)]
        voiceGuide.speak(step.instruction, enabled: isVoiceGuidanceEnabled)
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

    private func handleCameraEnd(_ region: MKCoordinateRegion) {
        let span = max(region.span.latitudeDelta, region.span.longitudeDelta)
        let center = region.center
        parcelService.refresh(around: center)
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
                pushCamera(.region(region))
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
        if let parcel = drawnParcels.first(where: { $0.contains(coordinate) }) ?? parcelService.parcel(at: coordinate) {
            parcelService.select(parcel)
            return
        }
        parcelService.refresh(around: coordinate, force: true)
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
            Text(String(format: "%.1f acres • %@", parcel.acreage, parcel.zoningOrUse))
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
            Text("\(parcel.subdivisionOrTract) • \(parcel.countyAndState)")
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
    var onCameraEnd: (MKCoordinateRegion) -> Void
    var onSpot: (CampSpot) -> Void
    var onInspect: (CLLocationCoordinate2D) -> Void
    var onSelectParcel: (String) -> Void

    static func == (lhs: StableRouteMap, rhs: StableRouteMap) -> Bool {
        lhs.sceneToken == rhs.sceneToken
            && lhs.cameraCommand == rhs.cameraCommand
            && lhs.showAlternates == rhs.showAlternates
            && lhs.routeStartedFromGPS == rhs.routeStartedFromGPS
            && lhs.routingActive == rhs.routingActive
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
        }
    }

    private var mapBody: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()
            ForEach(parcels) { parcel in
                parcelOverlay(parcel)
            }
            if let route {
                routeStroke(route)
            }
            if routingActive {
                if selectedTrailLine.count >= 2 {
                    MapPolyline(coordinates: selectedTrailLine)
                        .stroke(trailColors[selectedTrailID] ?? Color.green, lineWidth: 3.5)
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
                    if trail.coordinates.count >= 2 {
                        MapPolyline(coordinates: trail.coordinates)
                            .stroke(trailColors[trail.id] ?? Color.orange, lineWidth: trail.id == selectedTrailID ? 6.0 : 3.5)
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
        .mapStyle(.hybrid(elevation: .realistic))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            onCameraEnd(context.region)
        }
    }

    @MapContentBuilder
    private func parcelOverlay(_ parcel: PropertyParcel) -> some MapContent {
        let style = parcelStyle(parcel)
        MapPolygon(coordinates: parcel.boundaryCoordinates)
            .foregroundStyle(style.fill.opacity(style.fillOpacity))
        MapPolyline(coordinates: parcel.boundaryCoordinates)
            .stroke(style.stroke, lineWidth: style.lineWidth)
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
        if selected {
            return (Color.cyan, 0.24, Color.cyan, 2.6)
        }
        return (base, restingOpacity, base, 1.6)
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
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
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
    if abs(miles - 1) < 0.05 { return "1 mile" }
    if miles < 10 { return String(format: "%.1f miles", miles) }
    return String(format: "%.0f miles", miles)
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
