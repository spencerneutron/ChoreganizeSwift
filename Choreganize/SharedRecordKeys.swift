import CloudKit

struct SharedRecordKeys {
    static let ownerZoneName = "OwnerZone"
    static let ownerZoneID = CKRecordZone.ID(zoneName: ownerZoneName, ownerName: CKCurrentUserDefaultName)
    static let recordID = CKRecord.ID(recordName: "SharedAppState", zoneID: ownerZoneID)
    static let legacySubscriptionID = "shared-db-changes"
    static func subscriptionID(for recordID: CKRecord.ID) -> String {
        recordID.recordName + "-changes"
    }
    static let jsonKey = "json"
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
