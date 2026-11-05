import Testing
import Foundation
@testable import Choreganize

/// The completion wash fires only for a local completion that finishes an unlocked day.
struct CompletionWashTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func wash(was: Bool = false, is isDone: Bool = true, locked: Bool = false,
                      completedAgo: TimeInterval? = 1) -> Bool {
        WashTrigger.shouldWash(wasComplete: was, isComplete: isDone, isLocked: locked,
                               lastLocalCompletion: completedAgo.map { now.addingTimeInterval(-$0) },
                               now: now)
    }

    @Test func firesOnLocalCompletion() { #expect(wash()) }
    @Test func ignoresStaleCompletion() { #expect(!wash(completedAgo: 4)) }
    @Test func ignoresNoLocalCompletion() { #expect(!wash(completedAgo: nil)) }
    @Test func ignoresFutureCompletion() { #expect(!wash(completedAgo: -1)) }
    @Test func ignoresLockedDay() { #expect(!wash(locked: true)) }
    @Test func ignoresStayingComplete() { #expect(!wash(was: true, is: true)) }
    @Test func ignoresUncompleting() { #expect(!wash(was: true, is: false)) }
}
