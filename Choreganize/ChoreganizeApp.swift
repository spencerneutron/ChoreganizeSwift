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
                    // Republish today's chores to the App Group so the widget
                    // stays current (no-op until the App Group is entitled).
                    if phase == .active || phase == .background {
                        WidgetSnapshotWriter.update(
                            using: CoreDataStack.shared.viewContext,
                            activeHousehold: model.activeHousehold,
                            scopeLabel: model.scope == .household ? model.householdName : "Solo")
                    }
                }
        }
    }
}
