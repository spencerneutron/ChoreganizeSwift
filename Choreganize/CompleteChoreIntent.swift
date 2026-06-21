import AppIntents
#if !WIDGET_EXTENSION
import CoreData
#endif

/// "Mark '<chore>' as complete for today." Runs in the app's process (no UI),
/// so it uses the live Core Data stack and CloudKit sync happens normally.
///
/// The home-screen widget references this intent via `Button(intent:)` (CG-02), so
/// the type is compiled into the widget extension too — but the widget never owns
/// Core Data (no iCloud entitlement; the store isn't in the App Group), and the
/// system runs the intent in the **app's** process. The Core Data `perform()` body
/// is therefore gated out of the widget build (`WIDGET_EXTENSION`); the widget only
/// needs the parameter shape to construct the intent.
struct CompleteChoreIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete a Chore"
    static var description = IntentDescription("Marks a chore done for today.")
    static var openAppWhenRun = false

    @Parameter(title: "Chore")
    var chore: ChoreEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$chore) complete for today")
    }

    init() {}

    /// Constructs the intent from a widget snapshot row's stable UUID + name, so
    /// the home-screen widget can fire tap-to-complete WITHOUT touching Core Data
    /// (the `ChoreEntity` is built directly, not resolved via its query). `perform()`
    /// still runs in the app and resolves the chore by `id`.
    init(choreID: UUID, name: String) {
        self.chore = ChoreEntity(id: choreID, name: name)
    }

#if WIDGET_EXTENSION
    // Stub for the widget build: the system runs this intent in the app's process,
    // never the widget's, so this body is never executed here. It exists only so the
    // type compiles into the widget extension (which has no Core Data).
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "")
    }
#else
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<CDChore>(entityName: "CDChore")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", chore.id as CVarArg)

        guard let target = try? context.fetch(request).first else {
            return .result(dialog: "I couldn't find that chore.")
        }
        let name = target.name ?? "that chore"
        if target.isCompleted(on: Date()) {
            return .result(dialog: "‘\(name)’ is already done today.")
        }
        target.recordCompletion(on: Date(), in: context)
        return .result(dialog: "Done — marked ‘\(name)’ complete for today.")
    }
#endif
}
