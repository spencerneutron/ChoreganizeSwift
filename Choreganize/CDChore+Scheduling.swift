import CoreData
import Foundation

// Scheduling / completion / overdue logic, ported from AppModel onto the managed
// objects so the views can drive everything through Core Data + @FetchRequest.

/// A chore fetch that prefetches the relationships list/Work rendering touches —
/// `area`, `completions`, `household` — so SwiftUI doesn't fault them one row at a
/// time on the main thread. That per-row faulting was the N+1 `sqlite3_step` storm
/// behind the Edit/Work-open hang (cz_device10 triage). Used by `ChoreListView`
/// and `DayPage`.
func displayChoresFetchRequest() -> NSFetchRequest<CDChore> {
    let request = NSFetchRequest<CDChore>(entityName: "CDChore")
    request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
    request.relationshipKeyPathsForPrefetching = ["area", "completions", "household"]
    return request
}

// MARK: - Completion state & due-date logic

extension CDChore {
    /// Whether this chore is completed on the given day.
    func isCompleted(on date: Date) -> Bool {
        let cal = Calendar.current
        return completionsArray.contains { comp in
            guard let d = comp.date else { return false }
            return cal.isDate(d, inSameDayAs: date)
        }
    }

    /// The most recent completion on or before today (bounded by today).
    var lastCompletion: CDCompletion? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return completionsArray.first { comp in
            guard let d = comp.date else { return false }
            return cal.startOfDay(for: d) <= today
        }
    }

    /// Whether the chore is overdue based on its frequency and last completion.
    func isOverdue() -> Bool {
        guard let last = lastCompletion, let lastDate = last.date else { return true }
        let cal = Calendar.current
        let now = Date()
        if isDaily {
            return !cal.isDateInToday(lastDate)
        }
        guard let freq = frequencyValue else { return false }
        switch freq {
        case .weekly:
            guard let next = cal.date(byAdding: .weekOfYear, value: 1, to: lastDate) else { return false }
            return now >= next
        case .monthly:
            guard let next = cal.date(byAdding: .month, value: 1, to: lastDate) else { return false }
            return now >= next
        case .yearly:
            guard let next = cal.date(byAdding: .year, value: 1, to: lastDate) else { return false }
            return now >= next
        }
    }

    /// Whether the chore needs attention on the given date (not completed within
    /// its current scheduling window).
    func needsAttention(on date: Date) -> Bool {
        let cal = Calendar.current
        guard let last = lastCompletion, let lastDate = last.date else { return true }
        let next: Date?
        if isDaily {
            next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: lastDate))
        } else {
            next = nextDueDate(after: lastDate)
        }
        guard let next else { return true }
        return cal.startOfDay(for: next) <= cal.startOfDay(for: date)
    }

    /// The next scheduled date after the given reference (or the last completion).
    func nextDueDate(after date: Date? = nil) -> Date? {
        let cal = Calendar.current

        if isDaily {
            let reference = date ?? lastCompletion?.date
            let start = cal.startOfDay(for: reference ?? Date())
            return cal.date(byAdding: .day, value: 1, to: start)
        }

        guard let freq = frequencyValue else { return nil }
        let reference = date ?? lastCompletion?.date

        let startDate: Date
        if let reference {
            guard let advanced = cal.date(byAdding: freq.component, value: 1, to: reference) else { return nil }
            startDate = advanced
        } else {
            startDate = cal.startOfDay(for: Date())
        }

        guard let targetWeekday = assignedDayValue?.calendarWeekday else { return nil }
        var next = startDate
        while cal.component(.weekday, from: next) != targetWeekday {
            next = cal.date(byAdding: .day, value: 1, to: next)!
        }
        return next
    }

    /// Records a completion for the given day (no-op if already completed).
    /// Household completions are stamped with the completer's stable CloudKit
    /// user id (#59); Solo chores get no attribution.
    @discardableResult
    func recordCompletion(on date: Date = Date(), notes: String? = nil,
                          by completerID: String? = CompleterIdentity.cachedID,
                          in context: NSManagedObjectContext) -> CDCompletion? {
        guard !isCompleted(on: date) else { return nil }
        let completion = CDCompletion.make(in: context, date: date, notes: notes,
                                           completedBy: household == nil ? nil : completerID,
                                           chore: self, household: household)
        save(context)
        return completion
    }

    /// Removes the completion for the given day, if one exists.
    func removeCompletion(on date: Date, in context: NSManagedObjectContext) {
        let cal = Calendar.current
        guard let match = completionsArray.first(where: { comp in
            guard let d = comp.date else { return false }
            return cal.isDate(d, inSameDayAs: date)
        }) else { return }
        context.delete(match)
        save(context)
    }

    private func save(_ context: NSManagedObjectContext) {
        guard context.hasChanges else { return }
        do { try context.save() }
        catch { Log.error("CDChore save failed: \(error.localizedDescription)", category: .persistence) }
    }
}

