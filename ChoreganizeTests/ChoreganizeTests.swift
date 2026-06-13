//
//  ChoreganizeTests.swift
//  ChoreganizeTests
//

import Testing
import CoreData
@testable import Choreganize

struct ChoreganizeTests {

    /// Fresh in-memory Core Data context (no CloudKit) for each test.
    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    @Test func editChore() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Test", isDaily: true, frequency: nil, assignedDay: .all)
            try ctx.save()

            chore.name = "Updated"
            chore.isDaily = false
            chore.frequencyValue = .weekly
            chore.assignedDayValue = .tuesday
            try ctx.save()

            let all = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            #expect(all.count == 1)
            #expect(all.first?.name == "Updated")
            #expect(all.first?.assignedDayValue == .tuesday)
            #expect(all.first?.isDaily == false)
        }
    }

    @Test func completionToggling() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            try ctx.save()

            let today = Date()
            #expect(chore.isCompleted(on: today) == false)
            chore.recordCompletion(on: today, in: ctx)
            #expect(chore.isCompleted(on: today) == true)
            // Recording again on the same day is a no-op.
            chore.recordCompletion(on: today, in: ctx)
            #expect(chore.completionsArray.count == 1)
            chore.removeCompletion(on: today, in: ctx)
            #expect(chore.isCompleted(on: today) == false)
        }
    }

    @Test func weekDatesHelper() throws {
        let today = Calendar.current.startOfDay(for: Date())
        let dates = Scheduling.weekDates(startingFrom: today, includePast: 3, includeFuture: 10)
        #expect(dates.first == Calendar.current.date(byAdding: .day, value: -3, to: today))
        let maxFuture = Calendar.current.date(byAdding: .day, value: 6, to: today)!
        #expect(dates.last! <= maxFuture)
    }

    @Test func areaRelationship() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let area = CDArea.make(in: ctx, name: "Kitchen", detail: "Cooking")
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            chore.area = area
            try ctx.save()

            #expect(chore.area?.name == "Kitchen")
            #expect(area.choresArray.count == 1)
        }
    }
}
