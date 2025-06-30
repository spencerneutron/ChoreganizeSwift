import UIKit
import CloudKit

class AppDelegate: NSObject, UIApplicationDelegate {
    weak var model: AppModel?
    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if url.startAccessingSecurityScopedResource() { do { url.stopAccessingSecurityScopedResource() } }
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
}
