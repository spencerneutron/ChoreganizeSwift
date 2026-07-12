import CoreData
import Foundation

// CG-21 / #103 + CG-22 / #104 — pure aggregation behind the Insights surface.
//
// Everything here is `nonisolated`, value-returning, and derived from the SAME
// machinery the calendar renders with — `Scheduling.choresByDate` for what was
// due, `CalendarMarks.progress` for what counts (incl. the existedOn #85 rule),
// and `CalendarStreaks` for the perfect-day/streak scoring — so Insights can
// never disagree with the month grid about a day's numbers. All math is
// on-device over already-fetched managed objects; nothing here touches the
// network or performs its own fetches.
enum InsightsMath {

    // MARK: - Shared due-per-day derivation

    /// Chores due on each day of `start...end` (start-of-day keys). Applies
    /// `Scheduling.choresByDate` to every month the range touches and trims to
    /// the range — reuse, not a re-derivation of due-ness (same approach as
    /// `CalendarStreaks.perfectDays`).
    nonisolated static func choresByDay(chores: [CDChore], from start: Date, to end: Date,
                                        calendar cal: Calendar = .current) -> [Date: [CDChore]] {
        var result: [Date: [CDChore]] = [:]
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        guard startDay <= endDay,
              var monthAnchor = cal.date(from: cal.dateComponents([.year, .month], from: startDay))
        else { return result }
        while monthAnchor <= endDay {
            let byDate = Scheduling.choresByDate(inMonth: monthAnchor, chores: chores)
            for (day, dayChores) in byDate where day >= startDay && day <= endDay {
                result[day] = dayChores
            }
            guard let next = cal.date(byAdding: .month, value: 1, to: monthAnchor) else { break }
            monthAnchor = next
        }
        return result
    }

    /// One day's countable due/completed pair, scored exactly as the calendar
    /// meter scores it (`CalendarMarks.progress`, so #85's existedOn filter
    /// applies). The display-only inputs (mode/daysAgo/locked) don't affect the
    /// counts, so neutral values are passed.
    private nonisolated static func counts(_ dayChores: [CDChore], on day: Date,
                                           calendar cal: Calendar) -> (due: Int, completed: Int) {
        let p = CalendarMarks.progress(dayChores, on: day,
                                       mode: CalendarMarks.mode(for: day, calendar: cal),
                                       daysAgo: 0, locked: false)
        return (p.total, p.completed)
    }

    // MARK: - Completion rate (CG-21 / #103)

    /// Completed-vs-due totals over a window of days.
    nonisolated struct WindowStats: Equatable {
        var due: Int
        var completed: Int
        var ratio: Double { due > 0 ? Double(completed) / Double(due) : 0 }
        var percent: Int { Int((ratio * 100).rounded()) }
    }

    /// Completion rate over the trailing `days` window ending on `today`
    /// (inclusive) — the headline 7d/30d cards.
    nonisolated static func completionStats(chores: [CDChore], lastDays days: Int,
                                            endingOn today: Date = Date(),
                                            calendar cal: Calendar = .current) -> WindowStats {
        let end = cal.startOfDay(for: today)
        guard days > 0, let start = cal.date(byAdding: .day, value: -(days - 1), to: end) else {
            return WindowStats(due: 0, completed: 0)
        }
        var due = 0
        var completed = 0
        for (day, dayChores) in choresByDay(chores: chores, from: start, to: end, calendar: cal) {
            let c = counts(dayChores, on: day, calendar: cal)
            due += c.due
            completed += c.completed
        }
        return WindowStats(due: due, completed: completed)
    }

    // MARK: - Per-room / per-frequency breakdowns (CG-21 / #103)

    /// Completed-vs-due for one named group (a room, or a frequency bucket).
    nonisolated struct GroupStats: Equatable, Identifiable {
        var name: String
        var due: Int
        var completed: Int
        var id: String { name }
        var ratio: Double { due > 0 ? Double(completed) / Double(due) : 0 }
        var percent: Int { Int((ratio * 100).rounded()) }
    }

    /// Bucket label for chores with no `CDArea`.
    nonisolated static let noRoomLabel = "No room"

