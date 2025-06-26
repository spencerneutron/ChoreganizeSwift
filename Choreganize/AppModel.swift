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

    /// Assigns the specified chores to the given area.
    func assignChores(_ choreIDs: [UUID], to area: Area) {
        for id in choreIDs {
            if let index = chores.firstIndex(where: { $0.id == id }) {
                chores[index].areaId = area.id
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

    struct SavedState: Codable {
        var chores: [Chore]
        var areas: [Area]
        var completions: [Completion]
    }
}
