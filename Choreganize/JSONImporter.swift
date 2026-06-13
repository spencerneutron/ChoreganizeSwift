import CoreData
import Foundation

/// One-time importer that moves the legacy `chore_data.json` state into Core
/// Data. Idempotent (skips if the store is already populated) and UUID-preserving
/// so a re-run can never duplicate records.
///
/// Phase 1 / Checkpoint 1: this runs at launch but does NOT retire the JSON file,
/// because the live UI still reads it. The cutover (`retireLegacyFile`) happens
/// in Checkpoint 2 once the views read from Core Data.
enum JSONImporter {

    static var legacyURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("chore_data.json")
    }

    static func runIfNeeded(stack: CoreDataStack = .shared) {
        let ctx = stack.newBackgroundContext()
        ctx.perform {
            let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "CDChore")
            let existing = (try? ctx.count(for: countRequest)) ?? 0
            guard existing == 0 else {
                Log.debug("JSONImporter: store already has \(existing) chores; skipping import.", category: .persistence)
                retireLegacyFile()
                return
            }

            guard let url = legacyURL,
                  let data = try? Data(contentsOf: url),
                  let state = try? JSONDecoder().decode(AppModel.SavedState.self, from: data) else {
                Log.info("JSONImporter: no legacy chore_data.json found to import.", category: .persistence)
                return
            }

            if importState(state, into: ctx) {
                Log.info("JSONImporter: imported \(state.chores.count) chores, \(state.areas.count) areas, \(state.completions.count) completions, \(state.lockedDays.count) locked days.", category: .persistence)
                retireLegacyFile()
            }
        }
    }

    /// Inserts a decoded `SavedState` into the context and saves. Shared by the
    /// legacy import and the debug seed. Returns whether the save succeeded.
    @discardableResult
    private static func importState(_ state: AppModel.SavedState, into ctx: NSManagedObjectContext) -> Bool {
        // Areas first — chores reference them.
        var areasByID: [UUID: CDArea] = [:]
        for area in state.areas {
            areasByID[area.id] = CDArea.make(in: ctx, id: area.id, name: area.name, detail: area.description)
        }

        // Chores, linked to their area.
        var choresByID: [UUID: CDChore] = [:]
        for chore in state.chores {
            let cd = CDChore.make(
                in: ctx,
                id: chore.id,
                name: chore.name,
                isDaily: chore.isDaily,
                frequency: chore.frequency,
                assignedDay: chore.assignedDay,
                createdDate: chore.createdDate
            )
            if let areaID = chore.areaId { cd.area = areasByID[areaID] }
            choresByID[chore.id] = cd
        }

        // Completions, linked to their chore.
        for completion in state.completions {
            CDCompletion.make(
                in: ctx,
                id: completion.id,
                date: completion.date,
                notes: completion.notes,
                chore: choresByID[completion.choreId]
            )
        }

        // Locked days (solo scope — no household yet).
        for day in state.lockedDays {
            CDLockedDay.make(in: ctx, date: day)
        }

        do {
            try ctx.save()
            return true
        } catch {
            Log.error("JSONImporter: save failed: \(error.localizedDescription)", category: .persistence)
            return false
        }
    }

#if DEBUG
    /// Debug/screenshot seed. When `CHOREGANIZE_SEED_JSON` points to a
    /// `SavedState` JSON file, import it into an **empty** store so a simulator
    /// launches with a demonstrative dataset. Never compiled into release builds;
    /// intended to pair with `CHOREGANIZE_LOCAL_ONLY=1`. Used by the `deploy` skill
    /// (`SIMCTL_CHILD_CHOREGANIZE_SEED_JSON=…`). Note: `SavedState` decodes dates
    /// with a bare `JSONDecoder` (Apple reference-date seconds).
    static func seedFromEnvironmentIfNeeded(stack: CoreDataStack = .shared) {
        guard let path = ProcessInfo.processInfo.environment["CHOREGANIZE_SEED_JSON"],
              !path.isEmpty else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let state = try? JSONDecoder().decode(AppModel.SavedState.self, from: data) else {
            Log.error("JSONImporter seed: could not read/decode \(path)", category: .persistence)
            return
        }
        let ctx = stack.newBackgroundContext()
        ctx.perform {
            let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "CDChore")
            let existing = (try? ctx.count(for: countRequest)) ?? 0
            guard existing == 0 else {
                Log.debug("JSONImporter seed: store already populated (\(existing)); skipping.", category: .persistence)
                return
            }
            if importState(state, into: ctx) {
                Log.info("JSONImporter seed: loaded \(state.chores.count) chores / \(state.areas.count) areas from \(URL(fileURLWithPath: path).lastPathComponent)", category: .persistence)
            }
        }
    }
#endif

    /// Checkpoint 2 cutover: rename the legacy JSON so it stops being a live data
    /// source but remains on disk as a backup. Safe to call repeatedly.
    static func retireLegacyFile() {
        guard let url = legacyURL, FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent("chore_data.migrated.json")
        try? FileManager.default.removeItem(at: backup)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            Log.info("JSONImporter: retired legacy chore_data.json → chore_data.migrated.json", category: .persistence)
        } catch {
            Log.warning("JSONImporter: could not retire legacy file: \(error.localizedDescription)", category: .persistence)
        }
    }
}
