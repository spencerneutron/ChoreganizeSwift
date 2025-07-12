import CloudKit

struct SharedRecordKeys {
    static let recordID = CKRecord.ID(recordName: "SharedAppState")
    static let subscriptionID = "shared-db-changes"
    static let jsonKey = "json"
    static let lastEditedKey = "lastEdited"
    static let historyZoneName = "HistoryZone"
    // Keys for persisting share information in UserDefaults
    static let savedShareRecordKey = "ckShareRecordName"
    static let savedRootRecordKey = "ckRootRecordName"
}
