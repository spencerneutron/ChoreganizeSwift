import CloudKit
import UIKit

// MARK: - CloudKit abstractions

protocol CloudDatabase {
    func llmRecord(for id: CKRecord.ID) async throws -> CKRecord
    func llmModifyRecords(
        saving records: [CKRecord],
        deleting deletingIDs: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws -> ([CKRecord], [CKRecord.ID])
    func llmDeleteRecord(withID id: CKRecord.ID) async throws
    func llmDeleteSubscription(withID id: String) async throws
    func save(_ subscription: CKSubscription) async throws -> CKSubscription
    func llmAllRecords(ofType type: String, parentID: CKRecord.ID, in zoneID: CKRecordZone.ID) async throws -> [CKRecord]
}

protocol CloudContainer {
    var sharedDatabase: CloudDatabase { get }
    var privateDatabase: CloudDatabase { get }
    func add(_ op: CKOperation)
    func llmMetadata(for url: URL) async throws -> CKShare.Metadata
}

extension CKDatabase: CloudDatabase {
    func llmRecord(for id: CKRecord.ID) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { cont in
            fetch(withRecordID: id) { record, error in
                if let record { cont.resume(returning: record) }
                else { cont.resume(throwing: error ?? CKError(.unknownItem)) }
            }
        }
    }

    func llmModifyRecords(
        saving records: [CKRecord],
        deleting deletingIDs: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws -> ([CKRecord], [CKRecord.ID]) {
        let (saveResults, deleteResults) = try await modifyRecords(
            saving: records,
            deleting: deletingIDs,
            savePolicy: savePolicy,
            atomically: true
        )

        let saved = saveResults.compactMap { _, result in
            try? result.get()
        }

        let deleted = deleteResults.compactMap { id, result in
            (try? result.get()) != nil ? id : nil
        }

        return (saved, deleted)
    }

    func llmDeleteRecord(withID id: CKRecord.ID) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delete(withRecordID: id) { _, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: ()) }
            }
        }
    }

    func llmDeleteSubscription(withID id: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delete(withSubscriptionID: id) { _, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: ()) }
            }
        }
    }

    func save(_ subscription: CKSubscription) async throws -> CKSubscription {
        try await withCheckedThrowingContinuation { cont in
            save(subscription) { saved, error in
                if let saved { cont.resume(returning: saved) }
                else { cont.resume(throwing: error ?? CKError(.unknownItem)) }
            }
        }
    }

    func llmAllRecords(
        ofType type: String,
        parentID: CKRecord.ID,
        in zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord] {
        let parentRef = CKRecord.Reference(recordID: parentID, action: .none)
        let predicate = NSPredicate(format: "parent == %@", parentRef)
        let query = CKQuery(recordType: type, predicate: predicate)

        var results: [CKRecord] = []
        for try await record in recordsStream(matching: query, in: zoneID) {
            results.append(record)
        }
        return results
    }
}

extension CKDatabase {
    /// Streams records for a query in the given zone, paging under the hood.
    func recordsStream(
        matching query: CKQuery,
        in zoneID: CKRecordZone.ID,
        desiredKeys: [CKRecord.FieldKey]? = nil,
        resultsLimit: Int = 400
    ) -> AsyncThrowingStream<CKRecord, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var page = try await self.records(
                        matching: query,
                        inZoneWith: zoneID,
                        desiredKeys: desiredKeys,
                        resultsLimit: resultsLimit
                    )
                    for (_, result) in page.matchResults { continuation.yield(try result.get()) }

                    var cursor = page.queryCursor
                    while let c = cursor {
                        page = try await self.records(
                            continuingMatchFrom: c,
                            desiredKeys: desiredKeys,
                            resultsLimit: resultsLimit
                        )
                        for (_, result) in page.matchResults { continuation.yield(try result.get()) }
                        cursor = page.queryCursor
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}


extension CKContainer: CloudContainer {
    var sharedDatabase: CloudDatabase { sharedCloudDatabase }
    var privateDatabase: CloudDatabase { privateCloudDatabase }
    func llmMetadata(for url: URL) async throws -> CKShare.Metadata {
        try await withCheckedThrowingContinuation { cont in
            fetchShareMetadata(with: url) { metadata, error in
                if let metadata { cont.resume(returning: metadata) }
                else { cont.resume(throwing: error ?? CKError(.unknownItem)) }
            }
        }
    }
}

final class MockCloudDatabase: CloudDatabase {
    private var records: [CKRecord.ID: CKRecord] = [:]

