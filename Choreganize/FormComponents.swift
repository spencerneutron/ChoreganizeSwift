import SwiftUI

/// Shared form section used when creating or editing a chore. Keeping the
/// fields in one place ensures consistency across the app. A thin `Section`
/// wrapper around `ChoreFormRows` so the same fields can also be composed into
/// other forms (e.g. the add-flow wizard) without the section chrome.
///
/// CG-17 / #99 + CG-18 / #100 (Plus): also hosts the Schedule section (weekly
/// multi-day + interval) and, for household chores, the Assignment section.
/// Both are gated by `Entitlements.isPlus(for:)` — unentitled users see the
/// current values read-only with a lock (the Member-completions pattern).
struct ChoreFormFields: View {
    @Binding var name: String
    @Binding var isDaily: Bool
    @Binding var frequency: Frequency
    @Binding var day: Weekday?
    @Binding var multiDays: Set<Weekday>
    @Binding var interval: Int
    @Binding var assignee: String?
    @Binding var areaId: UUID?
    var areas: [CDArea]
    var household: CDHousehold?

    // Observed so the gated rows re-render when the entitlement flips
    // mid-session (purchase, restore, household flag sync).
    @ObservedObject private var entitlements = EntitlementStore.shared
    @ObservedObject private var completers = CompleterDirectory.shared

    private var plusUnlocked: Bool { Entitlements.isPlus(for: household) }

    /// The weekly multi-select supersedes the single Day picker — also for a
    /// non-Plus editor of an existing multi-day chore, where an editable
    /// single-day picker couldn't represent (and would silently fight) the set.
    private var hidesSingleDay: Bool {
        !isDaily && frequency == .weekly && (plusUnlocked || multiDays.count >= 2)
    }

    var body: some View {
        Section("Details") {
            ChoreFormRows(name: $name, isDaily: $isDaily, frequency: $frequency,
                          day: $day, areaId: $areaId, areas: areas,
                          showsDay: !hidesSingleDay)
        }
        if !isDaily {
            scheduleSection
        }
        if household != nil {
            assignmentSection
        }
    }

    // MARK: - Schedule (CG-18 / #100)

    private var unitName: String {
        switch frequency {
        case .weekly: return "week"
        case .monthly: return "month"
        case .yearly: return "year"
        }
    }

    private var intervalLabel: String {
        interval <= 1 ? "Every \(unitName)" : "Every \(interval) \(unitName)s"
    }

