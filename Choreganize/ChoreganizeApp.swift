import SwiftUI

@main
struct ChoreganizeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _model = StateObject(wrappedValue: AppModel())
        Log.setLevel(.trace)
        // Checkpoint 1: stand up Core Data + CloudKit and import legacy JSON.
        // The UI below still reads the old AppModel/JSON, so behavior is unchanged;
        // this just populates and syncs the new store in the background.
        JSONImporter.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environment(\.managedObjectContext, CoreDataStack.shared.viewContext)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background, .inactive:
                        CoreDataStack.shared.saveViewContext()
                    default:
                        break
                    }
                    // Re-evaluate chore reminders against the current store whenever
                    // we foreground or background (local notifications can't recompute
                    // "still unresolved" at fire time, so we refresh dated reminders).
                    if phase == .active || phase == .background {
                        Task {
                            await NotificationManager.reschedule(
                                using: CoreDataStack.shared.viewContext,
                                activeHousehold: model.activeHousehold)
                        }
                    }
                }
        }
    }
}