    func llmRecord(for id: CKRecord.ID) async throws -> CKRecord {
        guard let record = records[id] else { throw CKError(.unknownItem) }
        return record
    }

    func llmModifyRecords(
        saving records: [CKRecord],
        deleting deletingIDs: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws -> ([CKRecord], [CKRecord.ID]) {
        for id in deletingIDs { self.records.removeValue(forKey: id) }
        for record in records { self.records[record.recordID] = record }
        return (records, deletingIDs)
    }

    func llmDeleteRecord(withID id: CKRecord.ID) async throws {
        records.removeValue(forKey: id)
    }

    func llmDeleteSubscription(withID id: String) async throws {}

    func save(_ subscription: CKSubscription) async throws -> CKSubscription {
        return subscription
    }

    func llmAllRecords(ofType type: String, parentID: CKRecord.ID, in zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        return records.values.filter {
            $0.recordType == type &&
            $0.recordID.zoneID == zoneID &&
            $0.parent?.recordID == parentID
        }
    }
}

final class MockCloudContainer: CloudContainer {
    let sharedDatabase: CloudDatabase
    let privateDatabase: CloudDatabase

    init(shared: CloudDatabase = MockCloudDatabase(), privateDB: CloudDatabase = MockCloudDatabase()) {
        self.sharedDatabase = shared
        self.privateDatabase = privateDB
    }

    func add(_ op: CKOperation) {}
    func llmMetadata(for url: URL) async throws -> CKShare.Metadata {
        throw CKError(.notAuthenticated)
    }
}

/// Handles access to the user's shared CloudKit database and sharing APIs.
final class SharedCloudKitController: NSObject {
    static var shared = SharedCloudKitController()

    static func configure(container: CloudContainer) {
        shared = SharedCloudKitController(container: container)
    }

    private let container: CloudContainer
    private let sharedDB: CloudDatabase
    private let privateDB: CloudDatabase
    private var zoneID: CKRecordZone.ID?
    private var rootRecordID: CKRecord.ID?
    /// Callback fired when new shared state is downloaded.
    var onStateChange: ((AppModel.SavedState) -> Void)?

    private let defaults = UserDefaults.standard
    private var activeShare: CKShare?

    private var storedShareRecordName: String? {
        get { defaults.string(forKey: SharedRecordKeys.savedShareRecordKey) }
        set { defaults.setValue(newValue, forKey: SharedRecordKeys.savedShareRecordKey) }
    }

    private var storedRootRecordName: String? {
        get { defaults.string(forKey: SharedRecordKeys.savedRootRecordKey) }
        set { defaults.setValue(newValue, forKey: SharedRecordKeys.savedRootRecordKey) }
    }

    private func storedShareID() async throws -> CKRecord.ID? {
        guard let name = storedShareRecordName else { return nil }
        let zone = try await ensureZoneID()
        return CKRecord.ID(recordName: name, zoneID: zone)
    }

    private func storedRootID() async throws -> CKRecord.ID? {
        guard let name = storedRootRecordName else { return nil }
        let zone = try await ensureZoneID()
        return CKRecord.ID(recordName: name, zoneID: zone)
    }

    private var storedSubscriptionID: String? {
        get {
            if let id = defaults.string(forKey: SharedRecordKeys.savedSubscriptionIDKey) {
                return id
            } else if let name = storedShareRecordName {
                return SharedRecordKeys.subscriptionID(for: CKRecord.ID(recordName: name))
            } else {
                return nil
            }
        }
        set { defaults.setValue(newValue, forKey: SharedRecordKeys.savedSubscriptionIDKey) }
    }

    private func clearStoredShareInfo() {
        storedShareRecordName = nil
        storedRootRecordName = nil
        storedSubscriptionID = nil
        activeShare = nil
    }

