import SwiftUI
import MapKit
import StoreKit

// MARK: - Ultra-Simple 3-Mode Anti-Bloat UI (Beats Gaia GPS & onX Offroad)
enum CockpitMode: String, CaseIterable {
    case drive = "1. Go Drive"
    case camp  = "2. Flat Camp"
    case rig   = "3. My Rig"
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

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.9589, longitude: -107.7352),
            span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.10)
        )
    )

    private var filteredCatalog: [OverlandTrail] {
        let query = trailQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return USATrailAtlas.all.filter { trail in
            let matchesQuery = query.isEmpty || [trail.name, trail.region, trail.state, trail.agency].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
            let matchesRegion: Bool
            switch regionFilter {
            case "all":
                matchesRegion = true
            case "near":
                if let user = locationTracker.userCoordinate {
                    matchesRegion = miles(from: user, to: trail.centerCoordinate) <= 250
                } else {
                    matchesRegion = true
                }
            default:
                matchesRegion = trail.state == regionFilter
            }
            return matchesQuery && matchesRegion
        }
    }

    private var pickerTrails: [OverlandTrail] {
        var trails = filteredCatalog
        var seen = Set(trails.map(\.id))
        for trail in telemetry.discoveredTrails where seen.insert(trail.id).inserted {
            trails.append(trail)
        }
        if let selected = USATrailAtlas.all.first(where: { $0.id == selectedTrailID }),
           !seen.contains(selected.id) {
            trails.insert(selected, at: 0)
        }
        if trails.isEmpty, let first = USATrailAtlas.all.first {
            return [first]
        }
        return trails
    }

    private var activeTrail: OverlandTrail {
        pickerTrails.first(where: { $0.id == selectedTrailID })
            ?? USATrailAtlas.all.first(where: { $0.id == selectedTrailID })
            ?? USATrailAtlas.all[0]
    }

    private var campAnnotations: [OverlandTrail] {
        var trails = telemetry.discoveredTrails
        if !trails.contains(where: { $0.id == activeTrail.id }) {
            trails.insert(activeTrail, at: 0)
        }
        return trails
    }

    var body: some View {
        VStack(spacing: 0) {
            let fit = rigStore.evaluate(trail: activeTrail)
            HStack(spacing: 10) {
                Circle()
                    .fill(fitColor(activeTrail))
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(fit.verdict.rawValue) • \(activeTrail.name)")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
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

            ZStack {
                Map(position: $cameraPosition) {
                    UserAnnotation()
                    ForEach(pickerTrails) { trail in
                        if trail.coordinates.count >= 2 {
                            MapPolyline(coordinates: trail.coordinates)
                                .stroke(fitColor(trail), lineWidth: trail.id == selectedTrailID ? 6.0 : 3.5)
                        }
                    }
                    ForEach(campAnnotations) { trail in
                        ForEach(Array(trail.flatCamps.enumerated()), id: \.offset) { _, camp in
                            if camp.slopeDeg < 3 {
                                Annotation(camp.name, coordinate: CLLocationCoordinate2D(latitude: camp.lat, longitude: camp.lon)) {
                                    Text(String(format: "⛺ %.1f°", camp.slopeDeg))
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(camp.slopeDeg < 2 ? Color.green : Color.yellow)
                                        .foregroundColor(.black)
                                        .clipShape(Capsule())
                                }
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
                    mapCenter = context.region.center
                }

                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            mapButton("Center on My GPS", systemImage: "location.fill") {
                                cameraPosition = .userLocation(fallback: .automatic)
                            }
                            mapButton("Near My GPS", systemImage: "location.circle.fill") {
                                centerOnUserAndScan()
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

            VStack(spacing: 12) {
                Picker("Mode", selection: $mode) {
                    ForEach(CockpitMode.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if mode == .drive {
                    TextField("Search trails or state", text: $trailQuery)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("Area", selection: $regionFilter) {
                            Text("Near Me").tag("near")
                            Text("All USA").tag("all")
                            ForEach(USATrailAtlas.states, id: \.self) { state in
                                Text(state).tag(state)
                            }
                        }
                        .pickerStyle(.menu)
                        Picker("Trail", selection: $selectedTrailID) {
                            ForEach(pickerTrails) { trail in
                                Text("\(trail.state) · \(trail.name)").tag(trail.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if !telemetry.scanStatus.isEmpty {
                        Text(telemetry.scanStatus)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if mode == .camp {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nearest Verified Flat Camp: \(nearestCampName)")
                                .font(.subheadline.bold())
                            Text(nearestCampDetail)
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        Spacer()
                    }
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
            if centered, let coordinate = locationTracker.userCoordinate {
                mapCenter = coordinate
                cameraPosition = .userLocation(fallback: .automatic)
            }
        }
        .onChange(of: selectedTrailID) { _, _ in
            focus(on: activeTrail)
        }
        .onChange(of: regionFilter) { _, _ in
            let before = selectedTrailID
            keepSelectionVisible()
            if selectedTrailID == before {
                skipNextFocus = false
            }
        }
        .onChange(of: trailQuery) { _, _ in
            keepSelectionVisible()
        }
        .task {
            await telemetry.fetchUSGSStreamflow()
            await storeKit.loadProducts()
        }
    }

    private var gpsTelemetryLine: String {
        switch locationTracker.authorizationStatus {
        case .denied, .restricted:
            return "Location off — enable in Settings"
        default:
            break
        }
        guard let user = locationTracker.userCoordinate else {
            return "Waiting for GPS…"
        }
        let selected = miles(from: user, to: activeTrail.centerCoordinate)
        let nearest = pickerTrails.map { miles(from: user, to: $0.centerCoordinate) }.min() ?? selected
        return String(format: "%d ft · %.0f mph · %.1f mi to trail · %.1f mi nearest", locationTracker.altitudeFt, locationTracker.speedMph, selected, nearest)
    }

    private var nearestCampName: String {
        nearestCamp?.name ?? "None on this trail"
    }

    private var nearestCampDetail: String {
        guard let camp = nearestCamp else {
            return "Scan the map or pick a trail to load a <3° pad."
        }
        return String(format: "%.1f° Slope (No Blocks Needed) • %d%% Starlink Sky • %@", camp.slopeDeg, camp.starlinkPct, activeTrail.agency)
    }

    private var nearestCamp: (name: String, lat: Double, lon: Double, slopeDeg: Double, starlinkPct: Int)? {
        let pads = activeTrail.flatCamps.filter { $0.slopeDeg < 3 }
        guard let user = locationTracker.userCoordinate else {
            return pads.min(by: { $0.slopeDeg < $1.slopeDeg })
        }
        return pads.min { lhs, rhs in
            miles(from: user, to: CLLocationCoordinate2D(latitude: lhs.lat, longitude: lhs.lon))
                < miles(from: user, to: CLLocationCoordinate2D(latitude: rhs.lat, longitude: rhs.lon))
        }
    }

    private func bannerDetail(fitNotes: [String]) -> String {
        let note = fitNotes.first ?? ""
        if let user = locationTracker.userCoordinate {
            let away = miles(from: user, to: activeTrail.centerCoordinate)
            return String(format: "Gate: %@ • Ford: %d\" • %.1f mi • %@", activeTrail.gateStatus, activeTrail.waterCrossingIn, away, note)
        }
        return "Gate: \(activeTrail.gateStatus) • Ford: \(activeTrail.waterCrossingIn)\" • \(note)"
    }

    private func fitColor(_ trail: OverlandTrail) -> Color {
        switch rigStore.evaluate(trail: trail).verdict {
        case .fits:
            return .green
        case .caution:
            return .orange
        case .noGo:
            return .red
        }
    }

    private func miles(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let start = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let end = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return start.distance(from: end) / 1609.344
    }

    private func focus(on trail: OverlandTrail) {
        if skipNextFocus {
            skipNextFocus = false
            return
        }
        guard trail.centerLat != 0 || trail.centerLon != 0 else { return }
        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: trail.centerCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.22, longitudeDelta: 0.22)
                )
            )
        }
    }

    private func keepSelectionVisible() {
        if !pickerTrails.contains(where: { $0.id == selectedTrailID }), let first = pickerTrails.first {
            selectedTrailID = first.id
        }
    }

    private func centerOnUserAndScan() {
        cameraPosition = .userLocation(fallback: .automatic)
        if let coordinate = locationTracker.userCoordinate {
            mapCenter = coordinate
        }
        if regionFilter != "near" {
            skipNextFocus = true
            regionFilter = "near"
        }
        let center = locationTracker.userCoordinate ?? mapCenter
        Task { await telemetry.fetchTrailsInMapRegion(center: center) }
    }

    private func scanMapCenter() {
        Task { await telemetry.fetchTrailsInMapRegion(center: mapCenter) }
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
