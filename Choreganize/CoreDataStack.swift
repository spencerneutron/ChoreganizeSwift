import CoreData
import CloudKit
import os

/// Owns the Core Data + CloudKit stack for Choreganize.
///
/// Phase 3: two stores share one model — a `.private` store (your own data and
/// households you own) and a `.shared` store (households shared *with* you).
/// `NSPersistentCloudKitContainer` mirrors each to the matching CloudKit
/// database. CloudKit is skipped for tests / previews / `CHOREGANIZE_LOCAL_ONLY`.
final class CoreDataStack {
    /// Shared app stack. UI tests pass `CHOREGANIZE_UITEST_INMEMORY=1` for a clean,
    /// ephemeral store each launch (hermetic UI tests); production is unaffected.
    static let shared = CoreDataStack(
        inMemory: ProcessInfo.processInfo.environment["CHOREGANIZE_UITEST_INMEMORY"] == "1"
    )

    /// Must match the iCloud container in the entitlements.
    static let cloudContainerIdentifier = "iCloud.com.svk.Choreganize"
    /// Must match the `.xcdatamodeld` filename (without extension).
    static let modelName = "Choreganize"

    /// The managed object model, loaded **once** and shared by every container.
    /// `NSPersistentCloudKitContainer(name:)` otherwise reloads the model from the
    /// bundle per init, registering the `CD…` subclasses against multiple
    /// `NSEntityDescription`s — which races under parallel tests as "Unacceptable
    /// type of value … desired CDX; given CDX". One shared instance removes the
    /// ambiguity (sharing a model across coordinators is explicitly supported).
    static let managedObjectModel: NSManagedObjectModel = {
        let bundle = Bundle(for: CoreDataStack.self)
        guard let url = bundle.url(forResource: modelName, withExtension: "momd")
                ?? bundle.url(forResource: modelName, withExtension: "mom"),
              let model = NSManagedObjectModel(contentsOf: url) else {
            fatalError("CoreDataStack: failed to load managed object model '\(modelName)'")
        }
        return model
    }()

    let container: NSPersistentCloudKitContainer

    /// Whether CloudKit mirroring (and therefore sharing) is active. Starts from
    /// the run configuration but can flip to `false` at load time if CloudKit
    /// setup fails because there's no usable iCloud account (CG-07): we degrade to
    /// local-only rather than trap, so the app still runs offline.
    private(set) var cloudKitEnabled: Bool

    /// True when CloudKit was *intended* this run but we fell back to local-only
    /// because the iCloud account was missing/unavailable at launch. Lets the UI
    /// distinguish "sync paused, not signed in" from a deliberately local run.
    private(set) var degradedToLocalOnly: Bool = false

    /// The CloudKit private-database store (own data + owned households).
    private(set) var privateStore: NSPersistentStore?
    /// The CloudKit shared-database store (households shared with you).
    private(set) var sharedStore: NSPersistentStore?

    /// Main-queue context used by the UI and `@FetchRequest`.
    var viewContext: NSManagedObjectContext { container.viewContext }

    /// True when the process is running under XCTest (host app or test bundle).
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Skip CloudKit under test, in SwiftUI previews, or when explicitly asked via
    /// `CHOREGANIZE_LOCAL_ONLY=1` (simulator runs not signed into iCloud, where
    /// CloudKit setup can trap).
    static var skipCloudKit: Bool {
        isRunningTests
            || ProcessInfo.processInfo.environment["CHOREGANIZE_LOCAL_ONLY"] == "1"
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// True only for the *expected* "no usable iCloud account" failure when a
    /// CloudKit-backed store can't load (CG-07). Used to decide whether to degrade
    /// to local-only. Deliberately narrow so real misconfiguration still surfaces:
    /// `CKError.notAuthenticated` is the account-not-signed-in case, and Core Data
    /// surfaces the same condition as a `CKErrorDomain` error nested under
    /// `NSUnderlyingError`. Anything else (entitlements, schema, quota) returns false.
    static func isMissingAccountError(_ error: NSError) -> Bool {
        for candidate in [error] + (error.underlyingErrors as [NSError]) {
            if candidate.domain == CKErrorDomain,
               candidate.code == CKError.notAuthenticated.rawValue {
                return true
            }
        }
        return false
    }

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: Self.modelName, managedObjectModel: Self.managedObjectModel)
        cloudKitEnabled = !inMemory && !Self.skipCloudKit

        guard let privateDescription = container.persistentStoreDescriptions.first else {
            fatalError("CoreDataStack: no persistent store description found.")
        }

        if inMemory {
            privateDescription.url = URL(fileURLWithPath: "/dev/null")
        }

