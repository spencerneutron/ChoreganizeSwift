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

    // MARK: - One chore's stats (CG-28 / #129)

    /// A chore's own numbers, for its editor: when it was last done and how often it
    /// usually is (free), and how often it's done on its due day and who usually does it
    /// (Plus). Due days come from the calendar's derivation and a day counts as done by the
    /// same same-day rule. Unlike the calendar and the Insights tab, an unfinished today
    /// isn't counted against it: the day isn't over.
    nonisolated struct ChoreStats: Equatable {
        /// The latest completion on or before today.
        var lastDone: Date?
        /// The median number of days between recent completions. Nil until there are four
        /// completions, so a gap or two doesn't pass for a habit.
        var typicalGapDays: Int?
        /// Due days in the window it was done that day. Today counts only once it's done.
        /// Zero when not computed (`includesOnTime: false`).
        var onTime: WindowStats
        /// The window `onTime` covers, long enough for a few due days at the chore's pace.
        var onTimeWindowDays: Int
        /// The most frequent completer over the last `completerWindowDays`, when at least
        /// two completions there say who did them (households).
        var topCompleter: Completer?

        nonisolated struct Completer: Equatable {
            /// A `CDCompletion.completedBy` id.
            var id: String
            var count: Int
            /// Completions in the window that say who did them.
            var attributed: Int
        }
    }

    nonisolated static let completerWindowDays = 90
    /// Gaps behind `typicalGapDays`: recent habit, not the chore's whole history.
    nonisolated static let typicalGapSample = 10

    /// Whether the chore has due days at all: a weekly, monthly or yearly chore with no day
    /// set never comes due on the calendar, so it has no on-time rate.
    nonisolated static func hasDueDays(_ chore: CDChore) -> Bool {
        chore.isDaily || !chore.assignedDaysValue.isEmpty || chore.assignedDayValue?.calendarWeekday != nil
    }

    /// The on-time window for a chore: a month for daily and weekly chores, six months for
    /// monthly and two years for yearly ones, times its repeat interval ("every 6 weeks"
    /// looks back 6 months), so a single miss isn't the whole story.
    nonisolated static func onTimeWindowDays(for chore: CDChore) -> Int {
        if chore.isDaily { return 30 }
        let base: Int
        switch chore.frequencyValue {
        case .monthly: base = 180
        case .yearly: base = 730
        case .weekly, nil: base = 30
        }
        return base * max(1, chore.recurrenceIntervalValue)
    }

    /// The start-of-days a chore was done on, up to today. Built once per chore so the
    /// day loops below don't re-sort its history for every day they check.
    private nonisolated static func completedDays(_ chore: CDChore, through today: Date,
                                                  calendar cal: Calendar) -> Set<Date> {
        let end = cal.startOfDay(for: today)
        return Set(chore.completionsArray.compactMap { completion -> Date? in
            guard let d = completion.date else { return nil }
            let day = cal.startOfDay(for: d)
            return day <= end ? day : nil
        })
    }

    /// - Parameter includesOnTime: false skips the on-time pass (the row is locked).
    nonisolated static func choreStats(for chore: CDChore, includesOnTime: Bool = true,
                                       today: Date = Date(),
                                       calendar cal: Calendar = .current) -> ChoreStats {
        let todayStart = cal.startOfDay(for: today)
        let done = completedDays(chore, through: today, calendar: cal)
        let days = done.sorted()

        var typicalGap: Int?
        if days.count >= 4 {
            let gaps = zip(days, days.dropFirst())
                .compactMap { cal.dateComponents([.day], from: $0, to: $1).day }
                .suffix(typicalGapSample)
                .sorted()
            if !gaps.isEmpty {
                let mid = gaps.count / 2
                typicalGap = gaps.count.isMultiple(of: 2)
                    ? Int((Double(gaps[mid - 1] + gaps[mid]) / 2).rounded())
                    : gaps[mid]
            }
        }

        let windowDays = onTimeWindowDays(for: chore)
        var onTime = WindowStats(due: 0, completed: 0)
        if includesOnTime, let start = cal.date(byAdding: .day, value: -(windowDays - 1), to: todayStart) {
            for (day, dayChores) in choresByDay(chores: [chore], from: start, to: todayStart, calendar: cal)
            where !dayChores.isEmpty {
                let doneThatDay = done.contains(day)
                if day == todayStart && !doneThatDay { continue }   // today isn't over yet
                onTime.due += 1
                if doneThatDay { onTime.completed += 1 }
            }
        }

        var topCompleter: ChoreStats.Completer?
        if let since = cal.date(byAdding: .day, value: -(completerWindowDays - 1), to: todayStart) {
            // Newest first, so a tie goes to whoever did it most recently.
            let ids = chore.completionsArray.compactMap { c -> String? in
                guard let d = c.date else { return nil }
                let day = cal.startOfDay(for: d)
                return day >= since && day <= todayStart ? c.completedBy : nil
            }
            if ids.count >= 2 {
                let counts = Dictionary(ids.map { ($0, 1) }, uniquingKeysWith: +)
                if let best = counts.values.max(),
                   let id = ids.first(where: { counts[$0] == best }) {
                    topCompleter = .init(id: id, count: best, attributed: ids.count)
                }
            }
        }

        return ChoreStats(lastDone: days.last, typicalGapDays: typicalGap, onTime: onTime,
                          onTimeWindowDays: windowDays, topCompleter: topCompleter)
    }

    // MARK: - One room's stats (CG-28 / #129)

    /// A room's numbers, for its editor (Plus, like the Insights tab's room breakdown):
    /// how often its chores are done on their due days, and which chore misses most.
    nonisolated struct RoomStats: Equatable {
        /// Due days of the room's chores in the window that were done that day. Today
        /// counts only once done, as for one chore (so it can trail the tab's room row
        /// by today's open chores).
        var onTime: WindowStats
        var mostMissed: Missed?

        nonisolated struct Missed: Equatable {
            var name: String
            /// Past due days it wasn't done.
            var missed: Int
            var due: Int
        }
    }

    /// A chore needs this many due days in the window to be the room's most missed, so one
    /// missed day doesn't make a chore look worse than one missed every day for a month.
    nonisolated static let mostMissedMinimumDue = 3

    nonisolated static func roomStats(chores: [CDChore], lastDays days: Int = 30,
                                      today: Date = Date(),
                                      calendar cal: Calendar = .current) -> RoomStats {
        let todayStart = cal.startOfDay(for: today)
        var onTime = WindowStats(due: 0, completed: 0)
        var perChore: [NSManagedObjectID: (chore: CDChore, done: Set<Date>, due: Int, missed: Int)] = [:]
        if days > 0, let start = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) {
            for (day, dayChores) in choresByDay(chores: chores, from: start, to: todayStart, calendar: cal) {
                for chore in dayChores where chore.existedOn(day, calendar: cal) {
                    var entry = perChore[chore.objectID]
                        ?? (chore, completedDays(chore, through: today, calendar: cal), 0, 0)
                    let done = entry.done.contains(day)
                    if day == todayStart && !done { continue }   // today isn't over yet
                    onTime.due += 1
                    if done { onTime.completed += 1 }
                    entry.due += 1
                    if !done { entry.missed += 1 }
                    perChore[chore.objectID] = entry
                }
            }
        }
        // By miss rate, then misses, then name: a weekly chore never done outranks a daily
        // one missed a few times.
        let worst = perChore.values
            .filter { $0.missed > 0 && $0.due >= mostMissedMinimumDue }
            .max { a, b in
                let rateA = Double(a.missed) / Double(a.due), rateB = Double(b.missed) / Double(b.due)
                if rateA != rateB { return rateA < rateB }
                if a.missed != b.missed { return a.missed < b.missed }
                return (a.chore.name ?? "").localizedStandardCompare(b.chore.name ?? "") == .orderedDescending
            }
        return RoomStats(onTime: onTime,
                         mostMissed: worst.map { .init(name: $0.chore.name ?? "Untitled", missed: $0.missed, due: $0.due) })
    }

    // MARK: - Household members (CG-28 / #129)

    /// One completion, reduced to what the member stats need, so it can be read off a
    /// background context and summarised anywhere.
    nonisolated struct MemberCompletion: Equatable, Sendable {
        /// The chore's id, so a chore recorded twice on one day (a sync duplicate) counts once.
        var choreID: UUID?
        /// `CDCompletion.completedBy`; nil when it doesn't say who did it.
        var completedBy: String?
        var date: Date
    }

    /// A member's recent chores, for Hub ▸ Household (Plus). Meant to encourage, not keep
    /// score: a count and a run of days, never a rank or a share of the total.
    nonisolated struct MemberStats: Equatable, Identifiable, Sendable {
        /// A `CDCompletion.completedBy` id.
        var id: String
        /// Chores they did in the window.
        var choresDone: Int
        /// Days in a row, up to today, with at least one chore. Today doesn't break it
        /// before it's done: the run then counts back from yesterday.
        var streak: Int
    }

    nonisolated struct MembersSummary: Equatable, Sendable {
        /// Members with at least one chore in the window, by id.
        var members: [MemberStats]
        /// Chores done in the window by anyone, including ones that don't say who.
        var total: Int
        var windowDays: Int
    }

    nonisolated static let memberWindowDays = 30
    /// How far back a member's run can reach: the history Hub ▸ Household loads.
    nonisolated static let memberHistoryDays = 365

    nonisolated static func membersSummary(_ completions: [MemberCompletion],
                                           lastDays days: Int = memberWindowDays,
                                           today: Date = Date(),
                                           calendar cal: Calendar = .current) -> MembersSummary {
        struct ChoreDay: Hashable { var chore: UUID?; var day: Date }
        let todayStart = cal.startOfDay(for: today)
        let start = cal.date(byAdding: .day, value: -(max(days, 1) - 1), to: todayStart) ?? todayStart

        var everyone = Set<ChoreDay>()
        var inWindow: [String: Set<ChoreDay>] = [:]
        var activeDays: [String: Set<Date>] = [:]
        for completion in completions {
            let day = cal.startOfDay(for: completion.date)
            guard day <= todayStart else { continue }
            if let id = completion.completedBy { activeDays[id, default: []].insert(day) }
            guard day >= start else { continue }
            let key = ChoreDay(chore: completion.choreID, day: day)
            everyone.insert(key)
            if let id = completion.completedBy { inWindow[id, default: []].insert(key) }
        }

        let members = inWindow.map { id, done -> MemberStats in
            let active = activeDays[id] ?? []
            var day = active.contains(todayStart) ? todayStart : cal.date(byAdding: .day, value: -1, to: todayStart)
            var streak = 0
            while let d = day, active.contains(d) {
                streak += 1
                day = cal.date(byAdding: .day, value: -1, to: d)
            }
            return MemberStats(id: id, choresDone: done.count, streak: streak)
        }
        .sorted { $0.id < $1.id }
        return MembersSummary(members: members, total: everyone.count, windowDays: days)
    }
}
