import SwiftUI

/// Presents a month grid with chore counts.
struct CalendarHomeView: View {
    @EnvironmentObject private var model: AppModel
    // Prefetches area/completions/household so the month grid's per-day completion
    // checks don't fault each chore's relationships on the main thread (cz_device11).
    @FetchRequest(fetchRequest: displayChoresFetchRequest()) private var allChores: FetchedResults<CDChore>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDLockedDay.date)]) private var lockedDays: FetchedResults<CDLockedDay>
    @State private var month: Date = Date()
    /// The day on the left page where the month and a day show side by side; today at first.
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    /// One shared device-motion source; the glow bars' specular sweep tracks roll (#57 fast-follow).
    /// Held as plain `@State` (not `@StateObject`) so its 30 Hz `roll` updates DON'T re-render the
    /// whole calendar — the bars read `roll` per-frame via their own `TimelineView`.
    @State private var tilt = TiltProvider()
    /// False while a sheet (e.g. the Hub) covers the calendar; pause motion sampling then.
    @Environment(\.glowAnimationActive) private var glowActive

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
        layout
            .compatNavigationBarVisibility(.hidden)
            // Drive device-motion at the calendar level (one source for all glow bars). Stop it when
            // the calendar isn't visible OR is covered by a sheet (no point sampling behind the Hub).
            // No-op where motion is unavailable (Simulator).
            .onAppear { if glowActive { tilt.start() } }
            .onDisappear { tilt.stop() }
            .onChange(of: glowActive) { _, active in active ? tilt.start() : tilt.stop() }
    }

    /// The month alone, or — where two pages fit (iPad, iPhone Duo's inner display), by the
    /// same rule as Work's two-day spread — the selected day on the left page and the month on
    /// the right, divided where the device folds. The month keeps the right page, the one the
    /// outer display shows, so opening or closing iPhone Duo leaves it where your eyes are, and
    /// keeps its place in the view tree in both layouts. A 7-column grid across the whole inner
    /// display put its middle column on the fold (Apple: prefer even column counts there).
    @ViewBuilder private var layout: some View {
        #if os(iOS)
        SpreadReader { spread, margins, geo in
            pages(spread: spread, insets: margins, in: geo)
        }
        #else
        monthPage(spread: false)
        #endif
    }

    #if os(iOS)
    private func pages(spread: Bool, insets: EdgeInsets, in geo: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            if spread {
                let split = SpreadSplit(in: geo)
                // Its own page per day: a sheet or list position from one day doesn't carry
                // to the next. Work handles widget links, so this page doesn't.
                DayPage(date: selectedDay, handlesDeepLinks: false)
                    .id(selectedDay)
                    .padding(.leading, insets.leading)
                    .frame(width: split.leadingWidth)
                    // The day's grouped background runs from the edge to the fold: one page
                    // of the book, not a card floating in a white margin.
                    .background(Color.compatGroupedBackground.ignoresSafeArea())
                Color.clear
                    .frame(width: split.gap)
            }
            monthPage(spread: spread)
                .padding(.leading, spread ? 0 : insets.leading)
                .padding(.trailing, insets.trailing)
                .frame(maxWidth: .infinity)
        }
    }
    #endif

    /// The month: its header, the weekday row and the days. In a spread the rows fill the page,
    /// like a wall calendar, and a tap shows that day on the left page; on its own, a tap
    /// pushes the day as before.
    private func monthPage(spread: Bool) -> some View {
        let scopedLocks = Array(lockedDays).inScope(model.activeHousehold)
        let streaks = CalendarStreaks.slots(for: perfectDays(scopedLocks: scopedLocks))
        let columns = Array(repeating: GridItem(.flexible()), count: 7)
        let days = self.days
        let byDate = choresByDate

        @ViewBuilder func dayGrid(cellHeight: CGFloat) -> some View {
            LazyVGrid(columns: columns, spacing: CalendarGridMetrics.rowSpacing) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let day = calendar.startOfDay(for: date)
                        let cell = DayCell(date: date,
                                           chores: byDate[day] ?? [],
                                           isLocked: DayLock.isLocked(date, in: scopedLocks),
                                           tilt: tilt,
                                           streak: streaks[day] ?? (slot: 0, count: 1),
                                           minHeight: cellHeight,
                                           selection: !spread ? .none
                                               : day == selectedDay ? .selected : .unselected)
                        if spread {
                            Button { selectedDay = day } label: { cell }
                                .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                CalendarDayDestination(date: date, selectedDay: $selectedDay)
                            } label: { cell }
                        }
                    } else {
                        Color.clear
                            .frame(minHeight: cellHeight)
                    }
                }
            }
        }

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

            VStack(spacing: CalendarGridMetrics.rowSpacing) {
                LazyVGrid(columns: columns, spacing: CalendarGridMetrics.rowSpacing) {
                    ForEach(calendar.shortWeekdaySymbols, id: \.self) { day in
                        Text(day)
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                }
                if spread {
                    GeometryReader { grid in
                        dayGrid(cellHeight: CalendarGridMetrics.cellHeight(
                            available: grid.size.height, rows: days.count / 7))
                    }
                } else {
                    dayGrid(cellHeight: CalendarGridMetrics.minimumCellHeight)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal)
        }
    }
}

