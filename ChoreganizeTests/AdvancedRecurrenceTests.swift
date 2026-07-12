//
//  AdvancedRecurrenceTests.swift
//  ChoreganizeTests
//
//  CG-18 / #100 — advanced recurrence: multi-day weekly chores (assignedDays
//  supersedes the single assignedDay) and every-Nth-period intervals anchored
//  on createdDate. Legacy chores (no multi-day set, interval <= 1) must keep
//  the exact pre-#100 behavior covered by SchedulingTests.
//

import Testing
import CoreData
import Foundation
@testable import Choreganize

struct AdvancedRecurrenceTests {

    private let cal = Calendar.current

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    private func daysFromNow(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: Date())!
    }

    /// The first day matching `weekday` on/after `weeksBack` weeks ago — always
    /// safely in the past (lastCompletion is bounded by today) with room for
    /// +2 weeks of assertions to stay past too.
    private func pastDate(weekday: Int, weeksBack: Int = 5) -> Date {
        var d = cal.date(byAdding: .day, value: -7 * weeksBack, to: cal.startOfDay(for: Date()))!
        while cal.component(.weekday, from: d) != weekday { d = cal.date(byAdding: .day, value: 1, to: d)! }
        return d
    }

    // MARK: - assignedDays bridge

    @Test func assignedDaysValueRoundTrip() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly)
            try ctx.save()
            #expect(chore.assignedDaysValue.isEmpty)          // nil attribute -> empty set

            chore.assignedDaysValue = [.saturday, .tuesday]
            #expect(chore.assignedDays == "tuesday,saturday") // deterministic week order
            #expect(chore.assignedDaysValue == [.tuesday, .saturday])

            chore.assignedDaysValue = []
            #expect(chore.assignedDays == nil)                // empty set -> nil attribute

            chore.assignedDays = "tuesday,bogus"              // unknown tokens are dropped
            #expect(chore.assignedDaysValue == [.tuesday])
        }
    }

    // MARK: - recurrenceInterval bridge

    @Test func intervalZeroAndBelowReadsAsOne() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly, assignedDay: .monday)
            chore.recurrenceInterval = 0                      // synced-in legacy record
            #expect(chore.recurrenceIntervalValue == 1)
            chore.recurrenceIntervalValue = 0
            #expect(chore.recurrenceInterval == 1)            // setter clamps too

            // Interval 0 schedules exactly like the legacy weekly chore.
            let ref = cal.date(from: DateComponents(year: 2025, month: 6, day: 4))!
            let weekday = Weekday.standardCases[cal.component(.weekday, from: ref) - 1]
            chore.assignedDayValue = weekday
            chore.recurrenceInterval = 0
            #expect(chore.nextDueDate(after: ref) == cal.date(byAdding: .weekOfYear, value: 1, to: ref))
        }
    }

    // MARK: - Multi-day

    @Test func multiDayDueOnEachListedDayAndNotOthers() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            // Legacy single day deliberately conflicts with the set: the set wins.
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly, assignedDay: .monday)
            chore.assignedDaysValue = [.tuesday, .friday]
            try ctx.save()

            let tuesday = pastDate(weekday: 3)
            let friday = pastDate(weekday: 6)
            let monday = pastDate(weekday: 2)
            let wednesday = pastDate(weekday: 4)
            #expect(Scheduling.chores([chore], for: tuesday).count == 1)
            #expect(Scheduling.chores([chore], for: friday).count == 1)
            #expect(Scheduling.chores([chore], for: monday).isEmpty)     // superseded
            #expect(Scheduling.chores([chore], for: wednesday).isEmpty)
        }
    }

    @Test func multiDayNextDueIsNextListedDayNotNextPeriod() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly)
            chore.assignedDaysValue = [.monday, .thursday]
            try ctx.save()

            // Completed Monday -> due again Thursday of the SAME week.
            let monday = pastDate(weekday: 2)
            #expect(chore.nextDueDate(after: monday) == cal.date(byAdding: .day, value: 3, to: monday))
            // Completed Thursday -> due again next Monday.
            let thursday = cal.date(byAdding: .day, value: 3, to: monday)!
            #expect(chore.nextDueDate(after: thursday) == cal.date(byAdding: .day, value: 4, to: thursday))
        }
    }

    @Test func multiDayOverdueAtNextListedDay() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly)
            let today = Weekday.today
            let yesterday = Weekday.standardCases[(cal.component(.weekday, from: daysFromNow(-1)) - 1)]
            chore.assignedDaysValue = [yesterday, today]
            chore.recordCompletion(on: daysFromNow(-1), in: ctx)
            try ctx.save()
            // Done yesterday (a listed day); today is listed again -> overdue now.
            #expect(chore.isOverdue() == true)
            chore.recordCompletion(on: Date(), in: ctx)
            #expect(chore.isOverdue() == false)
        }
    }

    @Test func multiDayCalendarMarksEachListedDay() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            // March 2025: Saturdays 1/8/15/22/29, Sundays 2/9/16/23/30.
            let monthStart = cal.date(from: DateComponents(year: 2025, month: 3, day: 1))!
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly, createdDate: monthStart)
            chore.assignedDaysValue = [.saturday, .sunday]
            try ctx.save()

            let map = Scheduling.choresByDate(inMonth: monthStart, chores: [chore])
            #expect(map.count == 10)
            let sunday9 = cal.date(from: DateComponents(year: 2025, month: 3, day: 9))!
            let monday3 = cal.date(from: DateComponents(year: 2025, month: 3, day: 3))!
            #expect(map[cal.startOfDay(for: sunday9)]?.count == 1)
            #expect(map[cal.startOfDay(for: monday3)] == nil)
        }
    }

    // MARK: - Interval (biweekly = weekly + interval 2)

    @Test func biweeklyDueOnAlternateWeeksAnchoredOnCreatedDate() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let createdMonday = pastDate(weekday: 2)
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly,
                                     assignedDay: .monday, createdDate: createdMonday)
            chore.recurrenceIntervalValue = 2
            try ctx.save()

            let offMonday = cal.date(byAdding: .day, value: 7, to: createdMonday)!
            let onMonday = cal.date(byAdding: .day, value: 14, to: createdMonday)!
            #expect(Scheduling.chores([chore], for: createdMonday).count == 1)  // week 0: on
            #expect(Scheduling.chores([chore], for: offMonday).isEmpty)          // week 1: off
            #expect(Scheduling.chores([chore], for: onMonday).count == 1)        // week 2: on

            // Still gated by the anchor after a completion.
            chore.recordCompletion(on: createdMonday, in: ctx)
            #expect(Scheduling.chores([chore], for: offMonday).isEmpty)
            #expect(Scheduling.chores([chore], for: onMonday).count == 1)
        }
    }

    @Test func biweeklyNextDueAdvancesTwoWeeks() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let ref = cal.date(from: DateComponents(year: 2025, month: 6, day: 4))!
            let weekday = Weekday.standardCases[cal.component(.weekday, from: ref) - 1]
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly, assignedDay: weekday)
            chore.recurrenceIntervalValue = 2
            try ctx.save()
            #expect(chore.nextDueDate(after: ref) == cal.date(byAdding: .weekOfYear, value: 2, to: ref))
        }
    }

    @Test func biweeklyOverdueWindowIsTwoWeeks() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let recent = CDChore.make(in: ctx, name: "r", isDaily: false, frequency: .weekly, assignedDay: .monday)
            recent.recurrenceIntervalValue = 2
            recent.recordCompletion(on: daysFromNow(-8), in: ctx)
            let stale = CDChore.make(in: ctx, name: "s", isDaily: false, frequency: .weekly, assignedDay: .monday)
            stale.recurrenceIntervalValue = 2
            stale.recordCompletion(on: daysFromNow(-16), in: ctx)
            try ctx.save()
            #expect(recent.isOverdue() == false)   // next due ~6 days out
            #expect(stale.isOverdue() == true)      // next due ~2 days ago
        }
    }

    @Test func biweeklyCalendarMarksAlternateWeeks() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            // Mondays of March 2025: 3, 10, 17, 24, 31. Biweekly from the 3rd
            // marks 3/17/31 only.
            let monthStart = cal.date(from: DateComponents(year: 2025, month: 3, day: 1))!
            let created = cal.date(from: DateComponents(year: 2025, month: 3, day: 3))!
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly,
                                     assignedDay: .monday, createdDate: created)
            chore.recurrenceIntervalValue = 2
            try ctx.save()

            let map = Scheduling.choresByDate(inMonth: monthStart, chores: [chore])
            let marked = [3, 17, 31].map { cal.startOfDay(for: cal.date(from: DateComponents(year: 2025, month: 3, day: $0))!) }
            let skipped = [10, 24].map { cal.startOfDay(for: cal.date(from: DateComponents(year: 2025, month: 3, day: $0))!) }
            for d in marked { #expect(map[d]?.count == 1) }
            for d in skipped { #expect(map[d] == nil) }
            #expect(map.count == 3)
        }
    }

    // MARK: - Legacy chores unchanged

    @Test func legacySingleDayChoreSchedulesExactlyAsBefore() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "c", isDaily: false, frequency: .weekly, assignedDay: .monday)
            try ctx.save()
            #expect(chore.assignedDaysValue.isEmpty)
            #expect(chore.recurrenceIntervalValue == 1)
            #expect(chore.isInActivePeriod(on: daysFromNow(-9)))   // interval 1: always on

            // Due every Monday while uncompleted (mirrors SchedulingTests).
            let monday = pastDate(weekday: 2)
            let nextMonday = cal.date(byAdding: .day, value: 7, to: monday)!
            #expect(Scheduling.chores([chore], for: monday).count == 1)
            #expect(Scheduling.chores([chore], for: nextMonday).count == 1)

            // nextDueDate is one week after a same-weekday reference.
            let ref = cal.date(from: DateComponents(year: 2025, month: 6, day: 4))!
            let weekday = Weekday.standardCases[cal.component(.weekday, from: ref) - 1]
            chore.assignedDayValue = weekday
            #expect(chore.nextDueDate(after: ref) == cal.date(byAdding: .weekOfYear, value: 1, to: ref))
        }
    }
}
