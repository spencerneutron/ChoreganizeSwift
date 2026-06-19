import Testing
import Foundation
@testable import Choreganize

/// Coverage for the pure streak grouping that conducts one glow sweep across a run of
/// consecutive perfect days (#57 fast-follow): lone days, runs, and gaps.
struct CalendarStreaksTests {

    private let cal = Calendar.current
    private func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
    }

    @Test func emptyInputYieldsNothing() {
        #expect(CalendarStreaks.slots(for: []).isEmpty)
    }

    @Test func loneDayIsSlotZeroOfOne() {
        let s = CalendarStreaks.slots(for: [day(-5)])
        let r = s[cal.startOfDay(for: day(-5))]
        #expect(r?.slot == 0)
        #expect(r?.count == 1)
    }

    @Test func consecutiveDaysFormOneRun() {
        let s = CalendarStreaks.slots(for: [day(-3), day(-2), day(-1)])
        #expect(s[cal.startOfDay(for: day(-3))]?.slot == 0)
        #expect(s[cal.startOfDay(for: day(-2))]?.slot == 1)
        #expect(s[cal.startOfDay(for: day(-1))]?.slot == 2)
        #expect(s.values.allSatisfy { $0.count == 3 })
    }

    @Test func gapSplitsIntoSeparateRuns() {
        // -5,-4 (run of 2), gap at -3, then -2,-1,0 (run of 3).
        let s = CalendarStreaks.slots(for: [day(-5), day(-4), day(-2), day(-1), day(0)])
        #expect(s[cal.startOfDay(for: day(-5))]?.count == 2)
        #expect(s[cal.startOfDay(for: day(-4))]?.slot == 1)
        #expect(s[cal.startOfDay(for: day(-2))]?.slot == 0)
        #expect(s[cal.startOfDay(for: day(-2))]?.count == 3)
        #expect(s[cal.startOfDay(for: day(0))]?.slot == 2)
    }
}
