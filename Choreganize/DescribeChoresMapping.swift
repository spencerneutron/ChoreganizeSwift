import Foundation

/// Pure glue between Describe Chores' output (DescribeChores.swift) and the add-flow
/// drafts. No FoundationModels dependency, so it's unit-testable on any runtime.
enum DescribeChoresMapping {
    struct Result: Equatable {
        var drafts: [ChoreDraft]
        /// Why a draft's schedule was simplified: the Plus-only part the user asked for
        /// (#100: an interval, or several days a week), keyed by draft.
        var plusNotes: [ChoreDraft.ID: String]
    }

    /// Described chores → drafts. Blank names and repeats are dropped and names get a
    /// leading capital. Cadence maps onto isDaily/frequency, named days onto the day
    /// (and, with Plus, extra days), "every N" onto the interval (with Plus), and the
    /// room onto an existing area or a new one. A scheduled chore with no named day
    /// goes on the least-busy weekday.
    ///
    /// Without Plus, what can't be saved is simplified and noted. Several days a week
    /// become the first of them, or every day when it's four or more ("weekdays"). An
    /// interval becomes every week, month or year.
    static func drafts(from chores: [DescribedChore], areas: [(id: UUID, name: String)],
                       weekdayLoad: [Weekday: Int], isPlus: Bool) -> Result {
        var seen = Set<String>()
        var drafts: [ChoreDraft] = []
        var notes: [ChoreDraft.ID: String] = [:]
        for chore in chores {
            let name = capitalizedFirst(chore.name.trimmingCharacters(in: .whitespacesAndNewlines))
            let key = RoomVisionMapping.choreKey(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let areaRef = chore.room.isEmpty ? AreaRef.none
                : RoomVisionMapping.areaRef(forRoomName: chore.room, among: areas)
            var draft = ChoreDraft(name: name, isDaily: true, areaRef: areaRef)
            guard let frequency = Frequency(chore.cadence) else {
                drafts.append(draft)
                continue
            }
            draft.isDaily = false
            draft.frequency = frequency
            let days = chore.days.compactMap(Weekday.init(rawValue:)).filter { $0 != .all }
            var parts: [String] = []
            if frequency == .weekly && days.count >= 2 {
                if isPlus {
                    draft.day = days[0]
                    draft.multiDays = Set(days)
                } else if days.count >= 4 {
                    draft.isDaily = true
                    parts.append("Only some days a week needs Plus, so it's every day.")
                } else {
                    draft.day = days[0]
                    parts.append("More than one day a week needs Plus, so it's on \(days[0].displayName).")
                }
            } else {
                draft.day = days.first   // nil: spread below
            }
            if !draft.isDaily && chore.every > 1 {
                if isPlus {
                    draft.interval = min(chore.every, 6)
                } else {
                    let unit = unitName(frequency)
                    parts.append("Every \(chore.every) \(unit)s needs Plus, so it's every \(unit).")
                }
            }
            if draft.isDaily { draft.frequency = .weekly }
            if !parts.isEmpty { notes[draft.id] = parts.joined(separator: " ") }
            drafts.append(draft)
        }
        // Scheduled chores the text gave no day go on the least-busy days.
        let unscheduled = drafts.indices.filter { !drafts[$0].isDaily && drafts[$0].day == nil }
        for (index, day) in zip(unscheduled, RoomVisionMapping.spreadDays(count: unscheduled.count, load: weekdayLoad)) {
            drafts[index].day = day
        }
        return Result(drafts: drafts, plusNotes: notes)
    }

    /// Drafts the household already has: a chore of the same name in the draft's room,
    /// or anywhere when the text named no room ("do the dishes" is the Kitchen's
    /// "Do the dishes"). `existingNames(.none)` must return every chore's name.
    static func duplicates(in drafts: [ChoreDraft], existingNames: (AreaRef) -> [String]) -> Set<ChoreDraft.ID> {
        Set(drafts.filter { draft in
            existingNames(draft.areaRef).map(RoomVisionMapping.choreKey).contains(RoomVisionMapping.choreKey(draft.name))
        }.map(\.id))
    }

    private static func unitName(_ frequency: Frequency) -> String {
        switch frequency {
        case .weekly:  return "week"
        case .monthly: return "month"
        case .yearly:  return "year"
        }
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
