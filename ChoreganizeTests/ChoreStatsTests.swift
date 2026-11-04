import Testing
import CoreData
@testable import Choreganize

/// CG-28 / #129 — one chore's stats for its editor (`InsightsMath.choreStats`).
struct ChoreStatsTests {

    private let cal = Calendar.current
    /// A fixed "today" at noon, so the tests don't depend on the clock.
    private let today = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!

    private func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: today)!
    }

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    @Test func lastDoneAndTypicalGap() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Water plants", isDaily: true, createdDate: day(-40))
            for offset in [-12, -9, -6, -3] { chore.recordCompletion(on: day(offset), by: nil, in: ctx) }
            chore.recordCompletion(on: day(2), by: nil, in: ctx)   // ahead of today: ignored
            try ctx.save()

            let stats = InsightsMath.choreStats(for: chore, today: today)

            #expect(stats.lastDone == cal.startOfDay(for: day(-3)))
            #expect(stats.typicalGapDays == 3)
        }
    }

    @Test func typicalGapNeedsThreeCompletions() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Mop", isDaily: true, createdDate: day(-40))
            chore.recordCompletion(on: day(-5), by: nil, in: ctx)
            chore.recordCompletion(on: day(-2), by: nil, in: ctx)
            try ctx.save()

            let stats = InsightsMath.choreStats(for: chore, today: today)

            #expect(stats.lastDone == cal.startOfDay(for: day(-2)))
            #expect(stats.typicalGapDays == nil)
        }
    }

    @Test func onTimeCountsDueDaysAndSkipsAnOpenToday() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            // Created 9 days ago: due on 10 days including today, which isn't done yet.
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true, createdDate: day(-9))
            for offset in [-9, -7, -5, -3, -1] { chore.recordCompletion(on: day(offset), by: nil, in: ctx) }
            try ctx.save()

            let open = InsightsMath.choreStats(for: chore, today: today)
            #expect(open.onTime == InsightsMath.WindowStats(due: 9, completed: 5))
            #expect(open.onTimeWindowDays == 30)

            // Once today is done, it counts.
            chore.recordCompletion(on: today, by: nil, in: ctx)
            let done = InsightsMath.choreStats(for: chore, today: today)
            #expect(done.onTime == InsightsMath.WindowStats(due: 10, completed: 6))
        }
    }

    @Test func onTimeWindowFollowsTheChoresPace() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let daily = CDChore.make(in: ctx, name: "Daily", isDaily: true)
            let weekly = CDChore.make(in: ctx, name: "Weekly", frequency: .weekly, assignedDay: .monday)
            let monthly = CDChore.make(in: ctx, name: "Monthly", frequency: .monthly, assignedDay: .monday)
            let yearly = CDChore.make(in: ctx, name: "Yearly", frequency: .yearly, assignedDay: .monday)

            #expect(InsightsMath.onTimeWindowDays(for: daily) == 30)
            #expect(InsightsMath.onTimeWindowDays(for: weekly) == 30)
            #expect(InsightsMath.onTimeWindowDays(for: monthly) == 180)
            #expect(InsightsMath.onTimeWindowDays(for: yearly) == 730)
        }
    }

    @Test func topCompleterNeedsTwoAttributedAndBreaksTiesByRecency() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Trash", isDaily: true, createdDate: day(-120))
            // Outside the 90-day window: ignored.
            chore.recordCompletion(on: day(-100), by: "sam", in: ctx)
            chore.recordCompletion(on: day(-100), by: "sam", in: ctx)
            chore.recordCompletion(on: day(-30), by: "alex", in: ctx)
            chore.recordCompletion(on: day(-20), by: "sam", in: ctx)
            chore.recordCompletion(on: day(-10), by: nil, in: ctx)   // no attribution
            // Solo chores never stamp a completer, so set it directly.
            for completion in chore.completionsArray {
                guard let date = completion.date else { continue }
                if cal.isDate(date, inSameDayAs: day(-30)) { completion.completedBy = "alex" }
                if cal.isDate(date, inSameDayAs: day(-20)) || cal.isDate(date, inSameDayAs: day(-100)) {
                    completion.completedBy = "sam"
                }
            }
            try ctx.save()

            let tied = InsightsMath.choreStats(for: chore, today: today)
            // One each in the window: the more recent completer wins the tie.
            #expect(tied.topCompleter == .init(id: "sam", count: 1, attributed: 2))

            chore.recordCompletion(on: day(-5), by: nil, in: ctx)
            chore.completionsArray.first { cal.isDate($0.date ?? .distantPast, inSameDayAs: day(-5)) }?
                .completedBy = "alex"
            let alex = InsightsMath.choreStats(for: chore, today: today)
            #expect(alex.topCompleter == .init(id: "alex", count: 2, attributed: 3))
        }
    }

    @Test func aNewChoreHasNoStats() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "New", isDaily: true, createdDate: today)
            try ctx.save()

            let stats = InsightsMath.choreStats(for: chore, today: today)

            #expect(stats.lastDone == nil)
            #expect(stats.typicalGapDays == nil)
            #expect(stats.onTime == InsightsMath.WindowStats(due: 0, completed: 0))
            #expect(stats.topCompleter == nil)
        }
    }

    @Test func roomStatsCountsItsChoresAndFindsTheMostMissed() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            // Both due on 5 days including today (created 4 days ago).
            let dishes = CDChore.make(in: ctx, name: "Dishes", isDaily: true, createdDate: day(-4))
            let mop = CDChore.make(in: ctx, name: "Mop", isDaily: true, createdDate: day(-4))
            let bins = CDChore.make(in: ctx, name: "Bins", isDaily: true, createdDate: day(-4))
            for offset in [-4, -3, -2, -1, 0] { dishes.recordCompletion(on: day(offset), by: nil, in: ctx) }
            mop.recordCompletion(on: day(-4), by: nil, in: ctx)
            bins.recordCompletion(on: day(-4), by: nil, in: ctx)
            try ctx.save()

            let stats = InsightsMath.roomStats(chores: [dishes, mop, bins], today: today)

            // Dishes 5 of 5 (today done); Mop and Bins 1 of 4 each (today still open).
            #expect(stats.onTime == InsightsMath.WindowStats(due: 13, completed: 7))
            // Mop and Bins tie on 3 missed: the first by name wins.
            #expect(stats.mostMissed == .init(name: "Bins", missed: 3, due: 4))
        }
    }

    @Test func aRoomWithNothingMissedHasNoMostMissed() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let dishes = CDChore.make(in: ctx, name: "Dishes", isDaily: true, createdDate: day(-2))
            for offset in [-2, -1] { dishes.recordCompletion(on: day(offset), by: nil, in: ctx) }
            try ctx.save()

            let stats = InsightsMath.roomStats(chores: [dishes], today: today)

            #expect(stats.onTime == InsightsMath.WindowStats(due: 2, completed: 2))
            #expect(stats.mostMissed == nil)
        }
    }
}
