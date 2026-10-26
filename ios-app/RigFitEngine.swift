import Foundation
import CoreLocation

struct RigProfile: Codable {
    var name: String = "Toyota Tacoma TRD Off-Road"
    var tireInches: Double = 33.0
    var liftInches: Double = 2.5
    var minClearanceIn: Double = 11.2
    var roofHeightFt: Double = 6.8
    var widthIn: Double = 75.0
    var hasRearLocker: Bool = true
    var hasSnorkel: Bool = false
    var rigWeightLbs: Double = 5450
}

enum RigFitVerdict: String {
    case fits = "FITS YOUR RIG"
    case caution = "CAUTION"
    case noGo = "NO-GO CLEARANCE"
}

struct OverlandTrail: Identifiable {
    let id: String
    let name: String
    let region: String
    let agency: String
    let distanceMi: Double
    let peakElevFt: Int
    let reqClearanceIn: Double
    let minCanopyFt: Double
    let waterCrossingIn: Int
    let reqLocker: Bool
    let gateStatus: String
    let snotelSnowIn: Double
    let usgsFlowCfs: Int
    var state: String = ""
    var centerLat: Double = 0
    var centerLon: Double = 0
    var coordinates: [CLLocationCoordinate2D] = []
    var flatCamps: [(name: String, lat: Double, lon: Double, slopeDeg: Double, starlinkPct: Int)] = []

    var centerCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
    }
}

enum TrailGeometry {
    static func route(lat: Double, lon: Double, seed: Int, kilometers: Double = 14) -> [CLLocationCoordinate2D] {
        let heading = Double(abs(seed) % 360) * .pi / 180
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = max(20_000.0, 111_320.0 * cos(lat * .pi / 180))
        let steps = 7
        let step = (kilometers * 1000) / Double(steps)
        var points: [CLLocationCoordinate2D] = []
        let half = Double(steps) / 2
        for index in 0...steps {
            let wobble = sin(Double(index) * 0.85 + Double(seed % 17)) * 0.28
            let along = (Double(index) - half) * step
            let side = sin(Double(index) + Double(seed % 9)) * step * 0.18
            let dLat = (along * cos(heading + wobble) - side * sin(heading)) / metersPerDegLat
            let dLon = (along * sin(heading + wobble) + side * cos(heading)) / metersPerDegLon
            points.append(CLLocationCoordinate2D(latitude: lat + dLat, longitude: lon + dLon))
        }
        return points
    }

    static func seed(for id: String) -> Int {
        id.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 33 &+ Int(scalar.value)) % 50_000
        }
    }

    static func pads(lat: Double, lon: Double, seed: Int) -> [(name: String, lat: Double, lon: Double, slopeDeg: Double, starlinkPct: Int)] {
        let slopeA = 1.1 + Double(abs(seed) % 8) * 0.1
        let slopeB = 1.8 + Double(abs(seed / 7) % 8) * 0.1
        return [
            (name: "Flat Pad A", lat: lat + 0.012, lon: lon - 0.010, slopeDeg: min(slopeA, 2.4), starlinkPct: 88 + abs(seed) % 11),
            (name: "Flat Pad B", lat: lat - 0.014, lon: lon + 0.011, slopeDeg: min(slopeB, 2.8), starlinkPct: 80 + abs(seed / 3) % 15)
        ]
    }
}

final class RigProfileStore: ObservableObject {
    @Published var profile = RigProfile()

    func evaluate(trail: OverlandTrail) -> (verdict: RigFitVerdict, notes: [String]) {
        var notes: [String] = []
        var noGo = false
        var caution = false

        if profile.roofHeightFt > trail.minCanopyFt {
            noGo = true
            notes.append("Roof height (\(profile.roofHeightFt) ft) exceeds canopy (\(trail.minCanopyFt) ft).")
        }
        if profile.minClearanceIn < trail.reqClearanceIn - 0.8 {
            noGo = true
            notes.append("Clearance (\(profile.minClearanceIn)\") below shelf minimum (\(trail.reqClearanceIn)\").")
        } else if profile.minClearanceIn < trail.reqClearanceIn {
            caution = true
            notes.append("Tight clearance for \(trail.reqClearanceIn)\" ledges—skid plates advised.")
        }
        if trail.reqLocker && !profile.hasRearLocker {
            caution = true
            notes.append("Rear locker recommended for steep switchbacks.")
        }
        if Double(trail.waterCrossingIn) >= 24.0 && !profile.hasSnorkel {
            caution = true
            notes.append("Deep water ford (\(trail.waterCrossingIn)\") near stock intake.")
        }
        if notes.isEmpty {
            notes.append("Clearance & canopy verified safe for \(profile.name).")
        }
        return (noGo ? .noGo : (caution ? .caution : .fits), notes)
    }

    func recommendedAirDownPSI(surface: String, beadlocks: Bool) -> (front: Int, rear: Int) {
        let highway = profile.rigWeightLbs > 7000 ? 55.0 : 36.0
        let factor: Double = surface == "sand" ? 0.42 : (surface == "rock" ? 0.52 : 0.62)
        let bonus = max(0.0, (profile.tireInches - 30.0) * 1.1)
        let minSafe = beadlocks ? 10 : 15
        let front = max(minSafe, Int((highway * factor - bonus).rounded()))
        let rear = front + (profile.rigWeightLbs > 6500 ? 4 : 2)
        return (front, rear)
    }
}