    /// Per-room (CDArea) completion over the trailing window, busiest room
    /// first. Chores without a room land in `noRoomLabel`.
    nonisolated static func roomBreakdown(chores: [CDChore], lastDays days: Int = 30,
                                          endingOn today: Date = Date(),
                                          calendar cal: Calendar = .current) -> [GroupStats] {
        let end = cal.startOfDay(for: today)
        guard days > 0, let start = cal.date(byAdding: .day, value: -(days - 1), to: end) else { return [] }
        return groupedStats(chores: chores, from: start, to: end, calendar: cal) {
            $0.area?.name ?? noRoomLabel
        }
        .sorted { $0.due != $1.due ? $0.due > $1.due : $0.name < $1.name }
    }

    /// Per-frequency completion over the trailing window, in schedule order
    /// (Daily → Weekly → Monthly → Yearly).
    nonisolated static func frequencyBreakdown(chores: [CDChore], lastDays days: Int = 30,
                                               endingOn today: Date = Date(),
                                               calendar cal: Calendar = .current) -> [GroupStats] {
        let end = cal.startOfDay(for: today)
        guard days > 0, let start = cal.date(byAdding: .day, value: -(days - 1), to: end) else { return [] }
        let order = ["Daily", "Weekly", "Monthly", "Yearly"]
        return groupedStats(chores: chores, from: start, to: end, calendar: cal) { chore in
            chore.isDaily ? "Daily" : (chore.frequencyValue?.rawValue.capitalized ?? "Unscheduled")
        }
        .sorted { (order.firstIndex(of: $0.name) ?? .max) < (order.firstIndex(of: $1.name) ?? .max) }
    }

    /// Shared grouping core: due/completed per `key` across the range.
    private nonisolated static func groupedStats(chores: [CDChore], from start: Date, to end: Date,
                                                 calendar cal: Calendar,
                                                 key: (CDChore) -> String) -> [GroupStats] {
        var due: [String: Int] = [:]
        var completed: [String: Int] = [:]
        for (day, dayChores) in choresByDay(chores: chores, from: start, to: end, calendar: cal) {
            // Group per chore, but keep the countable/completed rules identical
            // to `counts` by scoring each chore through CalendarMarks alone.
            for chore in dayChores where chore.existedOn(day, calendar: cal) {
                let k = key(chore)
                due[k, default: 0] += 1
                if chore.isCompleted(on: day) { completed[k, default: 0] += 1 }
            }
        }
        return due.map { GroupStats(name: $0.key, due: $0.value, completed: completed[$0.key] ?? 0) }
    }

    // MARK: - Streaks (CG-21 / #103 — reuse, not reimplementation)

    /// Current + longest perfect-day streaks — a thin pass-through to the
    /// calendar's own machinery (`CalendarStreaks.perfectDays` → `earnsGlow`,
    /// `CalendarStreaks.summary`) so Insights can't invent a second
    /// perfect-day rule.
    nonisolated static func streakSummary(scopedChores: [CDChore], scopedLocks: [CDLockedDay],
                                          monthsBack: Int = 12,
                                          calendar cal: Calendar = .current) -> CalendarStreaks.Summary {
        CalendarStreaks.summary(
            for: CalendarStreaks.perfectDays(scopedChores: scopedChores, scopedLocks: scopedLocks,
                                             monthsBack: monthsBack, calendar: cal),
            calendar: cal)
    }

    // MARK: - Yearly heatmap (CG-22 / #104)

    /// One heatmap cell: `bucket` is nil when nothing was due that day
    /// (including every day before any chore existed — #85 keeps those at
    /// zero due), else a 0–4 intensity from the day's completion ratio.
    nonisolated struct HeatmapDay: Equatable, Identifiable {
        var date: Date        // start-of-day
        var bucket: Int?      // nil = empty; 0 = none done; 1–3 partial; 4 = all done
        var id: Date { date }
    }

