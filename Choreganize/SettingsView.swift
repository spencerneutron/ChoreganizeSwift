import SwiftUI

/// App settings — the foundation for the post-sharing feature wave.
///
/// It hosts reminder preferences (Phase B), the per-device display name
/// (groundwork for completion attribution — stored locally, stamped onto
/// completions later), the Solo/Household scope + sharing controls, and the
/// place the deferred Plus paywall will eventually live. Presented as a sheet
/// from `ContentView`; needs `AppModel` re-injected (sheets don't inherit
/// environment objects).
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Per-device display name. Latent in this phase; future attribution stamps
    /// it onto `CDCompletion`. Empty by default (no attribution shown).
    @AppStorage(SettingsKeys.displayName) private var displayName: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminders") {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                }

                Section {
                    TextField("Your name", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("Your Name")
                } footer: {
                    Text("Shown next to chores you complete when you share a household. Stored only on this device until then.")
                }

                Section("Household") {
                    Picker("Data", selection: Binding(
                        get: { model.scope },
                        set: { model.setScope($0) }
                    )) {
                        ForEach(AppScope.allCases) { scope in
                            Label(scope.title, systemImage: scope.systemImage).tag(scope)
                        }
                    }

                    if model.scope == .household {
                        LabeledContent("Sharing") {
                            HouseholdShareControl()
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Self.appVersion)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

/// Stable UserDefaults keys shared across the app (display name, future prefs).
enum SettingsKeys {
    static let displayName = "displayName"
}

#if DEBUG
#Preview {
    SettingsView()
        .environmentObject(AppModel())
        .environment(\.managedObjectContext, PreviewStack.context)
}
#endif
