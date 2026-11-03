import Testing
import Foundation
@testable import Choreganize

/// The Work pager's page arithmetic (iPhone Duo / iPad two-day spread): which spreads
/// exist, where a layout switch lands, where a deep link lands, and which page an offset
/// is on. The pager's range is 13 days, today at index 6.
struct WeekPagerTests {

    private let dayCount = 13
    private let today = 6

    // MARK: Spreads

    @Test func spreadsStepTwoDaysInStepWithTheFocus() {
        #expect(WeekPager.spreadRights(focus: 6, dayCount: dayCount) == [0, 2, 4, 6, 8, 10, 12])
        #expect(WeekPager.spreadRights(focus: 7, dayCount: dayCount) == [1, 3, 5, 7, 9, 11, 13])
    }

    @Test(arguments: 0...12)
    func theFocusedDayIsAlwaysARightPage(focus: Int) {
        #expect(WeekPager.spreadRights(focus: focus, dayCount: dayCount).contains(focus))
    }

    /// Whichever parity is in step, every day in the range shows on some spread, and the
    /// only sides outside the range are the one before the earliest day and the one after
    /// the latest (the edge notes).
    @Test(arguments: [6, 7])
    func everyDayHasASpreadAndOnlyEdgesFallOutside(focus: Int) {
        let rights = WeekPager.spreadRights(focus: focus, dayCount: dayCount)
        let shown = Set(rights.flatMap { [$0 - 1, $0] })
        #expect(Set(0..<dayCount).isSubset(of: shown))
        #expect(shown.subtracting(0..<dayCount).isSubset(of: [-1, dayCount]))
    }

    @Test func openedOnTheEarliestDayTheLeftSideIsTheEdge() {
        let rights = WeekPager.spreadRights(focus: 0, dayCount: dayCount)
        #expect(rights.first == 0)   // the spread (-1 | 0): "No earlier days" | earliest day
    }

    // MARK: Layout switches

    @Test func switchingToASpreadKeepsTheFocusedDayOnTheRight() {
        for focus in 0..<dayCount {
            #expect(WeekPager.pageID(switchingToSpread: true, focus: focus, dayCount: dayCount) == focus)
        }
    }

    @Test func switchingToOnePageKeepsTheRightPageAndClampsTheEdge() {
        #expect(WeekPager.pageID(switchingToSpread: false, focus: 8, dayCount: dayCount) == 8)
        // The last odd spread is (12 | "No later days"): one page shows day 12.
        #expect(WeekPager.pageID(switchingToSpread: false, focus: 13, dayCount: dayCount) == 12)
    }

    // MARK: Deep links

    @Test func aDeepLinkSnapsBackToToday() {
        #expect(WeekPager.deepLinkTarget(today: today, focus: 9) == today)
        #expect(WeekPager.deepLinkTarget(today: today, focus: today) == nil)
    }

    /// From any page (including a spread with today on the left, or the edge spread), a
    /// deep link makes today the focused page: the right page of a spread, the one the
    /// outer display keeps when iPhone Duo closes.
    @Test(arguments: 0...13)
    func aDeepLinkPutsTodayOnTheFocusedPage(focus: Int) {
        let landing = WeekPager.deepLinkTarget(today: today, focus: focus) ?? focus
        #expect(landing == today)
        #expect(WeekPager.spreadRights(focus: landing, dayCount: dayCount).contains(today))
        #expect(WeekPager.pageID(switchingToSpread: false, focus: landing, dayCount: dayCount) == today)
    }

    // MARK: Closing on the edge spread

    /// The last odd spread is (12 | "No later days"); folding to one page shows day 12.
    @Test func closingOnTheEdgeSpreadShowsTheLastDay() {
        let rights = WeekPager.spreadRights(focus: 11, dayCount: dayCount)
        #expect(rights.last == dayCount)
        #expect(WeekPager.pageID(switchingToSpread: false, focus: dayCount, dayCount: dayCount) == dayCount - 1)
    }

    // MARK: Offsets

    @Test func anOffsetRoundsToTheNearestPage() {
        #expect(WeekPager.pageIndex(offset: 0, pageWidth: 400, pageCount: 7) == 0)
        #expect(WeekPager.pageIndex(offset: 1210, pageWidth: 400, pageCount: 7) == 3)
        #expect(WeekPager.pageIndex(offset: 1190, pageWidth: 400, pageCount: 7) == 3)
    }

    @Test func anOffsetOutsideTheContentClamps() {
        #expect(WeekPager.pageIndex(offset: -80, pageWidth: 400, pageCount: 7) == 0)
        #expect(WeekPager.pageIndex(offset: 9_000, pageWidth: 400, pageCount: 7) == 6)
        #expect(WeekPager.pageIndex(offset: 100, pageWidth: 0, pageCount: 7) == 0)
    }
}
