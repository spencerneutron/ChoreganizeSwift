import SwiftUI

/// Presents a month grid with chore counts.
struct CalendarHomeView: View {
    @EnvironmentObject private var model: AppModel
    // Prefetches area/completions/household so the month grid's per-day completion
    // checks don't fault each chore's relationships on the main thread (cz_device11).
    @FetchRequest(fetchRequest: displayChoresFetchRequest()) private var allChores: FetchedResults<CDChore>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDLockedDay.date)]) private var lockedDays: FetchedResults<CDLockedDay>
    @State private var month: Date = Date()
    /// One shared device-motion source; the glow bars' specular sweep tracks roll (#57 fast-follow).
    @StateObject private var tilt = TiltProvider()

    private var calendar: Calendar { Calendar.current }

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
    }

    private var days: [Date?] {
        let range = calendar.range(of: .day, in: .month, for: monthStart)!
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        var items: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for day in range {
            items.append(calendar.date(byAdding: .day, value: day - 1, to: monthStart)!)
        }
        while items.count % 7 != 0 { items.append(nil) }
        return items
    }

    private var choresByDate: [Date: [CDChore]] {
        Scheduling.choresByDate(inMonth: monthStart, chores: Array(allChores).inScope(model.activeHousehold))
    }

    /// Days in the visible grid that earn the glow — used to conduct one specular sweep across a
    /// run of consecutive perfect days.
    private func perfectDays(scopedLocks: [CDLockedDay]) -> Set<Date> {
        let today = calendar.startOfDay(for: Date())
        var set: Set<Date> = []
        for case let date? in days {
            let day = calendar.startOfDay(for: date)
            let p = CalendarMarks.progress(
                choresByDate[day] ?? [], on: date,
                mode: CalendarMarks.mode(for: date),
                daysAgo: calendar.dateComponents([.day], from: day, to: today).day ?? 0,
                locked: DayLock.isLocked(date, in: scopedLocks))
            if p.earnsGlow { set.insert(day) }
        }
        return set
    }

    var body: some View {
        let scopedLocks = Array(lockedDays).inScope(model.activeHousehold)
        let streaks = CalendarStreaks.slots(for: perfectDays(scopedLocks: scopedLocks))
        return VStack {
            HStack {
                Button(action: { month = calendar.date(byAdding: .month, value: -1, to: month)! }) {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                Text(monthStart, format: Date.FormatStyle().month(.wide).year())
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { month = calendar.date(byAdding: .month, value: 1, to: month)! }) {
                    Image(systemName: "chevron.right")
                }
            }
            .padding(.horizontal)
            .animation(.easeInOut, value: month)

            let columns = Array(repeating: GridItem(.flexible()), count: 7)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(calendar.shortWeekdaySymbols, id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                    if let date {
                        NavigationLink(destination:
                            DayPage(date: date)
                                .toolbar(.visible, for: .navigationBar)
                        ) {
                            DayCell(date: date,
                                    chores: choresByDate[calendar.startOfDay(for: date)] ?? [],
                                    isLocked: DayLock.isLocked(date, in: scopedLocks),
                                    tilt: tilt,
                                    streak: streaks[calendar.startOfDay(for: date)] ?? (slot: 0, count: 1))
                        }
                    } else {
                        Color.clear
                            .frame(minHeight: 46)
                    }
                }
            }.frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal)
        }
        .toolbar(.hidden, for: .navigationBar)
        // Drive device-motion at the calendar level (one source for all glow bars), and stop it
        // when the calendar isn't visible. No-op where motion is unavailable (Simulator).
        .onAppear { tilt.start() }
        .onDisappear { tilt.stop() }
    }
}

// MARK: - Calendar day-cell marks (#57)

/// Tunables shared by the calendar's cell rendering (Part 1) and the retroactive
/// log-completion affordance (Part 2). Centralized so the two can't drift apart.
enum CalendarPolicy {
    /// Past days older than this no longer render "incomplete/red" marks; completed
    /// (green) marks are always shown. Recent incompletes are exactly the ones still
    /// worth acting on — and the window where retroactive logging is most useful.
    static let recentIncompleteWindow: Int = 14   // days
}

