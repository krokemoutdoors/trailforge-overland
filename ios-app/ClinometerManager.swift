import CoreMotion
import Foundation
import UIKit

/// Vehicle roll and pitch from the gravity vector, rotated into the current
/// interface orientation. Euler `attitude.pitch` / `attitude.roll` are relative
/// to a phone lying flat in portrait, so a dash mount reads ~80° and landscape
/// swaps the axes. Gravity decomposition stays valid upright and in landscape.
final class ClinometerMotionManager: ObservableObject {
    private let motion = CMMotionManager()
    @Published var pitchDegrees: Double = 0.0
    @Published var rollDegrees: Double = 0.0
    @Published var rollWarningLimit: Double = 25.0 {
        didSet {
            let clamped = min(45, max(8, rollWarningLimit))
            if clamped != rollWarningLimit {
                rollWarningLimit = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.limitKey)
        }
    }
    @Published private(set) var isCalibrated = false

    private var filteredRoll = 0.0
    private var filteredPitch = 0.0
    private var hasFilter = false
    private var autoPitchOffset: Double?
    private var hasSample = false
    private var latestSx = 0.0
    private var latestSy = -1.0
    private var latestSz = 0.0
    private var refSx: Double?
    private var refSy: Double?
    private var refSz: Double?

    private static let refKey = "trailforge.clinometer.ref"
    private static let limitKey = "trailforge.clinometer.rollLimit"
    private let smoothAlpha = 0.22

    init() {
        if let saved = UserDefaults.standard.array(forKey: Self.refKey) as? [Double], saved.count == 3,
           saved.allSatisfy(\.isFinite) {
            refSx = saved[0]
            refSy = saved[1]
            refSz = saved[2]
            isCalibrated = true
        }
        let storedLimit = UserDefaults.standard.object(forKey: Self.limitKey) as? Double
        if let storedLimit, storedLimit >= 8, storedLimit <= 45 {
            rollWarningLimit = storedLimit
        }
    }

