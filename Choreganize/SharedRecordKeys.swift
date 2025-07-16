import CloudKit

struct SharedRecordKeys {
    static let recordID = CKRecord.ID(recordName: "SharedAppState")
    static let subscriptionID = "shared-db-changes"
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
}
