import CloudKit
import UIKit
import os

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

/// Represents the user's role within the current shared environment ("Household").
enum EnvironmentRole {
    case owner
    case subscriber
    case none
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
    private var shareOperationInProgress = false

    // MARK: - Environment helpers
    /// Returns the current user's record name, if available.
    private func currentUserRecordName() async -> String? {
        return try? await SharedRecordKeys.userRecordName()
    }

    /// Returns the zone ID for the owner's shared environment if one is persisted.
    private func ownerZoneIDFromPersisted() -> CKRecordZone.ID? {
        guard let info = persistedShare else { return nil }
        return CKRecordZone.ID(zoneName: info.zoneName, ownerName: info.zoneOwner)
    }

    /// Determines whether the current user is the owner of the persisted share.
    func currentEnvironmentRole() async -> EnvironmentRole {
        guard let info = persistedShare, let me = try? await SharedRecordKeys.userRecordName() else { return .none }
        return info.zoneOwner == me ? .owner : .subscriber
    }

    /// A user-friendly name for the current environment.
    /// Falls back to "Household" if a share hasn't been created yet.
    func environmentDisplayName() -> String {
        if let activeShare,
           let title = activeShare[CKShare.SystemFieldKey.title] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return "Household"
    }

    private struct PersistedShare: Codable {
        let zoneName: String
        let zoneOwner: String
        let rootRecordName: String?
        let shareRecordName: String
    }

    private var persistedShare: PersistedShare? {
        get {
            guard let data = defaults.data(forKey: SharedRecordKeys.savedShareInfoKey) else { return nil }
            return try? JSONDecoder().decode(PersistedShare.self, from: data)
        }
        set {
            if let value = newValue, let data = try? JSONEncoder().encode(value) {
                defaults.setValue(data, forKey: SharedRecordKeys.savedShareInfoKey)
            } else {
                defaults.removeObject(forKey: SharedRecordKeys.savedShareInfoKey)
            }
        }
    }

    private func storedShareID() async throws -> CKRecord.ID? {
        guard let info = persistedShare else { return nil }
        let zone = CKRecordZone.ID(zoneName: info.zoneName, ownerName: info.zoneOwner)
        return CKRecord.ID(recordName: info.shareRecordName, zoneID: zone)
    }

    private func storedRootID() async throws -> CKRecord.ID? {
        guard let info = persistedShare, let name = info.rootRecordName else { return nil }
        let zone = CKRecordZone.ID(zoneName: info.zoneName, ownerName: info.zoneOwner)
        return CKRecord.ID(recordName: name, zoneID: zone)
    }

    private var storedSubscriptionID: String? {
        get {
            if let id = defaults.string(forKey: SharedRecordKeys.savedSubscriptionIDKey) {
                return id
            } else if let info = persistedShare {
                let shareID = CKRecord.ID(recordName: info.shareRecordName, zoneID: CKRecordZone.ID(zoneName: info.zoneName, ownerName: info.zoneOwner))
                return SharedRecordKeys.subscriptionID(for: shareID)
            } else {
                return nil
            }
        }
        set { defaults.setValue(newValue, forKey: SharedRecordKeys.savedSubscriptionIDKey) }
    }

    private func clearStoredShareInfo() {
        persistedShare = nil
        storedSubscriptionID = nil
        activeShare = nil
    }