    func startUpdates() {
        guard motion.isDeviceMotionAvailable else { return }
        if motion.isDeviceMotionActive { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        let handler: CMDeviceMotionHandler = { [weak self] data, _ in
            guard let self, let data else { return }
            self.ingest(gravity: data.gravity)
        }
        if CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical) {
            motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main, withHandler: handler)
        } else {
            motion.startDeviceMotionUpdates(to: .main, withHandler: handler)
        }
    }

    func stopUpdates() {
        motion.stopDeviceMotionUpdates()
    }

    /// Tare roll and pitch against the phone's current mount angle.
    func calibrateZero() {
        guard hasSample else { return }
        let magnitude = hypot(latestSx, hypot(latestSy, latestSz))
        guard magnitude > 0.2 else { return }
        refSx = latestSx / magnitude
        refSy = latestSy / magnitude
        refSz = latestSz / magnitude
        isCalibrated = true
        autoPitchOffset = nil
        UserDefaults.standard.set([refSx ?? 0, refSy ?? 0, refSz ?? 0], forKey: Self.refKey)
        filteredRoll = 0
        filteredPitch = 0
        hasFilter = true
        rollDegrees = 0
        pitchDegrees = 0
    }

    func resetCalibration() {
        refSx = nil
        refSy = nil
        refSz = nil
        isCalibrated = false
        autoPitchOffset = nil
        UserDefaults.standard.removeObject(forKey: Self.refKey)
    }

    private func ingest(gravity: CMAcceleration) {
        let screen = screenGravity(x: gravity.x, y: gravity.y, z: gravity.z)
        guard screen.sx.isFinite, screen.sy.isFinite, screen.sz.isFinite else { return }
        hasSample = true
        latestSx = screen.sx
        latestSy = screen.sy
        latestSz = screen.sz
        let sample = angles(sx: screen.sx, sy: screen.sy, sz: screen.sz)
        guard sample.roll.isFinite, sample.pitch.isFinite else { return }
        if !hasFilter {
            filteredRoll = sample.roll
            filteredPitch = sample.pitch
            hasFilter = true
        } else {
            filteredRoll += smoothAlpha * (sample.roll - filteredRoll)
            filteredPitch += smoothAlpha * (sample.pitch - filteredPitch)
        }
        rollDegrees = filteredRoll
        pitchDegrees = filteredPitch
    }

    /// `sx` is screen-right, `sy` is up the screen, `sz` is out of the screen.
    private func screenGravity(x gx: Double, y gy: Double, z gz: Double) -> (sx: Double, sy: Double, sz: Double) {
        switch interfaceOrientation() {
        case .portraitUpsideDown:
            return (-gx, -gy, gz)
        case .landscapeLeft:
            // Home indicator on the right; top of the phone is to the left.
            return (-gy, gx, gz)
        case .landscapeRight:
            // Home indicator on the left; top of the phone is to the right.
            return (gy, -gx, gz)
        default:
            return (gx, gy, gz)
        }
    }

    private func interfaceOrientation() -> UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.interfaceOrientation ?? .portrait
    }

    private func angles(sx: Double, sy: Double, sz: Double) -> (roll: Double, pitch: Double) {
        if let refSx, let refSy, let refSz {
            return relativeAngles(sx: sx, sy: sy, sz: sz, rx: refSx, ry: refSy, rz: refSz)
        }
        // Side-to-side tilt. `atan2(sx, hypot(sy, sz))` stays valid when the
        // phone is flat (`sz ≈ -1`) and when it is upright in a dash (`sy ≈ -1`).
        let rawRoll = atan2(sx, sqrt(sy * sy + sz * sz)) * 180.0 / .pi
        // Front-to-back incline relative to the screen. ~0° upright, ~90° flat.
        let rawPitch = atan2(-sz, -sy) * 180.0 / .pi
        if autoPitchOffset == nil {
            autoPitchOffset = rawPitch
        }
        let baseline = autoPitchOffset ?? 0
        return (rawRoll, rawPitch - baseline)
    }

    /// Roll and pitch of the live gravity vector relative to the saved mount.
    private func relativeAngles(sx: Double, sy: Double, sz: Double, rx: Double, ry: Double, rz: Double) -> (roll: Double, pitch: Double) {
        let gravity = normalize(sx, sy, sz)
        let down = normalize(rx, ry, rz)
        var right = subtract((1, 0, 0), scaled: dot((1, 0, 0), down), from: down)
        if length(right) < 0.25 {
            let projectedUp = subtract((0, 1, 0), scaled: dot((0, 1, 0), down), from: down)
            right = length(projectedUp) < 0.05 ? (1, 0, 0) : normalize(projectedUp.0, projectedUp.1, projectedUp.2)
        } else {
            right = normalize(right.0, right.1, right.2)
        }
        var forward = cross(right, down)
        if forward.1 < 0 {
            forward = (-forward.0, -forward.1, -forward.2)
        }
        let alongDown = dot(gravity, down)
        let alongRight = dot(gravity, right)
        let alongForward = dot(gravity, forward)
        let roll = atan2(alongRight, alongDown) * 180.0 / .pi
        // Positive pitch is nose-up when the top of the phone points forward.
        let pitch = atan2(-alongForward, alongDown) * 180.0 / .pi
        return (roll, pitch)
    }

    private func normalize(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        let magnitude = length((x, y, z))
        guard magnitude > 0.0001 else { return (0, -1, 0) }
        return (x / magnitude, y / magnitude, z / magnitude)
    }

    private func length(_ value: (Double, Double, Double)) -> Double {
        hypot(value.0, hypot(value.1, value.2))
    }

    private func dot(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        a.0 * b.0 + a.1 * b.1 + a.2 * b.2
    }

    private func subtract(_ vector: (Double, Double, Double), scaled: Double, from axis: (Double, Double, Double)) -> (Double, Double, Double) {
        (vector.0 - scaled * axis.0, vector.1 - scaled * axis.1, vector.2 - scaled * axis.2)
    }

    private func cross(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> (Double, Double, Double) {
        (
            a.1 * b.2 - a.2 * b.1,
            a.2 * b.0 - a.0 * b.2,
            a.0 * b.1 - a.1 * b.0
        )
    }
}
