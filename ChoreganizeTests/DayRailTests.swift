import Testing
import Foundation
@testable import Choreganize

/// The open iPhone Duo's day rail: tick positions, the pager position it tracks, which
/// spread a finger is on, where the pill sits, and the slice of gradient its rim shows. The
/// range is 13 days (today at 6); the rail is 649 pt tall, as on the Duo's inner display.
struct DayRailTests {

    private let dayCount = 13
    private let height: CGFloat = 649

    // MARK: Ticks

    @Test func ticksSpanTheRailInsideTheEndInsets() {
        #expect(DayRailMath.y(day: 0, height: height, dayCount: dayCount) == DayRailMath.endInset)
        #expect(DayRailMath.y(day: 12, height: height, dayCount: dayCount) == height - DayRailMath.endInset)
    }

    @Test(arguments: [0.0, 3.5, 6.0, 11.25, 12.0])
    func aHeightMapsBackToItsDay(day: Double) {
        let y = DayRailMath.y(day: CGFloat(day), height: height, dayCount: dayCount)
        #expect(abs(DayRailMath.day(atY: y, height: height, dayCount: dayCount) - CGFloat(day)) < 0.0001)
    }

    // MARK: Tracking the pager

    @Test func theScrollOffsetGivesAFractionalSpread() {
        // Spreads 0, 2, …, 12 one page width (880) apart: page 3 is the spread ending on 6.
        #expect(DayRailMath.rightIndex(firstRight: 0, offset: 3 * 880, pageWidth: 880) == 6)
        // Halfway to the next spread reads one day on.
        #expect(DayRailMath.rightIndex(firstRight: 0, offset: 3.5 * 880, pageWidth: 880) == 7)
        #expect(DayRailMath.rightIndex(firstRight: 1, offset: 0, pageWidth: 0) == 1)
    }

    // MARK: Dragging

    @Test func aFingerOnTheMiddleOfTwoDaysPicksTheirSpread() {
        let even = WeekPager.spreadRights(focus: 6, dayCount: dayCount)   // 0, 2, …, 12
        #expect(DayRailMath.spread(atDay: 5.5, rights: even) == 6)        // between 5 and 6
        #expect(DayRailMath.spread(atDay: 7.4, rights: even) == 8)
        let odd = WeekPager.spreadRights(focus: 7, dayCount: dayCount)    // 1, 3, …, 13
        #expect(DayRailMath.spread(atDay: 6.5, rights: odd) == 7)
    }

    @Test func aFingerPastTheEndsPicksTheEdgeSpreads() {
        let even = WeekPager.spreadRights(focus: 6, dayCount: dayCount)
        #expect(DayRailMath.spread(atDay: -3, rights: even) == 0)
        #expect(DayRailMath.spread(atDay: 20, rights: even) == 12)
        #expect(DayRailMath.spread(atDay: 0, rights: []) == nil)
    }

    // MARK: The pill

    @Test func thePillSitsBetweenItsSpreadsTwoTicks() {
        let five = DayRailMath.y(day: 5, height: height, dayCount: dayCount)
        let six = DayRailMath.y(day: 6, height: height, dayCount: dayCount)
        #expect(DayRailMath.pillCenter(rightIndex: 6, height: height, dayCount: dayCount) == (five + six) / 2)
    }

    @Test func anEdgeSpreadsPillSitsOnItsOneRealDay() {
        let first = DayRailMath.y(day: 0, height: height, dayCount: dayCount)
        #expect(DayRailMath.pillCenter(rightIndex: 0, height: height, dayCount: dayCount) == first)
    }

    @Test(arguments: [-100.0, 0.0, 324.5, 649.0, 900.0])
    func thePillStaysInsideTheRail(center: Double) {
        let pill = DayRailMath.pillHeight(height: height, dayCount: dayCount)
        let clamped = DayRailMath.clampedCenter(CGFloat(center), pillHeight: pill, railHeight: height)
        #expect(clamped - pill / 2 >= 0)
        #expect(clamped + pill / 2 <= height)
    }

    // MARK: The rim

    @Test func theRimShowsTheGoldEndAtTheTopAndThePeriwinkleEndAtTheBottom() {
        let pill = DayRailMath.pillHeight(height: height, dayCount: dayCount)
        let top = DayRailMath.rimSlice(center: pill / 2, pillHeight: pill, railHeight: height, dayCount: dayCount)
        #expect(top.from == 0)
        let bottom = DayRailMath.rimSlice(center: height - pill / 2, pillHeight: pill, railHeight: height,
                                          dayCount: dayCount)
        #expect(abs(bottom.from + bottom.span - 1) < 0.0001)
    }

    @Test(arguments: stride(from: 0.0, through: 649.0, by: 59.0).map { $0 })
    func theRimSliceIsTwiceThePillAndInsideTheGradient(center: Double) {
        let pill = DayRailMath.pillHeight(height: height, dayCount: dayCount)
        let slice = DayRailMath.rimSlice(center: CGFloat(center), pillHeight: pill, railHeight: height,
                                         dayCount: dayCount)
        let railSpan = height - 2 * DayRailMath.endInset
        #expect(abs(slice.span - 2 * pill / railSpan) < 0.0001)
        #expect(slice.from >= 0)
        #expect(slice.from + slice.span <= 1.0001)
    }
}
