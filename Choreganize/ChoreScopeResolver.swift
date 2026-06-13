import CoreData

/// Resolves the active Solo/Household scope **without** the SwiftUI `AppModel`.
///
/// App Intents run in the app's process via a background launch, where the
/// SwiftUI scene (and its `@StateObject AppModel`) may not exist. This mirrors
/// `AppModel`'s scope logic against `UserDefaults` + `CoreDataStack` so Siri
/// actions operate on the same data the user currently sees in the app.
enum ChoreScopeResolver {
    /// Matches `AppModel.scopeKey`.
    private static let scopeKey = "activeScope"

    static var scope: AppScope {
        AppScope(rawValue: UserDefaults.standard.string(forKey: scopeKey) ?? "") ?? .solo
    }

    /// The household backing the active scope (`nil` in Solo). Prefers a
    /// household shared with us over one we own — same precedence as `AppModel`.
    @MainActor
    static func activeHousehold(in context: NSManagedObjectContext) -> CDHousehold? {
        guard scope == .household else { return nil }
        return household(in: CoreDataStack.shared.sharedStore, context: context)
            ?? household(in: nil, context: context)
    }

    /// All chores in the active scope.
    @MainActor
    static func scopedChores(in context: NSManagedObjectContext) -> [CDChore] {
        let request = NSFetchRequest<CDChore>(entityName: "CDChore")
        let all = (try? context.fetch(request)) ?? []
        return all.inScope(activeHousehold(in: context))
    }

    @MainActor
    private static func household(in store: NSPersistentStore?, context: NSManagedObjectContext) -> CDHousehold? {
        let request = NSFetchRequest<CDHousehold>(entityName: "CDHousehold")
        request.fetchLimit = 1
        request.sortDescriptors = [NSSortDescriptor(key: "createdDate", ascending: true)]
        if let store { request.affectedStores = [store] }
        return try? context.fetch(request).first
    }
}
