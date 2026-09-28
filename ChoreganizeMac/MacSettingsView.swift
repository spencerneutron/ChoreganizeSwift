import SwiftUI
import StoreKit

/// The Mac Settings scene (⌘,) — the Hub's settings content redistributed into
/// native panes: General (name, Work-view grouping), Reminders (the shared
/// notification prefs), Plus (entitlement + paywall), and Backups (the shared
/// backup/restore flow, including automatic backups). Every pane is a grouped
/// form at the same width, sized to its content; the shared iOS views render
/// Mac controls and copy themselves (checkboxes, sheets, Finder).
struct MacSettingsView: View {
    /// Settings reopens on the pane you left it on (the Mac convention).
    @AppStorage(MacSettingsPane.storageKey) private var pane: MacSettingsPane = .general

    var body: some View {
        TabView(selection: $pane) {
            GeneralSettingsPane()
                .settingsPane(height: 360)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(MacSettingsPane.general)
            NotificationSettingsView()
                .settingsPane(height: 480)
                .tabItem { Label("Reminders", systemImage: "bell.badge") }
                .tag(MacSettingsPane.reminders)
            PlusSettingsPane()
                .settingsPane(height: 280)
                .tabItem { Label("Plus", systemImage: "sparkles") }
                .tag(MacSettingsPane.plus)
            BackupRestoreView()
                .settingsPane(height: 480)
                .tabItem { Label("Backups", systemImage: "externaldrive") }
                .tag(MacSettingsPane.backups)
        }
    }
}

private extension View {
    /// One Settings pane: the grouped form style (margins, section cards) at the
    /// window's standard width and a height fitted to the pane. Taller content
    /// scrolls inside the pane; the window resizes as you switch panes.
    func settingsPane(height: CGFloat) -> some View {
        formStyle(.grouped)
            .frame(width: 560, height: height)
    }
}

/// The Settings panes, persisted so the window reopens where you left it.
enum MacSettingsPane: String, CaseIterable {
    case general, reminders, plus, backups

    static let storageKey = "mac.settingsPane"
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
                OneOffLimitToggle()
            } header: {
                Text("Work View")
            } footer: {
                Text(model.activeHousehold == nil
                     ? "Group each day's tasks by frequency or by room. One-offs stay at the top, a few at a time."
                     : "Group each day's tasks by frequency or by room. The one-off limit applies to everyone in the household.")
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
