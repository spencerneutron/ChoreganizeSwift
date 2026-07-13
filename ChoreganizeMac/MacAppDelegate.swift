import AppKit
import CloudKit
import UserNotifications

/// macOS app delegate — the NSApplication twin of the iOS `AppDelegate`.
/// Registers for the silent CloudKit pushes NSPersistentCloudKitContainer uses
/// for background sync, runs the shared launch hooks, accepts incoming
/// Household share invitations into the shared store, and is the notification
/// center delegate so reminder "Mark done" actions complete chores directly.
final class MacAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Mac app did finish launching; registering for remote notifications", category: .app)
        NSApplication.shared.registerForRemoteNotifications()
        // Shared launch hooks — same order and rationale as the iOS delegate:
        // completer identity for #59 attribution, resume of an interrupted #64
        // owner move, the StoreKit 2 listener, the #62 member-completion watcher,
        // and the auto-backup scheduler + launch catch-up.
        CompleterIdentity.refresh()
        HouseholdMigration.resumePendingMoveIfNeeded()
        EntitlementStore.shared.start()
        MemberCompletionNotifier.shared.start()
        AutoBackup.register()
        AutoBackup.runCatchUpIfDue()
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.registerCategories()
    }

    /// The window may be closed while the menu-bar extra keeps working —
    /// quitting on last-window-close would kill sync and the Today list.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Log.info("Registered for remote notifications (\(deviceToken.count)-byte token)", category: .push)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.error("Remote notification registration failed: \(error.localizedDescription)", category: .push)
    }

    /// CloudKit share acceptance. macOS delivers this to the app delegate
    /// directly (no scene-delegate detour like iOS); requires
    /// `CKSharingSupported = YES` in Info.plist.
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Log.info("User accepted CloudKit share: \(metadata.share.recordID.recordName)", category: .cloud)
        CoreDataStack.shared.acceptShare(metadata)
    }
}

// MARK: - Reminder actions

extension MacAppDelegate: UNUserNotificationCenterDelegate {
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