/// A day pushed from the month where it stands alone. If two pages come to fit (iPhone Duo
/// opening or turning sideways, an iPad window widening), the day moves into the page beside
/// the month instead of covering both. It checks for itself: the month underneath isn't
/// laid out again while it's covered.
private struct CalendarDayDestination: View {
    let date: Date
    @Binding var selectedDay: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DayPage(date: date)
            .compatNavigationBarVisibility(.visible)
            #if os(iOS)
            .background {
                SpreadReader { spread, _, _ in
                    Color.clear.onChange(of: spread) { _, fits in
                        guard fits else { return }
                        selectedDay = Calendar.current.startOfDay(for: date)
                        dismiss()
                    }
                }
            }
            #endif
    }
}

/// The month grid's row arithmetic, kept pure for unit tests.
enum CalendarGridMetrics {
    static let rowSpacing: CGFloat = 8
    /// A day cell's height on its own (iPhone), and the floor when rows fill a page.
    static let minimumCellHeight: CGFloat = 46

    /// The height that lets `rows` rows fill `available` points, never below the minimum.
    static func cellHeight(available: CGFloat, rows: Int) -> CGFloat {
        guard rows > 0 else { return minimumCellHeight }
        let fill = (available - rowSpacing * CGFloat(rows - 1)) / CGFloat(rows)
        return max(minimumCellHeight, fill.rounded(.down))
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
        // A chore can't count against a day that predates its own creation (#85): a
        // task added after a past date shouldn't drag that earlier day's ratio down.
        // (`choresByDate` already starts each schedule at creation, so this only ever
        // tightens the count; a chore with no recorded creation date is left in.)
        let countable = chores.filter { $0.existedOn(date) }
        return DayProgress(
            total: countable.count,
            completed: countable.filter { $0.isCompleted(on: date) }.count,
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

extension CDChore {
    /// Whether the chore already existed on `date` (#85). A day strictly before the
    /// chore's creation must not be counted against it. A chore with no recorded
    /// creation date is treated as always-present (no constraint), so existing
    /// history is never hidden.
    nonisolated func existedOn(_ date: Date, calendar cal: Calendar = .current) -> Bool {
        guard let created = createdDate else { return true }
        return cal.startOfDay(for: date) >= cal.startOfDay(for: created)
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

    /// A current/longest streak readout derived from the perfect (glow-earning) days
    /// (#93, basic). `current` is the run ending today — or yesterday, so the streak
    /// survives an in-progress today that isn't perfect *yet* — and is 0 otherwise.
    /// `longest` is the most consecutive perfect days ever. Pure + `nonisolated`, built
    /// straight from `slots` so it can't disagree with the calendar's own run grouping.
    struct Summary: Equatable { var current: Int; var longest: Int }

    nonisolated static func summary(for perfectDays: Set<Date>,
                                    calendar cal: Calendar = .current) -> Summary {
        let runs = slots(for: perfectDays, calendar: cal)
        let longest = runs.values.map(\.count).max() ?? 0

        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)
        // Anchor the live streak to today if it's perfect, else to yesterday — a streak
        // shouldn't read as broken just because today's chores aren't all done yet.
        let anchor = runs[today] != nil ? today : yesterday
        let current = anchor.flatMap { runs[$0] }.map { $0.slot + 1 } ?? 0
        return Summary(current: current, longest: longest)
    }

    /// The set of perfect (glow-earning) days across the `monthsBack` months ending
    /// today — the calendar's `earnsGlow` rule applied beyond a single visible grid so
    /// the Hub can summarize streaks (#93). Reuses `Scheduling.choresByDate` +
    /// `CalendarMarks.progress` so it scores days exactly as the month grid does.
    nonisolated static func perfectDays(scopedChores: [CDChore], scopedLocks: [CDLockedDay],
                                        monthsBack: Int = 12, calendar cal: Calendar = .current) -> Set<Date> {
        let today = cal.startOfDay(for: Date())
        var perfect: Set<Date> = []
        for back in 0...max(0, monthsBack) {
            guard let monthAnchor = cal.date(byAdding: .month, value: -back, to: today) else { continue }
            let byDate = Scheduling.choresByDate(inMonth: monthAnchor, chores: scopedChores)
            for (day, chores) in byDate where day <= today {
                let daysAgo = cal.dateComponents([.day], from: day, to: today).day ?? 0
                let p = CalendarMarks.progress(
                    chores, on: day,
                    mode: CalendarMarks.mode(for: day, calendar: cal),
                    daysAgo: daysAgo,
                    locked: DayLock.isLocked(day, in: scopedLocks))
                if p.earnsGlow { perfect.insert(day) }
            }
        }
        return perfect
    }
}

private struct DayCell: View {
    var date: Date
    var chores: [CDChore]
    var isLocked: Bool
    var tilt: TiltProvider
    /// This day's place in a run of consecutive perfect days (slot 0 of 1 when not in a streak).
    var streak: (slot: Int, count: Int) = (0, 1)
    var minHeight: CGFloat = CalendarGridMetrics.minimumCellHeight
    /// Whether this day is the one showing beside the month (two-page layout only).
    var selection: Selection = .none

    enum Selection { case none, selected, unselected }

    /// As in Apple's Calendar month view: the chosen day's number sits in a solid circle,
    /// today's in a tinted one while it's the chosen day (and always where nothing is chosen),
    /// and once another day is chosen today is just tinted text, so only one day is circled.
    private var numberCircle: Color? {
        switch (selection, isToday) {
        case (.none, true), (.selected, true): .accentColor
        case (.selected, false): .primary
        default: nil
        }
    }

    private var numberColor: Color {
        if numberCircle == .primary { return Color.compatBackground }
        if numberCircle != nil { return .white }
        return isToday ? .accentColor : .primary
    }

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
                .fontWeight(isToday || selection == .selected ? .bold : .regular)
                .foregroundStyle(numberColor)
                .padding(5)
                .background { if let numberCircle { Circle().fill(numberCircle) } }
                .frame(maxWidth: .infinity, alignment: .leading)

            // The compact phone cell keeps its marks at its foot. Where rows fill a page (the
            // two-page layout) the marks sit under the number, as events do in a tall cell of
            // Apple's Calendar, rather than a page-row away from it.
            if selection == .none { Spacer(minLength: 0) }

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

            if selection != .none { Spacer(minLength: 0) }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .frame(minHeight: minHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary(p))
        .accessibilityAddTraits(selection == .selected ? .isSelected : [])
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
