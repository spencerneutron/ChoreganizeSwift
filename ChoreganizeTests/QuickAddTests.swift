import Testing
import CoreData
import Foundation
@testable import Choreganize

/// CG-26 / #127 — the Quick Add ghost's pure layer: section keys, the prefill
/// table (every key × weekday), which days offer the ghost, and which slot it
/// targets for given frames.
struct QuickAddTests {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        return cal
    }

    /// Sunday 2026-09-27 + `offset` days, at noon.
    private func day(_ offset: Int) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 12))!
        return calendar.date(byAdding: .day, value: offset, to: base)!
    }

    // MARK: Section keys

    @Test func sectionsCarryTheirKeys() throws {
        let ctx = CoreDataStack(inMemory: true).newBackgroundContext()
        ctx.performAndWait {
            let kitchen = CDArea.make(in: ctx, name: "Kitchen")
            let daily = CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            daily.area = kitchen
            let weekly = CDChore.make(in: ctx, name: "Vacuum", frequency: .weekly, assignedDay: .monday)
            let monthly = CDChore.make(in: ctx, name: "Filters", frequency: .monthly, assignedDay: .monday)
            let loose = CDChore.make(in: ctx, name: "Mystery", assignedDay: .monday)   // no frequency

            #expect(WorkGrouping.none.sections(for: [daily]).map(\.key) == [.all])
            #expect(WorkGrouping.frequency.sections(for: [daily, weekly, monthly, loose]).map(\.key)
                    == [.daily, .frequency(.weekly), .frequency(.monthly), .unscheduled])
            #expect(WorkGrouping.room.sections(for: [daily, weekly]).map(\.key)
                    == [.area(kitchen.id, name: "Kitchen"), .noArea])
        }
    }

    // MARK: Prefill

    @Test(arguments: 0..<7)
    func prefillUsesThePagesWeekday(offset: Int) {
        let date = day(offset)
        let weekday = Weekday.standardCases[offset]   // day(0) is a Sunday
        let name = weekday.displayName

        let plain = ChorePrefill.make(for: .all, on: date, calendar: calendar)
        #expect(plain == ChorePrefill(day: weekday, summary: "Weekly on \(name)s"))

        let daily = ChorePrefill.make(for: .daily, on: date, calendar: calendar)
        #expect(daily.isDaily && daily.day == weekday && daily.summary == "Every day")

        for frequency in Frequency.allCases {
            let prefill = ChorePrefill.make(for: .frequency(frequency), on: date, calendar: calendar)
            #expect(!prefill.isDaily && prefill.frequency == frequency && prefill.day == weekday)
            #expect(prefill.areaID == nil)
        }
        #expect(ChorePrefill.make(for: .frequency(.monthly), on: date, calendar: calendar).summary
                == "Monthly on a \(name)")

        #expect(ChorePrefill.make(for: .unscheduled, on: date, calendar: calendar) == plain)
        #expect(ChorePrefill.make(for: .noArea, on: date, calendar: calendar) == plain)

        let areaID = UUID()
        let room = ChorePrefill.make(for: .area(areaID, name: "Kitchen"), on: date, calendar: calendar)
        #expect(room == ChorePrefill(day: weekday, areaID: areaID, summary: "Kitchen · \(name)s"))
    }

    // MARK: Which days offer it

    @Test func pastAndLockedDaysDontOfferTheGhost() {
        let now = day(0)
        #expect(QuickAddRules.offersGhost(on: now, isLocked: false, now: now, calendar: calendar))
        #expect(QuickAddRules.offersGhost(on: day(3), isLocked: false, now: now, calendar: calendar))
        #expect(!QuickAddRules.offersGhost(on: day(-1), isLocked: false, now: now, calendar: calendar))
        #expect(!QuickAddRules.offersGhost(on: now, isLocked: true, now: now, calendar: calendar))
        #expect(!QuickAddRules.offersGhost(on: day(2), isLocked: true, now: now, calendar: calendar))
    }

    // MARK: Targeting

    private func span(_ minY: CGFloat, _ height: CGFloat = 42) -> QuickAddRules.Span {
        QuickAddRules.Span(minY: minY, maxY: minY + height)
    }

    @Test func targetsTheVisibleSlotNearestTheMiddle() {
        let viewport = QuickAddRules.Span(minY: 100, maxY: 900)   // midline 500
        let slots = ["Kitchen": span(180), "Bedroom": span(460), "Garage": span(700)]
        #expect(QuickAddRules.target(slots: slots, viewport: viewport) == "Bedroom")
    }

    @Test func ignoresSlotsNotWhollyOnScreen() {
        let viewport = QuickAddRules.Span(minY: 100, maxY: 900)
        // Bedroom straddles the top edge; Garage is under the bottom edge.
        let slots = ["Bedroom": span(80), "Kitchen": span(150), "Garage": span(880)]
        #expect(QuickAddRules.target(slots: slots, viewport: viewport) == "Kitchen")
        #expect(QuickAddRules.target(slots: ["Garage": span(880)], viewport: viewport) == nil)
        #expect(QuickAddRules.target(slots: [:], viewport: viewport) == nil)
    }

    @Test func tieGoesToTheUpperSlot() {
        let viewport = QuickAddRules.Span(minY: 0, maxY: 1000)    // midline 500
        let slots = ["Below": span(529), "Above": span(429)]      // mids 550 and 450
        #expect(QuickAddRules.target(slots: slots, viewport: viewport) == "Above")
    }

    // MARK: Tracker

    @MainActor @Test func trackerHopsAndLingers() async throws {
        let tracker = QuickAddTracker(linger: .milliseconds(50))
        tracker.updateViewport(QuickAddRules.Span(minY: 0, maxY: 1000))
        tracker.updateSlot("A", span: span(200))
        tracker.updateSlot("B", span: span(600))
        #expect(tracker.target == "B")
        #expect(!tracker.shows("B"))              // nothing until the list moves

        tracker.scrollMoved(true)
        #expect(tracker.shows("B") && !tracker.shows("A"))

        tracker.updateSlot("B", span: span(900))  // scrolled: A is now nearer
        tracker.updateSlot("A", span: span(480))
        #expect(tracker.target == "A")

        tracker.scrollMoved(false)
        #expect(tracker.shows("A"))               // lingers after settling…
        try await Task.sleep(for: .milliseconds(300))
        #expect(!tracker.shows("A"))              // …then fades

        tracker.scrollMoved(true)
        tracker.hovered = "B"                     // Mac: hover wins over the target
        #expect(tracker.shows("B") && !tracker.shows("A"))
        tracker.hovered = nil
        #expect(tracker.shows("A"))

        tracker.removeSlot("A")
        #expect(tracker.target == "B")
    }
}
