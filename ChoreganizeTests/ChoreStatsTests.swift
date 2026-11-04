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

    @Test func typicalGapNeedsFourCompletions() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Mop", isDaily: true, createdDate: day(-40))
            for offset in [-8, -5, -2] { chore.recordCompletion(on: day(offset), by: nil, in: ctx) }
            try ctx.save()

            let stats = InsightsMath.choreStats(for: chore, today: today)

            #expect(stats.lastDone == cal.startOfDay(for: day(-2)))
            #expect(stats.typicalGapDays == nil)
        }
    }

    @Test func typicalGapAveragesTheMiddlePair() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            // Gaps 2, 4, 6, 8: the median is between 4 and 6.
            let chore = CDChore.make(in: ctx, name: "Vacuum", isDaily: true, createdDate: day(-40))
            for offset in [-20, -18, -14, -8, 0] { chore.recordCompletion(on: day(offset), by: nil, in: ctx) }
            try ctx.save()

            #expect(InsightsMath.choreStats(for: chore, today: today).typicalGapDays == 5)
        }
    }

    @Test func gapAndWindowWording() {
        #expect(ChoreStatsSection.gapText(1) == "Every day")
        #expect(ChoreStatsSection.gapText(3) == "Every 3 days")
        #expect(ChoreStatsSection.gapText(7) == "Every week")
        #expect(ChoreStatsSection.gapText(14) == "Every 2 weeks")
        #expect(ChoreStatsSection.gapText(35) == "Every 5 weeks")
        #expect(ChoreStatsSection.gapText(30) == "Every month")
        #expect(ChoreStatsSection.gapText(31) == "Every month")
        #expect(ChoreStatsSection.gapText(45) == "Every 45 days")
        #expect(ChoreStatsSection.gapText(61) == "Every 2 months")
        #expect(ChoreStatsSection.gapText(365) == "Every year")
        #expect(ChoreStatsSection.gapText(731) == "Every 2 years")

        #expect(ChoreStatsSection.windowText(30) == "30 days")
        #expect(ChoreStatsSection.windowText(180) == "6 months")
        #expect(ChoreStatsSection.windowText(360) == "year")
        #expect(ChoreStatsSection.windowText(730) == "2 years")
        #expect(ChoreStatsSection.windowText(1080) == "3 years")

        #expect(ChoreStatsSection.lastDoneText(nil, today: today) == "Never")
        #expect(ChoreStatsSection.lastDoneText(day(0), today: today) == "Today")
        #expect(ChoreStatsSection.lastDoneText(day(-1), today: today) == "Yesterday")
        #expect(ChoreStatsSection.lastDoneText(day(-400), today: today).contains("2025"))
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

            // The repeat interval stretches it: every 6 weeks looks back 6 months.
            weekly.recurrenceIntervalValue = 6
            #expect(InsightsMath.onTimeWindowDays(for: weekly) == 180)
        }
    }

    @Test func aChoreWithNoSetDayHasNoDueDays() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let unscheduled = CDChore.make(in: ctx, name: "Someday", frequency: .weekly, assignedDay: nil)
            let scheduled = CDChore.make(in: ctx, name: "Mondays", frequency: .weekly, assignedDay: .monday)
            let daily = CDChore.make(in: ctx, name: "Daily", isDaily: true)

            #expect(!InsightsMath.hasDueDays(unscheduled))
            #expect(InsightsMath.hasDueDays(scheduled))
            #expect(InsightsMath.hasDueDays(daily))
        }
    }

    @Test func onTimeIsSkippedWhenLocked() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let chore = CDChore.make(in: ctx, name: "Dishes", isDaily: true, createdDate: day(-9))
            chore.recordCompletion(on: day(-1), by: nil, in: ctx)
            try ctx.save()

            let stats = InsightsMath.choreStats(for: chore, includesOnTime: false, today: today)
            #expect(stats.onTime == InsightsMath.WindowStats(due: 0, completed: 0))
            #expect(stats.lastDone == cal.startOfDay(for: day(-1)))
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
            // Mop and Bins tie on 3 missed of 4: the first by name wins.
            #expect(stats.mostMissed == .init(name: "Bins", missed: 3, due: 4))
        }
    }

    @Test func mostMissedRanksByRate() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            // A daily chore missed 5 of 29 past days, and a weekly one never done.
            let dishes = CDChore.make(in: ctx, name: "Dishes", isDaily: true, createdDate: day(-29))
            for offset in -29...0 where ![-25, -20, -15, -10, -5].contains(offset) {
                dishes.recordCompletion(on: day(offset), by: nil, in: ctx)
            }
            let weekday = try #require(Weekday.standardCases.first {
                $0.calendarWeekday == cal.component(.weekday, from: day(-1))
            })
            let trash = CDChore.make(in: ctx, name: "Trash", frequency: .weekly, assignedDay: weekday,
                                     createdDate: day(-29))
            try ctx.save()

            let stats = InsightsMath.roomStats(chores: [dishes, trash], today: today)

            #expect(stats.mostMissed?.name == "Trash")
            #expect(stats.mostMissed?.missed == stats.mostMissed?.due)
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

    // MARK: - Household members

    private func done(_ chore: UUID?, by member: String?, _ offset: Int) -> InsightsMath.MemberCompletion {
        .init(choreID: chore, completedBy: member, date: day(offset))
    }

    @Test func membersCountTheirChoresInTheWindowOnce() {
        let dishes = UUID(), mop = UUID()
        let summary = InsightsMath.membersSummary([
            done(dishes, by: "sam", 0),
            done(dishes, by: "sam", 0),     // a sync duplicate: once
            done(mop, by: "sam", -29),      // the window's first day
            done(mop, by: "sam", -30),      // just outside it
            done(mop, by: "sam", 1),        // ahead of today: ignored
            done(mop, by: "alex", -3),
            done(dishes, by: nil, -1),      // doesn't say who: left out
        ], today: today)

        #expect(summary.members.map(\.id) == ["alex", "sam"])
        #expect(summary.members.first { $0.id == "sam" }?.choresDone == 2)
        #expect(summary.members.first { $0.id == "alex" }?.choresDone == 1)
        #expect(summary.total == 3)
        #expect(summary.windowDays == 30)
    }

    @Test func theTotalMatchesTheRowsWhenTwoTickTheSameChore() {
        let dishes = UUID()
        // Both ticked it before either synced.
        let summary = InsightsMath.membersSummary([done(dishes, by: "sam", 0), done(dishes, by: "alex", 0)],
                                                  today: today)

        #expect(summary.members.map(\.choresDone) == [1, 1])
        #expect(summary.total == 2)
    }

    @Test func aRunSurvivesAClockChangeAtMidnight() throws {
        // Chile moved its clocks from 00:00 to 01:00 on Sunday 7 September 2025, so that day
        // starts at 01:00.
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = try #require(TimeZone(identifier: "America/Santiago"))
        let noon = { (day: Int) in santiago.date(from: DateComponents(year: 2025, month: 9, day: day, hour: 12))! }
        let chore = UUID()
        let summary = InsightsMath.membersSummary(
            (5...8).map { InsightsMath.MemberCompletion(choreID: chore, completedBy: "sam", date: noon($0)) },
            today: noon(8), calendar: santiago)

        #expect(summary.members.first?.streak == 4)
        #expect(summary.members.first?.choresDone == 4)
    }

    @Test func aMembersRunCountsBackFromTodayOrYesterday() {
        let chore = UUID()
        let summary = InsightsMath.membersSummary(
            // Sam: today and the 2 days before, then a gap. Alex: yesterday and the day
            // before, not yet today. Pat: 3 days ago only.
            [0, -1, -2, -4].map { done(chore, by: "sam", $0) }
            + [-1, -2].map { done(chore, by: "alex", $0) }
            + [done(chore, by: "pat", -3)],
            today: today)

        let streaks = Dictionary(uniqueKeysWithValues: summary.members.map { ($0.id, $0.streak) })
        #expect(streaks == ["sam": 3, "alex": 2, "pat": 0])
    }

    @Test func aRunCanReachPastTheWindow() {
        let chore = UUID()
        let summary = InsightsMath.membersSummary((-39...0).map { done(chore, by: "sam", $0) }, today: today)

        #expect(summary.members.first?.choresDone == 30)
        #expect(summary.members.first?.streak == 40)
    }

    @Test func membersWithNothingInTheWindowAreLeftOut() {
        let summary = InsightsMath.membersSummary([done(UUID(), by: "sam", -45)], today: today)

        #expect(summary.members.isEmpty)
        #expect(summary.total == 0)
    }

    @Test func memberRowsPutYouFirstThenNamesThenEveryoneElse() {
        let summary = InsightsMath.MembersSummary(members: [
            .init(id: "a", choresDone: 3, streak: 2),
            .init(id: "b", choresDone: 5, streak: 0),
            .init(id: "c", choresDone: 1, streak: 1),
            .init(id: "me", choresDone: 2, streak: 4),
            .init(id: "x", choresDone: 4, streak: 3),
            .init(id: "y", choresDone: 6, streak: 5),
        ], windowDays: 30)

        let rows = HouseholdMembers.rows(summary, names: ["a": "Sam", "b": "Alex", "c": "pat"], me: "me")

        #expect(rows.map(\.name) == ["You", "Alex", "pat", "Sam", "Other members"])
        #expect(rows.last?.choresDone == 10)
        #expect(rows.last?.streak == nil)

        let one = HouseholdMembers.rows(.init(members: [.init(id: "x", choresDone: 4, streak: 3)],
                                              windowDays: 30),
                                        names: [:], me: "me")
        #expect(one == [.init(id: "x", name: "A household member", choresDone: 4, streak: 3)])
    }

    @Test func membersShowOnlyWithMoreThanOnePerson() {
        let justMe = InsightsMath.MembersSummary(members: [.init(id: "me", choresDone: 2, streak: 1)],
                                                 windowDays: 30)
        #expect(!HouseholdMembers.isShared(justMe, participantIDs: []))
        #expect(!HouseholdMembers.isShared(justMe, participantIDs: ["me"]))
        #expect(HouseholdMembers.isShared(justMe, participantIDs: ["me", "sam"]))

        let two = InsightsMath.MembersSummary(members: [.init(id: "me", choresDone: 2, streak: 1),
                                                        .init(id: "sam", choresDone: 1, streak: 1)],
                                              windowDays: 30)
        #expect(HouseholdMembers.isShared(two, participantIDs: []))

        // CloudKit's stand-in for your own id isn't a second person.
        #expect(!HouseholdMembers.isShared(justMe, participantIDs: ["__defaultOwner__"]))
    }

    @Test func membersShowOnlyForTheHouseholdTheyWereLoadedFor() {
        let ctx = makeContext()
        ctx.performAndWait {
            let home = CDHousehold(context: ctx), cabin = CDHousehold(context: ctx)
            let summary = InsightsMath.MembersSummary(members: [.init(id: "me", choresDone: 2, streak: 1),
                                                                .init(id: "sam", choresDone: 1, streak: 1)],
                                                      windowDays: 30)
            let loaded = HouseholdMembers.Loaded(householdID: home.objectID, summary: summary)

            #expect(HouseholdMembers.shown(loaded, for: home.objectID, participantIDs: []) == summary)
            #expect(HouseholdMembers.shown(loaded, for: cabin.objectID, participantIDs: []) == nil)
            #expect(HouseholdMembers.shown(loaded, for: nil, participantIDs: []) == nil)
        }
    }
}
