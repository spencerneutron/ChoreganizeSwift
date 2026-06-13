import SwiftUI

/// Reminder preferences.
///
/// Phase A stub: establishes the destination so `SettingsView` can link to it.
/// Phase B fills this in with per-weekday + time scheduling backed by
/// `UNUserNotificationCenter`, plus the "only notify when chores are unresolved"
/// recompute. Keep the navigation title stable so the link doesn't churn.
struct NotificationSettingsView: View {
    var body: some View {
        Form {
            Section {
                Label("Daily reminders are coming soon.", systemImage: "bell")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("You'll be able to pick which days and what time to be reminded about chores that still need attention.")
            }
        }
        .navigationTitle("Reminders")
    }
}

#if DEBUG
#Preview {
    NavigationStack { NotificationSettingsView() }
}
#endif
