import Testing
import CoreData
@testable import Choreganize

/// Covers the pure widget-snapshot construction (`WidgetSnapshotBuilder`) — what
/// the home-screen widget shows for "today" — plus the snapshot's computed
/// `total`/`remaining`.
struct WidgetSnapshotTests {

    private func makeContext() -> NSManagedObjectContext {
        CoreDataStack(inMemory: true).newBackgroundContext()
    }

    @Test func snapshotReflectsTodayCompletions() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            let dishes = CDChore.make(in: ctx, name: "Dishes", isDaily: true)
            CDChore.make(in: ctx, name: "Trash", isDaily: true)
            try ctx.save()
            dishes.recordCompletion(on: Date(), in: ctx)

            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            let snap = WidgetSnapshotBuilder.snapshot(from: chores, on: Date(), scopeLabel: "Personal")

            #expect(snap.total == 2)
            #expect(snap.remaining == 1)
            #expect(snap.scopeLabel == "Personal")
            #expect(snap.items.first { $0.name == "Dishes" }?.isDone == true)
            #expect(snap.items.first { $0.name == "Trash" }?.isDone == false)
        }
    }

    @Test func snapshotExcludesChoresNotDueToday() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            CDChore.make(in: ctx, name: "Daily", isDaily: true)
            // A weekly chore assigned to a weekday other than today is not shown.
            let elsewhere: Weekday = Weekday.today == .monday ? .tuesday : .monday
            CDChore.make(in: ctx, name: "Weekly Elsewhere", isDaily: false,
                         frequency: .weekly, assignedDay: elsewhere)
            try ctx.save()

            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            let snap = WidgetSnapshotBuilder.snapshot(from: chores, on: Date(), scopeLabel: "Personal")

            #expect(snap.items.map { $0.name } == ["Daily"])
        }
    }

    @Test func snapshotListsOpenChoresFirstThenByName() throws {
        let ctx = makeContext()
        try ctx.performAndWait {
            for name in ["Trash", "Dishes", "plants", "Beds"] {
                CDChore.make(in: ctx, name: name, isDaily: true)
            }
            try ctx.save()
            let now = Date()
            let chores = try ctx.fetch(NSFetchRequest<CDChore>(entityName: "CDChore"))
            for chore in chores where ["Dishes", "Beds"].contains(chore.name) {
                chore.recordCompletion(on: now, in: ctx)
            }

            let snap = WidgetSnapshotBuilder.snapshot(from: chores, on: now, scopeLabel: "Personal")

            // Case doesn't split the list: "plants" sorts with the capitalized names.
            #expect(snap.items.map { $0.name } == ["plants", "Trash", "Beds", "Dishes"])
        }
    }

    @Test func markingDoneMovesTheChoreDownAndSkipsOtherDays() throws {
        let now = Date()
        let ids = (0..<3).map { _ in UUID() }
        let snap = ChoreWidgetSnapshot(
            date: Calendar.current.startOfDay(for: now), scopeLabel: "Personal",
            items: zip(ids, ["Beds", "Dishes", "Trash"]).map { .init(id: $0, name: $1, isDone: false) })

        let updated = try #require(WidgetSnapshotBuilder.markingDone(ids[0], in: snap, on: now))
        #expect(updated.items.map { $0.name } == ["Dishes", "Trash", "Beds"])
        #expect(updated.remaining == 2)

        // Already done, not listed, or a snapshot from another day: nothing to change.
        #expect(WidgetSnapshotBuilder.markingDone(ids[0], in: updated, on: now) == nil)
        #expect(WidgetSnapshotBuilder.markingDone(UUID(), in: snap, on: now) == nil)
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: now))
        #expect(WidgetSnapshotBuilder.markingDone(ids[1], in: snap, on: tomorrow) == nil)
    }

    @Test func emptyChoresGivesEmptySnapshot() {
        let snap = WidgetSnapshotBuilder.snapshot(from: [], on: Date(), scopeLabel: "Household")
        #expect(snap.items.isEmpty)
        #expect(snap.total == 0)
        #expect(snap.remaining == 0)
        #expect(snap.scopeLabel == "Household")
    }
}
