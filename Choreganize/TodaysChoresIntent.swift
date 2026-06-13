import AppIntents
import CoreData

/// "What chores do I have to do today?" — speaks back the unresolved chores in
/// the active scope. Read-only.
struct TodaysChoresIntent: AppIntent {
    static var title: LocalizedStringResource = "Today's Chores"
    static var description = IntentDescription("Lists the chores you still need to do today.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = CoreDataStack.shared.viewContext
        let scoped = ChoreScopeResolver.scopedChores(in: context)
        let today = Date()
        let remaining = Scheduling.chores(scoped, for: today)
            .filter { $0.needsAttention(on: today) && !$0.isCompleted(on: today) }
            .compactMap { $0.name }
        return .result(dialog: IntentDialog(stringLiteral: Self.spokenSummary(for: remaining)))
    }

    /// Builds the spoken sentence. Pure/testable.
    static func spokenSummary(for names: [String]) -> String {
        guard !names.isEmpty else { return "You're all caught up — no chores left today." }
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count == 1
            ? "You have 1 chore left today: \(list)."
            : "You have \(names.count) chores left today: \(list)."
    }
}
