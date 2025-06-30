import Foundation

/// Represents a grouping for chores.
struct Area: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var description: String
}

/// How often a chore occurs.
enum Frequency: String, CaseIterable, Codable, Identifiable {
    case weekly, monthly, yearly
    var id: String { rawValue }

    /// The calendar component associated with this frequency.
    var component: Calendar.Component {
        switch self {
        case .weekly: return .weekOfYear
        case .monthly: return .month
        case .yearly: return .year
        }
    }
}

/// Day of the week for scheduling chores.
enum Weekday: String, Codable, Identifiable, CaseIterable {
    case all, sunday, monday, tuesday, wednesday, thursday, friday, saturday
    static let standardCases: [Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "Every Day"
        default: return rawValue.capitalized
        }
    }

    /// Returns the weekday for today.
    static var today: Weekday {
        let index = Calendar.current.component(.weekday, from: Date()) - 1
        return Weekday.standardCases[index]
    }

    /// Weekday value compatible with `Calendar` where Sunday is 1.
    var calendarWeekday: Int? {
        switch self {
        case .all: return nil
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        }
    }
}

/// A chore item.
struct Chore: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var isDaily: Bool = false
    var frequency: Frequency?
    /// Optional day this chore is scheduled for. `nil` indicates the chore is
    /// not currently assigned to a specific day of the week.
    var assignedDay: Weekday?
    var areaId: UUID?
    /// Date the chore was created. Used for filtering history on the calendar.
    var createdDate: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, name, isDaily, frequency, assignedDay, areaId, createdDate
    }

    init(id: UUID = UUID(), name: String, isDaily: Bool = false, frequency: Frequency?, assignedDay: Weekday?, areaId: UUID?, createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.isDaily = isDaily
        self.frequency = frequency
        self.assignedDay = assignedDay
        self.areaId = areaId
        self.createdDate = createdDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        isDaily = try container.decodeIfPresent(Bool.self, forKey: .isDaily) ?? false
        if let freqString = try? container.decode(String.self, forKey: .frequency) {
            frequency = Frequency(rawValue: freqString)
            if freqString == "daily" { isDaily = true; frequency = nil }
        } else {
            frequency = try container.decodeIfPresent(Frequency.self, forKey: .frequency)
        }
        assignedDay = try container.decodeIfPresent(Weekday.self, forKey: .assignedDay)
        areaId = try container.decodeIfPresent(UUID.self, forKey: .areaId)
        createdDate = try container.decodeIfPresent(Date.self, forKey: .createdDate) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isDaily, forKey: .isDaily)
        try container.encodeIfPresent(frequency, forKey: .frequency)
        try container.encodeIfPresent(assignedDay, forKey: .assignedDay)
        try container.encodeIfPresent(areaId, forKey: .areaId)
        try container.encode(createdDate, forKey: .createdDate)
    }
}

/// Completion history for a chore.
struct Completion: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var choreId: UUID
    var date: Date
    var notes: String?
}
