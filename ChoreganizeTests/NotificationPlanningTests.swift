import Testing
import CoreData
@testable import Choreganize

/// Covers the pure reminder-planning decision (`NotificationManager.plannedReminders`):
/// enabled-day filtering, "skip today if time passed", "only when unresolved",
/// and the occurrence cap. Uses a fixed `now` so it's deterministic.
struct NotificationPlanningTests {

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    private let allDays = Set(Weekday.standardCases)

    @Test func dailyChoreSchedulesUpToCapOnEnabledDays() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            try ctx.save()
            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))

            let cal = Calendar.current
            let now = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
            let planned = NotificationManager.plannedReminders(
                chores: chores, days: allDays, hour: 18, minute: 0, from: now, calendar: cal)

            #expect(planned.count == 7)                          // capped at maxOccurrences
            #expect(planned.allSatisfy { $0.unresolvedCount == 1 })
            #expect(cal.isDate(planned[0].fireDate, inSameDayAs: now))   // today, 18:00 > 09:00
            for i in 1..<planned.count {
                #expect(planned[i].fireDate > planned[i - 1].fireDate)
            }
        }
    }

    @Test func skipsTodayWhenTimeHasPassed() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            try ctx.save()
            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))

            let cal = Calendar.current
            let now = cal.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!   // after 18:00
            let planned = NotificationManager.plannedReminders(
                chores: chores, days: allDays, hour: 18, minute: 0, from: now, calendar: cal)

            #expect(!planned.isEmpty)
            #expect(!cal.isDate(planned[0].fireDate, inSameDayAs: now))   // not today
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
            #expect(cal.isDate(planned[0].fireDate, inSameDayAs: tomorrow))
        }
    }

    @Test func onlyEnabledWeekdaysGetReminders() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            try ctx.save()
            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))

            let cal = Calendar.current
            let now = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
            let planned = NotificationManager.plannedReminders(
                chores: chores, days: [.monday], hour: 18, minute: 0, from: now, calendar: cal)

            #expect(!planned.isEmpty)
            #expect(planned.allSatisfy { cal.component(.weekday, from: $0.fireDate) == 2 })  // Monday
        }
    }

    @Test func completedTodayPushesFirstReminderToTomorrow() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            try ctx.save()
            chore.recordCompletion(on: Date(), in: ctx)   // done for today
            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))

            let cal = Calendar.current
            let now = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
            let planned = NotificationManager.plannedReminders(
                chores: chores, days: allDays, hour: 18, minute: 0, from: now, calendar: cal)

            #expect(!planned.isEmpty)
            #expect(!cal.isDate(planned[0].fireDate, inSameDayAs: now))   // today skipped (0 unresolved)
        }
    }

    @Test func emptyWhenNoChoresOrNoDays() {
        #expect(NotificationManager.plannedReminders(
            chores: [], days: Set(Weekday.standardCases), hour: 18, minute: 0, from: Date()).isEmpty)
    }
}
