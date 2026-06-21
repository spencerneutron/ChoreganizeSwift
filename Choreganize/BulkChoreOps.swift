import CoreData

/// A single facet of a chore to bulk-change across a selection (#55). Each case
/// keeps the model's daily/frequency/day invariant intact (daily ⇒ no frequency
/// and `assignedDay == .all`; scheduled ⇒ a real frequency, day optional).
enum ChoreFacetChange: Equatable {
    case makeDaily               // "Every Day" — clears frequency + pins assignedDay to .all
    case frequency(Frequency)    // a weekly/monthly/yearly rhythm — implies non-daily
    case day(Weekday?)           // a specific weekday, or `nil` for Unassigned — implies non-daily
}

/// Bulk operations on chores selected by object ID — extracted from
/// `ChoreListView` so the multi-select Change/Move/Delete logic is unit-testable
/// without a SwiftUI `List`/`FetchedResults`.
enum BulkChoreOps {
    /// Reassigns every chore in `ids` to `area` (or to no area when `nil`).
    static func move(_ ids: Set<NSManagedObjectID>, to area: CDArea?, in context: NSManagedObjectContext) {
        for chore in chores(ids, in: context) { chore.area = area }
        saveIfNeeded(context)
    }

    /// Records a completion on `date` for every chore in `ids`, skipping any that
    /// are already complete that day (CG-08 "Mark all done"). Mirrors
    /// `CDChore.recordCompletion` semantics but saves once for the whole batch.
    static func markAllDone(_ ids: Set<NSManagedObjectID>, on date: Date, in context: NSManagedObjectContext) {
        for chore in chores(ids, in: context) where !chore.isCompleted(on: date) {
            CDCompletion.make(in: context, date: date, chore: chore, household: chore.household)
        }
        saveIfNeeded(context)
    }

    /// Applies `change` to one facet of every chore in `ids`, leaving the others
    /// untouched. Used to correct entry mistakes / handle a move en masse.
    static func change(_ ids: Set<NSManagedObjectID>, _ change: ChoreFacetChange, in context: NSManagedObjectContext) {
        for chore in chores(ids, in: context) { apply(change, to: chore) }
        saveIfNeeded(context)
    }

    /// Mirrors `NewChoreView`/`EditChoreView` save semantics so a bulk change can
    /// never strand a chore in an inconsistent daily/scheduled state.
    private static func apply(_ change: ChoreFacetChange, to chore: CDChore) {
        switch change {
        case .makeDaily:
            chore.isDaily = true
            chore.frequencyValue = nil
            chore.assignedDayValue = .all
        case .frequency(let freq):
            let wasDaily = chore.isDaily
            chore.isDaily = false
            chore.frequencyValue = freq
            if wasDaily { chore.assignedDayValue = nil }   // .all is a daily-only marker
        case .day(let weekday):
            chore.isDaily = false
            chore.assignedDayValue = weekday
            if chore.frequencyValue == nil { chore.frequencyValue = .weekly }   // ensure a rhythm
        }
    }

    /// Deletes every chore in `ids`. Their completions cascade away (model rule).
    static func delete(_ ids: Set<NSManagedObjectID>, in context: NSManagedObjectContext) {
        for chore in chores(ids, in: context) { context.delete(chore) }
        saveIfNeeded(context)
    }

    private static func chores(_ ids: Set<NSManagedObjectID>, in context: NSManagedObjectContext) -> [CDChore] {
        guard !ids.isEmpty else { return [] }
        let request = NSFetchRequest<CDChore>(entityName: "CDChore")
        return ((try? context.fetch(request)) ?? []).filter { ids.contains($0.objectID) }
    }

    private static func saveIfNeeded(_ context: NSManagedObjectContext) {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
