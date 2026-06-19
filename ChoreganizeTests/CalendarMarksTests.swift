import Testing
import CoreData
@testable import Choreganize

/// Coverage for the pure calendar day-cell completion meter (#57 Part 1):
/// the ratio/percent math and the `showsMeter`/`showsPercent` rules — including the
/// recency window (older all-incomplete days stay blank; completed days always show)
/// and future-day handling (meter shown, but no %).
struct CalendarMarksTests {

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    private let day = Calendar.current.startOfDay(for: Date())

    /// `n` chores, the first `done` of them completed on `day`.
    private func progress(total: Int, done: Int, mode: CellMode, daysAgo: Int,
                          locked: Bool = false, in ctx: NSManagedObjectContext) -> DayProgress {
        let chores = (0..<total).map { i -> CDChore in
            let c = CDChore.make(in: ctx, name: "C\(i)", isDaily: true)
            if i < done { c.recordCompletion(on: day, in: ctx) }
            return c
        }
        return CalendarMarks.progress(chores, on: day, mode: mode, daysAgo: daysAgo, locked: locked)
    }

    @Test func ratioAndPercent() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            #expect(progress(total: 3, done: 2, mode: .past, daysAgo: 1, in: ctx).percent == 67)
            #expect(progress(total: 2, done: 1, mode: .past, daysAgo: 1, in: ctx).percent == 50)
            #expect(progress(total: 4, done: 4, mode: .currentWeek, daysAgo: 0, in: ctx).percent == 100)
            #expect(progress(total: 5, done: 0, mode: .past, daysAgo: 1, in: ctx).percent == 0)
        }
    }

    @Test func emptyDayShowsNothing() throws {
        let p = CalendarMarks.progress([], on: day, mode: .past, daysAgo: 0, locked: true)
        #expect(p.total == 0)
        #expect(!p.showsMeter)
        #expect(!p.showsPercent)
        #expect(!p.earnsGlow)   // empty days never glow, even if locked
    }

    @Test func futureShowsMeterButNoPercent() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let p = progress(total: 3, done: 0, mode: .future, daysAgo: -2, in: ctx)
            #expect(p.showsMeter)        // 3 blue bars
            #expect(!p.showsPercent)     // nothing completable yet
        }
    }

    @Test func recentIncompleteShowsButOldAllIncompleteIsBlank() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let window = CalendarPolicy.recentIncompleteWindow
            // All-incomplete, at the window edge → still shown (red, actionable).
            let atEdge = progress(total: 3, done: 0, mode: .past, daysAgo: window, in: ctx)
            #expect(atEdge.showsMeter)
            #expect(atEdge.showsPercent)
            // All-incomplete, one day past the window → blank (no neutral wall of zeros).
            let stale = progress(total: 3, done: 0, mode: .past, daysAgo: window + 1, in: ctx)
            #expect(!stale.showsMeter)
        }
    }

    @Test func oldButPartlyCompletedStillShows() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            // Beyond the window but with a completion → achievements always show.
            let p = progress(total: 4, done: 1, mode: .past, daysAgo: 99, in: ctx)
            #expect(p.showsMeter)
            #expect(p.showsPercent)
            #expect(p.percent == 25)
        }
    }

    @Test func glowRulesForCompletedDays() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            // Any fully-completed past day glows (lock state irrelevant — past is settled).
            #expect(progress(total: 3, done: 3, mode: .past, daysAgo: 2, in: ctx).earnsGlow)
            // Today glows only once it's LOCKED (the user tapped Done) and fully complete.
            #expect(progress(total: 3, done: 3, mode: .currentWeek, daysAgo: 0, locked: true, in: ctx).earnsGlow)
            #expect(!progress(total: 3, done: 3, mode: .currentWeek, daysAgo: 0, locked: false, in: ctx).earnsGlow)
            // Future never glows; partial days don't; locked-but-incomplete today doesn't.
            #expect(!progress(total: 3, done: 3, mode: .future, daysAgo: -1, locked: true, in: ctx).earnsGlow)
            #expect(!progress(total: 3, done: 2, mode: .past, daysAgo: 2, in: ctx).earnsGlow)
            #expect(!progress(total: 3, done: 2, mode: .currentWeek, daysAgo: 0, locked: true, in: ctx).earnsGlow)
        }
    }
}
