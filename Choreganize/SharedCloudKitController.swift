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
final class SharedCloudKitController {
    static var shared = SharedCloudKitController()

    static func configure(container: CloudContainer) {
        shared = SharedCloudKitController(container: container)
    }

    private let container: CloudContainer
    private let sharedDB: CloudDatabase
    private let privateDB: CloudDatabase

    init(container: CloudContainer? = nil) {
        if let container = container {
            self.container = container
        } else {
            guard let defaultContainer = try? CKContainer(identifier: "iCloud.svk.Choreganize") else {
                fatalError("Missing iCloud container or misconfigured CloudKit environment.")
            }
            self.container = defaultContainer
        }
        self.sharedDB = self.container.sharedDatabase
        self.privateDB = self.container.privateDatabase
    }


    // MARK: - Publishing
    /// Upserts the root record containing the serialized app state.
    func publish(state: AppModel.SavedState) async {
        do {
            let record = try await fetchOrCreateRootRecord()
            record[SharedRecordKeys.jsonKey] = try JSONEncoder().encode(state) as CKRecordValue
            record[SharedRecordKeys.lastEditedKey] = Date() as CKRecordValue
            _ = try await privateDB.llmModifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
        } catch {
            print("Publish failed: \(error)")
        }
    }

    // MARK: - Subscriptions
    /// Creates a database subscription so that CloudKit pushes changes in the background.
    func subscribeToChanges() async {
        let id = SharedRecordKeys.subscriptionID
        let sub = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do { _ = try await sharedDB.save(sub) } catch { }
    }

    /// Removes the subscription and any shared state from CloudKit.
    func stopSharing() async {
        do {
            _ = try? await sharedDB.llmDeleteSubscription(withID: SharedRecordKeys.subscriptionID)
            try? await sharedDB.llmDeleteRecord(withID: SharedRecordKeys.recordID)
            try? await privateDB.llmDeleteRecord(withID: SharedRecordKeys.recordID)
        }
    }

    // MARK: - Share acceptance
    func acceptShare(url: URL) async -> Bool {
        do {
            let metadata = try await container.llmMetadata(for: url)
            let op = CKAcceptSharesOperation(shareMetadatas: [metadata])
            op.qualityOfService = .userInitiated
            container.add(op)
            return true
        } catch {
            print("Accept share failed: \(error)")
            return false
        }
    }

    // MARK: - Share creation
    @MainActor
    func presentShare(from viewController: UIViewController) async {
        do {
            let record = try await fetchOrCreateRootRecord()
            let share = CKShare(rootRecord: record)
            share.publicPermission = .readWrite
            _ = try await privateDB.llmModifyRecords(saving: [record, share], deleting: [], savePolicy: .ifServerRecordUnchanged)
            if let ckContainer = container as? CKContainer {
                let controller = UICloudSharingController(share: share, container: ckContainer)
                controller.availablePermissions = [.allowReadWrite]
                viewController.present(controller, animated: true)
            }
        } catch {
            print("Share UI failed: \(error)")
        }
    }

    // MARK: - Helpers
    private func fetchOrCreateRootRecord() async throws -> CKRecord {
        if let existing = try? await privateDB.llmRecord(for: SharedRecordKeys.recordID) {
            return existing
        }
        return CKRecord(recordType: "AppState", recordID: SharedRecordKeys.recordID)
    }

    func fetchSharedRootRecord() async -> CKRecord? {
        return try? await sharedDB.llmRecord(for: SharedRecordKeys.recordID)
    }
}

