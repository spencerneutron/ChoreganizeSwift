import Testing
import CoreData
@testable import Choreganize

/// Coverage for JSON backup/restore (#63): a full round-trip preserves Personal data and
/// relationships, restore is an idempotent UUID upsert (re-import doesn't duplicate), and
/// export is scoped to Personal (household records are excluded).
struct BackupTests {

    private func freshContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    private func count(_ entity: String, in ctx: NSManagedObjectContext) -> Int {
        (try? ctx.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))) ?? -1
    }

    @Test func roundTripPreservesPersonalDataAndRelationships() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let areaID = UUID(), choreID = UUID()

        // Export from store A.
        var data = Data()
        let ctxA = freshContext()
        try ctxA.performAndWait {
            let kitchen = CDArea.make(in: ctxA, id: areaID, name: "Kitchen", detail: "Counters")
            let dishes = CDChore.make(in: ctxA, id: choreID, name: "Dishes", isDaily: true)
            dishes.area = kitchen
            _ = CDChore.make(in: ctxA, name: "Vacuum", isDaily: false, frequency: .weekly, assignedDay: .monday)
            CDCompletion.make(in: ctxA, date: day, notes: "done", chore: dishes)
            CDLockedDay.make(in: ctxA, date: day)
            try ctxA.save()
            data = try BackupCodec.exportData(in: ctxA)
        }

        // Restore into a fresh store B.
        let ctxB = freshContext()
        try ctxB.performAndWait {
            let summary = try BackupCodec.restore(data, into: ctxB)
            #expect(summary == BackupCodec.Summary(areas: 1, chores: 2, completions: 1, lockedDays: 1))
            #expect(count("CDChore", in: ctxB) == 2)
            #expect(count("CDArea", in: ctxB) == 1)
            #expect(count("CDCompletion", in: ctxB) == 1)
            #expect(count("CDLockedDay", in: ctxB) == 1)

            let req = NSFetchRequest<CDChore>(entityName: "CDChore")
            req.predicate = NSPredicate(format: "id == %@", argumentArray: [choreID])
            let restored = try ctxB.fetch(req).first
            #expect(restored?.name == "Dishes")
            #expect(restored?.isDaily == true)
            #expect(restored?.area?.name == "Kitchen")   // relationship survived the round-trip
        }
    }

    @Test func restoreIsIdempotent() throws {
        let ctx = freshContext()
        let areaID = UUID(), choreID = UUID()
        let state = AppModel.SavedState(
            chores: [Chore(id: choreID, name: "Dishes", isDaily: true,
                           frequency: nil, assignedDay: nil, areaId: areaID)],
            areas: [Area(id: areaID, name: "Kitchen", description: "")],
            completions: [Completion(id: UUID(), choreId: choreID, date: Date(), notes: nil)],
            lockedDays: [Calendar.current.startOfDay(for: Date())]
        )
        try ctx.performAndWait {
            try BackupCodec.apply(state, into: ctx)
            try BackupCodec.apply(state, into: ctx)   // re-importing the same backup must not duplicate
            #expect(count("CDChore", in: ctx) == 1)
            #expect(count("CDArea", in: ctx) == 1)
            #expect(count("CDCompletion", in: ctx) == 1)
            #expect(count("CDLockedDay", in: ctx) == 1)
        }
    }

    @Test func exportExcludesHouseholdRecords() throws {
        let ctx = freshContext()
        ctx.performAndWait {
            _ = CDChore.make(in: ctx, name: "Personal dish", isDaily: true)            // household == nil
            let household = CDHousehold(context: ctx)
            _ = CDChore.make(in: ctx, name: "Shared dish", isDaily: true, household: household)

            let state = BackupCodec.snapshot(in: ctx)
            #expect(state.chores.count == 1)
            #expect(state.chores.first?.name == "Personal dish")
        }
    }
}
