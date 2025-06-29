import CloudKit
import UIKit

/// Handles access to the user's shared CloudKit database and sharing APIs.
final class SharedCloudKitController {
    static let shared = SharedCloudKitController()

    private let container: CKContainer
    private let sharedDB: CKDatabase
    private let privateDB: CKDatabase

    init(container: CKContainer = .default()) {
        self.container = container
        self.sharedDB = container.sharedCloudDatabase
        self.privateDB = container.privateCloudDatabase
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
            let controller = UICloudSharingController(share: share, container: container)
            controller.availablePermissions = [.allowReadWrite]
            viewController.present(controller, animated: true)
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

// MARK: - Async helpers
private extension CKDatabase {
    func llmRecord(for id: CKRecord.ID) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { cont in
            fetch(withRecordID: id) { record, error in
                if let record { cont.resume(returning: record) }
                else { cont.resume(throwing: error ?? CKError(.unknownItem)) }
            }
        }
    }

    func llmModifyRecords(saving records: [CKRecord], deleting: [CKRecord.ID], savePolicy: CKModifyRecordsOperation.RecordSavePolicy) async throws -> ([CKRecord], [CKRecord.ID]) {
        try await withCheckedThrowingContinuation { cont in
            let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: deleting)
            op.savePolicy = savePolicy
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success(let (saved, deleted)):
                    cont.resume(returning: (saved, deleted))
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
            add(op)
        }
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
}

private extension CKContainer {
    func llmMetadata(for url: URL) async throws -> CKShare.Metadata {
        try await withCheckedThrowingContinuation { cont in
            fetchShareMetadata(with: url) { metadata, error in
                if let metadata { cont.resume(returning: metadata) }
                else { cont.resume(throwing: error ?? CKError(.unknownItem)) }
            }
        }
    }
}
