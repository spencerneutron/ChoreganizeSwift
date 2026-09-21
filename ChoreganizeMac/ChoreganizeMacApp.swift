import SwiftUI
import Metal
import CoreData

/// The macOS companion app. Same Core Data + CloudKit spine as the iPhone app
/// (identical container, App Group, and StoreKit products — the Mac binary
/// joins the iOS app record as a universal purchase); the shell is macOS-native:
/// a NavigationSplitView window, a Settings scene, a menu-bar Today checklist,
/// and full keyboard commands.
@main
struct ChoreganizeMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var ui = MacUIState.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _model = StateObject(wrappedValue: AppModel())
        Log.setLevel(.trace)
        // Same GPU/shader pre-warms as iOS: the calendar's perfect-day glow
        // shader is shared, and the first Metal device load is just as laggy
        // on the Mac's main thread.
        Task.detached(priority: .utility) { _ = MTLCreateSystemDefaultDevice() }
        GlowPrewarm.run()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MacRootView()
                .environmentObject(model)
                .environmentObject(ui)
                .environment(\.managedObjectContext, CoreDataStack.shared.viewContext)
                .frame(minWidth: 760, minHeight: 480)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background, .inactive:
                        CoreDataStack.shared.saveViewContext()
                    case .active:
                        // CG-13 / #96: catch entitlement changes made outside the
                        // app (renewals, refunds, Ask to Buy, Family Sharing).
                        EntitlementStore.shared.syncOnForeground()
                        // CG-15 / #97: reconcile the household's propagated Plus flag.
                        model.syncHouseholdPlusStamp()
                    default:
                        break
                    }
                    if phase == .active || phase == .background {
                        let context = CoreDataStack.shared.viewContext
                        let household = model.activeHousehold
                        let badgeHousehold = model.resolvedHousehold
                        let isForeground = phase == .active
                        Task {
                            // Same policy as iOS: reminders reschedule when leaving
                            // the foreground, the Dock badge refreshes both ways.
                            if !isForeground {
                                await NotificationManager.reschedule(using: context, activeHousehold: household)
                            }
                            await NotificationManager.refreshBadge(using: context, household: badgeHousehold)
                            if isForeground { await NotificationManager.clearDeliveredReminders() }
                        }
                    }
                }
                // iCloud share links (accept into the shared store) and
                // `choreganize://` deep links (Continuity widgets, notifications).
                .onOpenURL { url in
                    if appDelegate.acceptShareLink(url) { return }
                    handleDeepLink(url)
                }
        }
        .defaultSize(width: 980, height: 640)
        .commands { MacCommands() }

        Settings {
            MacSettingsView()
                .environmentObject(model)
                .environment(\.managedObjectContext, CoreDataStack.shared.viewContext)
        }

        MenuBarExtra {
            MenuBarTodayView()
                .environmentObject(model)
                .environment(\.managedObjectContext, CoreDataStack.shared.viewContext)
        } label: {
            Image(systemName: "checklist")
        }
        .menuBarExtraStyle(.window)
    }

    /// Resolves a `choreganize://` URL and routes to the targeted chore, same
    /// contract as the iOS shell: align the scope, then hand the target to the
    /// Work surface via `model.deepLinkChore`.
    @MainActor
    private func handleDeepLink(_ url: URL) {
        guard let resolved = WidgetDeepLink.choreID(from: url) else { return }
        guard let choreID = resolved else { return }

        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<CDChore>(entityName: "CDChore")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", choreID as CVarArg)
        if let chore = try? context.fetch(request).first {
            let targetScope: AppScope = chore.household == nil ? .solo : .household
            if model.scope != targetScope { model.setScope(targetScope) }
        }
        ui.surface = .work
        model.deepLinkChore = choreID
    }
}