    /// 0–4 intensity bucket from a day's counts. Boundaries: nothing due → nil
    /// (empty cell), 0 done → 0, all done → 4, partials split at ⅓ and ⅔.
    nonisolated static func heatmapBucket(completed: Int, total: Int) -> Int? {
        guard total > 0 else { return nil }
        guard completed > 0 else { return 0 }
        guard completed < total else { return 4 }
        let ratio = Double(completed) / Double(total)
        if ratio <= 1.0 / 3.0 { return 1 }
        if ratio <= 2.0 / 3.0 { return 2 }
        return 3
    }

    /// A cell for each of the last `days` days ending on `today` (inclusive),
    /// oldest first — the GitHub-style year grid's data.
    nonisolated static func yearHeatmap(chores: [CDChore], days: Int = 365,
                                        endingOn today: Date = Date(),
                                        calendar cal: Calendar = .current) -> [HeatmapDay] {
        let end = cal.startOfDay(for: today)
        guard days > 0, let start = cal.date(byAdding: .day, value: -(days - 1), to: end) else { return [] }
        let byDay = choresByDay(chores: chores, from: start, to: end, calendar: cal)
        var result: [HeatmapDay] = []
        result.reserveCapacity(days)
        var day = start
        while day <= end {
            let c = counts(byDay[day] ?? [], on: day, calendar: cal)
            result.append(HeatmapDay(date: day, bucket: heatmapBucket(completed: c.completed, total: c.due)))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    // MARK: - Monthly share-card summary (CG-22 / #104)

    /// Everything the shareable month card renders. Value-only (no managed
    /// objects) so it can cross into `ImageRenderer` content untethered.
    nonisolated struct MonthSummary: Equatable {
        var monthStart: Date
        var stats: WindowStats
        /// Longest run of perfect days *within* the month (through `today`).
        var bestStreak: Int
        /// Room with the best completion ratio this month (ties → more due
        /// chores wins). Nil when nothing was due yet.
        var topRoom: String?
        /// One bucket per elapsed day of the month (1st → today / month end),
        /// for the card's mini heatmap strip.
        var dayBuckets: [Int?]
    }

    /// Summarizes the month containing `date`, up to and including `date`
    /// (future days of an in-progress month are excluded, matching the
    /// calendar's "nothing to complete yet" stance).
    nonisolated static func monthSummary(chores: [CDChore], locks: [CDLockedDay],
                                         containing date: Date = Date(),
                                         calendar cal: Calendar = .current) -> MonthSummary {
        let today = cal.startOfDay(for: date)
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: today)),
              let monthEnd = cal.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)
        else {
            return MonthSummary(monthStart: today, stats: WindowStats(due: 0, completed: 0),
                                bestStreak: 0, topRoom: nil, dayBuckets: [])
        }
        let end = min(monthEnd, today)
        let byDay = Scheduling.choresByDate(inMonth: monthStart, chores: chores)

        var due = 0
        var completed = 0
        var buckets: [Int?] = []
        var perfect: Set<Date> = []
        var day = monthStart
        while day <= end {
            let dayChores = byDay[day] ?? []
            let c = counts(dayChores, on: day, calendar: cal)
            due += c.due
            completed += c.completed
            buckets.append(heatmapBucket(completed: c.completed, total: c.due))
            // Perfect-day scoring stays the calendar's (earnsGlow), locks included.
            let daysAgo = cal.dateComponents([.day], from: day, to: today).day ?? 0
            let p = CalendarMarks.progress(dayChores, on: day,
                                           mode: CalendarMarks.mode(for: day, calendar: cal),
                                           daysAgo: daysAgo,
                                           locked: DayLock.isLocked(day, in: locks))
            if p.earnsGlow { perfect.insert(day) }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let bestStreak = CalendarStreaks.slots(for: perfect, calendar: cal).values.map(\.count).max() ?? 0
        let topRoom = groupedStats(chores: chores, from: monthStart, to: end, calendar: cal) {
            $0.area?.name ?? noRoomLabel
        }
        .filter { $0.due > 0 }
        .max { ($0.ratio, $0.due) < ($1.ratio, $1.due) }?
        .name

        return MonthSummary(monthStart: monthStart,
                            stats: WindowStats(due: due, completed: completed),
                            bestStreak: bestStreak, topRoom: topRoom, dayBuckets: buckets)
    }
}
