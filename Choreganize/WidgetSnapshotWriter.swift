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
        let due = Scheduling.chores(chores, for: date)
        let items: [ChoreWidgetSnapshot.Item] = due.map { chore in
            ChoreWidgetSnapshot.Item(
                id: chore.objectID.uriRepresentation().absoluteString,
                name: chore.name ?? "Untitled",
                isDone: chore.isCompleted(on: date))
        }
        return ChoreWidgetSnapshot(
            date: Calendar.current.startOfDay(for: date),
            scopeLabel: scopeLabel,
            items: items)
    }
}
