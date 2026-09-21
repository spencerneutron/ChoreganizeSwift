import CloudKit
import CoreData
import UIKit

/// iOS presentation half of `HouseholdSharing` (the cross-platform state/rename
/// half lives in HouseholdShareState.swift; the macOS presentation in
/// ChoreganizeMac/MacHouseholdSharing.swift).
extension HouseholdSharing {

    /// Presents the share sheet for the given household (owner flow). Reuses an
    /// existing share if the household is already shared (so the owner/participant
    /// can manage members or stop). Presented only once the share is saved.
    @MainActor
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
        let title = household.name ?? "Household"
        let householdID = household.objectID

        // fetchShares/share(_:to:) block their calling thread on the container's
        // request executor. On the main thread that beachballs the app — and
        // deadlocks it outright if a mirroring event fires mid-request (the event
        // post waits on main; main waits on the mirroring queue). Do the share
        // lookup/creation off-main and hop back only to present.
        Task.detached(priority: .userInitiated) {
            if let existing = (try? container.fetchShares(matching: [householdID]))?[householdID] {
                Log.info("Presenting existing household share", category: .cloud)
                // Heal shares created before the title was persisted (their invitation
                // links read "cloudkit.zoneshare"); only the owner may edit the share.
                if existing[CKShare.SystemFieldKey.title] == nil,
                   existing.currentUserParticipant?.role == .owner,
                   let store = stack.privateStore {
                    existing[CKShare.SystemFieldKey.title] = title as CKRecordValue
                    container.persistUpdatedShare(existing, in: store) { _, error in
                        if let error { Log.error("Backfilling share title failed: \(error.localizedDescription)", category: .cloud) }
                    }
                }
                await MainActor.run {
                    present(UICloudSharingController(share: existing, container: ckContainer), from: presenter)
                }
                return
            }

            Log.info("Creating new household share", category: .cloud)
            container.share([household], to: nil) { _, share, sharedContainer, error in
                guard let share, let sharedContainer, error == nil else {
                    Log.error("Failed to create household share: \(error?.localizedDescription ?? "unknown")", category: .cloud)
                    return
                }
                share[CKShare.SystemFieldKey.title] = title as CKRecordValue
                // Persist the title before the sheet can send a link: `share(_:to:)`
                // already saved the share, so a title set only in memory never
                // reaches the server and invitations read "cloudkit.zoneshare".
                guard let store = stack.privateStore else {
                    Task { @MainActor in
                        present(UICloudSharingController(share: share, container: sharedContainer), from: presenter)
                    }
                    return
                }
                container.persistUpdatedShare(share, in: store) { persisted, error in
                    if let error { Log.error("Persisting share title failed: \(error.localizedDescription)", category: .cloud) }
                    Task { @MainActor in
                        present(UICloudSharingController(share: persisted ?? share, container: sharedContainer), from: presenter)
                    }
                }
            }
        }
    }

    @MainActor
    private static func present(_ controller: UICloudSharingController, from presenter: UIViewController) {
        controller.delegate = SharingDelegate.shared
        // Read-write only (households are collaborative), but allow BOTH access
        // modes. Without `.allowPublic` the share is locked to invite-only, and a
        // copied link handed to a non-invitee dead-ends in "Item Unavailable" —
        // the owner must be able to pick "Anyone with the link". New shares still
        // default to invite-only; this only unlocks the choice.
        controller.availablePermissions = [.allowReadWrite, .allowPrivate, .allowPublic]
        // Block swipe-to-dismiss so member edits (e.g. removing an invited person)
        // can't be silently discarded by pulling the sheet down — the user must
        // tap the system Save (checkmark) or Cancel. The controller's own buttons
        // still dismiss it.
        controller.isModalInPresentation = true
        presenter.present(controller, animated: true)
    }

    @MainActor
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

/// Logs sharing outcomes and notifies the UI to refresh its share state.
final class SharingDelegate: NSObject, UICloudSharingControllerDelegate {
    static let shared = SharingDelegate()

    func itemTitle(for csc: UICloudSharingController) -> String? {
        csc.share?[CKShare.SystemFieldKey.title] as? String ?? "Household"
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        Log.info("Household share saved", category: .cloud)
        NotificationCenter.default.post(name: .householdShareDidChange, object: nil)
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        Log.info("Household sharing stopped", category: .cloud)
        NotificationCenter.default.post(name: .householdShareDidChange, object: nil)
    }

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        Log.error("Share save failed: \(error.localizedDescription)", category: .cloud)
    }
}
