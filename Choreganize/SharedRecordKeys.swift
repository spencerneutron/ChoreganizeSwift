import CloudKit
import Foundation

struct SharedRecordKeys {
    /// Stores the CloudKit user record name so all devices for the same account
    /// share the same zone and record identifiers. Cleared when the user changes
    /// iCloud accounts.
    private static let userNameKey = "ckUserRecordName"
    private static var defaults: UserDefaults { .standard }
    private static var accountObserverInstalled = false

    /// Ensures we listen for `CKAccountChanged` so the cached name is cleared if
    /// the user signs out.
    static func ensureAccountObservation() {
        guard !accountObserverInstalled else { return }
        accountObserverInstalled = true
        NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in
            clearCachedUserName()
        }
    }

    /// Returns the current user's record name, fetching it once and caching it in
    /// `UserDefaults` for subsequent launches.
    static func userRecordName() async throws -> String {
        if let cached = defaults.string(forKey: userNameKey) { return cached }
        let name = try await CKContainer.default().userRecordID().recordName
        defaults.set(name, forKey: userNameKey)
        return name
    }

    /// Removes any stored user record name. Called when `CKAccountChanged` fires.
    private static func clearCachedUserName() {
        defaults.removeObject(forKey: userNameKey)
    }

    /// Zone used for all private records. Appends the user record name for
    /// clearer logs while still being private to the current account.
    static func ownerZoneID(for userName: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "OwnerZone-\(userName)", ownerName: CKCurrentUserDefaultName)
    }

    /// Record ID for the root application state.
    static func recordID(for userName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "AppState-\(userName)", zoneID: ownerZoneID(for: userName))
    }

    /// Legacy subscription identifier retained for backward compatibility.
    @available(*, deprecated, message: "Remove after migrating to per-share subscriptions")
    static let legacySubscriptionID = "shared-db-changes"

    static func subscriptionID(for recordID: CKRecord.ID) -> String {
        recordID.recordName + "-changes"
    }

    static let stateJSONKey = "json"
    static let lastEditedKey = "lastEdited"
    static let historyZoneName = "HistoryZone"
    // Record type names
    static let rootRecordType = "AppState"
    static let choreRecordType = "Chore"
    static let areaRecordType = "Area"
    static let completionRecordType = "Completion"
    // Keys for persisting share information in UserDefaults
    static let savedShareRecordKey = "ckShareRecordName"
    static let savedRootRecordKey = "ckRootRecordName"
    static let savedSubscriptionIDKey = "ckSubscriptionID"
    static let savedShareInfoKey = "ckShareInfo"
}
