import SwiftUI
import MapKit
import StoreKit
import UIKit

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
                systemImage: "point.topleft.down.to.point.bottomright.curvepath"
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

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.9589, longitude: -107.7352),
            span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.10)
        )
    )

    private var pickerTrails: [OverlandTrail] {
        let query = trailQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        func matchesQuery(_ trail: OverlandTrail) -> Bool {
            query.isEmpty || [trail.name, trail.region, trail.state, trail.agency].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
        func matchesFilter(_ trail: OverlandTrail) -> Bool {
            guard matchesQuery(trail) else { return false }
            switch regionFilter {
            case "all", "near":
                return true
            default:
                return trail.state == regionFilter
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
        default: return regionFilter
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let route = activeRoute {
                navigationBanner(route)
            } else {
                fitBanner
            }

            ZStack {
                Map(position: $cameraPosition) {
                    UserAnnotation()
                    if let route = activeRoute {
                        routeOverlay(route)
                    }
                    ForEach(pickerTrails) { trail in
                        if trail.coordinates.count >= 2 {
                            MapPolyline(coordinates: trail.coordinates)
                                .stroke(fitColor(trail), lineWidth: trail.id == selectedTrailID ? 6.0 : 3.5)
                        }
                        Annotation(trail.trailhead.name, coordinate: trail.trailhead.coordinate) {
                            Button {
                                Task { await beginRoute(to: trail.trailhead) }
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
                    }
                    ForEach(mapCampSpots) { spot in
                        Annotation(spot.name, coordinate: spot.coordinate) {
                            Button {
                                Task { await beginRoute(to: spot) }
                            } label: {
                                Text(String(format: "⛺ %.1f°", spot.slopeDeg))
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(spot.slopeDeg < 2 ? Color.green : Color.yellow)
                                    .foregroundColor(.black)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule().stroke(activeRoute?.destination.id == spot.id ? Color.white : Color.clear, lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
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
                    mapCenter = context.region.center
                }

                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            mapButton("Center on My GPS", systemImage: "location.fill") {
                                followRoute = false
                                cameraPosition = .userLocation(fallback: .automatic)
                            }
                            mapButton("Near My GPS", systemImage: "location.circle.fill") {
                                selectNearMe()
                            }
                            mapButton(telemetry.isScanningTrails ? "Scanning…" : "Scan Area for All USA 4x4 Trails", systemImage: "binoculars.fill") {
                                scanMapCenter()
                            }
                            .disabled(telemetry.isScanningTrails)
                        }
                        Spacer()
                    }
                    Spacer()
                    VStack(spacing: 8) {
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
        }
        .onChange(of: locationTracker.hasCenteredOnUserOnce) { _, centered in
            guard centered, let coordinate = locationTracker.userCoordinate else { return }
            mapCenter = coordinate
            if activeRoute == nil, regionFilter == "near" {
                applyFilterSelection(scanIfNear: true)
            } else if activeRoute == nil {
                cameraPosition = .userLocation(fallback: .automatic)
            }
        }
        .onChange(of: locationTracker.userCoordinate?.latitude) { _, _ in
            handleLiveGPS()
        }
        .onChange(of: selectedTrailID) { _, _ in
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
        .onChange(of: trailQuery) { _, _ in
            guard !pickerTrails.contains(where: { $0.id == selectedTrailID }), let first = pickerTrails.first else { return }
            selectedTrailID = first.id
        }
        .onChange(of: telemetry.isScanningTrails) { _, scanning in
            guard !scanning, regionFilter == "near", activeRoute == nil, !followRoute, let first = pickerTrails.first else { return }
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
        return HStack(spacing: 10) {
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
                    Text(route.destination.kind == .trailhead ? route.destination.name : String(format: "%@ • %.1f° • %d%% Starlink", route.destination.name, route.destination.slopeDeg, route.destination.starlinkPct))
                        .font(.caption)
                        .foregroundColor(.cyan)
                        .lineLimit(1)
                }
                Spacer()
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
        let remaining = remainingMeters(route)
        let eta = Date().addingTimeInterval(remainingSeconds(route, remaining: remaining))
        return VStack(alignment: .leading, spacing: 8) {
            Text(destinationTitle(route.destination))
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .lineLimit(2)
            HStack {
                Label(formatDuration(remainingSeconds(route, remaining: remaining)), systemImage: "clock")
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
                    Label(followRoute ? "Follow GPS" : "Start Turn-by-Turn", systemImage: "location.north.line.fill")
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
                        Button {
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
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    @MapContentBuilder
    private func routeOverlay(_ route: ActiveCampRoute) -> some MapContent {
        let road = route.selected.road
        if road.count >= 2 {
            MapPolyline(coordinates: road)
                .stroke(Color.blue.opacity(0.45), lineWidth: 14)
            MapPolyline(coordinates: road)
                .stroke(Color.cyan, lineWidth: 6)
        }
        if route.spur.count >= 2 {
            MapPolyline(coordinates: route.spur)
                .stroke(Color.green, lineWidth: 8)
            MapPolyline(coordinates: route.spur)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 6]))
        }
        if let start = road.first {
            Annotation("Start", coordinate: start) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.title3)
                    .foregroundColor(.green)
                    .background(Circle().fill(Color.white).padding(4))
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
        guard trail.centerLat != 0 || trail.centerLon != 0 else { return }
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: trail.centerCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.22, longitudeDelta: 0.22)
            ))
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
        let trail = trail(for: spot) ?? activeTrail
        let origin = locationTracker.userCoordinate ?? trail.trailhead.coordinate
        isRouting = true
        let built = await CampRouteBuilder.make(
            from: origin,
            to: spot,
            trailCoordinates: trail.coordinates,
            originWasGPS: originWasGPS
        )
        guard generation == routeGeneration else { return }
        isRouting = false
        activeRoute = built
        showAllSteps = false
        if spot.trailID != selectedTrailID {
            skipNextFocus = true
            selectedTrailID = spot.trailID
        }
        if refit {
            followRoute = false
            frame(built)
        } else if followRoute {
            cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
        }
    }

    private func handleLiveGPS() {
        guard let route = activeRoute, let user = locationTracker.userCoordinate else { return }
        if !route.originWasGPS {
            var updated = route
            updated.originWasGPS = true
            activeRoute = updated
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
        route.spur = overlandSpur(from: route.selected.road, to: route.destination.coordinate)
        activeRoute = route
        if !followRoute { frame(route) }
    }

    private func startFollow() {
        followRoute = true
        cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    }

    private func showOverview() {
        followRoute = false
        if let route = activeRoute { frame(route) }
    }

    private func endRoute() {
        routeGeneration += 1
        activeRoute = nil
        followRoute = false
        showAllSteps = false
        isRouting = false
    }

    private func frame(_ route: ActiveCampRoute) {
        var coords = route.roadAndSpur
        if let user = locationTracker.userCoordinate { coords.append(user) }
        coords.append(route.destination.coordinate)
        guard let minLat = coords.map(\.latitude).min(),
              let maxLat = coords.map(\.latitude).max(),
              let minLon = coords.map(\.longitude).min(),
              let maxLon = coords.map(\.longitude).max() else { return }
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                span: MKCoordinateSpan(
                    latitudeDelta: max(0.03, (maxLat - minLat) * 1.45),
                    longitudeDelta: max(0.03, (maxLon - minLon) * 1.45)
                )
            ))
        }
    }

    private func nextCue(_ route: ActiveCampRoute) -> (text: String, icon: String) {
        let steps = route.displaySteps
        guard let user = locationTracker.userCoordinate else {
            return ("Head toward \(route.destination.name)", "arrow.up")
        }
        let traveled = traveledMeters(user: user, along: route.roadAndSpur)
        var cursor = 0.0
        for step in steps {
            cursor += step.distanceMeters
            if cursor > traveled + 20 {
                let remaining = max(0, cursor - traveled)
                if step.id == 10_000 {
                    return ("Proceed \(formatDistance(remaining)) on overland spur to \(route.destination.name)", step.systemImage)
                }
                return ("In \(formatDistance(remaining)) • \(step.instruction)", step.systemImage)
            }
        }
        return ("Arriving at \(route.destination.name)", "flag.checkered")
    }

    private func remainingMeters(_ route: ActiveCampRoute) -> Double {
        let total = polylineMeters(route.roadAndSpur)
        guard let user = locationTracker.userCoordinate else { return total }
        return max(0, total - traveledMeters(user: user, along: route.roadAndSpur))
    }

    private func remainingSeconds(_ route: ActiveCampRoute, remaining: Double) -> TimeInterval {
        let total = max(route.selected.distanceMeters + route.spurMeters, 1)
        return route.selected.expectedTravelTime * (remaining / total)
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

private enum CampRouteBuilder {
    static func make(
        from origin: CLLocationCoordinate2D,
        to spot: CampSpot,
        trailCoordinates: [CLLocationCoordinate2D],
        originWasGPS: Bool
    ) async -> ActiveCampRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: spot.coordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        let directions = MKDirections(request: request)
        if let response = try? await directions.calculate(), !response.routes.isEmpty {
            let options = response.routes.enumerated().map { index, route in
                navOption(index: index, route: route)
            }
            let road = options[0].road
            return ActiveCampRoute(
                destination: spot,
                options: options,
                selectedIndex: 0,
                spur: overlandSpur(from: road, to: spot.coordinate),
                originWasGPS: originWasGPS
            )
        }
        let road = backcountryRoad(from: origin, to: spot.coordinate, trail: trailCoordinates)
        let distance = polylineMeters(road)
        let option = NavOption(
            id: 0,
            title: "Trail approach",
            expectedTravelTime: (distance / 1609.344) / 15.0 * 3600,
            distanceMeters: distance,
            road: road,
            steps: [
                NavStep(id: 0, instruction: "Follow the trail toward \(spot.name)", distanceMeters: distance, systemImage: "arrow.up")
            ]
        )
        return ActiveCampRoute(
            destination: spot,
            options: [option],
            selectedIndex: 0,
            spur: overlandSpur(from: road, to: spot.coordinate),
            originWasGPS: originWasGPS
        )
    }

    private static func navOption(index: Int, route: MKRoute) -> NavOption {
        var steps: [NavStep] = []
        for step in route.steps {
            let instruction = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { continue }
            steps.append(NavStep(
                id: steps.count,
                instruction: instruction,
                distanceMeters: step.distance,
                systemImage: maneuverIcon(instruction)
            ))
        }
        if steps.isEmpty {
            steps.append(NavStep(id: 0, instruction: "Continue to the trail", distanceMeters: route.distance, systemImage: "arrow.up"))
        }
        return NavOption(
            id: index,
            title: "Route \(index + 1)",
            expectedTravelTime: route.expectedTravelTime,
            distanceMeters: route.distance,
            road: coordinates(of: route.polyline),
            steps: steps
        )
    }
}

private func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
    let count = polyline.pointCount
    guard count > 0 else { return [] }
    var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0), count: count)
    polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
    return coords
}

private func overlandSpur(from road: [CLLocationCoordinate2D], to destination: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
    guard let last = road.last else { return [destination] }
    if meters(from: last, to: destination) < 30 {
        return [last, destination]
    }
    return [last, destination]
}

private func backcountryRoad(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, trail: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    guard trail.count >= 2 else { return [origin, destination] }
    let start = nearestVertex(origin, on: trail)
    let end = nearestVertex(destination, on: trail)
    let slice: [CLLocationCoordinate2D]
    if start <= end {
        slice = Array(trail[start...end])
    } else {
        slice = Array(trail[end...start].reversed())
    }
    return [origin] + slice
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