    /// Attempts to restore the previously accepted share. Returns `true` if the
    /// share and root record still exist and `activeShare` was populated.
    func restorePersistedShare() async -> Bool {
        guard let shareID = try? await storedShareID(),
              let rootID  = try? await storedRootID() else {
            return false
        }

        do {
            guard let share = try await privateDB.llmRecord(for: shareID) as? CKShare else {
                clearStoredShareInfo()
                return false
            }

            _ = try await privateDB.llmRecord(for: rootID)
            activeShare = share
            return true
        } catch {
            clearStoredShareInfo()
            return false
        }
    }

    init(container: CloudContainer? = nil) {
        if let container = container {
            self.container = container
        } else {
            guard let defaultContainer = try? CKContainer(identifier: "iCloud.com.svk.Choreganize") else {
                fatalError("Missing iCloud container or misconfigured CloudKit environment.")
            }
            self.container = defaultContainer
        }
        self.sharedDB  = self.container.sharedDatabase
        self.privateDB = self.container.privateDatabase

        super.init()   // self is now fully initialised

        SharedRecordKeys.ensureAccountObservation()

        Task { [weak self] in
            try? await self?.prepareUserContext()
        }
    }


    private func createZoneIfNeeded(_ zoneID: CKRecordZone.ID) async {
        guard let db = privateDB as? CKDatabase else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await db.modifyRecordZones(saving: [zone], deleting: [])
        } catch {
            // Ignore failures -- zone may already exist or CloudKit may be unavailable
        }
    }

    private func prepareUserContext() async throws {
        let name = try await SharedRecordKeys.userRecordName()
        let zone = SharedRecordKeys.ownerZoneID(for: name)
        let recordID = SharedRecordKeys.recordID(for: name)
        self.zoneID = zone
        self.rootRecordID = recordID
        await createZoneIfNeeded(zone)
    }

    private func ensureZoneID() async throws -> CKRecordZone.ID {
        if let zoneID { return zoneID }
        try await prepareUserContext()
        return zoneID!
    }

    private func ensureRootRecordID() async throws -> CKRecord.ID {
        if let rootRecordID { return rootRecordID }
        try await prepareUserContext()
        return rootRecordID!
    }


    // MARK: - Publishing
    /// Upserts the root record containing the serialized app state.
    func publish(state: AppModel.SavedState) async {
        do {
            let root = try await fetchOrCreateRootRecord()
            root[SharedRecordKeys.lastEditedKey] = Date() as CKRecordValue

            var records: [CKRecord] = [root]
            records += state.chores.map { record(from: $0, parent: root) }
            records += state.areas.map { record(from: $0, parent: root) }
            records += state.completions.map { record(from: $0, parent: root) }

            _ = try await privateDB.llmModifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
        } catch {
            print("Publish failed: \(error)")
        }
    }