/// How a calendar cell relates to today — selects the meter colors.
enum CellMode: Equatable { case past, currentWeek, future }

/// The per-day completion summary a cell renders: a proportional meter (green =
/// completed share) + a "% done" label. Pure value type so it's unit-testable.
struct DayProgress: Equatable {
    let total: Int
    let completed: Int
    let mode: CellMode
    /// Within `CalendarPolicy.recentIncompleteWindow` of today (drives the remainder
    /// color — red when recent/actionable, neutral when older).
    let withinWindow: Bool
    /// Whether the day is locked (past days are always locked; today is locked once the
    /// user taps "Done"). Lets a finished, fully-completed *today* earn the glow.
    let locked: Bool

    var ratio: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    var percent: Int { Int((ratio * 100).rounded()) }

    /// Show the meter at all? Future days show it (upcoming, blue); past/current show
    /// it when recent OR when something was completed. An older, all-incomplete day
    /// stays blank — no neutral "wall of zeros" (the recency-window principle).
    var showsMeter: Bool {
        total > 0 && (mode == .future || withinWindow || completed > 0)
    }
    /// "% done" is only meaningful for past/current days (future has nothing to complete).
    var showsPercent: Bool { showsMeter && mode != .future }

    /// Earns the celebratory glow bar (a single combined green bar, no "%"): a fully
    /// completed day that's *settled* — any past day, or **today once it's locked**
    /// (the user tapped Done). Empty days and unfinished/unlocked todays don't qualify.
    var earnsGlow: Bool {
        total > 0 && completed == total && (mode == .past || (mode == .currentWeek && locked))
    }
}

enum CalendarMarks {
    /// The cell's completion summary. Pure + `nonisolated` so it's unit-testable
    /// without the main actor. `future` days carry `completed == 0` (nothing done yet).
    nonisolated static func progress(_ chores: [CDChore], on date: Date,
                                     mode: CellMode, daysAgo: Int, locked: Bool) -> DayProgress {
        DayProgress(
            total: chores.count,
            completed: chores.filter { $0.isCompleted(on: date) }.count,
            mode: mode,
            withinWindow: daysAgo <= CalendarPolicy.recentIncompleteWindow,
            locked: locked
        )
    }

    /// Whether a date is past, today, or future relative to now. Shared by the cell and the
    /// streak scan so the two can't disagree about what "today" means.
    nonisolated static func mode(for date: Date, calendar cal: Calendar = .current) -> CellMode {
        let today = cal.startOfDay(for: Date())
        let day = cal.startOfDay(for: date)
        if day < today { return .past }
        return day == today ? .currentWeek : .future
    }
}

/// Groups perfect (glow-earning) days into maximal runs of consecutive calendar days so a single
/// specular sweep can be conducted across a streak (#57 fast-follow). For each perfect day it
/// returns its 0-based `slot` within its run and the run's `count`; a lone perfect day is slot 0
/// of 1. Pure + `nonisolated` so it's unit-testable.
enum CalendarStreaks {
    nonisolated static func slots(for perfectDays: Set<Date>,
                                  calendar cal: Calendar = .current) -> [Date: (slot: Int, count: Int)] {
        let days = perfectDays.map { cal.startOfDay(for: $0) }.sorted()
        var result: [Date: (slot: Int, count: Int)] = [:]
        var i = 0
        while i < days.count {
            var j = i
            while j + 1 < days.count,
                  let next = cal.date(byAdding: .day, value: 1, to: days[j]),
                  cal.isDate(next, inSameDayAs: days[j + 1]) {
                j += 1
            }
            let count = j - i + 1
            for k in i...j { result[days[k]] = (slot: k - i, count: count) }
            i = j + 1
        }
        return result
    }
}

private struct DayCell: View {
    var date: Date
    var chores: [CDChore]
    var isLocked: Bool
    var tilt: TiltProvider
    /// This day's place in a run of consecutive perfect days (slot 0 of 1 when not in a streak).
    var streak: (slot: Int, count: Int) = (0, 1)

