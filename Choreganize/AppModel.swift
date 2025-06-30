import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    let cloudController: SharedCloudKitController
    @AppStorage("sharingEnabled") var sharingEnabled = false
    @Published var chores: [Chore] = []
    @Published var areas: [Area] = []
    @Published var completions: [Completion] = []
    @Published var completionCache: [Date: [Completion]] = [:]

    private let fileURL: URL

    init(cloudController: SharedCloudKitController = .shared) {
        self.cloudController = cloudController
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = documents.appendingPathComponent("chore_data.json")
        load()
        Task {
            await loadSharedState()
            if sharingEnabled {
                await cloudController.subscribeToChanges()
            }
        }
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
        if sharingEnabled {
            Task { await cloudController.publish(state: state) }
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

    /// Deletes chores matching the provided identifiers.
    func deleteChores(withIDs ids: [UUID]) {
        chores.removeAll { ids.contains($0.id) }
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

    /// Returns the most recent completion for the given chore that occurred on
    /// or before the provided date.
    private func lastCompletion(for chore: Chore, before date: Date) -> Completion? {
        completions
            .filter { $0.choreId == chore.id && $0.date <= date }
            .sorted { $0.date > $1.date }
            .first
    }

    /// Returns chores that should appear on the provided date. A chore is shown
    /// on its assigned weekday when the next scheduled occurrence is on or
    /// before that day and the chore has not been completed since the last
    /// scheduled occurrence.
    func chores(for date: Date) -> [Chore] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)

        return chores.filter { chore in
            if chore.isDaily { return true }
            guard
                let weekday = chore.assignedDay?.calendarWeekday,
                calendar.component(.weekday, from: dayStart) == weekday
            else { return false }

            let last = lastCompletion(for: chore, before: dayStart)
            guard var due = nextDueDate(for: chore, after: last?.date) else { return false }

            // Advance through missed intervals until the due date is on or after
            // the provided day.
            while calendar.startOfDay(for: due) < dayStart,
                  let next = nextDueDate(for: chore, after: due) {
                due = next
            }

            return calendar.isDate(due, inSameDayAs: dayStart)
        }
    }

    /// Indicates whether the chore is overdue based on its frequency and last completion date.
    func isOverdue(_ chore: Chore) -> Bool {
        guard let last = lastCompletion(for: chore) else { return true }
        let calendar = Calendar.current
        let now = Date()
        if chore.isDaily {
            return !calendar.isDateInToday(last.date)
        }

        guard let freq = chore.frequency else { return false }
        switch freq {
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
    /// Calculates the next scheduled date for a chore.
    /// - Parameter date: The reference date to add a frequency interval to.
    ///   If `nil`, the chore's last completion date will be used. When there is
    ///   no prior completion the search starts from today.
    func nextDueDate(for chore: Chore, after date: Date? = nil) -> Date? {
        let calendar = Calendar.current

        if chore.isDaily {
            let reference = date ?? lastCompletion(for: chore)?.date
            let start = calendar.startOfDay(for: reference ?? Date())
            return calendar.date(byAdding: .day, value: 1, to: start)
        }

        guard let freq = chore.frequency else { return nil }

        // Determine the base date from which to calculate the next occurrence.
        let reference = date ?? lastCompletion(for: chore)?.date

        let startDate: Date
        if let reference {
            guard let advanced = calendar.date(byAdding: freq.component, value: 1, to: reference) else {
                return nil
            }
            startDate = advanced
        } else {
            startDate = calendar.startOfDay(for: Date())
        }

        guard let targetWeekday = chore.assignedDay?.calendarWeekday else {
            return nil
        }

        var next = startDate
        while calendar.component(.weekday, from: next) != targetWeekday {
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
            if chore.isDaily {
                var next = calendar.startOfDay(for: chore.createdDate)
                while next < monthStart { next = calendar.date(byAdding: .day, value: 1, to: next)! }
                while next <= monthEnd {
                    let key = calendar.startOfDay(for: next)
                    result[key, default: []].append(chore)
                    next = calendar.date(byAdding: .day, value: 1, to: next)!
                }
                continue
            }

            guard let weekday = chore.assignedDay?.calendarWeekday, let freq = chore.frequency else { continue }

            var next = calendar.startOfDay(for: chore.createdDate)
            // align to first scheduled weekday on/after creation
            while calendar.component(.weekday, from: next) != weekday {
                next = calendar.date(byAdding: .day, value: 1, to: next)!
            }

            // Advance until within visible range
            while next < monthStart {
                if let advanced = calendar.date(byAdding: freq.component, value: 1, to: next) {
                    var candidate = advanced
                    while calendar.component(.weekday, from: candidate) != weekday {
                        candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
                    }
                    next = candidate
                } else {
                    break
                }
            }

            while next <= monthEnd {
                let key = calendar.startOfDay(for: next)
                result[key, default: []].append(chore)

                if let advanced = calendar.date(byAdding: freq.component, value: 1, to: next) {
                    var candidate = advanced
                    while calendar.component(.weekday, from: candidate) != weekday {
                        candidate = calendar.date(byAdding: .day, value: 1, to: candidate)!
                    }
                    next = candidate
                } else {
                    break
                }
            }
        }
        return result
    }

    /// Loads any shared app state from CloudKit and merges it into the current state.
    func loadSharedState() async {
        guard let record = await cloudController.fetchSharedRootRecord(),
              let data = record[SharedRecordKeys.jsonKey] as? Data,
              let decoded = try? JSONDecoder().decode(SavedState.self, from: data) else {
            sharingEnabled = false
            return
        }
        sharingEnabled = true
        self.chores = decoded.chores
        self.areas = decoded.areas
        self.completions = decoded.completions
    }

    /// Initiates sharing by presenting the CloudKit share UI.
    @MainActor
    func startSharing(from controller: UIViewController) async {
        await cloudController.presentShare(from: controller)
        sharingEnabled = true
        await cloudController.subscribeToChanges()
    }

    /// Removes all shared data and subscriptions.
    func stopSharing() async {
        await cloudController.stopSharing()
        sharingEnabled = false
    }

    /// Loads completions for the specified date from disk or CloudKit and caches them.
    func loadCompletions(for date: Date) async -> [Completion] {
        let day = Calendar.current.startOfDay(for: date)
        if let cached = completionCache[day] { return cached }

        var allCompletions: [Completion] = []
        if sharingEnabled,
           let record = await cloudController.fetchSharedRootRecord(),
           let data = record[SharedRecordKeys.jsonKey] as? Data,
           let decoded = try? JSONDecoder().decode(SavedState.self, from: data) {
            allCompletions = decoded.completions
        } else if let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode(SavedState.self, from: data) {
            allCompletions = decoded.completions
        }

        let matches = allCompletions.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
        completionCache[day] = matches
        return matches
    }

    /// Returns a sequence of dates around the provided start date.
    /// - Parameters:
    ///   - date: The reference date from which to generate the range.
    ///   - includePast: How many days prior to `date` to include.
    ///   - includeFuture: How many days after `date` to include. The range will
    ///     never extend more than six days beyond today.
    func weekDates(startingFrom date: Date, includePast: Int, includeFuture: Int) -> [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: Date())
        let maxFuture = calendar.date(byAdding: .day, value: 6, to: today) ?? today
        let upperBound = min(includeFuture, calendar.dateComponents([.day], from: start, to: maxFuture).day ?? 0)

        return (-includePast...upperBound).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start)
        }
    }

    struct SavedState: Codable {
        var chores: [Chore]
        var areas: [Area]
        var completions: [Completion]
    }
}
