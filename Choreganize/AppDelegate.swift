import UIKit

/// App delegate. Registers for the silent CloudKit pushes that
/// NSPersistentCloudKitContainer uses to drive background sync. Requires the
/// `remote-notification` background mode (see Info.plist) — without it CloudKit
/// logs "BUG IN CLIENT OF CLOUDKIT: … require the 'remote-notification'
/// background mode" and background/push sync never happens.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.info("App did finish launching; registering for remote notifications", category: .app)
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Log.info("Registered for remote notifications (\(deviceToken.count)-byte token)", category: .push)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.error("Remote notification registration failed: \(error.localizedDescription)", category: .push)
    }
}
