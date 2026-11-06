import Testing
import Foundation
import CoreGraphics
@testable import Choreganize

/// The day page's rim wiring: which sections flourish, and where a section card sits.
struct SectionRimLayerTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func flourishes(old: [String: Double], new: [String: Double], locked: Bool = false,
                            completedAgo: TimeInterval? = 1) -> [String: Double] {
        SectionRimTrigger.flourishes(old: old, new: new, isLocked: locked,
                                     lastLocalCompletion: completedAgo.map { now.addingTimeInterval(-$0) },
                                     now: now)
    }

    @Test func localFinishFlourishesFromItsLevel() {
        #expect(flourishes(old: ["Kitchen": 0.5, "Bedroom": 0], new: ["Kitchen": 1, "Bedroom": 0]) == ["Kitchen": 0.5])
    }

    @Test func markAllDoneFlourishesEverySection() {
        #expect(flourishes(old: ["A": 0, "B": 0.5], new: ["A": 1, "B": 1]) == ["A": 0, "B": 0.5])
    }

    @Test func syncedFinishEasesInstead() { #expect(flourishes(old: ["A": 0.5], new: ["A": 1], completedAgo: nil).isEmpty) }
    @Test func staleLocalCompletionEasesInstead() { #expect(flourishes(old: ["A": 0.5], new: ["A": 1], completedAgo: 4).isEmpty) }
    @Test func lockedDayNeverFlourishes() { #expect(flourishes(old: ["A": 0.5], new: ["A": 1], locked: true).isEmpty) }
    @Test func newSectionIsNotCelebrated() { #expect(flourishes(old: [:], new: ["A": 1]).isEmpty) }
    @Test func stayingFullIsNotCelebrated() { #expect(flourishes(old: ["A": 1], new: ["A": 1]).isEmpty) }
    @Test func partialProgressIsNotCelebrated() { #expect(flourishes(old: ["A": 0], new: ["A": 0.5]).isEmpty) }

    // A card is read from its rows' frames in display order.
    private func row(y: CGFloat, height: CGFloat = 70) -> CGRect {
        CGRect(x: 32, y: y, width: 338, height: height)
    }

    @Test func cardIsTheUnionOfItsRows() {
        let card = SectionRimTracker.cardFrame(ordered: [row(y: 100), row(y: 170), row(y: 240)])
        #expect(card == CGRect(x: 32, y: 100, width: 338, height: 210))
    }

    @Test func offscreenRowsAreEstimated() {
        // Rows 2...3 of 6 measured: two above and two below at their average height.
        let card = SectionRimTracker.cardFrame(ordered: [nil, nil, row(y: 100), row(y: 170), nil, nil])
        #expect(card == CGRect(x: 32, y: -40, width: 338, height: 420))
    }

    // A row that moved (or scrolled away) and hasn't reported since sits apart from the
    // others, so it's estimated instead of stretching the card (the "bridged rim" bug: a new
    // chore added above a row left the card reaching into the next section).
    @Test func strayFrameIsIgnored() {
        let card = SectionRimTracker.cardFrame(ordered: [row(y: 100), row(y: 170), row(y: 520)])
        #expect(card == CGRect(x: 32, y: 100, width: 338, height: 210))
    }

    @Test func newRowAboveKeepsTheCardItsOwnSize() {
        // "Test" inserted above "Wash the dishes": both report, flush, and nothing is estimated.
        let card = SectionRimTracker.cardFrame(ordered: [row(y: 100, height: 62), row(y: 162, height: 62)])
        #expect(card == CGRect(x: 32, y: 100, width: 338, height: 124))
    }

    @Test func noRowsNoCard() { #expect(SectionRimTracker.cardFrame(ordered: [nil, nil]) == nil) }

    // A room named "No Room" beside chores with no room: two sections, one title.
    @Test func repeatedTitlesGetUniqueIDs() {
        #expect(SectionRimSpec.uniqueIDs(["Kitchen", "No Room", "No Room", "Untitled", "Untitled", "Untitled"])
                == ["Kitchen", "No Room", "No Room#1", "Untitled", "Untitled#1", "Untitled#2"])
    }

    // A room literally named "No Room#1" beside the generated one.
    @Test func generatedIDsSkipTakenNames() {
        let ids = SectionRimSpec.uniqueIDs(["No Room", "No Room#1", "No Room"])
        #expect(ids == ["No Room", "No Room#1", "No Room#2"])
        #expect(Set(ids).count == ids.count)
    }
}
