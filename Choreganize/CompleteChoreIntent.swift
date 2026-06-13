import AppIntents
import CoreData

/// "Mark '<chore>' as complete for today." Runs in the app's process (no UI),
/// so it uses the live Core Data stack and CloudKit sync happens normally.
struct CompleteChoreIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete a Chore"
    static var description = IntentDescription("Marks a chore done for today.")
    static var openAppWhenRun = false

    @Parameter(title: "Chore")
    var chore: ChoreEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$chore) complete for today")
    }

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
}
