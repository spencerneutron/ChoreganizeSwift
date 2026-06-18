import SwiftUI
import Metal

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
        #if DEBUG
        // Screenshot/demo seed for the simulator (no-op unless CHOREGANIZE_SEED_JSON
        // is set; see the `deploy` skill). Release builds never include this.
        JSONImporter.seedFromEnvironmentIfNeeded()
        #endif

        // Pre-warm the GPU/Metal stack off the main thread at launch, so the first
        // Liquid Glass morph (the floating switcher's first expand) doesn't pay the
        // ~0.8s AGXMetal/RenderBox driver load on the main thread (cz_device12 hang).
        Task.detached(priority: .utility) { _ = MTLCreateSystemDefaultDevice() }
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
                    // On foreground/background, refresh both the dated chore reminders
                    // (local notifications can't recompute "still unresolved" at fire
                    // time, so we re-evaluate them) and the widget's App Group snapshot.
                    if phase == .active || phase == .background {
                        let context = CoreDataStack.shared.viewContext
                        let household = model.activeHousehold
                        let badgeHousehold = model.resolvedHousehold
                        let isForeground = phase == .active
                        let householdID = household?.objectID
                        let scopeLabel = model.scope == .household ? model.householdName : AppScope.solo.title
                        Task {
                            // Reminders only need (re)scheduling when the app leaves the
                            // foreground — local notifications fire while we're away, and the
                            // plan only changes via data or prefs (prefs reschedule themselves
                            // in NotificationSettingsView). Re-running on every foreground was
                            // wasteful and spammed the scheduling log (#61).
                            if !isForeground {
                                await NotificationManager.reschedule(using: context, activeHousehold: household)
                            }
                            await NotificationManager.refreshBadge(using: context, household: badgeHousehold)
                            if isForeground { await NotificationManager.clearDeliveredReminders() }
                            // Off the main thread: the App Group write + chore fetch are disk
                            // I/O that otherwise hitch scene activation (cz_device10 hang).
                            await WidgetSnapshotWriter.update(householdID: householdID, scopeLabel: scopeLabel)
                        }
                    }
                }
        }
    }
}
