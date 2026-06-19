import CoreData
import Foundation

/// Export/restore the user's **Personal** chores, areas, completions, and locked days
/// as a JSON backup (#63). Reuses the app's `AppModel.SavedState` Codable shape, so a backup is a
/// self-describing snapshot.
///
/// v1 is **Personal-scope only** (`household == nil`): it never reads from or writes into a
/// shared CloudKit household zone — that keeps backup/restore decoupled from the in-flight
/// sharing re-platform and avoids propagating duplicates to household peers.
///
/// Restore is a **UUID upsert (merge)**: items with a matching `id` are updated in place and
/// new ones inserted — nothing is deleted. Re-importing the same file is therefore idempotent,
/// and restoring into an empty store is a full restore.
enum BackupCodec {

    // MARK: Coders — ISO-8601 dates keep the file human-readable and round-trip cleanly.

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Export

    /// Snapshot the Personal-scope store into a `AppModel.SavedState`.
    static func snapshot(in ctx: NSManagedObjectContext) -> AppModel.SavedState {
        let areas = personal(CDArea.self, "CDArea", in: ctx).map {
            Area(id: $0.id ?? UUID(), name: $0.name ?? "", description: $0.detail ?? "")
        }
        let chores = personal(CDChore.self, "CDChore", in: ctx).map {
            Chore(id: $0.id ?? UUID(), name: $0.name ?? "", isDaily: $0.isDaily,
                  frequency: $0.frequencyValue, assignedDay: $0.assignedDayValue,
                  areaId: $0.area?.id, createdDate: $0.createdDate ?? Date())
        }
        let completions = personal(CDCompletion.self, "CDCompletion", in: ctx).compactMap { c -> Completion? in
            guard let choreId = c.chore?.id else { return nil }   // orphan completion — nothing to restore against
            return Completion(id: c.id ?? UUID(), choreId: choreId, date: c.date ?? Date(), notes: c.notes)
        }
        let locked = Set(personal(CDLockedDay.self, "CDLockedDay", in: ctx).compactMap { $0.date })
        return AppModel.SavedState(chores: chores, areas: areas, completions: completions, lockedDays: locked)
    }

    /// Encoded JSON for the current Personal-scope store.
    static func exportData(in ctx: NSManagedObjectContext) throws -> Data {
        try encoder.encode(snapshot(in: ctx))
    }

    // MARK: - Restore (UUID upsert, Personal scope)

    struct Summary: Equatable {
        var areas = 0
        var chores = 0
        var completions = 0
        var lockedDays = 0
    }

    /// Decode and merge a backup into the Personal-scope store.
    @discardableResult
    static func restore(_ data: Data, into ctx: NSManagedObjectContext) throws -> Summary {
        try apply(decoder.decode(AppModel.SavedState.self, from: data), into: ctx)
    }

    /// Upsert a decoded `AppModel.SavedState` into the Personal scope and save. Shared by `restore`
    /// and tests. UUID-keyed: existing rows are updated, missing ones inserted.
    @discardableResult
    static func apply(_ state: AppModel.SavedState, into ctx: NSManagedObjectContext) throws -> Summary {
        var summary = Summary()

        // Areas first — chores reference them.
        var areasByID: [UUID: CDArea] = [:]
        for area in state.areas {
            let cd = existing(CDArea.self, "CDArea", id: area.id, in: ctx)
                ?? CDArea.make(in: ctx, id: area.id, name: area.name, detail: area.description, household: nil)
            cd.name = area.name
            cd.detail = area.description
            areasByID[area.id] = cd
            summary.areas += 1
        }

        // Chores, linked to their area.
        var choresByID: [UUID: CDChore] = [:]
        for chore in state.chores {
            let cd = existing(CDChore.self, "CDChore", id: chore.id, in: ctx)
                ?? CDChore.make(in: ctx, id: chore.id, name: chore.name, household: nil)
            cd.name = chore.name
            cd.isDaily = chore.isDaily
            cd.frequencyValue = chore.frequency
            cd.assignedDayValue = chore.assignedDay
            cd.createdDate = chore.createdDate
            if let areaId = chore.areaId {
                cd.area = areasByID[areaId] ?? existing(CDArea.self, "CDArea", id: areaId, in: ctx)
            } else {
                cd.area = nil
            }
            choresByID[chore.id] = cd
            summary.chores += 1
        }

        // Completions, linked to their chore. Orphans (chore not in the backup or store) are skipped.
        for completion in state.completions {
            guard let chore = choresByID[completion.choreId]
                    ?? existing(CDChore.self, "CDChore", id: completion.choreId, in: ctx) else { continue }
            let cd = existing(CDCompletion.self, "CDCompletion", id: completion.id, in: ctx)
                ?? CDCompletion.make(in: ctx, id: completion.id, date: completion.date,
                                     notes: completion.notes, chore: chore, household: nil)
            cd.date = completion.date
            cd.notes = completion.notes
            cd.chore = chore
            summary.completions += 1
        }

        // Locked days — dedup by calendar day (the legacy shape stores dates, not ids).
        let cal = Calendar.current
        let existingLocks = personal(CDLockedDay.self, "CDLockedDay", in: ctx).compactMap { $0.date }
        for day in state.lockedDays where !existingLocks.contains(where: { cal.isDate($0, inSameDayAs: day) }) {
            CDLockedDay.make(in: ctx, date: day, household: nil)
            summary.lockedDays += 1
        }

        if ctx.hasChanges { try ctx.save() }
        return summary
    }

    // MARK: - Fetch helpers (Personal scope)

    private static func personal<T: NSManagedObject>(_ type: T.Type, _ entity: String,
                                                      in ctx: NSManagedObjectContext) -> [T] {
        let req = NSFetchRequest<T>(entityName: entity)
        req.predicate = NSPredicate(format: "household == nil")
        return (try? ctx.fetch(req)) ?? []
    }

    private static func existing<T: NSManagedObject>(_ type: T.Type, _ entity: String, id: UUID,
                                                     in ctx: NSManagedObjectContext) -> T? {
        let req = NSFetchRequest<T>(entityName: entity)
        req.predicate = NSPredicate(format: "id == %@ AND household == nil", argumentArray: [id])
        req.fetchLimit = 1
        return (try? ctx.fetch(req))?.first
    }
}
