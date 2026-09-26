import CoreData
import Foundation

/// Pure glue between the room-vision engine's output (RoomVision.swift) and the
/// app's add-flow types. No FoundationModels dependency, so it's unit-testable on
/// any runtime.
enum RoomVisionMapping {

    // MARK: Name matching

    /// Comparison key for chore names: case-, diacritic- and punctuation-insensitive,
    /// articles dropped, a simple plural "s" folded. "Wipe down the counters." and
    /// "wipe down counter" share a key.
    static func choreKey(_ name: String) -> String {
        words(name).filter { !articles.contains($0) }.map(singular).joined(separator: " ")
    }

    /// Comparison key for room names: like `choreKey`, but spacing is ignored too, so
    /// "Living Room", "living-room" and "Livingroom" all match.
    static func roomKey(_ name: String) -> String {
        singular(words(name).filter { !articles.contains($0) }.joined())
    }

    private static let articles: Set<String> = ["a", "an", "the"]

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func singular(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
    }

    // MARK: Rooms

    /// The model's room name → the existing area with a matching name, otherwise a
    /// new room under the model's name (AddFlowCommit creates it once, on save).
    static func areaRef(forRoomName name: String, among areas: [(id: UUID, name: String)]) -> AreaRef {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = roomKey(trimmed)
        guard !key.isEmpty else { return .none }
        if let match = areas.first(where: { roomKey($0.name) == key }) { return .existing(match.id) }
        return .new(trimmed)
    }

    // MARK: Drafts

    /// Suggested chores → add-flow drafts for one room. Blank names and repeats within
    /// the batch are dropped, names get a leading capital, cadence maps onto
    /// isDaily/frequency, and non-daily chores are spread over the least-busy weekdays.
    static func drafts(from chores: [SuggestedChore], areaRef: AreaRef,
                       weekdayLoad: [Weekday: Int]) -> [ChoreDraft] {
        var seen = Set<String>()
        let unique: [SuggestedChore] = chores.compactMap { chore in
            let name = capitalizedFirst(chore.name.trimmingCharacters(in: .whitespacesAndNewlines))
            let key = choreKey(name)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return SuggestedChore(name: name, cadence: chore.cadence)
        }
        var days = spreadDays(count: unique.filter { $0.cadence != .daily }.count, load: weekdayLoad).makeIterator()
        return unique.map { chore in
            guard let frequency = Frequency(chore.cadence) else {
                return ChoreDraft(name: chore.name, isDaily: true, areaRef: areaRef)
            }
            return ChoreDraft(name: chore.name, isDaily: false, frequency: frequency,
                              day: days.next(), areaRef: areaRef)
        }
    }

    /// Drafts whose name matches a chore the destination room already has.
    static func duplicates(in drafts: [ChoreDraft], existingNames: [String]) -> Set<ChoreDraft.ID> {
        let existing = Set(existingNames.map(choreKey))
        return Set(drafts.filter { existing.contains(choreKey($0.name)) }.map(\.id))
    }

    /// A weekday for each of `count` new scheduled chores: the least-loaded day so far
    /// (ties go to the earliest, Monday first), counting each pick as it's made.
    static func spreadDays(count: Int, load: [Weekday: Int]) -> [Weekday] {
        let order: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
        var load = load
        return (0..<max(0, count)).map { _ in
            // `min(by:)` keeps the first of equal minima, so ties resolve in `order`.
            let day = order.min { load[$0, default: 0] < load[$1, default: 0] } ?? .monday
            load[day, default: 0] += 1
            return day
        }
    }

    // MARK: Household context (Core Data)

    /// Scheduled chores per weekday. Daily chores are left out: they're on every day.
    static func weekdayLoad(of chores: [CDChore]) -> [Weekday: Int] {
        var load: [Weekday: Int] = [:]
        for chore in chores where !chore.isDaily {
            for calendarDay in chore.dueWeekdays {
                if let day = Weekday.standardCases.first(where: { $0.calendarWeekday == calendarDay }) {
                    load[day, default: 0] += 1
                }
            }
        }
        return load
    }

    /// What the household already has, for the suggest prompt: its room names, and
    /// its chores keyed by room (chores without a room are left out).
    static func homeContext(areas: [CDArea], chores: [CDChore]) -> RoomVisionHomeContext {
        var byRoom: [String: [String]] = [:]
        for chore in chores {
            guard let room = chore.area?.name, let name = chore.name else { continue }
            byRoom[room, default: []].append(name)
        }
        return RoomVisionHomeContext(
            roomNames: areas.compactMap(\.name).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            choresByRoom: byRoom)
    }

    /// Names of the chores already in the room `ref` points at. A `.new` room that
    /// matches an existing area's name counts as that area (AddFlowCommit reuses it).
    static func existingChoreNames(in ref: AreaRef, chores: [CDChore]) -> [String] {
        switch ref {
        case .existing(let id):
            return chores.filter { $0.area?.id == id }.compactMap(\.name)
        case .new(let name):
            let key = roomKey(name)
            return chores.filter { $0.area.map { roomKey($0.name ?? "") == key } ?? false }.compactMap(\.name)
        case .none:
            return chores.filter { $0.area == nil }.compactMap(\.name)
        }
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

// MARK: - Photo check-off (#107)

/// One room's open chores, as offered by the photo check-off room picker.
struct PhotoCheckRoom: Identifiable {
    /// The area's id; nil for chores without a room.
    let areaID: UUID?
    let title: String
    let chores: [CDChore]

    var id: String { areaID?.uuidString ?? "none" }
}

extension RoomVisionMapping {
    /// The most chores one photo check looks at (keeps the prompt and the list small).
    static let maxCheckChores = 30

    /// Open chores grouped by room for the check-off picker: rooms A→Z, then chores
    /// without a room as "Other chores"; chores A→Z within each, capped.
    static func checkRooms(for chores: [CDChore]) -> [PhotoCheckRoom] {
        var groups: [UUID?: [CDChore]] = [:]
        var titles: [UUID: String] = [:]
        for chore in chores {
            let id = chore.area?.id
            groups[id, default: []].append(chore)
            if let id { titles[id] = chore.area?.name ?? "Untitled" }
        }
        func ordered(_ chores: [CDChore]) -> [CDChore] {
            Array(chores.sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
                .prefix(maxCheckChores))
        }
        let rooms = groups.compactMap { id, chores -> PhotoCheckRoom? in
            guard let id else { return nil }
            return PhotoCheckRoom(areaID: id, title: titles[id] ?? "Untitled", chores: ordered(chores))
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let other = groups[nil].map { [PhotoCheckRoom(areaID: nil, title: "Other chores", chores: ordered($0))] } ?? []
        return rooms + other
    }

    /// What a check pre-selects: only the chores that look done. "Can't tell" and "not
    /// done" are never pre-checked, and nothing is completed without the user confirming.
    static func preselected<ID: Hashable>(_ ids: [ID], verdicts: [ChoreVerdict]) -> Set<ID> {
        Set(zip(ids, verdicts).filter { $0.1 == .looksDone }.map(\.0))
    }
}

extension Frequency {
    /// The add-flow frequency for a model cadence; nil for daily (a daily chore has none).
    init?(_ cadence: ChoreCadence) {
        switch cadence {
        case .daily:   return nil
        case .weekly:  self = .weekly
        case .monthly: self = .monthly
        case .yearly:  self = .yearly
        }
    }
}
