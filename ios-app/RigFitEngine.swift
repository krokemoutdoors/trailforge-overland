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
