import Testing
import AppIntents
@testable import Choreganize

/// Covers the spoken-summary formatting for the "today's chores" Siri intent
/// (`TodaysChoresIntent.spokenSummary`) — the user-facing sentence Siri reads.
struct SiriIntentTests {

    @Test func summaryWhenNothingLeft() {
        let s = TodaysChoresIntent.spokenSummary(for: [])
        #expect(s.contains("all caught up"))
        #expect(s.contains("no chores left today"))
    }

    @Test func summaryForSingleChore() {
        #expect(TodaysChoresIntent.spokenSummary(for: ["Dishes"]) == "You have 1 chore left today: Dishes.")
    }

    @Test func summaryForManyChores() {
        let s = TodaysChoresIntent.spokenSummary(for: ["Dishes", "Trash", "Plants"])
        #expect(s.hasPrefix("You have 3 chores left today:"))
        #expect(s.contains("Dishes"))
        #expect(s.contains("Trash"))
        #expect(s.contains("Plants"))
        #expect(s.hasSuffix("."))
    }
}
