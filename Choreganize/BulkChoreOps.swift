import CoreData

/// Bulk operations on chores selected by object ID — extracted from
/// `ChoreListView` so the multi-select Move/Delete logic is unit-testable
/// without a SwiftUI `List`/`FetchedResults`.
enum BulkChoreOps {
    /// Reassigns every chore in `ids` to `area` (or to no area when `nil`).
    static func move(_ ids: Set<NSManagedObjectID>, to area: CDArea?, in context: NSManagedObjectContext) {
        for chore in chores(ids, in: context) { chore.area = area }
        saveIfNeeded(context)
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