    /// Attempts to restore the previously accepted share. Returns `true` if the
    /// share and root record still exist and `activeShare` was populated.
    func restorePersistedShare() async -> Bool {
        Log.debug(.cloud, "Attempting to restore persisted share")
        guard let shareID = try? await storedShareID(),
              let rootID  = try? await storedRootID() else {
            return false
        }

        do {
            guard let share = try await privateDB.llmRecord(for: shareID) as? CKShare else {
                Log.warning(.cloud, "Failed to restore persisted share; clearing stored info")
                clearStoredShareInfo()
                return false
            }

            _ = try await privateDB.llmRecord(for: rootID)
            activeShare = share
            Log.info(.cloud, "Restored persisted share successfully")
            return true
        } catch {
            Log.warning(.cloud, "Failed to restore persisted share; clearing stored info")
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
        Log.debug(.cloud, "Prepared user context: zone=\(zone.zoneName)")
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
        Log.info(.cloud, "Publishing state (role=\(await currentEnvironmentRole()))")
        do {
            let role = await currentEnvironmentRole()

            switch role {
            case .owner:
                // Owner writes to their private database in their own zone.
                let zone = try await ensureZoneID()
                let root = try await fetchOrCreateRootRecord()
                root[SharedRecordKeys.lastEditedKey] = Date() as CKRecordValue

                var records: [CKRecord] = [root]
                records += state.chores.map { record(from: $0, parent: root, in: zone) }
                records += state.areas.map { record(from: $0, parent: root, in: zone) }
                records += state.completions.map { record(from: $0, parent: root, in: zone) }

                Log.debug(.cloud, "Owner publishing: records=\(records.count)")
                _ = try await privateDB.llmModifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)

            case .subscriber:
                // Participant writes to the shared database in the OWNER's zone.
                guard let ownerZone = ownerZoneIDFromPersisted(),
                      let rootID = try await storedRootID(),
                      let root = try? await sharedDB.llmRecord(for: rootID) else {
                    return
                }

                if let rootRecord = root as CKRecord? {
                    rootRecord[SharedRecordKeys.lastEditedKey] = Date() as CKRecordValue

                    var records: [CKRecord] = [rootRecord]
                    records += state.chores.map { record(from: $0, parent: rootRecord, in: ownerZone) }
                    records += state.areas.map { record(from: $0, parent: rootRecord, in: ownerZone) }
                    records += state.completions.map { record(from: $0, parent: rootRecord, in: ownerZone) }

                    Log.debug(.cloud, "Subscriber publishing: records=\(records.count)")
                    _ = try await sharedDB.llmModifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
                }

            case .none:
                // No environment selected; nothing to publish.
                return
            }
        } catch {
            Log.error(.cloud, "Publish failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Subscriptions
    /// Subscribes for silent push notifications when the shared root record changes.
    /// Limits the subscription to the specific record to avoid cross‑share notifications.
    func subscribeToChanges() async {
        Log.info(.cloud, "Subscribing to changes for rootID and shareID")
        guard let shareID = try? await storedShareID(),
              let rootID  = try? await storedRootID() else { return }
        let subID: String
        if let existing = storedSubscriptionID {
            subID = existing
        } else {
            let generated = SharedRecordKeys.subscriptionID(for: shareID)
            storedSubscriptionID = generated
            subID = generated
        }
        let predicate = NSPredicate(format: "recordID == %@", rootID)
        let sub = CKQuerySubscription(recordType: SharedRecordKeys.rootRecordType, predicate: predicate, subscriptionID: subID, options: [.firesOnRecordUpdate, .firesOnRecordCreation])
        sub.zoneID = rootID.zoneID
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do {
            _ = try await sharedDB.save(sub)
            Log.info(.cloud, "Subscription saved: id=\(subID)")
        } catch {
            Log.error(.cloud, "Subscription save failed: \(error.localizedDescription)")
        }
    }

    /// Removes the subscription and any shared state from CloudKit.
    func stopSharing() async {
        Log.info(.cloud, "Stopping sharing: deleting subscription and root records if present")
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
        Log.info(.cloud, "Accepting share from URL: \(url.absoluteString)")
        guard !shareOperationInProgress else { return false }
        shareOperationInProgress = true
        defer { shareOperationInProgress = false }
        do {
            let metadata = try await container.llmMetadata(for: url)
            storeShareMetadata(metadata)

            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                let op = CKAcceptSharesOperation(shareMetadatas: [metadata])
                op.qualityOfService = .userInitiated

                op.perShareResultBlock = { _, result in
                    switch result {
                    case .failure(let error):
                        cont.resume(throwing: error)
                    case .success:
                        break
                    }
                }

                op.acceptSharesResultBlock = { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: true)
                    }
                }

                self.container.add(op)
            }
        } catch {
            Log.error(.cloud, "Accept share failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Persists identifiers from an accepted share so future operations can
    /// reference the correct CloudKit records.
    func storeShareMetadata(_ metadata: CKShare.Metadata) {
        Log.debug(.cloud, "Stored share metadata for zone=\(metadata.share.recordID.zoneID.zoneName)")
        let zone = metadata.share.recordID.zoneID
        persistedShare = PersistedShare(
            zoneName: zone.zoneName,
            zoneOwner: zone.ownerName,
            rootRecordName: metadata.rootRecord?.recordID.recordName,
            shareRecordName: metadata.share.recordID.recordName
        )
        storedSubscriptionID = SharedRecordKeys.subscriptionID(for: metadata.share.recordID)
    }

    // MARK: - Share creation
    @MainActor
    func inviteCollaborator(from viewController: UIViewController) async {
        Log.info(.cloud, "Presenting UICloudSharingController")
        guard !shareOperationInProgress else { return }
        shareOperationInProgress = true
        defer { shareOperationInProgress = false }
        do {
            let (_, share) = try await fetchOrCreateShare()
            if let ckContainer = container as? CKContainer {
                let controller = UICloudSharingController(share: share, container: ckContainer)
                controller.availablePermissions = [.allowReadWrite, .allowPrivate]
                controller.delegate = self
                viewController.present(controller, animated: true)
            }
        } catch {
            Log.error(.cloud, "Share UI failed: \(error.localizedDescription)")
        }
    }

    /// Retained for backward compatibility with earlier API.
    @MainActor
    func presentShare(from viewController: UIViewController) async {
        await inviteCollaborator(from: viewController)
    }

    // MARK: - Helpers
    private func fetchOrCreateRootRecord() async throws -> CKRecord {
        let id: CKRecord.ID
        if let stored = try? await storedRootID() {
            id = stored
        } else {
            id = try await ensureRootRecordID()
        }
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
                Log.info(.cloud, "Reusing existing share and root record")
                activeShare = share
                return (root, share)
            }
        }

        Log.info(.cloud, "Creating new share and root record")
        // Create a new root record and share.
        let rootRecord = try await fetchOrCreateRootRecord()
        let zoneID     = try await ensureZoneID()           // ensure the per‑user zone exists

        let share = CKShare(rootRecord: rootRecord)
        share[CKShare.SystemFieldKey.title] = "Household" as CKRecordValue
        share.publicPermission = CKShare.ParticipantPermission.none

        _ = try await privateDB.llmModifyRecords(
                saving: [rootRecord, share],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged)

        try? await sharedDB.llmModifyRecords(
                saving: [rootRecord],
                deleting: [],
                savePolicy: .changedKeys)

        persistedShare = PersistedShare(
            zoneName: zoneID.zoneName,
            zoneOwner: zoneID.ownerName,
            rootRecordName: rootRecord.recordID.recordName,
            shareRecordName: share.recordID.recordName
        )
        storedSubscriptionID  = SharedRecordKeys.subscriptionID(for: share.recordID)
        activeShare           = share

        return (rootRecord, share)
    }



    /// Processes a push notification from CloudKit and merges any updates.
    func handleRemoteNotification(_ userInfo: [AnyHashable : Any]) async {
        Log.debug(.push, "Handling remote notification: subscriptionID=\(String(describing: (CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification)?.subscriptionID))")
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification else { return }
        let validIDs = [storedSubscriptionID, SharedRecordKeys.legacySubscriptionID]
        guard validIDs.contains(notification.subscriptionID) else { return }
        guard let state = try? await fetchSharedState() else { return }
        Log.info(.cloud, "Fetched shared state due to push; notifying observers")
        await MainActor.run { self.onStateChange?(state) }
    }

    func fetchSharedRootRecord() async -> CKRecord? {
        guard let id = try? await ensureRootRecordID() else { return nil }
        return try? await sharedDB.llmRecord(for: id)
    }

    /// Downloads all shared records and assembles an app state.
    func fetchSharedState() async throws -> AppModel.SavedState {
        Log.debug(.cloud, "Fetching shared state from shared DB")
        let rootID: CKRecord.ID
        if let stored = try? await storedRootID() {
            rootID = stored
        } else {
            rootID = try await ensureRootRecordID()
        }
        _ = try await fetchOrCreateRootRecord()

        let zone: CKRecordZone.ID
        if let ownerZone = ownerZoneIDFromPersisted() {
            zone = ownerZone
        } else {
            zone = try await ensureZoneID()
        }

        let choreRecords = try await sharedDB.llmAllRecords(ofType: SharedRecordKeys.choreRecordType, parentID: rootID, in: zone)
        let areaRecords = try await sharedDB.llmAllRecords(ofType: SharedRecordKeys.areaRecordType, parentID: rootID, in: zone)
        let completionRecords = try await sharedDB.llmAllRecords(ofType: SharedRecordKeys.completionRecordType, parentID: rootID, in: zone)

        let chores = choreRecords.compactMap(recordToChore)
        let areas = areaRecords.compactMap(recordToArea)
        let completions = completionRecords.compactMap(recordToCompletion)
        Log.debug(.cloud, "Fetched counts: chores=\(chores.count), areas=\(areas.count), completions=\(completions.count)")
        return AppModel.SavedState(chores: chores, areas: areas, completions: completions)
    }

    // MARK: - Record Conversion
    private func record(from chore: Chore, parent: CKRecord, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: SharedRecordKeys.choreRecordType, recordID: CKRecord.ID(recordName: chore.id.uuidString, zoneID: zoneID))
        record.parent = CKRecord.Reference(recordID: parent.recordID, action: .none)
        record["name"] = chore.name as CKRecordValue
        record["isDaily"] = chore.isDaily as CKRecordValue
        if let freq = chore.frequency { record["frequency"] = freq.rawValue as CKRecordValue }
        if let day = chore.assignedDay { record["assignedDay"] = day.rawValue as CKRecordValue }
        if let area = chore.areaId { record["areaId"] = area.uuidString as CKRecordValue }
        record["createdDate"] = chore.createdDate as CKRecordValue
        return record
    }

    private func record(from area: Area, parent: CKRecord, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: SharedRecordKeys.areaRecordType, recordID: CKRecord.ID(recordName: area.id.uuidString, zoneID: zoneID))
        record.parent = CKRecord.Reference(recordID: parent.recordID, action: .none)
        record["name"] = area.name as CKRecordValue
        record["description"] = area.description as CKRecordValue
        return record
    }

    private func record(from completion: Completion, parent: CKRecord, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: SharedRecordKeys.completionRecordType, recordID: CKRecord.ID(recordName: completion.id.uuidString, zoneID: zoneID))
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
        let zone = share.recordID.zoneID
        persistedShare = PersistedShare(
            zoneName: zone.zoneName,
            zoneOwner: zone.ownerName,
            rootRecordName: rootRecordID?.recordName,
            shareRecordName: share.recordID.recordName
        )
        storedSubscriptionID = SharedRecordKeys.subscriptionID(for: share.recordID)
    }

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        print("Share save failed: \(error)")
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        print("Sharing cancelled")
    }
}

