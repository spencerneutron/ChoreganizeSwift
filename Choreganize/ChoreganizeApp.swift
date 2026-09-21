import SwiftUI
import Metal
import CoreData

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
        // Pre-compile the calendar's perfect-day glow shader so the first 100%-day bar
        // doesn't hitch on first use (#57).
        GlowPrewarm.run()
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
                    case .active:
                        // CG-13 / #96: catch entitlement changes made outside the
                        // app (renewals, refunds, Ask to Buy, Family Sharing).
                        EntitlementStore.shared.syncOnForeground()
                        // CG-15 / #97: reconcile the household's propagated Plus
                        // flag (any async refresh above re-stamps via its own
                        // change notification).
                        model.syncHouseholdPlusStamp()
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
                // CG-05: widget rows deep-link via the `choreganize://` scheme. Route to
                // the targeted chore: switch to its scope so it's in view, then hand the
                // target to the UI via `model.deepLinkChore` — ContentView switches to
                // Work, WeekView snaps to today, and the day's page scrolls to + flashes
                // the row (see AppModel.deepLinkChore).
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    /// Resolves a `choreganize://` URL and routes to the targeted chore. Switches the
    /// active scope so a Household chore tapped from the widget is actually on screen,
    /// then sets `model.deepLinkChore` for the Work view to scroll to + highlight.
    @MainActor
    private func handleDeepLink(_ url: URL) {
        // `nil` outer means "not our URL"; inner `nil` means "ours, but not chore-specific"
        // (a plain open — the app foregrounds wherever it was, nothing more to do).
        guard let resolved = WidgetDeepLink.choreID(from: url) else { return }
        guard let choreID = resolved else { return }

        // Align the active scope with the chore so it's visible on today's DayPage.
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<CDChore>(entityName: "CDChore")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", choreID as CVarArg)
        if let chore = try? context.fetch(request).first {
            let targetScope: AppScope = chore.household == nil ? .solo : .household
            if model.scope != targetScope { model.setScope(targetScope) }
        }
        model.deepLinkChore = choreID
    }
}