// MARK: - Cross-chore scheduling helpers

enum Scheduling {
    /// Chores to show on a given date. Daily chores show every day. A scheduled
    /// (weekly/monthly/yearly) chore shows on its assigned weekday only when it's
    /// due or overdue, and stays there until completion is recorded — and remains
    /// visible on the day it's completed.
    static func chores(_ chores: [CDChore], for date: Date) -> [CDChore] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        return chores.filter { chore in
            if chore.isDaily { return true }
            guard let weekday = chore.assignedDayValue?.calendarWeekday,
                  cal.component(.weekday, from: dayStart) == weekday else { return false }
            return chore.needsAttention(on: date) || chore.isCompleted(on: date)
        }
    }

    /// A range of dates around `date`, never extending past six days beyond today.
    static func weekDates(startingFrom date: Date, includePast: Int, includeFuture: Int) -> [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let today = cal.startOfDay(for: Date())
        let maxFuture = cal.date(byAdding: .day, value: 6, to: today) ?? today
        let upperBound = min(includeFuture, cal.dateComponents([.day], from: start, to: maxFuture).day ?? 0)
        guard upperBound >= -includePast else { return [] }
        return (-includePast...upperBound).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    /// Maps dates within `month` to the chores due on those dates.
    static func choresByDate(inMonth month: Date, chores: [CDChore]) -> [Date: [CDChore]] {
        var result: [Date: [CDChore]] = [:]
        let cal = Calendar.current
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let monthEnd = cal.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)
        else { return result }

        for chore in chores {
            let created = cal.startOfDay(for: chore.createdDate ?? Date())

            if chore.isDaily {
                var next = created
                while next < monthStart { next = cal.date(byAdding: .day, value: 1, to: next)! }
                while next <= monthEnd {
                    result[cal.startOfDay(for: next), default: []].append(chore)
                    next = cal.date(byAdding: .day, value: 1, to: next)!
                }
                continue
            }

            guard let weekday = chore.assignedDayValue?.calendarWeekday, let freq = chore.frequencyValue else { continue }

            var next = created
            while cal.component(.weekday, from: next) != weekday {
                next = cal.date(byAdding: .day, value: 1, to: next)!
            }
            while next < monthStart {
                guard let advanced = cal.date(byAdding: freq.component, value: 1, to: next) else { break }
                var candidate = advanced
                while cal.component(.weekday, from: candidate) != weekday {
                    candidate = cal.date(byAdding: .day, value: 1, to: candidate)!
                }
                next = candidate
            }
            while next <= monthEnd {
                result[cal.startOfDay(for: next), default: []].append(chore)
                guard let advanced = cal.date(byAdding: freq.component, value: 1, to: next) else { break }
                var candidate = advanced
                while cal.component(.weekday, from: candidate) != weekday {
                    candidate = cal.date(byAdding: .day, value: 1, to: candidate)!
                }
                next = candidate
            }
        }
        return result
    }
}

// MARK: - Day locking (CDLockedDay)

enum DayLock {
    /// Past days are always locked; future days are locked only if explicitly set.
    static func isLocked(_ date: Date, in lockedDays: [CDLockedDay]) -> Bool {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        let today = cal.startOfDay(for: Date())
        if day < today { return true }
        return lockedDays.contains { ld in
            guard let d = ld.date else { return false }
            return cal.startOfDay(for: d) == day
        }
    }

    static func lock(_ date: Date, existing lockedDays: [CDLockedDay], household: CDHousehold?, in context: NSManagedObjectContext) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        guard day >= cal.startOfDay(for: Date()) else { return }
        let alreadyLocked = lockedDays.contains { ($0.date.map { cal.startOfDay(for: $0) == day }) ?? false }
        guard !alreadyLocked else { return }
        CDLockedDay.make(in: context, date: day, household: household)
        commit(context)
    }

    static func unlock(_ date: Date, existing lockedDays: [CDLockedDay], in context: NSManagedObjectContext) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        for ld in lockedDays where (ld.date.map { cal.startOfDay(for: $0) == day }) ?? false {
            context.delete(ld)
        }
        commit(context)
    }

    private static func commit(_ context: NSManagedObjectContext) {
        guard context.hasChanges else { return }
        do { try context.save() }
        catch { Log.error("DayLock save failed: \(error.localizedDescription)", category: .persistence) }
    }
}
