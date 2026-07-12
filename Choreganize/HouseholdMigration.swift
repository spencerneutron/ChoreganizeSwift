import CoreData
import CloudKit

/// CG-11 / #64 — migrate Personal chores & areas into the active Household.
///
/// Two fundamentally different paths, decided by where the household lives
/// (spike #94 verdict, PLAN decision log 2026-07-09):
///
/// **Owner** (household in the private store) — a true MOVE. Setting the
/// `household` relationship alone never re-homes an already-exported record
/// into the share zone, and the resulting cross-zone relationship is silently
/// dropped on a fresh-device restore. So the move is two steps, journaled so a
/// crash between them resumes on next launch: (1) re-parent the whole closure
/// and save atomically; (2) `container.share(closure, to: existingShare)`,
/// which is the supported zone re-home. When the household isn't shared yet
/// there is no second zone, so step 1 alone is complete (share creation later
/// moves the household's whole graph).
///
/// **Participant** (household in the shared store) — a cross-store COPY that
/// RETAINS the Personal original (locked product decision: zero data loss).
/// Copies mint fresh UUIDs — never reuse a UUID across the Personal/Household
/// domains — and each migrated root records original→copy provenance, which is
/// both the idempotency key (an interrupted contribution never mints a second
/// copy) and the seed for a future "migrated" badge / bulk-cleanup.
///
/// Rooms move as a unit: migrating part of an area would leave the remainder
/// pointing across the zone boundary — exactly the dropped-relationship
/// corruption the spike demonstrated.
enum HouseholdMigration {

    enum Mode {
        /// The household is ours (private store): true move.
        case ownerMove
        /// The household is shared with us (shared store): copy-and-retain.
        case participantCopy
    }

    /// What the user picked in the migration sheet. Whole rooms plus loose
    /// (area-less) chores; a room implies all of its chores and completions.
    struct Selection {
        var areas: [CDArea] = []
        var chores: [CDChore] = []

        var isEmpty: Bool { areas.isEmpty && chores.isEmpty }
        var rootCount: Int { areas.count + chores.count }
    }

    struct Outcome {
        var mode: Mode
        var migratedRoots: Int
        var skippedRoots: Int
    }

    enum MigrationError: LocalizedError {
        case nothingSelected
        case noContext

        var errorDescription: String? {
            switch self {
            case .nothingSelected: "Nothing was selected."
            case .noContext: "The selected items are no longer available."
            }
        }
    }

    /// Which path a migration into this household takes.
    static func mode(for household: CDHousehold, stack: CoreDataStack = .shared) -> Mode {
        if let shared = stack.sharedStore,
           household.objectID.persistentStore === shared {
            return .participantCopy
        }
        return .ownerMove
    }

    // MARK: - Entry point

    /// Migrates the selection into the household and returns what happened.
    /// Call from the main actor with view-context objects.
    @MainActor
    static func migrate(_ selection: Selection,
                        into household: CDHousehold,
                        stack: CoreDataStack = .shared,
                        journal: MigrationJournal = .shared) async throws -> Outcome {
        guard !selection.isEmpty else { throw MigrationError.nothingSelected }
        guard let ctx = household.managedObjectContext else { throw MigrationError.noContext }

        switch mode(for: household, stack: stack) {
        case .ownerMove:
            try await moveOwnerSide(selection, into: household, context: ctx, stack: stack, journal: journal)
            return Outcome(mode: .ownerMove, migratedRoots: selection.rootCount, skippedRoots: 0)
        case .participantCopy:
            let store = household.objectID.persistentStore
            let copied = try contribute(selection, into: household, store: store, context: ctx, journal: journal)
            return Outcome(mode: .participantCopy,
                           migratedRoots: copied,
                           skippedRoots: selection.rootCount - copied)
        }
    }

    // MARK: - Owner-side move

    /// Step 1 (re-parent + atomic save) is journaled before it runs; step 2
    /// (zone re-home via `share(_:to:)`) clears the journal only on success, so
    /// a crash in between resumes on next launch (`resumePendingMoveIfNeeded`).
    @MainActor
    private static func moveOwnerSide(_ selection: Selection,
                                      into household: CDHousehold,
                                      context: NSManagedObjectContext,
                                      stack: CoreDataStack,
                                      journal: MigrationJournal) async throws {
        let objects = closure(for: selection)
        journal.beginPendingMove(ids: uuids(of: objects), householdID: household.id)

        reparent(objects, to: household)
        try context.save()
        Log.info("Owner migration: re-parented \(objects.count) record(s) into the household", category: .cloud)

        try await rehomeIntoShareZoneIfShared(objects, household: household, stack: stack)
        journal.clearPendingMove()
    }

    /// Sets the `household` relationship on every object in the closure.
    /// All migratable entities carry the relationship under the same name.
    static func reparent(_ objects: [NSManagedObject], to household: CDHousehold?) {
        for object in objects {
            object.setValue(household, forKey: "household")
        }
    }

