import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var chores: [Chore] = []
    @Published var areas: [Area] = []
    @Published var completions: [Completion] = []

    private let fileURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = documents.appendingPathComponent("chore_data.json")
        load()
    }

    // MARK: - Persistence
    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode(SavedState.self, from: data) {
            self.chores = decoded.chores
            self.areas = decoded.areas
            self.completions = decoded.completions
        }
    }

    func save() {
        let state = SavedState(chores: chores, areas: areas, completions: completions)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL)
        }
    }

    // MARK: - Chore management
    func addChore(_ chore: Chore) {
        chores.append(chore)
        save()
    }

    /// Updates an existing chore with new details.
    func updateChore(_ chore: Chore) {
        if let index = chores.firstIndex(where: { $0.id == chore.id }) {
            chores[index] = chore
            save()
        }
    }

    func deleteChores(at offsets: IndexSet) {
        chores.remove(atOffsets: offsets)
        save()
    }

    // MARK: - Area management
    func addArea(_ area: Area) {
        areas.append(area)
        save()
    }

    func deleteAreas(at offsets: IndexSet) {
        areas.remove(atOffsets: offsets)
        save()
    }

    /// Updates an existing area with new values.
    func updateArea(_ area: Area) {
        if let index = areas.firstIndex(where: { $0.id == area.id }) {
            areas[index] = area
            save()
        }
    }

    /// Assigns the specified chores to the given area identifier. Pass `nil` to
    /// unassign the chores.
    func assignChores(_ choreIDs: [UUID], toAreaID areaID: UUID?) {
        for id in choreIDs {
            if let index = chores.firstIndex(where: { $0.id == id }) {
                chores[index].areaId = areaID
            }
        }
        save()
    }

    // MARK: - Completion
    func isCompleted(_ chore: Chore, on date: Date) -> Bool {
        completions.contains { $0.choreId == chore.id && Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    func recordCompletion(_ chore: Chore, notes: String? = nil, date: Date = Date()) {
        guard !isCompleted(chore, on: date) else { return }
        completions.append(Completion(choreId: chore.id, date: date, notes: notes))
        save()
    }

    func removeCompletionForToday(_ chore: Chore) {
        if let index = completions.firstIndex(where: { $0.choreId == chore.id && Calendar.current.isDate($0.date, inSameDayAs: Date()) }) {
            completions.remove(at: index)
            save()
        }
    }

    /// Returns the most recent completion for the given chore, if any.
    func lastCompletion(for chore: Chore) -> Completion? {
        completions
            .filter { $0.choreId == chore.id }
            .sorted { $0.date > $1.date }
            .first
    }

    /// Indicates whether the chore is overdue based on its frequency and last completion date.
    func isOverdue(_ chore: Chore) -> Bool {
        guard let last = lastCompletion(for: chore) else { return true }
        let calendar = Calendar.current
        let now = Date()
        switch chore.frequency {
        case .daily:
            return !calendar.isDateInToday(last.date)
        case .weekly:
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: last.date) else { return false }
            return now >= next
        case .monthly:
            guard let next = calendar.date(byAdding: .month, value: 1, to: last.date) else { return false }
            return now >= next
        case .yearly:
            guard let next = calendar.date(byAdding: .year, value: 1, to: last.date) else { return false }
            return now >= next
        }
    }

    /// Calculates the next due date for a chore after the given date.
    /// If `after` is nil the chore's last completion date is used.
    func nextDueDate(for chore: Chore, after date: Date? = nil) -> Date? {
        let calendar = Calendar.current
        let start = date ?? lastCompletion(for: chore)?.date ?? .distantPast
        guard var next = calendar.date(byAdding: chore.frequency.component, value: 1, to: start) else {
            return nil
        }
        while calendar.component(.weekday, from: next) != chore.assignedDay.calendarWeekday {
            next = calendar.date(byAdding: .day, value: 1, to: next)!
        }
        return next
    }

    /// Returns a dictionary mapping dates within the specified month to the chores due on those dates.
    func choresByDate(inMonth month: Date) -> [Date: [Chore]] {
        var result: [Date: [Chore]] = [:]
        let calendar = Calendar.current
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)
        else { return result }

        for chore in chores {
            guard var due = nextDueDate(for: chore) else { continue }
            due = calendar.startOfDay(for: due)
            // Advance until the due date is within the visible month range
            while due < monthStart {
                if let next = nextDueDate(for: chore, after: due) {
                    due = calendar.startOfDay(for: next)
                } else {
                    break
                }
            }
            while due <= monthEnd {
                let key = calendar.startOfDay(for: due)
                result[key, default: []].append(chore)
                if let next = nextDueDate(for: chore, after: due) {
                    due = calendar.startOfDay(for: next)
                } else {
                    break
                }
            }
        }
        return result
    }

    struct SavedState: Codable {
        var chores: [Chore]
        var areas: [Area]
        var completions: [Completion]
    }
}
