import Testing
import Foundation
@testable import Choreganize

/// The completion wash fires only for a local completion that finishes an unlocked day.
struct CompletionWashTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func wash(was: Bool = false, is isDone: Bool = true, locked: Bool = false,
                      completedAgo: TimeInterval? = 1, washedAgo: TimeInterval? = nil) -> Bool {
        WashTrigger.shouldWash(wasComplete: was, isComplete: isDone, isLocked: locked,
                               lastLocalCompletion: completedAgo.map { now.addingTimeInterval(-$0) },
                               lastWash: washedAgo.map { now.addingTimeInterval(-$0) },
                               now: now)
    }

    @Test func firesOnLocalCompletion() { #expect(wash()) }
    @Test func ignoresStaleCompletion() { #expect(!wash(completedAgo: 4)) }
    @Test func ignoresNoLocalCompletion() { #expect(!wash(completedAgo: nil)) }
    @Test func ignoresFutureCompletion() { #expect(!wash(completedAgo: -1)) }
    @Test func ignoresLockedDay() { #expect(!wash(locked: true)) }
    @Test func ignoresStayingComplete() { #expect(!wash(was: true, is: true)) }
    @Test func ignoresUncompleting() { #expect(!wash(was: true, is: false)) }

    // Re-checking the last chore fires again, at most once per 30 s per page.
    @Test func refiresAfterInterval() { #expect(wash(washedAgo: 31)) }
    @Test func refiresAtInterval() { #expect(wash(washedAgo: 30)) }
    @Test func holdsWithinInterval() { #expect(!wash(washedAgo: 12)) }

    // A chore added to the day re-arms the wash inside the re-fire limit.
    private let a = UUID(), b = UUID()
    @Test func newChoreRearms() { #expect(WashTrigger.rearms(oldChores: [a], newChores: [a, b])) }
    @Test func removedChoreDoesNotRearm() { #expect(!WashTrigger.rearms(oldChores: [a, b], newChores: [a])) }
    @Test func sameChoresDoNotRearm() { #expect(!WashTrigger.rearms(oldChores: [a, b], newChores: [a, b])) }
}
