import AppKit
import CloudKit
import CoreData

/// macOS presentation half of `HouseholdSharing` (state/rename live in the
/// shared HouseholdShareState.swift). `UICloudSharingController` doesn't exist
/// on macOS — the AppKit path is `NSSharingService(named: .cloudSharing)` fed
/// an `NSItemProvider` that registers the CKShare. Share creation/lookup is
/// identical to iOS: off-main (the container share APIs block their calling
/// thread on the request executor — v1.6.1 lesson), title persisted via
/// `persistUpdatedShare` before the panel can send a link.
extension HouseholdSharing {

    /// Presents the collaboration panel for the given household (share or
    /// manage members/stop, depending on state).
    @MainActor
    static func share(_ household: CDHousehold, stack: CoreDataStack = .shared) {
        guard stack.cloudKitEnabled else {
            Log.warning("Sharing unavailable: CloudKit disabled for this run", category: .cloud)
            return
        }

        let container = stack.container
        let ckContainer = CKContainer(identifier: CoreDataStack.cloudContainerIdentifier)
        let title = household.name ?? "Household"
        let householdID = household.objectID

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
                    present(existing, in: ckContainer)
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
                // Persist the title before the panel can send a link (same as iOS).
                guard let store = stack.privateStore else {
                    Task { @MainActor in
                        present(share, in: sharedContainer)
                    }
                    return
                }
                container.persistUpdatedShare(share, in: store) { persisted, error in
                    if let error { Log.error("Persisting share title failed: \(error.localizedDescription)", category: .cloud) }
                    Task { @MainActor in
                        present(persisted ?? share, in: sharedContainer)
                    }
                }
            }
        }
    }

    @MainActor
    private static func present(_ share: CKShare, in container: CKContainer) {
        guard let service = NSSharingService(named: .cloudSharing) else {
            Log.error("Cloud-sharing service unavailable", category: .cloud)
            return
        }
        let itemProvider = NSItemProvider()
        itemProvider.registerCloudKitShare(share, container: container)
        service.delegate = MacSharingDelegate.shared
        service.perform(withItems: [itemProvider])
    }
}

/// Logs sharing outcomes and notifies the UI to refresh its share state —
/// the AppKit twin of the iOS `SharingDelegate`.
final class MacSharingDelegate: NSObject, NSCloudSharingServiceDelegate {
    static let shared = MacSharingDelegate()

    /// Read-write only (households are collaborative), both access modes —
    /// mirrors the iOS controller's `availablePermissions` (see the
    /// "Item Unavailable" copied-link rationale there).
    func options(for sharingService: NSSharingService,
                 share provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
        [.allowReadWrite, .allowPrivate, .allowPublic]
    }

    func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
        Log.info("Household share saved", category: .cloud)
        NotificationCenter.default.post(name: .householdShareDidChange, object: nil)
    }

    func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
        Log.info("Household sharing stopped", category: .cloud)
        NotificationCenter.default.post(name: .householdShareDidChange, object: nil)
    }

    func sharingService(_ sharingService: NSSharingService,
                        didFailToShareItems items: [Any], error: Error) {
        Log.error("Share save failed: \(error.localizedDescription)", category: .cloud)
    }
}