    /// When the household already has a CKShare, `share(_:to:)` is the only
    /// supported way to move already-exported records into its zone. No-op when
    /// CloudKit is off or the household isn't shared (single-zone: nothing to
    /// re-home). The container's share APIs block their calling thread on the
    /// request executor, so both calls run detached — never on main.
    private static func rehomeIntoShareZoneIfShared(_ objects: [NSManagedObject],
                                                    household: CDHousehold,
                                                    stack: CoreDataStack) async throws {
        guard stack.cloudKitEnabled else { return }
        let container = stack.container
        let householdID = household.objectID
        try await Task.detached(priority: .userInitiated) {
            guard let share = (try? container.fetchShares(matching: [householdID]))?[householdID] else { return }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                container.share(objects, to: share) { _, _, _, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
            Log.info("Owner migration: closure re-homed into the share zone", category: .cloud)
        }.value
    }

    /// Finishes an owner-side move interrupted between the local save and the
    /// zone re-home (journal still pending). Idempotent: re-parenting is a
    /// no-op on already-moved records and re-sharing to the same share is
    /// harmless. Call once at launch; does nothing when the journal is clear.
    @MainActor
    static func resumePendingMoveIfNeeded(stack: CoreDataStack = .shared,
                                          journal: MigrationJournal = .shared) {
        guard let pending = journal.pendingMove else { return }
        let ctx = stack.viewContext
        guard let householdID = pending.householdID,
              let household = fetchByID(CDHousehold.self, entityName: "CDHousehold", id: householdID, in: ctx) else {
            journal.clearPendingMove()
            return
        }
        let objects = pending.ids.compactMap { fetchScopedObject(id: $0, in: ctx) }
        guard !objects.isEmpty else {
            journal.clearPendingMove()
            return
        }
        Log.info("Resuming interrupted owner migration (\(objects.count) record(s))", category: .cloud)
        reparent(objects, to: household)
        try? ctx.save()
        Task { @MainActor in
            try? await rehomeIntoShareZoneIfShared(objects, household: household, stack: stack)
            journal.clearPendingMove()
        }
    }

    // MARK: - Participant-side contribution (copy-and-retain)

    /// Copies each not-yet-contributed root (with fresh UUIDs) into the
    /// household, records provenance, and saves the whole closure atomically.
    /// Originals are retained. Returns how many roots were actually copied.
    ///
    /// Provenance is written before the save: if the process dies in between,
    /// the entry points at a copy that never materialized, which the next run
    /// detects (`isContributed` checks the copy exists) and heals by clearing
    /// the stale entry — so an interrupted contribution converges to exactly
    /// one copy, never zero-and-locked and never two.
    @MainActor
    static func contribute(_ selection: Selection,
                           into household: CDHousehold,
                           store: NSPersistentStore?,
                           context ctx: NSManagedObjectContext,
                           journal: MigrationJournal = .shared) throws -> Int {
        var copiedRoots = 0

        for area in selection.areas where !isContributed(area.id, in: ctx, journal: journal) {
            let areaCopy = CDArea.make(in: ctx, id: UUID(),
                                       name: area.name ?? "Room",
                                       detail: area.detail ?? "",
                                       household: household)
            assign(areaCopy, to: store, in: ctx)
            for chore in area.choresArray {
                copyChore(chore, area: areaCopy, into: household, store: store, ctx: ctx)
            }
            if let originalID = area.id, let copyID = areaCopy.id {
                journal.recordContribution(original: originalID, copy: copyID)
            }
            copiedRoots += 1
        }

        for chore in selection.chores where !isContributed(chore.id, in: ctx, journal: journal) {
            let choreCopy = copyChore(chore, area: nil, into: household, store: store, ctx: ctx)
            if let originalID = chore.id, let copyID = choreCopy.id {
                journal.recordContribution(original: originalID, copy: copyID)
            }
            copiedRoots += 1
        }

        guard copiedRoots > 0 else { return 0 }
        try ctx.save()
        Log.info("Participant migration: contributed \(copiedRoots) root(s) as copies; originals retained", category: .cloud)
        return copiedRoots
    }

    /// Whether this root already has a live Household twin. A provenance entry
    /// whose copy no longer exists (interrupted save, or the copy was deleted)
    /// is stale: it's cleared so the root becomes eligible again.
    @MainActor
    static func isContributed(_ originalID: UUID?,
                              in ctx: NSManagedObjectContext,
                              journal: MigrationJournal = .shared) -> Bool {
        guard let originalID, let copyID = journal.contributedCopyID(for: originalID) else { return false }
        if fetchScopedObject(id: copyID, in: ctx) != nil { return true }
        journal.clearContribution(for: originalID)
        return false
    }

    @discardableResult
    @MainActor
    private static func copyChore(_ chore: CDChore,
                                  area: CDArea?,
                                  into household: CDHousehold,
                                  store: NSPersistentStore?,
                                  ctx: NSManagedObjectContext) -> CDChore {
        let copy = CDChore.make(in: ctx, id: UUID(),
                                name: chore.name ?? "Chore",
                                isDaily: chore.isDaily,
                                frequency: chore.frequencyValue,
                                assignedDay: chore.assignedDayValue,
                                createdDate: chore.createdDate ?? Date(),
                                household: household)
        copy.area = area
        assign(copy, to: store, in: ctx)
        for completion in chore.completionsArray {
            let completionCopy = CDCompletion.make(in: ctx, id: UUID(),
                                                   date: completion.date ?? Date(),
                                                   notes: completion.notes,
                                                   completedBy: completion.completedBy,
                                                   chore: copy,
                                                   household: household)
            assign(completionCopy, to: store, in: ctx)
        }
        return copy
    }

    /// Pins an insert to the target persistent store — the reason a cross-store
    /// move can't be done in place. `nil` (tests / single-store stacks) leaves
    /// the default store assignment.
    private static func assign(_ object: NSManagedObject, to store: NSPersistentStore?, in ctx: NSManagedObjectContext) {
        if let store { ctx.assign(object, to: store) }
    }

    // MARK: - Closure collection

    /// The complete object graph a selection drags along: each room with all
    /// of its chores and their completions, plus each loose chore with its
    /// completions. Completeness is load-bearing — a partial closure leaves
    /// cross-zone relationships behind, which CloudKit silently drops.
    static func closure(for selection: Selection) -> [NSManagedObject] {
        var objects: [NSManagedObject] = []
        for area in selection.areas {
            objects.append(area)
            for chore in area.choresArray {
                objects.append(chore)
                objects.append(contentsOf: chore.completionsArray)
            }
        }
        for chore in selection.chores {
            objects.append(chore)
            objects.append(contentsOf: chore.completionsArray)
        }
        return objects
    }

    // MARK: - Lookup helpers

    private static func uuids(of objects: [NSManagedObject]) -> [UUID] {
        objects.compactMap { $0.value(forKey: "id") as? UUID }
    }

    /// Finds a migratable record by UUID across the scoped entity types.
    private static func fetchScopedObject(id: UUID, in ctx: NSManagedObjectContext) -> NSManagedObject? {
        for entityName in ["CDChore", "CDArea", "CDCompletion"] {
            if let found = fetchByID(NSManagedObject.self, entityName: entityName, id: id, in: ctx) {
                return found
            }
        }
        return nil
    }

    private static func fetchByID<T: NSManagedObject>(_ type: T.Type, entityName: String,
                                                      id: UUID, in ctx: NSManagedObjectContext) -> T? {
        let request = NSFetchRequest<T>(entityName: entityName)
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try? ctx.fetch(request).first
    }
}

// MARK: - Journal

/// Durable bookkeeping for migrations, in the App Group defaults.
///
/// Two independent records:
/// - **Pending owner move** — set before the re-parent save, cleared after the
///   zone re-home succeeds. Non-empty at launch ⇒ the move was interrupted and
///   is resumed. (The spike showed NSPCKC's export can transiently crash the
///   process mid-migration; journaled resumable writes are mandatory.)
/// - **Contributions** — original→copy UUID provenance for participant-side
///   copies: the idempotency key, and the seed for the future "migrated"
///   badge / bulk-cleanup of retained Personal originals.
struct MigrationJournal {
    static let shared = MigrationJournal(
        defaults: UserDefaults(suiteName: WidgetShared.appGroupIdentifier) ?? .standard
    )

