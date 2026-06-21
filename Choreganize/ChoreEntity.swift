import AppIntents
#if !WIDGET_EXTENSION
import CoreData
#endif

/// An App Intents representation of a chore, so Siri/Shortcuts can refer to one
/// by name. Identified by the chore's stable, synced `UUID` (never `objectID`,
/// which isn't stable across store reloads).
///
/// Also compiled into the widget extension so it can build a `CompleteChoreIntent`
/// from a snapshot row (CG-02). The widget never resolves entities (no Core Data),
/// so the Core Data query + initializer below are gated out of the widget build.
struct ChoreEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Chore" }
    static var defaultQuery = ChoreEntityQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

#if !WIDGET_EXTENSION
extension ChoreEntity {
    init?(_ chore: CDChore) {
        guard let id = chore.id else { return nil }
        self.init(id: id, name: chore.name ?? "Untitled")
    }
}
#endif

#if WIDGET_EXTENSION
/// Widget-build stub: the widget never resolves chore entities (it builds them
/// directly from the snapshot), so this returns nothing. Exists only so
/// `ChoreEntity` has a `defaultQuery` in the widget build.
struct ChoreEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [ChoreEntity] { [] }
    func entities(matching string: String) async throws -> [ChoreEntity] { [] }
    func suggestedEntities() async throws -> [ChoreEntity] { [] }
}
#else
/// Resolves `ChoreEntity` values for Siri — by id (re-resolution), by spoken
/// name (string match), and as suggestions (today's actionable chores). All
/// queries run against the active scope on the main context.
struct ChoreEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [ChoreEntity] {
        await MainActor.run {
            let ids = Set(identifiers)
            return ChoreScopeResolver
                .scopedChores(in: CoreDataStack.shared.viewContext)
                .compactMap(ChoreEntity.init)
                .filter { ids.contains($0.id) }
        }
    }

    func entities(matching string: String) async throws -> [ChoreEntity] {
        await MainActor.run {
            let needle = string.lowercased()
            return ChoreScopeResolver
                .scopedChores(in: CoreDataStack.shared.viewContext)
                .compactMap(ChoreEntity.init)
                .filter { $0.name.lowercased().contains(needle) }
        }
    }

    func suggestedEntities() async throws -> [ChoreEntity] {
        await MainActor.run {
            let scoped = ChoreScopeResolver.scopedChores(in: CoreDataStack.shared.viewContext)
            return Scheduling.chores(scoped, for: Date()).compactMap(ChoreEntity.init)
        }
    }
}
#endif