    private var multiDaySummary: String {
        let names = Weekday.standardCases.filter { multiDays.contains($0) }
            .map { String($0.displayName.prefix(3)) }
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    @ViewBuilder private var scheduleSection: some View {
        Section {
            if frequency == .weekly {
                if plusUnlocked {
                    WeekdayMultiPicker(selection: $multiDays)
                } else if multiDays.count >= 2 {
                    lockedRow("Days", value: multiDaySummary)
                }
            }
            if plusUnlocked {
                Stepper(value: $interval, in: 1...6) {
                    Text(intervalLabel)
                }
            } else {
                lockedRow("Repeats", value: intervalLabel)
            }
        } header: {
            Text("Schedule")
        } footer: {
            if !plusUnlocked {
                Text("Repeating every 2–6 \(unitName)s and multiple days per week require Choreganize Plus (Hub ▸ Get Choreganize Plus).")
            }
        }
        // Frequency changes keep the two day representations coherent: entering
        // weekly seeds the multi-select from the single day; day-order mirroring
        // keeps `day` meaningful if the user leaves weekly again (and as the
        // legacy-compat value written alongside a multi-day set).
        .onChange(of: frequency) { _, newValue in
            if newValue == .weekly, multiDays.isEmpty, let day, day != .all {
                multiDays = [day]
            }
        }
        .onChange(of: multiDays) { _, newValue in
            if frequency == .weekly, plusUnlocked {
                day = Weekday.standardCases.first { newValue.contains($0) }
            }
        }
    }

    // MARK: - Assignment (CG-17 / #99)

    /// Household members other than the current user, from the share-participant
    /// directory. Ids share the CloudKit user-record-name domain with
    /// `CDCompletion.completedBy`.
    private var otherMembers: [(id: String, name: String)] {
        completers.namesByID
            .filter { $0.key != CompleterIdentity.cachedID }
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private var assigneeName: String {
        guard let assignee else { return "Anyone" }
        if assignee == CompleterIdentity.cachedID { return "Me" }
        return completers.namesByID[assignee] ?? "Member"
    }

    @ViewBuilder private var assignmentSection: some View {
        Section {
            if plusUnlocked {
                Picker("Assigned to", selection: $assignee) {
                    Text("Anyone").tag(String?.none)
                    if let me = CompleterIdentity.cachedID {
                        Text("Me").tag(Optional(me))
                    }
                    ForEach(otherMembers, id: \.id) { member in
                        Text(member.name).tag(Optional(member.id))
                    }
                    // An assignee who left the share (or predates the directory)
                    // still needs a row, or the picker renders no selection.
                    if let current = assignee, current != CompleterIdentity.cachedID,
                       completers.namesByID[current] == nil {
                        Text("Member").tag(Optional(current))
                    }
                }
            } else {
                lockedRow("Assigned to", value: assigneeName)
            }
        } header: {
            Text("Assignment")
        } footer: {
            Text(plusUnlocked
                 ? "Everyone in the household sees who a chore belongs to; anyone can still complete it."
                 : "Assigning chores to household members requires Choreganize Plus (Hub ▸ Get Choreganize Plus).")
        }
    }

    private func lockedRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                Image(systemName: "lock")
                Text(value)
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// CG-18 / #100 — compact one-row weekday multi-select (the Reminders-style
/// circle row) for weekly chores; an empty selection means "no assigned day",
/// matching the single picker's "None".
struct WeekdayMultiPicker: View {
    @Binding var selection: Set<Weekday>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Weekday.standardCases) { day in
                let isOn = selection.contains(day)
                Button {
                    if isOn { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(day.displayName.prefix(1))
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(isOn ? Color.accentColor : Color(.tertiarySystemFill)))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.displayName)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The bare chore-detail rows (no `Section` wrapper). Visibility flags let a
/// caller hide a field it pins elsewhere — the add-flow wizard hides the area
/// in the room lens and the daily-toggle/day in the day lens, while still
/// surfacing every other control (notably Frequency, which the day lens used
/// to drop). Defaults reproduce the full New/Edit Chore form exactly.
struct ChoreFormRows: View {
    @Binding var name: String
    @Binding var isDaily: Bool
    @Binding var frequency: Frequency
    @Binding var day: Weekday?
    @Binding var areaId: UUID?
    var areas: [CDArea]

    var showsName = true
    var showsDailyToggle = true
    var showsDay = true
    var showsArea = true

    var body: some View {
        if showsName {
            TextField("Name", text: $name)
        }
        if showsDailyToggle {
            Toggle("Every Day", isOn: $isDaily)
        }
        if !isDaily {
            Picker("Frequency", selection: $frequency) {
                ForEach(Frequency.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            if showsDay {
                Picker("Day", selection: $day) {
                    Text("None").tag(Weekday?.none)
                    ForEach(Weekday.standardCases) { Text($0.displayName).tag(Optional($0)) }
                }
            }
        } else if showsDay {
            Picker("Day", selection: .constant(Weekday.all)) {
                Text(Weekday.all.displayName).tag(Weekday.all)
            }
            .disabled(true)
        }
        if showsArea {
            Picker("Area", selection: $areaId) {
                Text("None").tag(UUID?.none)
                ForEach(areas, id: \.objectID) { area in
                    Text(area.name ?? "Untitled").tag(area.id)
                }
            }
        }
    }
}

/// Section for editing area metadata to match the style of `ChoreFormFields`.
struct AreaFormFields: View {
    @Binding var name: String
    @Binding var description: String

    var body: some View {
        Section("Details") {
            TextField("Name", text: $name)
            TextField("Description", text: $description)
        }
    }
}