        // Both required for CloudKit sync and clean merges of remote changes.
        privateDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        privateDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        if cloudKitEnabled {
            // Private database store.
            let privateOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudContainerIdentifier)
            privateOptions.databaseScope = .private
            privateDescription.cloudKitContainerOptions = privateOptions

            // Shared database store: a second store, same model, pointed at the
            // CloudKit *shared* database (households other people share with you).
            guard let sharedDescription = privateDescription.copy() as? NSPersistentStoreDescription else {
                fatalError("CoreDataStack: could not derive the shared store description.")
            }
            sharedDescription.url = privateDescription.url?
                .deletingLastPathComponent()
                .appendingPathComponent("Choreganize-shared.sqlite")
            let sharedOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudContainerIdentifier)
            sharedOptions.databaseScope = .shared
            sharedDescription.cloudKitContainerOptions = sharedOptions

            container.persistentStoreDescriptions = [privateDescription, sharedDescription]
        } else {
            privateDescription.cloudKitContainerOptions = nil
        }

        var loadError: NSError?
        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                Log.error("Core Data store failed to load: \(error.code) \(error.localizedDescription)", category: .persistence)
                loadError = error
            } else {
                let scope = storeDescription.cloudKitContainerOptions?.databaseScope
                let label = scope == .shared ? "shared/CloudKit"
                    : (scope == .private ? "private/CloudKit" : "local-only")
                Log.info("Core Data store loaded (\(label)): \(storeDescription.url?.lastPathComponent ?? "?")", category: .persistence)
            }
        }

        // CG-07: if a CloudKit-backed store failed to load *only because there's no
        // usable iCloud account*, degrade to local-only and reload — the app should
        // still run offline, not trap. A genuine misconfiguration (entitlements,
        // schema, etc.) is NOT swallowed: it's logged above and left to surface.
        if cloudKitEnabled, let loadError, Self.isMissingAccountError(loadError) {
            Log.warning("CloudKit unavailable (no iCloud account); degrading to local-only.", category: .cloud)
            cloudKitEnabled = false
            degradedToLocalOnly = true
            sharedStore = nil
            for description in container.persistentStoreDescriptions {
                description.cloudKitContainerOptions = nil
            }
            // Drop the second (shared) store description added for CloudKit; one
            // local store is enough offline.
            if let primary = container.persistentStoreDescriptions.first {
                container.persistentStoreDescriptions = [primary]
            }
            container.loadPersistentStores { storeDescription, error in
                if let error = error as NSError? {
                    Log.error("Local-only store failed to load after degrade: \(error.code) \(error.localizedDescription)", category: .persistence)
                } else {
                    Log.info("Core Data store loaded (local-only fallback): \(storeDescription.url?.lastPathComponent ?? "?")", category: .persistence)
                }
            }
        }

        // loadPersistentStores completes synchronously for SQLite stores, so the
        // stores exist by now. Map them to private/shared by database scope.
        for description in container.persistentStoreDescriptions {
            guard let url = description.url,
                  let store = container.persistentStoreCoordinator.persistentStore(for: url) else { continue }
            if description.cloudKitContainerOptions?.databaseScope == .shared {
                sharedStore = store
            } else {
                privateStore = store
            }
        }

        let context = container.viewContext
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.transactionAuthor = "app"
        // The ephemeral in-memory store (UI tests) doesn't support query-generation
        // pinning; only pin the real on-disk store.
        if !inMemory {
            try? context.setQueryGenerationFrom(.current)
        }
    }

    /// Background context for imports and bulk writes.
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.transactionAuthor = "app"
        return context
    }

    /// Saves the view context if it has pending changes.
    func saveViewContext() {
        let context = viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            Log.error("Core Data save failed: \(error.localizedDescription)", category: .persistence)
        }
    }

    /// Accepts an incoming CloudKit share into the shared store. Phase 3.
    func acceptShare(_ metadata: CKShare.Metadata) {
        guard let sharedStore else {
            Log.error("Cannot accept share: no shared store (CloudKit disabled?)", category: .cloud)
            return
        }
        container.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            if let error {
                Log.error("acceptShareInvitations failed: \(error.localizedDescription)", category: .cloud)
            } else {
                Log.info("Accepted CloudKit share into shared store", category: .cloud)
                // Let the sharing UI re-query its state; the shared household's
                // data itself arrives via the mirroring import that follows.
                NotificationCenter.default.post(name: .householdShareDidChange, object: nil)
            }
        }
    }

    #if DEBUG
    /// One-time helper to publish the model to the CloudKit **Development** schema.
    /// Run once from a debug build while signed into iCloud, then remove the call.
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
