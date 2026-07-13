import CloudKit
import CoreData

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
/// The state/rename halves below are cross-platform; each platform contributes
/// its own `share(_:stack:)` presentation in a platform-specific file
/// (`UICloudSharingController` in HouseholdSharing.swift on iOS,
/// `NSSharingService(.cloudSharing)` in ChoreganizeMac/MacHouseholdSharing.swift).
enum HouseholdSharing {

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
}
