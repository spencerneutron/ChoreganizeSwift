import Testing
import CoreData
@testable import Choreganize

/// Covers bulk multi-select operations (`BulkChoreOps`): move-to-area for the
/// selection only, move-to-nil, and delete (with completion cascade).
struct BulkChoreTests {

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    @Test func moveReassignsOnlySelectedChores() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let kitchen = CDArea.make(in: ctx, name: "Kitchen")
            let a = CDChore.make(in: ctx, name: "A", isDaily: true)
            let b = CDChore.make(in: ctx, name: "B", isDaily: true)
            let c = CDChore.make(in: ctx, name: "C", isDaily: true)
            try ctx.save()   // permanent object IDs

            BulkChoreOps.move([a.objectID, b.objectID], to: kitchen, in: ctx)

            #expect(a.area == kitchen)
            #expect(b.area == kitchen)
            #expect(c.area == nil)
        }
    }

    @Test func moveToNilClearsArea() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let kitchen = CDArea.make(in: ctx, name: "Kitchen")
            let a = CDChore.make(in: ctx, name: "A", isDaily: true)
            a.area = kitchen
            try ctx.save()

            BulkChoreOps.move([a.objectID], to: nil, in: ctx)
            #expect(a.area == nil)
        }
    }

    @Test func deleteRemovesSelectedAndCascadesCompletions() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let a = CDChore.make(in: ctx, name: "A", isDaily: true)
            CDChore.make(in: ctx, name: "B", isDaily: true)
            try ctx.save()
            a.recordCompletion(on: Date(), in: ctx)   // A has a completion

            BulkChoreOps.delete([a.objectID], in: ctx)

            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            #expect(chores.map { $0.name } == ["B"])
            let completions = try ctx.fetch(NSFetchRequest<CDCompletion>(entityName: "CDCompletion"))
            #expect(completions.isEmpty)   // cascaded with the deleted chore
        }
    }

    @Test func changeFrequencyAppliesToSelectionAndNormalizesDaily() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let a = CDChore.make(in: ctx, name: "A", isDaily: true)                                  // was daily
            let b = CDChore.make(in: ctx, name: "B", isDaily: false, frequency: .weekly, assignedDay: .monday)
            let c = CDChore.make(in: ctx, name: "C", isDaily: true)                                  // not selected
            try ctx.save()

            BulkChoreOps.change([a.objectID, b.objectID], .frequency(.monthly), in: ctx)

            #expect(a.isDaily == false)
            #expect(a.frequencyValue == .monthly)
            #expect(a.assignedDayValue == nil)        // .all dropped when leaving daily
            #expect(b.frequencyValue == .monthly)
            #expect(b.assignedDayValue == .monday)    // existing day preserved
            #expect(c.isDaily == true)                // untouched
        }
    }

    @Test func makeDailyClearsScheduleFields() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let a = CDChore.make(in: ctx, name: "A", isDaily: false, frequency: .weekly, assignedDay: .friday)
            try ctx.save()
            BulkChoreOps.change([a.objectID], .makeDaily, in: ctx)
            #expect(a.isDaily == true)
            #expect(a.frequencyValue == nil)
            #expect(a.assignedDayValue == .all)
        }
    }

    @Test func changeDaySetsWeekdayAndEnsuresFrequency() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let daily  = CDChore.make(in: ctx, name: "Daily", isDaily: true)   // no frequency
            let yearly = CDChore.make(in: ctx, name: "Yearly", isDaily: false, frequency: .yearly, assignedDay: .monday)
            try ctx.save()

            BulkChoreOps.change([daily.objectID, yearly.objectID], .day(.thursday), in: ctx)

            #expect(daily.isDaily == false)
            #expect(daily.assignedDayValue == .thursday)
            #expect(daily.frequencyValue == .weekly)   // defaulted (was daily ⇒ nil freq)
            #expect(yearly.assignedDayValue == .thursday)
            #expect(yearly.frequencyValue == .yearly)  // existing rhythm preserved
        }
    }

    @Test func changeDayToUnassignedClearsDay() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let a = CDChore.make(in: ctx, name: "A", isDaily: false, frequency: .weekly, assignedDay: .monday)
            try ctx.save()
            BulkChoreOps.change([a.objectID], .day(nil), in: ctx)
            #expect(a.assignedDayValue == nil)
            #expect(a.frequencyValue == .weekly)
            #expect(a.isDaily == false)
        }
    }
}
