import SwiftUI
import UIKit
import UserNotifications

/// Reminder preferences (Phase B). Toggling on requests notification
/// authorization; time + day changes write through to `NotificationManager`
/// and re-schedule. Prefs are per-device; see `NotificationManager` for why we
/// re-schedule concrete dated reminders rather than one repeating trigger.
struct NotificationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.managedObjectContext) private var context

    @AppStorage(NotificationManager.Keys.enabled) private var enabled = false
    @AppStorage(NotificationManager.Keys.hour) private var hour = 18
    @AppStorage(NotificationManager.Keys.minute) private var minute = 0
    /// CG-14 / #62: member-completion alerts (Plus). Default on; Plus gates delivery.
    @AppStorage(MemberCompletionNotifier.Keys.enabled) private var memberAlerts = true
    @ObservedObject private var entitlements = EntitlementStore.shared

    @State private var selectedDays: Set<Weekday> = Set(Weekday.standardCases)
    @State private var badgeScopes: Set<AppScope> = Set(AppScope.allCases)
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var didLoad = false

    private var deniedInSystem: Bool { status == .denied }

    /// CG-15 / #97: own Plus OR the household's propagated flag.
    private var effectivePlus: Bool {
        entitlements.isPlus || model.resolvedHousehold?.plusEnabled == true
    }

    var body: some View {
        Form {
            Section {
                Toggle("Daily reminders", isOn: $enabled)
                    .disabled(deniedInSystem)
            } footer: {
                Text("Get reminded about chores that still need attention.")
            }

            if deniedInSystem {
                Section {
                    Label("Notifications are off for Choreganize in iOS Settings.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("Open iOS Settings") { openSystemSettings() }
                }
            }

            if enabled && !deniedInSystem {
                Section("Time") {
                    DatePicker("Remind me at", selection: timeBinding, displayedComponents: .hourAndMinute)
                }
                Section {
                    ForEach(Weekday.standardCases) { day in
                        Button {
                            toggleDay(day)
                        } label: {
                            HStack {
                                Text(day.displayName).foregroundStyle(.primary)
                                Spacer()
                                if selectedDays.contains(day) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Days")
                } footer: {
                    Text("You're only reminded on days that still have chores to do.")
                }
            }

            // CG-14 / #62: household activity alerts (Plus). Independent of the
            // daily-reminder toggle — these fire on sync when ANOTHER member
            // completes a chore, not on a schedule. The gate is household-
            // scoped (CG-15 / #97): any member's Plus lights it up for all.
            if !deniedInSystem {
                Section {
                    if effectivePlus {
                        Toggle("Member completions", isOn: $memberAlerts)
                    } else {
                        Label("Member completions", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Household Activity")
                } footer: {
                    Text(effectivePlus
                         ? "Get notified when another household member completes a chore."
                         : "Get notified when another household member completes a chore. Requires Choreganize Plus (Hub ▸ Get Choreganize Plus).")
                }
            }

            // Independent of the reminder toggle above: the badge reflects today's
            // open chores per these scopes whenever notifications are authorized.
            if !deniedInSystem {
                Section {
                    ForEach(AppScope.allCases) { scope in
                        Button {
                            toggleBadgeScope(scope)
                        } label: {
                            HStack {
                                Label(scope.title, systemImage: scope.systemImage)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if badgeScopes.contains(scope) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("App Icon Badge")
                } footer: {
                    Text("Badge the app icon with today's unfinished chores. Pick which lists it counts; uncheck both to hide it.")
                }
            }
        }
        .navigationTitle("Reminders")
        .task {
            status = await NotificationManager.authorizationStatus()
            // Single, low-frequency auth prompt: only the first time the user opens
            // this screen (never on launch/foreground), so we don't badger them.
            if status == .notDetermined {
                _ = await NotificationManager.requestAuthorization()
                status = await NotificationManager.authorizationStatus()
            }
            if !didLoad {
                selectedDays = NotificationManager.days
                badgeScopes = NotificationManager.badgeScopes
                didLoad = true
            }
        }
        .onChange(of: enabled) { _, newValue in
            Task { await handleEnabledChange(to: newValue) }
        }
        .onChange(of: hour) { _, _ in apply() }
        .onChange(of: minute) { _, _ in apply() }
        .onChange(of: selectedDays) { _, newValue in
            NotificationManager.days = newValue
            apply()
        }
        .onChange(of: badgeScopes) { _, newValue in
            NotificationManager.badgeScopes = newValue
            Task { await NotificationManager.refreshBadge(using: context, household: model.resolvedHousehold) }
        }
    }

    /// Bridges the stored hour/minute to the DatePicker's `Date`.
    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                hour = comps.hour ?? 18
                minute = comps.minute ?? 0
            }
        )
    }

    private func toggleDay(_ day: Weekday) {
        if selectedDays.contains(day) { selectedDays.remove(day) }
        else { selectedDays.insert(day) }
    }

    private func toggleBadgeScope(_ scope: AppScope) {
        if badgeScopes.contains(scope) { badgeScopes.remove(scope) }
        else { badgeScopes.insert(scope) }
    }

    private func handleEnabledChange(to newValue: Bool) async {
        if newValue {
            let granted = await NotificationManager.requestAuthorization()
            status = await NotificationManager.authorizationStatus()
            if !granted {
                enabled = false   // reverts the toggle; denied banner shows when status == .denied
                return
            }
        }
        apply()
    }

    private func apply() {
        Task { await NotificationManager.reschedule(using: context, activeHousehold: model.activeHousehold) }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#if DEBUG
#Preview {
    NavigationStack { NotificationSettingsView() }
        .environmentObject(AppModel())
        .environment(\.managedObjectContext, PreviewStack.context)
}
#endif