    private let defaults: UserDefaults
    private let pendingIDsKey = "migration.pendingMove.ids"
    private let pendingHouseholdKey = "migration.pendingMove.household"
    private let contributionsKey = "migration.contributions"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: Pending owner move

    func beginPendingMove(ids: [UUID], householdID: UUID?) {
        defaults.set(ids.map(\.uuidString), forKey: pendingIDsKey)
        defaults.set(householdID?.uuidString, forKey: pendingHouseholdKey)
    }

    func clearPendingMove() {
        defaults.removeObject(forKey: pendingIDsKey)
        defaults.removeObject(forKey: pendingHouseholdKey)
    }

    var pendingMove: (ids: [UUID], householdID: UUID?)? {
        guard let raw = defaults.stringArray(forKey: pendingIDsKey), !raw.isEmpty else { return nil }
        return (ids: raw.compactMap(UUID.init(uuidString:)),
                householdID: defaults.string(forKey: pendingHouseholdKey).flatMap(UUID.init(uuidString:)))
    }

    // MARK: Contributions (participant provenance)

    func recordContribution(original: UUID, copy: UUID) {
        var map = contributionMap
        map[original.uuidString] = copy.uuidString
        defaults.set(map, forKey: contributionsKey)
    }

    func contributedCopyID(for original: UUID) -> UUID? {
        contributionMap[original.uuidString].flatMap(UUID.init(uuidString:))
    }

    func clearContribution(for original: UUID) {
        var map = contributionMap
        map.removeValue(forKey: original.uuidString)
        defaults.set(map, forKey: contributionsKey)
    }

    private var contributionMap: [String: String] {
        defaults.dictionary(forKey: contributionsKey) as? [String: String] ?? [:]
    }
}
