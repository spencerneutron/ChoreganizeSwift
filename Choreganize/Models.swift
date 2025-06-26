import Foundation

/// Represents a grouping for chores.
struct Area: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var description: String
}

/// How often a chore occurs.
enum Frequency: String, CaseIterable, Codable, Identifiable {
    case daily, weekly, monthly, yearly
    var id: String { rawValue }
}

/// Day of the week for scheduling chores.
enum Weekday: String, CaseIterable, Codable, Identifiable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday
    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    /// Returns the weekday for today.
    static var today: Weekday {
        let index = Calendar.current.component(.weekday, from: Date()) - 1
        return Weekday.allCases[index]
    }
}

/// A chore item.
struct Chore: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var frequency: Frequency
    var assignedDay: Weekday
    var areaId: UUID?
}

/// Completion history for a chore.
struct Completion: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var choreId: UUID
    var date: Date
    var notes: String?
}
