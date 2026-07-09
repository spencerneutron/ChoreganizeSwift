import CloudKit
import CoreData
import UIKit

extension Notification.Name {
    /// Posted when the household share changes (created, members changed, stopped).
    static let householdShareDidChange = Notification.Name("householdShareDidChange")
}

/// A snapshot of the active household's share state, for the UI.
struct HouseholdShareInfo {
    var isShared: Bool
    var acceptedCount: Int   // accepted participants, including the owner
    var pendingCount: Int
    var isOwner: Bool

    static let notShared = HouseholdShareInfo(isShared: false, acceptedCount: 0, pendingCount: 0, isOwner: true)

    var statusText: String {
        guard isShared else { return "Not shared yet" }
        var parts = ["\(acceptedCount) member\(acceptedCount == 1 ? "" : "s")"]
        if pendingCount > 0 { parts.append("\(pendingCount) pending") }
        return "Shared · " + parts.joined(separator: " · ")
    }
}

/// Drives the system CloudKit sharing UI for a Household and reports its state.
enum HouseholdSharing {

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

        if let existing = (try? container.fetchShares(matching: [household.objectID]))?[household.objectID] {
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
            present(UICloudSharingController(share: existing, container: ckContainer), from: presenter)
            return
        }

        Log.info("Creating new household share", category: .cloud)
        container.share([household], to: nil) { _, share, sharedContainer, error in
            Task { @MainActor in
                guard let share, let sharedContainer, error == nil else {
                    Log.error("Failed to create household share: \(error?.localizedDescription ?? "unknown")", category: .cloud)
                    return
                }
                share[CKShare.SystemFieldKey.title] = title as CKRecordValue
                // Persist the title before the sheet can send a link: `share(_:to:)`
                // already saved the share, so a title set only in memory never
                // reaches the server and invitations read "cloudkit.zoneshare".
                guard let store = stack.privateStore else {
                    present(UICloudSharingController(share: share, container: sharedContainer), from: presenter)
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

    /// Current share state for the household (nil when CloudKit is disabled).
    static func shareInfo(for household: CDHousehold, stack: CoreDataStack = .shared) -> HouseholdShareInfo? {
        guard stack.cloudKitEnabled else { return nil }
        let shares = (try? stack.container.fetchShares(matching: [household.objectID])) ?? [:]
        guard let share = shares[household.objectID] else { return .notShared }
        let accepted = share.participants.filter { $0.acceptanceStatus == .accepted }.count
        let pending = share.participants.filter { $0.acceptanceStatus == .pending }.count
        let isOwner = share.currentUserParticipant?.role == .owner
        return HouseholdShareInfo(isShared: true, acceptedCount: accepted, pendingCount: pending, isOwner: isOwner)
    }

    /// Renames the household (a synced attribute, so it updates for every member),
    /// and best-effort updates the CKShare title when the current user owns it.
    static func rename(_ household: CDHousehold, to newName: String, stack: CoreDataStack = .shared) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        household.name = trimmed
        try? household.managedObjectContext?.save()
        Log.info("Renamed household", category: .cloud)

        guard stack.cloudKitEnabled,
              let store = stack.privateStore,
              let share = (try? stack.container.fetchShares(matching: [household.objectID]))?[household.objectID],
              share.currentUserParticipant?.role == .owner else { return }
        share[CKShare.SystemFieldKey.title] = trimmed as CKRecordValue
        stack.container.persistUpdatedShare(share, in: store) { _, error in
            if let error { Log.error("persistUpdatedShare failed: \(error.localizedDescription)", category: .cloud) }
        }
    }

    @MainActor
    private static func present(_ controller: UICloudSharingController, from presenter: UIViewController) {
        controller.delegate = SharingDelegate.shared
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
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
