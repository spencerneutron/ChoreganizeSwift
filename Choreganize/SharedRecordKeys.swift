import CloudKit
import Foundation

struct SharedRecordKeys {
    /// Identifier generated once per install and cached in `UserDefaults`.
    /// Remains stable until the user deletes local app data.
    private static var installUUID: String {
        let key = "installUUID"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key) { return existing }
        let new = UUID().uuidString
        defaults.set(new, forKey: key)
        return new
    }

    /// Per-install zone used for all private records.
    static var privateZoneName: String { "OwnerZone-\(installUUID)" }
    static var ownerZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: privateZoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Record ID for the root application state in the owner's zone.
    static var recordID: CKRecord.ID {
        CKRecord.ID(recordName: "AppState-\(installUUID)", zoneID: ownerZoneID)
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
}
