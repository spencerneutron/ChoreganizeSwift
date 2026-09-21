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

    /// CG-12 / #95: live Plus entitlement for the Support section.
    @ObservedObject private var entitlements = EntitlementStore.shared
    @State private var showPaywall = false

    #if DEBUG
    /// #65 A/B: which floating mode-switcher style to use (toggled in the Developer
    /// section below). Shares the key `ContentView` reads, so the switch is live.
    @AppStorage(SettingsKeys.switcherStyle) private var switcherStyleRaw = SwitcherStyle.morph.rawValue
    /// CG-12 / #95: force the Plus gate on/off to exercise gated UI in the sim.
    @AppStorage(EntitlementStore.debugOverrideKey) private var plusOverride = "default"
    #endif

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Streaks (#93, basic) — current run + best-ever record, derived
                // from the calendar's perfect-day machinery (no new persistence).
                Section {
                    StreakSummaryView()
                } header: {
                    Text("Streaks")
                } footer: {
                    Text("A streak is a run of days where every chore was done. Keep it going!")
                }

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

                // MARK: Data — JSON backup/restore of Personal chores & history (#63).
                Section {
                    NavigationLink {
                        BackupRestoreView()
                    } label: {
                        Label("Backup & Restore", systemImage: "externaldrive")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export your Personal chores and history to a file, or restore from a backup.")
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

                // MARK: Plus (CG-12 / #95)
                Section {
                    Button {
                        showPaywall = true
                    } label: {
                        if entitlements.isPlus {
                            Label("Choreganize Plus — active", systemImage: "sparkles")
                        } else {
                            Label("Get Choreganize Plus…", systemImage: "sparkles")
                        }
                    }
                } footer: {
                    Text(entitlements.isPlus
                         ? "Thanks for supporting Choreganize! Manage your plan from the Plus screen."
                         : "Member notifications, chore assignment, insights, and more — and it keeps development going.")
                }

                #if DEBUG
                Section {
                    Picker("View switcher", selection: $switcherStyleRaw) {
                        ForEach(SwitcherStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
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
                    Text("A/B the floating Work/Edit/Calendar switcher, and force the Plus entitlement to exercise gated UI without a purchase.")
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
            .sheet(isPresented: $showPaywall) {
                PaywallView()
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

/// The Hub's streak readout (#93, basic): the current run of perfect days and the
/// best-ever record, derived from the same perfect-day rule the calendar uses
/// (`CalendarStreaks`). No new persistence — it recomputes from existing chores and
/// completions. A synced "streak freeze" token is explicitly deferred.
private struct StreakSummaryView: View {
    @EnvironmentObject private var model: AppModel
    // Same prefetch as the calendar so the per-day scoring doesn't fault relationships
    // one row at a time on the main thread.
    @FetchRequest(fetchRequest: displayChoresFetchRequest()) private var allChores: FetchedResults<CDChore>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDLockedDay.date)]) private var lockedDays: FetchedResults<CDLockedDay>

    private var summary: CalendarStreaks.Summary {
        let scope = model.activeHousehold
        let perfect = CalendarStreaks.perfectDays(
            scopedChores: Array(allChores).inScope(scope),
            scopedLocks: Array(lockedDays).inScope(scope))
        return CalendarStreaks.summary(for: perfect)
    }

    var body: some View {
        let s = summary
        HStack(spacing: 0) {
            stat(value: s.current, caption: "Current", systemImage: "flame.fill",
                 tint: s.current > 0 ? .orange : .secondary)
            Divider()
            stat(value: s.longest, caption: "Record", systemImage: "trophy.fill",
                 tint: s.longest > 0 ? .yellow : .secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current streak \(s.current) \(s.current == 1 ? "day" : "days"), best \(s.longest) \(s.longest == 1 ? "day" : "days").")
    }

    @ViewBuilder
    private func stat(value: Int, caption: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text("\(value)")
                    .font(.title2).fontWeight(.semibold)
                    .contentTransition(.numericText())
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview {
    HubView()
        .environmentObject(AppModel())
        .environmentObject(OnboardingCoordinator())
        .environment(\.managedObjectContext, PreviewStack.context)
}
#endif
