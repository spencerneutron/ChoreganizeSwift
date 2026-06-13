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
        .onReceive(NotificationCenter.default.publisher(for: .householdShareDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in refresh() }
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
