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
                return
            }

            guard let url = legacyURL,
                  let data = try? Data(contentsOf: url),
                  let state = try? JSONDecoder().decode(AppModel.SavedState.self, from: data) else {
                Log.info("JSONImporter: no legacy chore_data.json found to import.", category: .persistence)
                return
            }

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
                Log.info("JSONImporter: imported \(state.chores.count) chores, \(state.areas.count) areas, \(state.completions.count) completions, \(state.lockedDays.count) locked days.", category: .persistence)
            } catch {
                Log.error("JSONImporter: save failed: \(error.localizedDescription)", category: .persistence)
            }
        }
    }

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
