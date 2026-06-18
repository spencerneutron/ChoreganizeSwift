import SwiftUI
import AppIntents

/// The app's "Hub" — the single entry point for settings *and* support, reached
/// from the toolbar. It hosts reminder prefs (Phase B), the per-device display
/// name (groundwork for completion attribution), the Solo/Household scope +
/// sharing controls, help/tour replay (folded in from the old Support sheet),
/// and the place the deferred Plus paywall will live.
///
/// Presented as a sheet from `ContentView`; needs `AppModel` and
/// `OnboardingCoordinator` re-injected (sheets don't inherit environment
/// objects). The presenter's `onDismiss` runs `playPendingIfNeeded()` so a tour
/// requested here plays after the Hub closes.
struct HubView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @Environment(\.dismiss) private var dismiss

    /// Per-device display name. Latent in this phase; future attribution stamps
    /// it onto `CDCompletion`. Empty by default (no attribution shown).
    @AppStorage(SettingsKeys.displayName) private var displayName: String = ""

    /// How the Work view's day list is grouped (default none). Stored as the raw value.
    @AppStorage(SettingsKeys.workGrouping) private var workGrouping: String = WorkGrouping.none.rawValue

    #if DEBUG
    /// #65 A/B: which floating mode-switcher style to use (toggled in the Developer
    /// section below). Shares the key `ContentView` reads, so the switch is live.
    @AppStorage(SettingsKeys.switcherStyle) private var switcherStyleRaw = SwitcherStyle.menu.rawValue
    #endif

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Settings
                Section("Reminders") {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
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

                // MARK: Help & Support (folded from the old Support sheet)
                Section("Learn the app") {
                    Button {
                        onboarding.requestReplay(OnboardingStep.all)
                        dismiss()
                    } label: {
                        Label("Take the tour", systemImage: "play.circle")
                    }
                    ForEach(OnboardingStep.all) { step in
                        Button {
                            onboarding.requestReplay([step])
                            dismiss()
                        } label: {
                            Label(step.title, systemImage: step.systemImage)
                        }
                    }
                }

                // MARK: Siri (#66) — teach the app's declared AppIntents. SiriTipView
                // reflects the real phrases from `ChoreShortcuts`, so the guidance
                // can't drift from what Siri actually accepts.
                Section {
                    SiriTipView(intent: TodaysChoresIntent())
                    SiriTipView(intent: CompleteChoreIntent())
                    ShortcutsLink()
                } header: {
                    Text("Siri")
                } footer: {
                    Text("Hands-free with Siri — try “What Chores do I have today?” or “Complete a Chores task.” Tap a tip to add it, or open Shortcuts to see them all.")
                }

                Section {
                    Button {
                        // TODO: Integrate StoreKit 2 tips / Pro unlock (deferred paywall).
                    } label: {
                        Label("Support the app — coming soon", systemImage: "sparkles")
                    }
                    .disabled(true)
                } footer: {
                    Text("Thanks for using Choreganize! Ways to support development are coming soon. In the meantime, your feedback is invaluable.")
                }

                #if DEBUG
                Section {
                    Picker("View switcher", selection: $switcherStyleRaw) {
                        ForEach(SwitcherStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("A/B the floating Work/Edit/Calendar switcher. “Menu” is the production default; “Glass morph” is the experimental custom morph.")
                }
                #endif

                Section("About") {
                    LabeledContent("Version", value: Self.appVersion)
                }
            }
            .navigationTitle("Hub")
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
    static let workGrouping = "workGrouping"
    static let switcherStyle = "switcherStyle"
}

#if DEBUG
#Preview {
    HubView()
        .environmentObject(AppModel())
        .environmentObject(OnboardingCoordinator())
        .environment(\.managedObjectContext, PreviewStack.context)
}
#endif
