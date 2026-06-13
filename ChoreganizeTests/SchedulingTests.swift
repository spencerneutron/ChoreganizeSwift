//
//  SchedulingTests.swift
//  ChoreganizeTests
//
//  Coverage for the scheduling / overdue / day-lock core (CDChore+Scheduling).
//

import Testing
import CoreData
import Foundation
@testable import Choreganize

struct SchedulingTests {

    private let cal = Calendar.current

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    private func daysFromNow(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: Date())!
    }

    // MARK: - Completion state

    @Test func isCompletedMatchesByDay() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "C", isDaily: true)
            try ctx.save()
            #expect(chore.isCompleted(on: Date()) == false)
            chore.recordCompletion(on: Date(), in: ctx)
            #expect(chore.isCompleted(on: Date()) == true)
            #expect(chore.isCompleted(on: daysFromNow(-1)) == false)
        }
    }

    @Test func lastCompletionIsBoundedByToday() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "C", isDaily: true)
            chore.recordCompletion(on: daysFromNow(-1), in: ctx)  // yesterday
            chore.recordCompletion(on: daysFromNow(2), in: ctx)   // future (ignored)
            try ctx.save()
            let last = chore.lastCompletion?.date
            #expect(last != nil)
            #expect(cal.isDate(last!, inSameDayAs: daysFromNow(-1)))
        }
    }

    // MARK: - isOverdue

    @Test func dailyOverdueWhenNotCompletedToday() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "C", isDaily: true)
            try ctx.save()
            #expect(chore.isOverdue() == true)                       // never completed
            chore.recordCompletion(on: daysFromNow(-1), in: ctx)
            #expect(chore.isOverdue() == true)                       // completed yesterday
            chore.recordCompletion(on: Date(), in: ctx)
            #expect(chore.isOverdue() == false)                      // completed today
        }
    }

    @Test func weeklyOverdueAfterOneWeek() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let recent = CDChore.make(in: ctx, name: "recent", isDaily: false, frequency: .weekly, assignedDay: .monday)
            recent.recordCompletion(on: daysFromNow(-3), in: ctx)
            let stale = CDChore.make(in: ctx, name: "stale", isDaily: false, frequency: .weekly, assignedDay: .monday)
            stale.recordCompletion(on: daysFromNow(-10), in: ctx)
            try ctx.save()
            #expect(recent.isOverdue() == false)   // next due ~4 days out
            #expect(stale.isOverdue() == true)      // next due ~3 days ago
        }
    }

    @Test func monthlyOverdueAfterOneMonth() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let recent = CDChore.make(in: ctx, name: "r", isDaily: false, frequency: .monthly, assignedDay: .monday)
            recent.recordCompletion(on: daysFromNow(-10), in: ctx)
            let stale = CDChore.make(in: ctx, name: "s", isDaily: false, frequency: .monthly, assignedDay: .monday)
            stale.recordCompletion(on: daysFromNow(-40), in: ctx)
            try ctx.save()
            #expect(recent.isOverdue() == false)
            #expect(stale.isOverdue() == true)
        }
    }

    @Test func noFrequencyIsNeverOverdueOnceCompleted() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: nil, assignedDay: .monday)
            #expect(chore.isOverdue() == true)     // no completion -> true
            chore.recordCompletion(on: daysFromNow(-30), in: ctx)
            try ctx.save()
            #expect(chore.isOverdue() == false)    // nil frequency -> not overdue
        }
    }

    // MARK: - nextDueDate

    @Test func dailyNextDueIsTomorrow() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "c", isDaily: true)
            try ctx.save()
            let expected = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
            #expect(chore.nextDueDate() == expected)
        }
    }

    @Test func weeklyNextDueAdvancesOneWeekOnAssignedDay() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            // A fixed reference whose weekday we read back, so the assigned day
            // matches it and the result is exactly +1 week.
            let ref = cal.date(from: DateComponents(year: 2025, month: 6, day: 4))!
            let weekday = Weekday.standardCases[cal.component(.weekday, from: ref) - 1]
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly, assignedDay: weekday)
            try ctx.save()
            #expect(chore.nextDueDate(after: ref) == cal.date(byAdding: .weekOfYear, value: 1, to: ref))
        }
    }

    @Test func nilAssignedDayHasNoWeeklyDueDate() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly, assignedDay: nil)
            try ctx.save()
            #expect(chore.nextDueDate(after: Date()) == nil)
        }
    }

    // MARK: - needsAttention

    @Test func dailyNeedsAttentionDependsOnLastCompletion() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "c", isDaily: true)
            #expect(chore.needsAttention(on: Date()) == true)        // never completed
            chore.recordCompletion(on: Date(), in: ctx)
            try ctx.save()
            #expect(chore.needsAttention(on: Date()) == false)       // done today
            #expect(chore.needsAttention(on: daysFromNow(1)) == true) // due again tomorrow
        }
    }

    // MARK: - Scheduling.chores(for:)

    @Test func choresForDateIncludesDailyAndMatchingWeekday() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let monday = cal.nextDate(after: Date(), matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
            let tuesday = cal.date(byAdding: .day, value: 1, to: monday)!
            let daily = CDChore.make(in: ctx, name: "daily", isDaily: true)
            let mondayChore = CDChore.make(in: ctx, name: "mon", isDaily: false, frequency: .weekly, assignedDay: .monday)
            try ctx.save()
            let all = [daily, mondayChore]
            #expect(Scheduling.chores(all, for: monday).compactMap { $0.name }.sorted() == ["daily", "mon"])
            #expect(Scheduling.chores(all, for: tuesday).compactMap { $0.name }.sorted() == ["daily"])
        }
    }

    @Test func workViewIgnoresFrequency_currentBehavior() throws {
        // Documents a known inconsistency: Scheduling.chores(for:) ignores
        // frequency, so a *monthly* chore still appears on every matching weekday.
        // When #4 makes the Work view frequency-aware, update this expectation.
        let ctx = makeContext()
        try ctx.performAndWait {
            let monday = cal.nextDate(after: Date(), matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
            let nextMonday = cal.date(byAdding: .day, value: 7, to: monday)!
            let monthly = CDChore.make(in: ctx, name: "monthly", isDaily: false, frequency: .monthly, assignedDay: .monday)
            try ctx.save()
            #expect(Scheduling.chores([monthly], for: monday).count == 1)
            #expect(Scheduling.chores([monthly], for: nextMonday).count == 1)
        }
    }

    // MARK: - Scheduling.choresByDate(inMonth:)

    @Test func choresByDateDailyCoversEveryDay() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let monthStart = cal.date(from: DateComponents(year: 2025, month: 3, day: 1))!  // 31 days
            let chore = CDChore.make(in: ctx, name: "daily", isDaily: true, createdDate: monthStart)
            try ctx.save()
            let map = Scheduling.choresByDate(inMonth: monthStart, chores: [chore])
            #expect(map.count == 31)
            let mid = cal.date(byAdding: .day, value: 14, to: monthStart)!
            #expect(map[cal.startOfDay(for: mid)]?.count == 1)
        }
    }

    // MARK: - DayLock

    @Test func dayLockPastIsAlwaysLocked() throws {
        #expect(DayLock.isLocked(daysFromNow(-1), in: []) == true)
        #expect(DayLock.isLocked(daysFromNow(1), in: []) == false)
    }

    @Test func dayLockAndUnlock() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let tomorrow = daysFromNow(1)
            DayLock.lock(tomorrow, existing: [], household: nil, in: ctx)
            let locked = try ctx.fetch(NSFetchRequest<CDLockedDay>(entityName: "CDLockedDay"))
            #expect(DayLock.isLocked(tomorrow, in: locked) == true)
            DayLock.unlock(tomorrow, existing: locked, in: ctx)
            let after = try ctx.fetch(NSFetchRequest<CDLockedDay>(entityName: "CDLockedDay"))
            #expect(DayLock.isLocked(tomorrow, in: after) == false)
        }
    }

    @Test func dayLockIgnoresPastDates() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            DayLock.lock(daysFromNow(-1), existing: [], household: nil, in: ctx)
            let locked = try ctx.fetch(NSFetchRequest<CDLockedDay>(entityName: "CDLockedDay"))
            #expect(locked.isEmpty)
        }
    }

    // MARK: - Scope inheritance

    @Test func completionInheritsChoreHousehold() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let household = CDHousehold(context: ctx)
            household.id = UUID()
            household.name = "H"
            household.createdDate = Date()
            let chore = CDChore.make(in: ctx, name: "c", isDaily: true, household: household)
            try ctx.save()
            chore.recordCompletion(on: Date(), in: ctx)
            #expect(chore.completionsArray.first?.household == household)
        }
    }
}
