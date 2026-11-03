import Testing
import CoreGraphics
@testable import Choreganize

/// The month grid's rows filling a page (iPad / iPhone Duo two-page Calendar).
struct CalendarGridMetricsTests {

    @Test func rowsFillTheAvailableHeight() {
        // 5 rows and 4 gaps of 8 pt in 540 pt: (540 - 32) / 5 = 101.6, rounded down.
        #expect(CalendarGridMetrics.cellHeight(available: 540, rows: 5) == 101)
        // A 6-row month gets shorter cells in the same page.
        #expect(CalendarGridMetrics.cellHeight(available: 540, rows: 6) == 83)
    }

    @Test func theCellNeverDropsBelowItsPhoneHeight() {
        #expect(CalendarGridMetrics.cellHeight(available: 200, rows: 6) == CalendarGridMetrics.minimumCellHeight)
        #expect(CalendarGridMetrics.cellHeight(available: 0, rows: 5) == CalendarGridMetrics.minimumCellHeight)
    }

    @Test func noRowsFallsBackToTheMinimum() {
        #expect(CalendarGridMetrics.cellHeight(available: 500, rows: 0) == CalendarGridMetrics.minimumCellHeight)
    }

    @Test func filledRowsFitTheirPage() {
        for rows in 4...6 {
            let height = CalendarGridMetrics.cellHeight(available: 600, rows: rows)
            let used = height * CGFloat(rows) + CalendarGridMetrics.rowSpacing * CGFloat(rows - 1)
            #expect(used <= 600)
        }
    }
}
