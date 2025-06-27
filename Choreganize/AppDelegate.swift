import UIKit
import CloudKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if url.startAccessingSecurityScopedResource() { defer { url.stopAccessingSecurityScopedResource() } }
        if CKShare.Metadata.isShareURL(url) {
            Task { await SharedCloudKitController.shared.acceptShare(url: url) }
            return true
        }
        return false
    }
}
