import UIKit
import CloudKit
import UserNotifications

/// App delegate. Registers for the silent CloudKit pushes that
/// NSPersistentCloudKitContainer uses to drive background sync (requires the
/// `remote-notification` background mode in Info.plist), accepts incoming
/// Household share invitations into the shared store, and is the notification
/// center delegate so chore reminders' "Mark done" action can complete chores
/// without opening the app.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.info("App did finish launching; registering for remote notifications", category: .app)
        application.registerForRemoteNotifications()
        // Become the notification delegate and register the actionable reminder
        // category up front, so a delivered reminder shows "Mark done" and routes
        // the tap back here even on a cold launch from the notification.
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.registerCategories()
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

// MARK: - Reminder actions

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Handles a tapped reminder action. For "Mark done" we resolve the chores
    /// carried in the reminder's userInfo and complete any still open today via
    /// the existing `recordCompletion` path — no app UI is brought up.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        guard response.actionIdentifier == NotificationManager.Action.markDone else {
            completionHandler()
            return
        }
        Task { @MainActor in
            NotificationManager.completeChores(fromUserInfo: userInfo)
            completionHandler()
        }
    }
}
