import SwiftUI
import MapKit
import CoreMotion
import StoreKit
import BackgroundTasks

final class TrailForgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.edwardshin.trailforge.camps", using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let work = Task {
                await CampCatalog.refreshSavedCenters()
                refresh.setTaskCompleted(success: true)
            }
            refresh.expirationHandler = { work.cancel() }
            Self.scheduleCampRefresh()
        }
        Self.scheduleCampRefresh()
        return true
    }

    static func scheduleCampRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.edwardshin.trailforge.camps")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

@main
struct TrailForgeOverlandApp: App {
    @UIApplicationDelegateAdaptor(TrailForgeAppDelegate.self) private var appDelegate
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