    private var cal: Calendar { Calendar.current }
    private var dayNumber: Int { cal.component(.day, from: date) }
    private var isToday: Bool { cal.isDateInToday(date) }
    /// Completion semantics (green/red + %) apply to today and past days; any day
    /// after today is "upcoming" (blue, no %) — even when it falls in the current week.
    private var mode: CellMode { CalendarMarks.mode(for: date, calendar: cal) }
    private var daysAgo: Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: date),
                           to: cal.startOfDay(for: Date())).day ?? 0
    }

    private func summary(_ p: DayProgress) -> String {
        let day = date.formatted(.dateTime.weekday(.wide).month().day())
        guard p.total > 0 else { return "\(day). No chores." }
        if p.mode == .future {
            return "\(day). \(p.total) upcoming \(p.total == 1 ? "chore" : "chores")."
        }
        return "\(day). \(p.completed) of \(p.total) done, \(p.percent)%."
    }

    var body: some View {
        let p = CalendarMarks.progress(chores, on: date, mode: mode, daysAgo: daysAgo, locked: isLocked)
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(dayNumber))
                .fontWeight(isToday ? .bold : .regular)
                .foregroundStyle(isToday ? Color.white : Color.primary)
                .padding(5)
                .background { if isToday { Circle().fill(.tint) } }
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if p.earnsGlow {
                // A settled, fully-completed day (any past day, or today once locked):
                // the three segments fuse into one glowing green bar. The glow says
                // "100%" on its own, so the label is dropped. `tilt` + `streak` drive the
                // device-motion-reactive sweep and conduct it across consecutive perfect days.
                NeonCompletionBar(tilt: tilt, slot: streak.slot, slots: streak.count)
            } else if p.showsMeter {
                HStack(spacing: 3) {
                    DayMeter(progress: p)
                    if p.showsPercent {
                        Text("\(p.percent)%")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary(p))
        .accessibilityIdentifier("calendar-day-\(dayNumber)")
    }
}

/// Three bar segments whose green fill is the completion ratio (continuous — a
/// boundary segment fills partially). Green encodes "done" by FILL as well as hue,
/// so it survives grayscale / red-green color blindness; the remainder track is red
/// when recent/actionable, neutral-gray when older, blue for upcoming future days.
private struct DayMeter: View {
    let progress: DayProgress
    private let segments = 3

    private var trackColor: Color {
        switch progress.mode {
        case .future:                 return .blue
        case .past, .currentWeek:     return progress.withinWindow ? .red : .gray
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                // Continuous fill: each segment takes the next 1/`segments` slice of the
                // ratio. `.future` shows an empty (blue) track — nothing completed yet.
                let fill = progress.mode == .future
                    ? 0
                    : min(max(progress.ratio * Double(segments) - Double(i), 0), 1)
                Capsule()
                    .fill(trackColor.opacity(0.22))
                    .overlay { Capsule().strokeBorder(trackColor, lineWidth: 0.75) }
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.green).scaleEffect(x: fill, anchor: .leading)
                    }
                    .frame(height: 3)
            }
        }
        .frame(height: 4)
    }
}

/// One shared time origin so every glow bar shares the sweep's phase — no per-cell
/// animation churn, and a future "streak" treatment can conduct one sweep across a run
/// of adjacent perfect days just by phase-offsetting each bar (see calendar-glow-handoff §streaks).
enum GlowClock { static let epoch = Date() }

private struct GlowAnimationActiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False when a full-cover sheet (e.g. the Hub) is presented over the calendar. A sheet
    /// doesn't unmount its presenter, so the glow's `TimelineView` + Metal shaders would keep
    /// running behind it at 60 fps and starve the sheet's scroll framerate. The calendar sets
    /// this from `ContentView`'s sheet state; `NeonCompletionBar` freezes to a static bar when false.
    var glowAnimationActive: Bool {
        get { self[GlowAnimationActiveKey.self] }
        set { self[GlowAnimationActiveKey.self] = newValue }
    }
}

/// Pre-compiles the perfect-day glow shader off-main at launch so the first perfect bar
/// doesn't hitch on first use — the glow analog of the Metal/haptic pre-warms in the app.
enum GlowPrewarm {
    static func run() {
        Task.detached(priority: .utility) {
            let shader = ShaderLibrary.perfectDayGlow(.float(0),
                                                      .float2(CGSize(width: 1, height: 1)),
                                                      .float(0), .float(1),   // slot, slots
                                                      .float(0), .float(1))   // tilt, intensity
            try? await shader.compile(as: .colorEffect)
        }
    }
}

