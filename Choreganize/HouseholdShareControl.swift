import SwiftUI
import CoreData

/// Toolbar control for the active Household: shows share status and offers
/// share / manage / rename. Shown only in Household scope. The share/manage
/// actions need CloudKit; rename works offline (it's a synced attribute).
struct HouseholdShareControl: View {
    @EnvironmentObject private var model: AppModel
    @State private var info: HouseholdShareInfo = .notShared
    @State private var showRename = false
    @State private var draftName = ""

    private var cloudKitEnabled: Bool { CoreDataStack.shared.cloudKitEnabled }

    var body: some View {
        Menu {
            if cloudKitEnabled {
                Text(info.statusText)
                Button {
                    HouseholdSharing.share(model.ensureHousehold())
                } label: {
                    Label(info.isShared ? "Manage Sharing…" : "Share Household…",
                          systemImage: info.isShared ? "person.2.fill" : "square.and.arrow.up")
                }
            }
            // CG-11 / #64: bring Personal items into the household (owners
            // move, participants add copies — the sheet explains which).
            Button {
                model.showMigrationPicker = true
            } label: {
                Label("Add Personal Items…", systemImage: "tray.and.arrow.up")
            }
            Button {
                draftName = model.activeHousehold?.name ?? "Household"
                showRename = true
            } label: {
                Label("Rename Household…", systemImage: "pencil")
            }
        } label: {
            Image(systemName: menuIcon)
        }
        .task(id: model.scope) { refresh() }
        // These notifications post on background queues — NSPersistentStoreRemoteChange
        // from Core Data during CloudKit import, householdShareDidChange from sharing
        // callbacks — so hop to the main thread before refresh() mutates @State. Without
        // this SwiftUI faults with "Publishing changes from background threads is not
        // allowed" on every sync batch (confirmed in device logs, not a console artifact).
        .onReceive(NotificationCenter.default.publisher(for: .householdShareDidChange).receive(on: RunLoop.main)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange).receive(on: RunLoop.main)) { _ in refresh() }
        .alert("Rename Household", isPresented: $showRename) {
            TextField("Name", text: $draftName)
            Button("Save") {
                HouseholdSharing.rename(model.ensureHousehold(), to: draftName)
                model.refreshHouseholdName()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var menuIcon: String {
        guard cloudKitEnabled else { return "ellipsis.circle" }
        return info.isShared ? "person.2.fill" : "person.crop.circle.badge.plus"
    }

    private func refresh() {
        guard cloudKitEnabled, let household = model.activeHousehold else {
            info = .notShared
            return
        }
        info = HouseholdSharing.shareInfo(for: household) ?? .notShared
    }
}
