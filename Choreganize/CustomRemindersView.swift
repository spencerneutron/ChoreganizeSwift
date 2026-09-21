import SwiftUI
import CoreData

/// CG-19 / #101 — per-room / per-chore custom reminder times (Plus).
///
/// Each row shows the item's override or its fallback ("Default", or a chore's
/// inherited room time). Overrides are the "HH:mm" strings on
/// `CDArea`/`CDChore` (see `ReminderTimeOverride` for the chore → room →
/// global chain). Every edit saves and re-schedules immediately through the
/// same `NotificationManager.reschedule` path NotificationSettingsView uses,
/// so the pending-notification plan never drifts from what's on screen.
/// Reached only through the Plus-gated "Custom Times" link in
/// NotificationSettingsView — no additional gating here.
struct CustomRemindersView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(sortDescriptors: [SortDescriptor(\CDArea.name)]) private var areas: FetchedResults<CDArea>
    // Prefetches `area` so chore rows can show inherited room times without
    // per-row faulting (same rationale as ChoreListView, cz_device10).
    @FetchRequest(fetchRequest: displayChoresFetchRequest()) private var chores: FetchedResults<CDChore>

    var body: some View {
        let scopedAreas = areas.inScope(model.activeHousehold)
        let scopedChores = chores.inScope(model.activeHousehold)

        Form {
            if scopedAreas.isEmpty && scopedChores.isEmpty {
                Section {
                    Text("Nothing to customize yet — add chores and rooms in the Edit tab first.")
                        .foregroundStyle(.secondary)
                }
            }

            if !scopedAreas.isEmpty {
                Section {
                    ForEach(scopedAreas, id: \.objectID) { area in
                        OverrideRow(title: area.name ?? "Untitled",
                                    inherited: nil,
                                    timeString: overrideBinding(for: area, \.reminderTime))
                    }
                } header: {
                    Text("Rooms")
                } footer: {
                    Text("A room's time applies to all of its chores that don't set their own.")
                }
            }

            if !scopedChores.isEmpty {
                Section {
                    ForEach(scopedChores, id: \.objectID) { chore in
                        OverrideRow(title: chore.name ?? "Untitled",
                                    inherited: ReminderTimeOverride.parse(chore.area?.reminderTime),
                                    timeString: overrideBinding(for: chore, \.reminderTime))
                    }
                } header: {
                    Text("Chores")
                } footer: {
                    Text("Chores without their own time follow their room's time, then the main reminder time. Swipe a row left to go back to the default.")
                }
            }
        }
        .navigationTitle("Custom Times")
    }

    /// Read-write bridge to a managed object's "HH:mm" override. Writes save
    /// and re-schedule immediately — mirrors NotificationSettingsView's
    /// `apply()` so both screens share one reschedule path.
    private func overrideBinding<T: NSManagedObject>(
        for object: T,
        _ keyPath: ReferenceWritableKeyPath<T, String?>
    ) -> Binding<String?> {
        Binding(
            get: { object[keyPath: keyPath] },
            set: { newValue in
                object[keyPath: keyPath] = newValue
                guard context.hasChanges else { return }
                try? context.save()
                Task { await NotificationManager.reschedule(using: context, activeHousehold: model.activeHousehold) }
            }
        )
    }
}

/// One room/chore row: name on the left; on the right either a compact time
/// picker (override set) or the fallback shown as a tappable placeholder.
/// Tapping the placeholder opens a sheet seeded with the row's current
/// effective time; nothing is written until the user taps Set. (The earlier
/// design wrote the seed on the tap itself, which read as accidental data
/// entry at the 2-sim gate — every curious tap saved an override and
/// rescheduled reminders.)
private struct OverrideRow: View {
    let title: String
    /// What this row falls back to without an override: the room's time for
    /// chores (rendered as a dimmed time), or nil to label it "Default".
    let inherited: (hour: Int, minute: Int)?
    @Binding var timeString: String?

    @State private var editing = false
    @State private var draft = Date()

    private var override: (hour: Int, minute: Int)? { ReminderTimeOverride.parse(timeString) }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if override != nil {
                DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            } else {
                Button {
                    let seed = inherited ?? (hour: NotificationManager.hour, minute: NotificationManager.minute)
                    draft = Calendar.current.date(bySettingHour: seed.hour, minute: seed.minute, second: 0, of: Date()) ?? Date()
                    editing = true
                } label: {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if timeString != nil {
                Button("Default") { timeString = nil }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                VStack(spacing: 12) {
                    DatePicker("Reminder time", selection: $draft, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        #if os(iOS)
                        .datePickerStyle(.wheel)
                        #endif
                    Text("Only \(title) will use this time. Swipe the row later to go back to the default.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editing = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Set") {
                            let comps = Calendar.current.dateComponents([.hour, .minute], from: draft)
                            timeString = ReminderTimeOverride.format(hour: comps.hour ?? 18, minute: comps.minute ?? 0)
                            editing = false
                        }
                    }
                }
            }
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        }
    }

    /// "Default", or the inherited room time so a chore row shows when it
    /// will actually fire even without its own override.
    private var placeholder: String {
        guard let inherited,
              let date = Calendar.current.date(bySettingHour: inherited.hour, minute: inherited.minute,
                                               second: 0, of: Date()) else { return "Default" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Bridges the "HH:mm" override to the DatePicker's `Date` (same bridge
    /// as NotificationSettingsView's global time picker).
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let time = override ?? (hour: 18, minute: 0)
                return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                timeString = ReminderTimeOverride.format(hour: comps.hour ?? 18, minute: comps.minute ?? 0)
            }
        )
    }
}

#if DEBUG
#Preview {
    NavigationStack { CustomRemindersView() }
        .environmentObject(AppModel())
        .environment(\.managedObjectContext, PreviewStack.context)
}
#endif