/// Celebratory bar for a fully-completed *past* day (#57). On appear it **ignites**
/// (a quick grow-in + brighter halo), then rests with a slow **specular sweep** gliding
/// along the bar — "energized," not nagging (per the researcher's recommendation). The
/// glow itself signals 100%, so the cell drops the "%" label.
///
/// Accessibility: Reduce Motion / Low Power → a static glossy bar (no sweep); Differentiate
/// Without Color → a seal glyph so "perfect" isn't conveyed by color+glow alone. Decorative —
/// the cell's a11y label still states the count.
///
/// Implemented with a Metal `colorEffect` shader (`PerfectDayGlow.metal`) that paints a
/// traveling specular highlight, pre-compiled at launch (`GlowPrewarm`) to avoid a first-use
/// hitch. Reduce Motion / Low Power fall back to a static glossy bar.
///
/// The sweep is **device-motion reactive** (`tilt` ← `TiltProvider.roll`, so the highlight slides
/// as the phone tilts and settles when set down) and **conducts across a streak** of consecutive
/// perfect days (`slot`/`slots`): one highlight relays from one day to the next via the shared
/// `GlowClock` epoch, so a run reads as a single glowing strip. See calendar-glow-recommendation.
private struct NeonCompletionBar: View {
    var tilt: TiltProvider
    /// Position within a consecutive-perfect-day streak (slot 0 of 1 = a lone perfect day).
    var slot: Int = 0
    var slots: Int = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var diffWithoutColor
    @Environment(\.colorScheme) private var scheme
    @Environment(\.glowAnimationActive) private var glowActive
    @State private var lit = false

    /// Deepen the green in light mode (halos read poorly on white; lean on core + glyph).
    private var base: Color {
        scheme == .dark ? Color(red: 0.18, green: 0.95, blue: 0.45)
                        : Color(red: 0.05, green: 0.62, blue: 0.30)
    }
    /// Render the static (non-animated) bar — no `TimelineView`/shader churn — under Reduce
    /// Motion, Low Power, or when the calendar is obscured by a sheet (so the shader doesn't
    /// burn frames behind, e.g., the Hub).
    private var still: Bool {
        reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled || !glowActive
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            barCore
            if diffWithoutColor {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.trailing, 1)
            }
        }
        .frame(height: 4)
        // Halo brightens on ignite, then holds (resting motion is the sweep, not the halo).
        // Radii capped so the bloom doesn't bleed into neighbor cells.
        .shadow(color: base.opacity(scheme == .dark ? 0.9 : 0.5), radius: lit ? 9 : 6)
        .shadow(color: base.opacity(0.4), radius: lit ? 5 : 3)
        .scaleEffect(y: lit ? 1 : 0.6)            // ignition: thin → full
        .padding(.vertical, 1)                    // headroom so the glow isn't clipped
        .onAppear {
            guard !still else { lit = true; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { lit = true }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var barCore: some View {
        let shape = Capsule()
        if still {
            // Static glossy bar (Reduce Motion / Low Power).
            shape.fill(base)
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.6), .clear],
                                                   startPoint: .top, endPoint: .bottom)))
        } else {
            // Animated specular sweep via a Metal colorEffect shader, time-driven from the
            // shared clock (one display-link tick; TimelineView auto-pauses when paged
            // off-screen). GeometryReader only here, on the ≤handful of glow cells — not the grid.
            GeometryReader { geo in
                TimelineView(.animation) { tl in
                    let t = Float(tl.date.timeIntervalSince(GlowClock.epoch))
                    shape.fill(base)
                        .colorEffect(ShaderLibrary.perfectDayGlow(
                            .float(t), .float2(geo.size),
                            .float(Float(slot)), .float(Float(slots)),
                            .float(Float(tilt.roll)), .float(1.0)))
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { CalendarHomeView() }
        .environment(\.managedObjectContext, PreviewStack.context)
        .environmentObject(AppModel())
}
#endif
