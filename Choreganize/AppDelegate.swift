import UIKit
import CloudKit

class AppDelegate: NSObject, UIApplicationDelegate {
    weak var model: AppModel?
    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if url.startAccessingSecurityScopedResource() { defer { url.stopAccessingSecurityScopedResource() } }
        if CKShare.Metadata.isShareURL(url) {
            Task {
                await SharedCloudKitController.shared.acceptShare(url: url)
                await model?.loadSharedState()
                if model?.sharingEnabled == true {
                    await SharedCloudKitController.shared.subscribeToChanges()
                }
            }
            return true
        }
        return false
    }
}
