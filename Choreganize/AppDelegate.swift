import UIKit
import CloudKit

/// App delegate. Registers for the silent CloudKit pushes that
/// NSPersistentCloudKitContainer uses to drive background sync (requires the
/// `remote-notification` background mode in Info.plist), and accepts incoming
/// Household share invitations into the shared store.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.info("App did finish launching; registering for remote notifications", category: .app)
        application.registerForRemoteNotifications()
        return true
    }

    /// Fired when the user taps a Household share invitation link. The system has
    /// already accepted at the CloudKit level; we pull the share into the shared
    /// Core Data store so it appears under the Household scope.
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Log.info("User accepted CloudKit share: \(metadata.share.recordID.recordName)", category: .cloud)
        CoreDataStack.shared.acceptShare(metadata)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Log.info("Registered for remote notifications (\(deviceToken.count)-byte token)", category: .push)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.error("Remote notification registration failed: \(error.localizedDescription)", category: .push)
    }
}
