import Testing
import CoreData
@testable import Choreganize

/// Coverage for retroactively editing completions on a past day (#57 Part 2): the
/// record/undo round-trip on a past date via the existing completion API, which the
/// `LogCompletionSheet` checklist drives (tap to record, tap again to remove).
struct LogCompletionTests {

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    @Test func recordsCompletionOnAPastDayAndIsIdempotent() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let cal = Calendar.current
            let pastDay = cal.date(byAdding: .day, value: -10, to: cal.startOfDay(for: Date()))!
            let chore = CDChore.make(in: ctx, name: "Vacuum", isDaily: false,
                                     frequency: .weekly, assignedDay: .monday)
            #expect(!chore.isCompleted(on: pastDay))

            chore.recordCompletion(on: pastDay, in: ctx)
            #expect(chore.isCompleted(on: pastDay))

            // Logging the same day again must not add a duplicate completion.
            chore.recordCompletion(on: pastDay, in: ctx)
            let sameDay = chore.completionsArray.filter {
                cal.isDate($0.date ?? .distantPast, inSameDayAs: pastDay)
            }
            #expect(sameDay.count == 1)
        }
    }

    @Test func undoRemovesARetroactiveCompletion() throws {
        let ctx = makeContext()
        ctx.performAndWait {
            let cal = Calendar.current
            let pastDay = cal.date(byAdding: .day, value: -5, to: cal.startOfDay(for: Date()))!
            let chore = CDChore.make(in: ctx, name: "Mop", isDaily: true)

            chore.recordCompletion(on: pastDay, in: ctx)
            #expect(chore.isCompleted(on: pastDay))

            chore.removeCompletion(on: pastDay, in: ctx)
            #expect(!chore.isCompleted(on: pastDay))
        }
    }
}
