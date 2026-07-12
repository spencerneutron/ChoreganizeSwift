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
        // #59: cache the stable CloudKit user id so Household completions can be
        // stamped with who completed them (no-op when CloudKit is off).
        CompleterIdentity.refresh()
        // CG-11 / #64: finish an owner-side migration interrupted between its
        // local save and the share-zone re-home (no-op when the journal is clear).
        HouseholdMigration.resumePendingMoveIfNeeded()
        // CG-12 / #95: start the StoreKit 2 transaction listener + entitlement load.
        EntitlementStore.shared.start()
        // Become the notification delegate and register the actionable reminder
        // category up front, so a delivered reminder shows "Mark done" and routes
        // the tap back here even on a cold launch from the notification.
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.registerCategories()
        return true
    }

    /// Routes scene connections through our own scene delegate. Scene-lifecycle
    /// apps deliver CloudKit share acceptances to the *window scene* delegate —
    /// `application(_:userDidAcceptCloudKitShareWith:)` never fires once a scene
    /// manifest is generated, which silently broke accepting Household invites.
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Log.info("Registered for remote notifications (\(deviceToken.count)-byte token)", category: .push)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.error("Remote notification registration failed: \(error.localizedDescription)", category: .push)
    }
}

// MARK: - Share acceptance (scene delegate)

/// Exists solely to catch CloudKit share acceptances, which scene-lifecycle apps
/// deliver here instead of the app delegate. SwiftUI keeps managing the window;
/// deliberately implements no URL/user-activity methods so `onOpenURL` (widget
/// deep links) keeps flowing through SwiftUI untouched.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Warm accept: the app was running when the user tapped the invitation link.
    /// The system has already accepted at the CloudKit level; we pull the share
    /// into the shared Core Data store so it appears under the Household scope.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Log.info("User accepted CloudKit share: \(metadata.share.recordID.recordName)", category: .cloud)
        CoreDataStack.shared.acceptShare(metadata)
    }

    /// Cold accept: the invitation tap launched the app, so the metadata arrives
    /// with the scene's connection options instead of the callback above.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Log.info("Launched from CloudKit share acceptance: \(metadata.share.recordID.recordName)", category: .cloud)
            CoreDataStack.shared.acceptShare(metadata)
        }
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
