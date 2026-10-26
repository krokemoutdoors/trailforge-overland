import SwiftUI
import MapKit
import CoreMotion
import StoreKit

@main
struct TrailForgeOverlandApp: App {
    @StateObject private var rigStore = RigProfileStore()
    @StateObject private var motionManager = ClinometerMotionManager()
    @StateObject private var storeKit = TrailForgeStoreKitManager()

    var body: some Scene {
        WindowGroup {
            MainCockpitView()
                .environmentObject(rigStore)
                .environmentObject(motionManager)
                .environmentObject(storeKit)
                .preferredColorScheme(.dark)
        }
    }
}
