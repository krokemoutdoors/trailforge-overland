import Foundation
import CoreMotion

final class ClinometerMotionManager: ObservableObject {
    private let motion = CMMotionManager()
    @Published var pitchDegrees: Double = 0.0
    @Published var rollDegrees: Double = 0.0
    @Published var rollWarningLimit: Double = 25.0

    func startUpdates() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let attitude = data?.attitude else { return }
            self?.pitchDegrees = attitude.pitch * 180.0 / .pi
            self?.rollDegrees = attitude.roll * 180.0 / .pi
        }
    }

    func stopUpdates() {
        motion.stopDeviceMotionUpdates()
    }
}
