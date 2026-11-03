import Foundation

/// How the Work view's day list is grouped — a Hub preference (default `.none`).
/// The grouping logic is pure and deterministic so it can be unit-tested without UI.
enum WorkGrouping: String, CaseIterable, Identifiable {
    case none, frequency, room

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:      return "None"
        case .frequency: return "Frequency"
        case .room:      return "Room"
        }
    }

    /// What a section groups by — the Quick Add ghost (#127) prefills New Chore from it.
    enum Key: Hashable {
        /// Grouping `.none`: the day's single section.
        case all
        case daily
        case frequency(Frequency)
        case unscheduled
        /// A room section. Rooms group by name, so this is the first chore's area.
        case area(UUID?, name: String)
        case noArea
    }

    /// One ordered, non-empty section of the day list.
    struct Group: Identifiable {
        let title: String
        let chores: [CDChore]
        var key: Key = .all
        var id: String { title }
    }

    /// Splits `chores` into ordered sections for this grouping.
    ///
    /// - `.none` → a single implicit group (empty title), or `[]` when there are no chores.
    /// - `.frequency` → Every Day (daily) first, then weekly → monthly → yearly, then any
    ///   non-daily chore missing a frequency under "Unscheduled" (defensive).
    /// - `.room` → one group per area name (A→Z, case-insensitive), with "No Room" last.
    ///
    /// Empty groups are dropped; order within a group preserves the caller's input order.
    func sections(for chores: [CDChore]) -> [Group] {
        switch self {
        case .none:
            return chores.isEmpty ? [] : [Group(title: "", chores: chores, key: .all)]

        case .frequency:
            var groups: [Group] = []
            let daily = chores.filter { $0.isDaily }
            if !daily.isEmpty { groups.append(Group(title: Weekday.all.displayName, chores: daily, key: .daily)) }
            for freq in Frequency.allCases {
                let inFreq = chores.filter { !$0.isDaily && $0.frequencyValue == freq }
                if !inFreq.isEmpty {
                    groups.append(Group(title: freq.rawValue.capitalized, chores: inFreq, key: .frequency(freq)))
                }
            }
            let unscheduled = chores.filter { !$0.isDaily && $0.frequencyValue == nil }
            if !unscheduled.isEmpty { groups.append(Group(title: "Unscheduled", chores: unscheduled, key: .unscheduled)) }
            return groups

        case .room:
            let byRoom = Dictionary(grouping: chores.filter { $0.area != nil }) { $0.area?.name ?? "" }
            var groups = byRoom
                .map { Group(title: $0.key.isEmpty ? "Untitled" : $0.key, chores: $0.value,
                             key: .area($0.value.first?.area?.id, name: $0.key)) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let noRoom = chores.filter { $0.area == nil }
            if !noRoom.isEmpty { groups.append(Group(title: "No Room", chores: noRoom, key: .noArea)) }
            return groups
        }
    }
}
