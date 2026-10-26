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

    @State private var mode: CockpitMode = .drive
    @State private var selectedTrailIndex: Int = 0
    @State private var offlineSaved: Bool = true
    @State private var showProPaywall: Bool = false

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.9589, longitude: -107.7352),
            span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.10)
        )
    )

    let trails: [OverlandTrail] = [
        OverlandTrail(
            id: "imogene",
            name: "Imogene Pass (FS-869)",
            region: "Ouray to Telluride, CO",
            agency: "USFS Legal Dispersed",
            distanceMi: 17.2,
            peakElevFt: 13114,
            reqClearanceIn: 10.5,
            minCanopyFt: 8.5,
            waterCrossingIn: 19,
            reqLocker: true,
            gateStatus: "OPEN",
            snotelSnowIn: 4.2,
            usgsFlowCfs: 12
        ),
        OverlandTrail(
            id: "whiterim",
            name: "White Rim & Shafer Trail",
            region: "Moab, UT",
            agency: "BLM Legal Boondocking",
            distanceMi: 71.4,
            peakElevFt: 6180,
            reqClearanceIn: 9.8,
            minCanopyFt: 11.5,
            waterCrossingIn: 12,
            reqLocker: false,
            gateStatus: "OPEN",
            snotelSnowIn: 0.0,
            usgsFlowCfs: 8940
        ),
        OverlandTrail(
            id: "usal",
            name: "Lost Coast Usal Redwood Rd",
            region: "Mendocino Coast, CA",
            agency: "BLM Coast Corridor",
            distanceMi: 26.8,
            peakElevFt: 2840,
            reqClearanceIn: 9.2,
            minCanopyFt: 7.4,
            waterCrossingIn: 16,
            reqLocker: false,
            gateStatus: "CAUTION",
            snotelSnowIn: 0.0,
            usgsFlowCfs: 68
        )
    ]

    var activeTrail: OverlandTrail { trails[selectedTrailIndex] }

    var body: some View {
        VStack(spacing: 0) {
            // 1. TOP TRAFFIC-LIGHT BANNER (Zero guessing if your rig fits)
            let fit = rigStore.evaluate(trail: activeTrail)
            HStack(spacing: 10) {
                Circle()
                    .fill(fit.verdict == .fits ? Color.green : (fit.verdict == .caution ? Color.orange : Color.red))
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(fit.verdict.rawValue) • \(activeTrail.name)")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Text("Gate: \(activeTrail.gateStatus) • Ford: \(activeTrail.waterCrossingIn)\" • \(fit.notes.first ?? "")")
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

            // 2. FULL-BLEED GLANCEABLE MAP (Fused Topo + Public Land + Flat Camps)
            ZStack(alignment: .bottom) {
                Map(position: $cameraPosition) {
                    Annotation("⛺ Flat Pad #1 (1.4° • 96% Starlink)", coordinate: CLLocationCoordinate2D(latitude: 37.98142, longitude: -107.73411)) {
                        Text("⛺ 1.4° FLAT")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.green)
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }
                    Annotation("⛺ Flat Pad #2 (2.1° • 99% Starlink)", coordinate: CLLocationCoordinate2D(latitude: 37.94185, longitude: -107.73598)) {
                        Text("⛺ 2.1° FLAT")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.yellow)
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }
                }
                .mapStyle(.hybrid(elevation: .realistic))

                // Floating Clinometer & Tire PSI Pill on Map
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
                .padding(.bottom, 10)
            }
            .frame(maxHeight: .infinity)

            // 3. BOTTOM ONE-HANDED THUMB SHEET (Only 3 Big Buttons)
            VStack(spacing: 12) {
                Picker("Mode", selection: $mode) {
                    ForEach(CockpitMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                if mode == .drive {
                    Picker("Select Trail", selection: $selectedTrailIndex) {
                        ForEach(0..<trails.count, id: \.self) { idx in
                            Text(trails[idx].name).tag(idx)
                        }
                    }
                    .pickerStyle(.menu)
                } else if mode == .camp {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nearest Verified Flat Camp: Upper Basin Pad #1")
                                .font(.subheadline.bold())
                            Text("1.4° Slope (No Blocks Needed) • 96% Starlink Sky • USFS Legal")
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
        .onAppear { motionManager.startUpdates() }
        .task {
            await telemetry.fetchUSGSStreamflow()
            await storeKit.loadProducts()
        }
    }
}
