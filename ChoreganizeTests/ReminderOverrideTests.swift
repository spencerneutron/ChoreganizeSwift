import Testing
import CoreData
@testable import Choreganize

/// CG-19 / #101 — covers the "HH:mm" override helpers (`ReminderTimeOverride`)
/// and the grouped planning seam (`NotificationManager.plannedGroupedReminders`):
/// parse/format round-trips, chore-beats-area-beats-global precedence, and
/// splitting chores into one plan per distinct effective time. Uses a fixed
/// `now` so it's deterministic (same approach as NotificationPlanningTests).
struct ReminderOverrideTests {

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    private let allDays = Set(Weekday.standardCases)

    // MARK: - Parse / format

    @Test func parsesValidTimes() {
        #expect(ReminderTimeOverride.parse("07:30")! == (7, 30))
        #expect(ReminderTimeOverride.parse("0:00")! == (0, 0))
        #expect(ReminderTimeOverride.parse("23:59")! == (23, 59))
        #expect(ReminderTimeOverride.parse("7:5")! == (7, 5))   // lenient padding
    }

    @Test func rejectsInvalidStrings() {
        let bad: [String?] = [nil, "", "24:00", "12:60", "-1:15", "7", ":30", "7:30:00", "ab:cd", "7.30"]
        for string in bad {
            #expect(ReminderTimeOverride.parse(string) == nil,
                    "\(String(describing: string)) should not parse")
        }
    }

    @Test func formatRoundTripsAndCanonicalizes() {
        #expect(ReminderTimeOverride.format(hour: 7, minute: 5) == "07:05")
        #expect(ReminderTimeOverride.parse(ReminderTimeOverride.format(hour: 0, minute: 0))! == (0, 0))
        #expect(ReminderTimeOverride.parse(ReminderTimeOverride.format(hour: 23, minute: 59))! == (23, 59))
        // Lenient parse → canonical zero-padded storage.
        let parsed = ReminderTimeOverride.parse("7:5")!
        #expect(ReminderTimeOverride.format(hour: parsed.hour, minute: parsed.minute) == "07:05")
    }

    // MARK: - Precedence (chore beats area beats global)

    @Test func choreOverrideBeatsAreaBeatsGlobal() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let area = CDArea.make(in: ctx, name: "Kitchen")
            area.reminderTime = "20:15"
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            chore.area = area
            try ctx.save()

            chore.reminderTime = "07:30"
            #expect(ReminderTimeOverride.effectiveOverride(chore: chore)! == (7, 30))   // chore wins

            chore.reminderTime = nil
            #expect(ReminderTimeOverride.effectiveOverride(chore: chore)! == (20, 15))  // then area

            area.reminderTime = nil
            #expect(ReminderTimeOverride.effectiveOverride(chore: chore) == nil)        // then global
        }
    }

    @Test func invalidChoreOverrideFallsBackToArea() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let area = CDArea.make(in: ctx, name: "Kitchen")
            area.reminderTime = "20:15"
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            chore.area = area
            chore.reminderTime = "25:00"   // malformed sync artifact
            try ctx.save()

            #expect(ReminderTimeOverride.effectiveOverride(chore: chore)! == (20, 15))
        }
    }

    // MARK: - Grouped planning

    @Test func planningSplitsChoresByEffectiveTime() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let area = CDArea.make(in: ctx, name: "Kitchen")
            area.reminderTime = "20:15"
            let early = CDChore.make(in: ctx, name: "Beds", isDaily: true)
            early.reminderTime = "07:30"
            let inherited = CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            inherited.area = area
            CDChore.make(in: ctx, name: "Trash", isDaily: true)   // no override → global
            try ctx.save()
            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))

            let cal = Calendar.current
            let now = cal.date(bySettingHour: 6, minute: 0, second: 0, of: Date())!   // before every slot
            let planned = NotificationManager.plannedGroupedReminders(
                chores: chores, days: allDays, globalHour: 18, globalMinute: 0,
                overridesEnabled: true, from: now, calendar: cal)

            // Three distinct effective times → three independent capped plans.
            #expect(planned.count == 21)
            for i in 1..<planned.count {
                #expect(planned[i].fireDate >= planned[i - 1].fireDate)   // merged plan stays sorted
            }

            let today = planned.filter { cal.isDate($0.fireDate, inSameDayAs: now) }
            #expect(today.count == 3)
            func reminder(at hour: Int, _ minute: Int) -> NotificationManager.PlannedReminder? {
                today.first {
                    cal.component(.hour, from: $0.fireDate) == hour
                        && cal.component(.minute, from: $0.fireDate) == minute
                }
            }
            #expect(reminder(at: 7, 30)?.choreIDs == [early.id!])        // chore's own time
            #expect(reminder(at: 20, 15)?.choreIDs == [inherited.id!])   // room's time
            #expect(reminder(at: 18, 0)?.choreIDs.count == 1)            // global keeps the rest
            #expect(today.allSatisfy { $0.unresolvedCount == $0.choreIDs.count })
        }
    }

    @Test func overrideMatchingGlobalMergesIntoOneReminder() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let a = CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            a.reminderTime = "18:00"                                  // same as global
            let b = CDChore.make(in: ctx, name: "Trash", isDaily: true)
            try ctx.save()
            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))

            let cal = Calendar.current
            let now = cal.date(bySettingHour: 6, minute: 0, second: 0, of: Date())!
            let planned = NotificationManager.plannedGroupedReminders(
                chores: chores, days: allDays, globalHour: 18, globalMinute: 0,
                overridesEnabled: true, from: now, calendar: cal)

            let today = planned.filter { cal.isDate($0.fireDate, inSameDayAs: now) }
            #expect(today.count == 1)                                 // one notification, not two
            #expect(Set(today[0].choreIDs) == Set([a.id!, b.id!]))
        }
    }

    @Test func gatedOffMatchesGlobalOnlyPlan() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let area = CDArea.make(in: ctx, name: "Kitchen")
            area.reminderTime = "20:15"
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            chore.area = area
            chore.reminderTime = "07:30"
            try ctx.save()
            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))

            let cal = Calendar.current
            let now = cal.date(bySettingHour: 6, minute: 0, second: 0, of: Date())!
            let gated = NotificationManager.plannedGroupedReminders(
                chores: chores, days: allDays, globalHour: 18, globalMinute: 0,
                overridesEnabled: false, from: now, calendar: cal)
            let baseline = NotificationManager.plannedReminders(
                chores: chores, days: allDays, hour: 18, minute: 0, from: now, calendar: cal)

            #expect(gated == baseline)   // without Plus, overrides are inert
        }
    }
}
