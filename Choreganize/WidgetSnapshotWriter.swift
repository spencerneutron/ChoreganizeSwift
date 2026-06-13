import Foundation
import CoreData
import WidgetKit

/// Publishes "today's chores" to the App Group so the widget can render without
/// touching Core Data. Called at the same moments as reminder rescheduling
/// (app foreground/background). Safe before the App Group is entitled — the
/// write becomes a no-op and the widget reload is harmless.
@MainActor
enum WidgetSnapshotWriter {
    static func update(using context: NSManagedObjectContext,
                       activeHousehold: CDHousehold?,
                       scopeLabel: String) {
        let today = Date()
        let request = NSFetchRequest<CDChore>(entityName: "CDChore")
        let chores = ((try? context.fetch(request)) ?? []).inScope(activeHousehold)
        let due = Scheduling.chores(chores, for: today)

        let items: [ChoreWidgetSnapshot.Item] = due.map { chore in
            ChoreWidgetSnapshot.Item(
                id: chore.objectID.uriRepresentation().absoluteString,
                name: chore.name ?? "Untitled",
                isDone: chore.isCompleted(on: today))
        }
        let snapshot = ChoreWidgetSnapshot(
            date: Calendar.current.startOfDay(for: today),
            scopeLabel: scopeLabel,
            items: items)

        guard let defaults = WidgetShared.defaults,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: WidgetShared.snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetShared.widgetKind)
    }
}
