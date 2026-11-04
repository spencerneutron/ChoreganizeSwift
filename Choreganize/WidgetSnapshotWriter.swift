import Foundation
import CoreData
import WidgetKit

/// Publishes "today's chores" to the App Group so the widget can render without
/// touching Core Data. Called at the same moments as reminder rescheduling
/// (app foreground/background). Safe before the App Group is entitled — the
/// write becomes a no-op and the widget reload is harmless.
enum WidgetSnapshotWriter {
    /// Builds and publishes the snapshot on a **background** context. The chore
    /// fetch and the App Group container write are disk I/O — running them on the
    /// main thread hitched the UI at scene activation (cz_device10 hang triage), so
    /// the household is passed by `objectID` and re-resolved on the private queue.
    static func update(householdID: NSManagedObjectID?,
                       scopeLabel: String,
                       stack: CoreDataStack = .shared) async {
        let context = stack.newBackgroundContext()
        await context.perform {
            let household = householdID.flatMap { try? context.existingObject(with: $0) as? CDHousehold }
            let request = NSFetchRequest<CDChore>(entityName: "CDChore")
            let chores = ((try? context.fetch(request)) ?? []).inScope(household)
            let snapshot = WidgetSnapshotBuilder.snapshot(from: chores, on: Date(), scopeLabel: scopeLabel)

            guard let defaults = WidgetShared.defaults,
                  let data = try? JSONEncoder().encode(snapshot) else { return }
            defaults.set(data, forKey: WidgetShared.snapshotKey)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetShared.widgetKind)
        }
    }
}

/// Pure construction of the widget snapshot from chores — the data the widget
/// shows. Separated from the App Group write so it can be unit-tested.
enum WidgetSnapshotBuilder {
    static func snapshot(from chores: [CDChore], on date: Date, scopeLabel: String) -> ChoreWidgetSnapshot {
        let calendar = Calendar.current
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        return ChoreWidgetSnapshot(
            date: calendar.startOfDay(for: date),
            scopeLabel: scopeLabel,
            items: items(from: chores, on: date),
            nextDay: nextDay.map { items(from: chores, on: $0) })
    }

    private static func items(from chores: [CDChore], on date: Date) -> [ChoreWidgetSnapshot.Item] {
        let due = Scheduling.chores(chores, for: date)
        return ordered(due.compactMap { chore in
            // Carry the chore's STABLE synced UUID (not the Core Data objectID URI,
            // which isn't stable across store reloads and can't be resolved by
            // CompleteChoreIntent's UUID predicate). A chore with no id is skipped.
            guard let id = chore.id else { return nil }
            return ChoreWidgetSnapshot.Item(
                id: id,
                name: chore.name ?? "Untitled",
                isDone: chore.isCompleted(on: date))
        })
    }

    /// Open chores first, since the widget lists what still needs doing and can only
    /// show so many; then the done ones. By name within each (as Finder sorts), then by
    /// id so equal names keep their places. The fetch has no order, so without this
    /// the rows shuffled between updates.
    static func ordered(_ items: [ChoreWidgetSnapshot.Item]) -> [ChoreWidgetSnapshot.Item] {
        items.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id.uuidString < b.id.uuidString
            }
        }
    }

}
