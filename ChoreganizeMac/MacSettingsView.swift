import SwiftUI
import StoreKit

/// The Mac Settings scene (⌘,) — the Hub's settings content redistributed into
/// native panes: General (name, Work-view grouping), Reminders (the shared
/// notification prefs), Plus (entitlement + paywall), and Backups (the shared
/// backup/restore flow, including automatic backups).
struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gear") }
            NavigationStack { NotificationSettingsView() }
                .tabItem { Label("Reminders", systemImage: "bell.badge") }
            PlusSettingsPane()
                .tabItem { Label("Plus", systemImage: "sparkles") }
            NavigationStack { BackupRestoreView() }
                .tabItem { Label("Backups", systemImage: "externaldrive") }
        }
        .frame(width: 620, height: 560)
    }
}

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKeys.displayName) private var displayName: String = ""
    @AppStorage(SettingsKeys.workGrouping) private var workGrouping: String = WorkGrouping.none.rawValue

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $displayName)
                    .autocorrectionDisabled()
            } header: {
                Text("Your Name")
            } footer: {
                Text("Shown next to chores you complete when you share a household. Stored only on this device until then.")
            }

            Section {
                Picker("Group tasks by", selection: $workGrouping) {
                    ForEach(WorkGrouping.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("Work View")
            } footer: {
                Text("Group each day's tasks in the Work view by frequency or by room.")
            }

            Section("About") {
                LabeledContent("Version", value: Self.appVersion)
            }
        }
        .formStyle(.grouped)
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

private struct PlusSettingsPane: View {
    @ObservedObject private var entitlements = EntitlementStore.shared
    @State private var showPaywall = false
    #if DEBUG
    @AppStorage(EntitlementStore.debugOverrideKey) private var plusOverride = "default"
    #endif

    var body: some View {
        Form {
            Section {
                if entitlements.isPlus {
                    Label("Choreganize Plus — active", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        showPaywall = true
                    } label: {
                        Label("Get Choreganize Plus…", systemImage: "sparkles")
                    }
                }
            } footer: {
                Text(entitlements.isPlus
                     ? "Thanks for supporting Choreganize! Your purchase applies on iPhone and Mac (universal purchase), and shares with your Apple Family."
                     : "Member notifications, chore assignment, insights, and more — one purchase covers iPhone and Mac.")
            }

            #if DEBUG
            Section {
                Picker("Plus override", selection: $plusOverride) {
                    Text("StoreKit").tag("default")
                    Text("Force on").tag("on")
                    Text("Force off").tag("off")
                }
                .onChange(of: plusOverride) { _, _ in
                    entitlements.applyDebugOverride()
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Force the Plus entitlement to exercise gated UI without a purchase.")
            }
            #endif
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .frame(minWidth: 440, minHeight: 560)
        }
    }
}
