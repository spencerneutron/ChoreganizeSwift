import UIKit
import CloudKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.info("App did finish launching; registering for remote notifications", category: .app)
        Task { @MainActor in
            UIApplication.shared.registerForRemoteNotifications()
        }
        return true
    }

    weak var model: AppModel?
    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        Log.info("Opening URL: \(url.absoluteString)", category: .app)
        Task {
            let accepted = await model?.cloudController.acceptShare(url: url) ?? false
            if accepted {
                await model?.loadSharedState()
                if model?.sharingEnabled == true {
                    await model?.cloudController.subscribeToChanges()
                }
            }
        }
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            Log.debug("Received remote notification with userInfo keys: \(userInfo.keys.count)", category: .push)
            await model?.cloudController.handleRemoteNotification(userInfo)
            completionHandler(.newData)
        }
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Log.info("User accepted CloudKit share via delegate; storing metadata", category: .cloud)
        model?.cloudController.storeShareMetadata(metadata)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.error("Remote notification registration failed: \(error.localizedDescription)", category: .push)
    }
}