    // MARK: - Subscriptions
    /// Subscribes for silent push notifications when the shared record changes.
    func subscribeToChanges() async {
        guard let shareID = try? await storedShareID() else { return }
        let subID: String
        if let existing = storedSubscriptionID {
            subID = existing
        } else {
            let generated = SharedRecordKeys.subscriptionID(for: shareID)
            storedSubscriptionID = generated
            subID = generated
        }
        let predicate = NSPredicate(value: true)
        let sub = CKQuerySubscription(recordType: SharedRecordKeys.rootRecordType, predicate: predicate, subscriptionID: subID, options: [.firesOnRecordUpdate, .firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do { _ = try await sharedDB.save(sub) } catch { }
    }

    /// Removes the subscription and any shared state from CloudKit.
    func stopSharing() async {
        do {
            if let subID = storedSubscriptionID {
                _ = try? await sharedDB.llmDeleteSubscription(withID: subID)
            }
            // Clean up legacy subscription if present
            _ = try? await sharedDB.llmDeleteSubscription(withID: SharedRecordKeys.legacySubscriptionID)
            if let rootID = try? await ensureRootRecordID() {
                try? await sharedDB.llmDeleteRecord(withID: rootID)
                try? await privateDB.llmDeleteRecord(withID: rootID)
            }
        }
        clearStoredShareInfo()
    }

    // MARK: - Share acceptance
    func acceptShare(url: URL) async -> Bool {
        do {
            let metadata = try await container.llmMetadata(for: url)
            storeShareMetadata(metadata)
            let op = CKAcceptSharesOperation(shareMetadatas: [metadata])
            op.qualityOfService = .userInitiated
            container.add(op)
            return true
        } catch {
            print("Accept share failed: \(error)")
            return false
        }
    }

    /// Persists identifiers from an accepted share so future operations can
    /// reference the correct CloudKit records.
    func storeShareMetadata(_ metadata: CKShare.Metadata) {
        storedShareRecordName = metadata.share.recordID.recordName
        storedRootRecordName = metadata.rootRecord?.recordID.recordName
        storedSubscriptionID = SharedRecordKeys.subscriptionID(for: metadata.share.recordID)
    }

    // MARK: - Share creation
    @MainActor
    func inviteCollaborator(from viewController: UIViewController) async {
        do {
            let (_, share) = try await fetchOrCreateShare()
            if let ckContainer = container as? CKContainer {
                let controller = UICloudSharingController(share: share, container: ckContainer)
                controller.availablePermissions = [.allowReadWrite, .allowPrivate]
                controller.delegate = self
                viewController.present(controller, animated: true)
            }
        } catch {
            print("Share UI failed: \(error)")
        }
    }

    /// Retained for backward compatibility with earlier API.
    @MainActor
    func presentShare(from viewController: UIViewController) async {
        await inviteCollaborator(from: viewController)
    }

    // MARK: - Helpers
    private func fetchOrCreateRootRecord() async throws -> CKRecord {
        let id = try await ensureRootRecordID()
        if let existing = try? await privateDB.llmRecord(for: id) {
            return existing
        }
        return CKRecord(recordType: SharedRecordKeys.rootRecordType, recordID: id)
    }

    /// Fetches or creates the share + root record pair used for collaboration.
    private func fetchOrCreateShare() async throws -> (CKRecord, CKShare) {

        // Try to reuse an existing share + root.
        if let shareID = try await storedShareID(),
           let share   = try? await privateDB.llmRecord(for: shareID) as? CKShare {
            
            let rootID: CKRecord.ID
            if let stored = try await storedRootID() {
                rootID = stored
            } else {
                rootID = try await ensureRootRecordID()
            }

            if let root = try? await privateDB.llmRecord(for: rootID) {
                activeShare = share
                return (root, share)
            }
        }

        // Create a new root record and share.
        let rootRecord = try await fetchOrCreateRootRecord()
        let zoneID     = try await ensureZoneID()           // ensure the per‑user zone exists

        let share = CKShare(rootRecord: rootRecord)
        share[CKShare.SystemFieldKey.title] = "Choreganize" as CKRecordValue
        share.publicPermission = CKShare.ParticipantPermission.none

        _ = try await privateDB.llmModifyRecords(
                saving: [rootRecord, share],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged)

        try? await sharedDB.llmModifyRecords(
                saving: [rootRecord],
                deleting: [],
                savePolicy: .changedKeys)

        storedShareRecordName = share.recordID.recordName
        storedRootRecordName  = rootRecord.recordID.recordName
        storedSubscriptionID  = SharedRecordKeys.subscriptionID(for: share.recordID)
        activeShare           = share

        return (rootRecord, share)
    }



    /// Processes a push notification from CloudKit and merges any updates.
    func handleRemoteNotification(_ userInfo: [AnyHashable : Any]) async {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification else { return }
        let validIDs = [storedSubscriptionID, SharedRecordKeys.legacySubscriptionID]
        guard validIDs.contains(notification.subscriptionID) else { return }
        guard let state = try? await fetchSharedState() else { return }
        await MainActor.run { self.onStateChange?(state) }
    }

    func fetchSharedRootRecord() async -> CKRecord? {
        guard let id = try? await ensureRootRecordID() else { return nil }
        return try? await sharedDB.llmRecord(for: id)
    }

    /// Downloads all shared records and assembles an app state.
    func fetchSharedState() async throws -> AppModel.SavedState {
        let rootID = try await ensureRootRecordID()
        _ = try await fetchOrCreateRootRecord()
        let zone = try await ensureZoneID()
        let choreRecords = try await sharedDB.llmAllRecords(ofType: SharedRecordKeys.choreRecordType, parentID: rootID, in: zone)
        let areaRecords = try await sharedDB.llmAllRecords(ofType: SharedRecordKeys.areaRecordType, parentID: rootID, in: zone)
        let completionRecords = try await sharedDB.llmAllRecords(ofType: SharedRecordKeys.completionRecordType, parentID: rootID, in: zone)

        let chores = choreRecords.compactMap(recordToChore)
        let areas = areaRecords.compactMap(recordToArea)
        let completions = completionRecords.compactMap(recordToCompletion)
        return AppModel.SavedState(chores: chores, areas: areas, completions: completions)
    }

    // MARK: - Record Conversion
    private func record(from chore: Chore, parent: CKRecord) -> CKRecord {
        let record = CKRecord(recordType: SharedRecordKeys.choreRecordType, recordID: CKRecord.ID(recordName: chore.id.uuidString, zoneID: zoneID!))
        record.parent = CKRecord.Reference(recordID: parent.recordID, action: .none)
        record["name"] = chore.name as CKRecordValue
        record["isDaily"] = chore.isDaily as CKRecordValue
        if let freq = chore.frequency { record["frequency"] = freq.rawValue as CKRecordValue }
        if let day = chore.assignedDay { record["assignedDay"] = day.rawValue as CKRecordValue }
        if let area = chore.areaId { record["areaId"] = area.uuidString as CKRecordValue }
        record["createdDate"] = chore.createdDate as CKRecordValue
        return record
    }

    private func record(from area: Area, parent: CKRecord) -> CKRecord {
        let record = CKRecord(recordType: SharedRecordKeys.areaRecordType, recordID: CKRecord.ID(recordName: area.id.uuidString, zoneID: zoneID!))
        record.parent = CKRecord.Reference(recordID: parent.recordID, action: .none)
        record["name"] = area.name as CKRecordValue
        record["description"] = area.description as CKRecordValue
        return record
    }

    private func record(from completion: Completion, parent: CKRecord) -> CKRecord {
        let record = CKRecord(recordType: SharedRecordKeys.completionRecordType, recordID: CKRecord.ID(recordName: completion.id.uuidString, zoneID: zoneID!))
        record.parent = CKRecord.Reference(recordID: parent.recordID, action: .none)
        record["choreId"] = completion.choreId.uuidString as CKRecordValue
        record["date"] = completion.date as CKRecordValue
        if let notes = completion.notes { record["notes"] = notes as CKRecordValue }
        return record
    }

    private func recordToChore(_ record: CKRecord) -> Chore? {
        guard let name = record["name"] as? String else { return nil }
        let id = UUID(uuidString: record.recordID.recordName) ?? UUID()
        let isDaily = record["isDaily"] as? Bool ?? false
        let freq = (record["frequency"] as? String).flatMap { Frequency(rawValue: $0) }
        let day = (record["assignedDay"] as? String).flatMap { Weekday(rawValue: $0) }
        let area = (record["areaId"] as? String).flatMap { UUID(uuidString: $0) }
        let created = record["createdDate"] as? Date ?? Date()
        return Chore(id: id, name: name, isDaily: isDaily, frequency: freq, assignedDay: day, areaId: area, createdDate: created)
    }

    private func recordToArea(_ record: CKRecord) -> Area? {
        guard let name = record["name"] as? String,
              let desc = record["description"] as? String else { return nil }
        let id = UUID(uuidString: record.recordID.recordName) ?? UUID()
        return Area(id: id, name: name, description: desc)
    }

    private func recordToCompletion(_ record: CKRecord) -> Completion? {
        guard let choreStr = record["choreId"] as? String,
              let choreId = UUID(uuidString: choreStr),
              let date = record["date"] as? Date else { return nil }
        let id = UUID(uuidString: record.recordID.recordName) ?? UUID()
        let notes = record["notes"] as? String
        return Completion(id: id, choreId: choreId, date: date, notes: notes)
    }
}

// MARK: - UICloudSharingControllerDelegate
extension SharedCloudKitController: UICloudSharingControllerDelegate {
    func itemTitle(for csc: UICloudSharingController) -> String? { "Choreganize" }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        guard let share = csc.share else { return }
        storedShareRecordName = share.recordID.recordName
        storedSubscriptionID = SharedRecordKeys.subscriptionID(for: share.recordID)
    }

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        print("Share save failed: \(error)")
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        print("Sharing cancelled")
    }
}

