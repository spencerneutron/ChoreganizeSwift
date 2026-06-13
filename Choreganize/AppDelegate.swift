import UIKit

/// Minimal app delegate. CloudKit sharing acceptance and remote-notification
/// handling return in Phase 3/4, driven by NSPersistentCloudKitContainer.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.info("App did finish launching", category: .app)
        return true
    }
}
