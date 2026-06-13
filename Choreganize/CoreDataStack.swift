import CoreData
import CloudKit
import os

/// Owns the Core Data + CloudKit stack for Choreganize.
///
/// Phase 1: a single `.private` persistent store mirrored to CloudKit via
/// `NSPersistentCloudKitContainer`. The `.shared` store — used to participate in
/// other people's Households — is added in Phase 3, alongside a second store
/// description pointed at the same model.
final class CoreDataStack {
    static let shared = CoreDataStack()

    /// Must match the iCloud container in the entitlements.
    static let cloudContainerIdentifier = "iCloud.com.svk.Choreganize"
    /// Must match the `.xcdatamodeld` filename (without extension).
    static let modelName = "Choreganize"

    let container: NSPersistentCloudKitContainer

    /// Main-queue context used by the UI and `@FetchRequest`.
    var viewContext: NSManagedObjectContext { container.viewContext }

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: Self.modelName)

        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("CoreDataStack: no persistent store description found.")
        }

        if inMemory {
            // Tests / previews: ephemeral store, no CloudKit.
            description.url = URL(fileURLWithPath: "/dev/null")
            description.cloudKitContainerOptions = nil
        } else {
            // Mirror this store to the CloudKit *private* database.
            let options = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudContainerIdentifier)
            options.databaseScope = .private
            description.cloudKitContainerOptions = options
        }

        // Both required for CloudKit sync and clean merges of remote changes.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                Log.error("Core Data store failed to load: \(error.code) \(error.localizedDescription)", category: .persistence)
            } else {
                let cloud = storeDescription.cloudKitContainerOptions != nil ? "CloudKit" : "local-only"
                Log.info("Core Data store loaded (\(cloud)): \(storeDescription.url?.lastPathComponent ?? "?")", category: .persistence)
            }
        }

        let ctx = container.viewContext
        ctx.automaticallyMergesChangesFromParent = true
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        ctx.transactionAuthor = "app"
        // Pin to the latest generation so the UI sees a stable snapshot between merges.
        try? ctx.setQueryGenerationFrom(.current)
    }

    /// Background context for imports and bulk writes.
    func newBackgroundContext() -> NSManagedObjectContext {
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        ctx.transactionAuthor = "app"
        return ctx
    }

    /// Saves the view context if it has pending changes.
    func saveViewContext() {
        let ctx = viewContext
        guard ctx.hasChanges else { return }
        do {
            try ctx.save()
        } catch {
            Log.error("Core Data save failed: \(error.localizedDescription)", category: .persistence)
        }
    }

    #if DEBUG
    /// One-time helper to publish the model to the CloudKit **Development** schema.
    ///
    /// Run this once from a debug build (e.g. temporarily call it from
    /// `ChoreganizeApp.init`) while signed into iCloud, watch the logs for
    /// success, then remove the call. NSPCKC also creates schema lazily as
    /// records save, so this is mainly to force/verify schema creation up front.
    func initializeCloudKitSchemaForDevelopment() {
        do {
            try container.initializeCloudKitSchema(options: [])
            Log.info("CloudKit development schema initialized.", category: .cloud)
        } catch {
            Log.error("initializeCloudKitSchema failed: \(error.localizedDescription)", category: .cloud)
        }
    }
    #endif
}
