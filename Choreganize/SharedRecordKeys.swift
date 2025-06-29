import CloudKit

struct SharedRecordKeys {
    static let recordID = CKRecord.ID(recordName: "SharedAppState")
    static let subscriptionID = "shared-db-changes"
    static let jsonKey = "json"
    static let lastEditedKey = "lastEdited"
    static let historyZoneName = "HistoryZone"
}
