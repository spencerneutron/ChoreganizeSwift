import CloudKit
import CoreData
import UIKit

/// Drives the system CloudKit sharing UI for a Household.
///
/// Uses `NSPersistentCloudKitContainer.share(_:to:)` to create (or reuse) the
/// CKShare, then presents `UICloudSharingController` only once the share is
/// saved — which avoids the classic "share sheet never appears because the root
/// record wasn't saved" failure.
@MainActor
enum HouseholdSharing {
    /// Presents the share sheet for the given household (owner flow). If the
    /// household is already shared, reuses the existing share (so participants /
    /// owners can manage it).
    static func share(_ household: CDHousehold, stack: CoreDataStack = .shared) {
        guard stack.cloudKitEnabled else {
            Log.warning("Sharing unavailable: CloudKit disabled for this run", category: .cloud)
            return
        }
        guard let presenter = topViewController() else {
            Log.error("No view controller available to present the sharing UI", category: .cloud)
            return
        }

        let container = stack.container
        let ckContainer = CKContainer(identifier: CoreDataStack.cloudContainerIdentifier)

        // Reuse an existing share if the household is already shared.
        if let existing = (try? container.fetchShares(matching: [household.objectID]))?[household.objectID] {
            Log.info("Presenting existing household share", category: .cloud)
            present(UICloudSharingController(share: existing, container: ckContainer), from: presenter)
            return
        }

        // Otherwise create a new share for the household graph and present it.
        Log.info("Creating new household share", category: .cloud)
        container.share([household], to: nil) { _, share, sharedContainer, error in
            Task { @MainActor in
                guard let share, let sharedContainer, error == nil else {
                    Log.error("Failed to create household share: \(error?.localizedDescription ?? "unknown")", category: .cloud)
                    return
                }
                share[CKShare.SystemFieldKey.title] = "Household" as CKRecordValue
                present(UICloudSharingController(share: share, container: sharedContainer), from: presenter)
            }
        }
    }

    private static func present(_ controller: UICloudSharingController, from presenter: UIViewController) {
        controller.delegate = SharingDelegate.shared
        // Invite-only (private), read-write so the household is co-equal.
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        presenter.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Logs the outcomes of the sharing UI. The UI updates itself via @FetchRequest /
/// the shared store, so this mostly just records what happened.
final class SharingDelegate: NSObject, UICloudSharingControllerDelegate {
    static let shared = SharingDelegate()

    func itemTitle(for csc: UICloudSharingController) -> String? { "Household" }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        Log.info("Household share saved", category: .cloud)
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        Log.info("Household sharing stopped", category: .cloud)
    }

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        Log.error("Share save failed: \(error.localizedDescription)", category: .cloud)
    }
}
