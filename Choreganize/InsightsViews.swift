import SwiftUI
import CoreData

// CG-21 / #103 — the Insights dashboard, the 4th primary surface (Plus).
// CG-22 / #104 — yearly heatmap + shareable monthly summary card.
//
// All math lives in `InsightsMath` (pure, calendar-consistent, on-device);
// this file only renders it. Scope-aware like CalendarHomeView: one prefetching
// fetch request, filtered with `.inScope(model.activeHousehold)`.

/// The Insights surface. When the user isn't entitled to Plus the full layout
/// still renders — blurred/redacted behind a lock card — so the surface sells
/// itself without leaking interactivity (CG-21 / #103).
struct InsightsHomeView: View {
    @EnvironmentObject private var model: AppModel
    // Prefetches area/completions/household so the year-long aggregation doesn't
    // fault relationships one row at a time on the main thread (cz_device10/11).
    @FetchRequest(fetchRequest: displayChoresFetchRequest()) private var allChores: FetchedResults<CDChore>
    @FetchRequest(sortDescriptors: [SortDescriptor(\CDLockedDay.date)]) private var lockedDays: FetchedResults<CDLockedDay>
    /// Live entitlement so the lock lifts the moment a purchase (or the
    /// household's propagated flag, CG-15 / #97) lands.
    @ObservedObject private var entitlements = EntitlementStore.shared

    private var isPlus: Bool {
        HouseholdEntitlement.effectiveIsPlus(ownPlus: entitlements.isPlus,
                                             household: model.activeHousehold)
    }

    var body: some View {
        let scope = model.activeHousehold
        let chores = Array(allChores).inScope(scope)
        let locks = Array(lockedDays).inScope(scope)
        let dashboard = InsightsDashboard(
            chores: chores, locks: locks,
            scopeName: scope != nil ? model.householdName : AppScope.solo.title)

        return Group {
            if isPlus {
                dashboard
            } else {
                // Teaser: the real layout, blurred + redacted, behind the lock
                // card. Hit-testing off so nothing under the glass is tappable.
                dashboard
                    .blur(radius: 8)
                    .redacted(reason: .placeholder)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .overlay { InsightsLockCard() }
            }
        }
    }
}

/// The unlock pitch shown over the blurred dashboard. Deliberately just a
/// pointer to the existing Hub entry point — no embedded paywall, so there's
/// exactly one purchase surface (CG-12 / #95).
private struct InsightsLockCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Insights is part of Choreganize Plus")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Unlock in Hub ▸ Get Choreganize Plus")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(32)
        .accessibilityElement(children: .combine)
    }
}

/// The dashboard proper: headline 7d/30d rate cards, the year heatmap, per-room
/// and per-frequency bars, streaks, and the shareable month card.
private struct InsightsDashboard: View {
    let chores: [CDChore]
    let locks: [CDLockedDay]
    let scopeName: String

    var body: some View {
        // Recomputed per render, same as the calendar grid / Hub streaks — the
        // aggregation is pure and the data volumes of a chores app keep it cheap.
        let week = InsightsMath.completionStats(chores: chores, lastDays: 7)
        let month = InsightsMath.completionStats(chores: chores, lastDays: 30)
        let rooms = InsightsMath.roomBreakdown(chores: chores)
        let frequencies = InsightsMath.frequencyBreakdown(chores: chores)
        let streaks = InsightsMath.streakSummary(scopedChores: chores, scopedLocks: locks)
        let heatmap = InsightsMath.yearHeatmap(chores: chores)
        let monthSummary = InsightsMath.monthSummary(chores: chores, locks: locks)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    RateCard(title: "Last 7 days", stats: week)
                    RateCard(title: "Last 30 days", stats: month)
                }

                InsightsSection("This year") {
                    YearHeatmapView(days: heatmap)
                }

                InsightsSection("Rooms — last 30 days") {
                    if rooms.isEmpty {
                        EmptyHint(text: "No chores were due in the last 30 days.")
                    } else {
                        VStack(spacing: 10) {
                            ForEach(rooms) { BreakdownBar(stats: $0) }
                        }
                    }
                }

                InsightsSection("By frequency — last 30 days") {
                    if frequencies.isEmpty {
                        EmptyHint(text: "No chores were due in the last 30 days.")
                    } else {
                        VStack(spacing: 10) {
                            ForEach(frequencies) { BreakdownBar(stats: $0) }
                        }
                    }
                }

                InsightsSection("Streaks") {
                    StreakRow(summary: streaks)
                }

                InsightsSection("Share your month") {
                    ShareCardSection(summary: monthSummary, scopeName: scopeName)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        // Float-over-content (#65): the last section must clear the floating
        // glass mode switcher, same clearance EditHome uses.
        .contentMargins(.bottom, 100, for: .scrollContent)
    }
}

/// Section chrome shared by the dashboard blocks.
private struct InsightsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

private struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

/// Headline completion-rate card (7d / 30d).
private struct RateCard: View {
    let title: String
    let stats: InsightsMath.WindowStats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(stats.due > 0 ? "\(stats.percent)%" : "—")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(stats.due > 0 ? Color.primary : Color.secondary)
                .contentTransition(.numericText())
            Text(stats.due > 0
                 ? "\(stats.completed) of \(stats.due) chores done"
                 : "Nothing was due")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(stats.due > 0 ? "\(stats.percent) percent, \(stats.completed) of \(stats.due) chores done" : "nothing was due").")
    }
}

/// One labeled capsule bar — the DayMeter's fill treatment (green fill share
/// over a tinted track) stretched into a single row-sized bar, so "done" is
/// encoded by fill length as well as hue.
private struct BreakdownBar: View {
    let stats: InsightsMath.GroupStats

    var body: some View {
        HStack(spacing: 10) {
            Text(stats.name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 96, alignment: .leading)
            Capsule()
                .fill(.gray.opacity(0.22))
                .overlay { Capsule().strokeBorder(.gray.opacity(0.5), lineWidth: 0.75) }
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.green)
                            .frame(width: max(geo.size.width * stats.ratio, stats.completed > 0 ? 6 : 0))
                    }
                }
                .frame(height: 8)
            Text("\(stats.percent)%")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stats.name): \(stats.completed) of \(stats.due) done, \(stats.percent) percent.")
    }
}

/// Current + record streak readout — same flame/trophy stat pair as the Hub's
/// StreakSummaryView, derived from the same perfect-day machinery.
private struct StreakRow: View {
    let summary: CalendarStreaks.Summary

    var body: some View {
        HStack(spacing: 0) {
            stat(value: summary.current, caption: "Current", systemImage: "flame.fill",
                 tint: summary.current > 0 ? .orange : .secondary)
            Divider()
            stat(value: summary.longest, caption: "Record", systemImage: "trophy.fill",
                 tint: summary.longest > 0 ? .yellow : .secondary)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current streak \(summary.current) \(summary.current == 1 ? "day" : "days"), best \(summary.longest) \(summary.longest == 1 ? "day" : "days").")
    }

    private func stat(value: Int, caption: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text("\(value)")
                    .font(.title2).fontWeight(.semibold)
                    .contentTransition(.numericText())
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Yearly heatmap (CG-22 / #104)

/// GitHub-style year grid: one column per week (rows = weekdays), month labels
/// along the top, green intensity ramp. Scrolls horizontally when the 53
/// columns outgrow the screen; lands scrolled to "now" (the trailing edge).
private struct YearHeatmapView: View {
    let days: [InsightsMath.HeatmapDay]

    private let cellSize: CGFloat = 10
    private let gap: CGFloat = 2
    private var columnStride: CGFloat { cellSize + gap }
    private var calendar: Calendar { Calendar.current }

    /// Days chunked into week columns of 7 weekday rows, padded with nil at the
    /// head (before the range starts) and tail (after today).
    private var weeks: [[InsightsMath.HeatmapDay?]] {
        guard let first = days.first else { return [] }
        let weekday = calendar.component(.weekday, from: first.date)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        var flat: [InsightsMath.HeatmapDay?] = Array(repeating: nil, count: lead)
        flat.append(contentsOf: days.map { Optional($0) })
        while flat.count % 7 != 0 { flat.append(nil) }
        return stride(from: 0, to: flat.count, by: 7).map { Array(flat[$0..<$0 + 7]) }
    }

    /// Week columns where a new month begins (its label anchors there).
    private func monthLabels(for weeks: [[InsightsMath.HeatmapDay?]]) -> [(weekIndex: Int, name: String)] {
        var labels: [(Int, String)] = []
        var lastMonth = -1
        for (index, week) in weeks.enumerated() {
            guard let firstDay = week.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: firstDay.date)
            if month != lastMonth {
                // Skip a label crammed against the previous one (a partial
                // first column can otherwise collide with the next month).
                if labels.last.map({ index - $0.0 >= 3 }) ?? true {
                    labels.append((index, firstDay.date.formatted(.dateTime.month(.abbreviated))))
                }
                lastMonth = month
            }
        }
        return labels
    }

    var body: some View {
        let weeks = self.weeks
        let gridWidth = CGFloat(weeks.count) * columnStride - gap
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: max(gridWidth, 0), height: 14)
                    ForEach(monthLabels(for: weeks), id: \.weekIndex) { label in
                        Text(label.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: CGFloat(label.weekIndex) * columnStride)
                    }
                }
                HStack(alignment: .top, spacing: gap) {
                    ForEach(weeks.indices, id: \.self) { w in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { row in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(color(for: weeks[w][row]))
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .defaultScrollAnchor(.trailing)   // land on the most recent weeks
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Yearly completion heatmap, most recent weeks at the end.")
    }

    /// The green intensity ramp. Padding cells are invisible; a day with
    /// nothing due is a faint placeholder; 0 done reads as an empty track and
    /// 1–4 ramp up to full green (fill intensity, not hue alone).
    private func color(for day: InsightsMath.HeatmapDay?) -> Color {
        guard let day else { return .clear }
        guard let bucket = day.bucket else { return Color.primary.opacity(0.06) }
        switch bucket {
        case 0:  return Color.primary.opacity(0.14)
        case 1:  return Color.green.opacity(0.30)
        case 2:  return Color.green.opacity(0.50)
        case 3:  return Color.green.opacity(0.75)
        default: return Color.green
        }
    }
}

// MARK: - Shareable monthly summary card (CG-22 / #104)

/// Preview + ShareLink for the month card. The card renders to a UIImage via
/// `ImageRenderer` once per summary change (`.task(id:)`), and shares through
/// `ShareLink` — the codebase's sharing idiom (see LogViewerView).
private struct ShareCardSection: View {
    let summary: InsightsMath.MonthSummary
    let scopeName: String
    @State private var cardImage: PlatformImage?

    private var monthTitle: String {
        summary.monthStart.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Live preview, scaled down from the fixed 1080×1350 render size.
            GeometryReader { geo in
                MonthlySummaryCard(summary: summary, scopeName: scopeName)
                    .frame(width: MonthlySummaryCard.size.width,
                           height: MonthlySummaryCard.size.height)
                    .scaleEffect(geo.size.width / MonthlySummaryCard.size.width,
                                 anchor: .topLeading)
            }
            .aspectRatio(MonthlySummaryCard.size.width / MonthlySummaryCard.size.height,
                         contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityLabel("Monthly summary card for \(monthTitle).")

            if let cardImage {
                let shareImage = Image(platformImage: cardImage)
                ShareLink(item: shareImage,
                          preview: SharePreview("Choreganize — \(monthTitle)", image: shareImage)) {
                    Label("Share summary card", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            } else {
                Label("Preparing card…", systemImage: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: summary) { renderCard() }
    }

    /// Renders the fixed-size card off the live view tree. @2x for crisp pixels.
    @MainActor private func renderCard() {
        let renderer = ImageRenderer(
            content: MonthlySummaryCard(summary: summary, scopeName: scopeName)
                .frame(width: MonthlySummaryCard.size.width,
                       height: MonthlySummaryCard.size.height))
        renderer.scale = 2
        cardImage = renderer.platformImage
    }
}

/// The fixed-size (1080×1350, 4:5) share card. Self-contained: explicit colors
/// (no environment/theme dependence — ImageRenderer content gets neither), and
/// no user-identifying info beyond the scope/household name.
private struct MonthlySummaryCard: View {
    static let size = CGSize(width: 1080, height: 1350)

    let summary: InsightsMath.MonthSummary
    let scopeName: String

    private var monthTitle: String {
        summary.monthStart.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text(scopeName)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            Text(monthTitle)
                .font(.system(size: 80, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 6)

            Spacer()

            // Headline percentage
            Text(summary.stats.due > 0 ? "\(summary.stats.percent)%" : "—")
                .font(.system(size: 300, weight: .heavy, design: .rounded))
                .foregroundStyle(cardGreen)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(summary.stats.due > 0
                 ? "\(summary.stats.completed) of \(summary.stats.due) chores done"
                 : "Nothing was due yet")
                .font(.system(size: 48, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))

            Spacer()

            // Best streak + top room
            HStack(spacing: 48) {
                statBlock(icon: "flame.fill", tint: .orange,
                          value: "\(summary.bestStreak)",
                          caption: summary.bestStreak == 1 ? "day best streak" : "days best streak")
                if let topRoom = summary.topRoom {
                    statBlock(icon: "house.fill", tint: cardGreen,
                              value: topRoom, caption: "top room")
                }
            }

            Spacer()

            // Mini heatmap strip: one square per elapsed day of the month.
            if !summary.dayBuckets.isEmpty {
                HStack(spacing: 8) {
                    ForEach(summary.dayBuckets.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(stripColor(summary.dayBuckets[i]))
                            .frame(height: 44)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 40)
            }

            // Footer branding
            HStack(spacing: 14) {
                Image(systemName: "checklist")
                    .font(.system(size: 40, weight: .semibold))
                Text("Choreganize")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(80)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.07, green: 0.10, blue: 0.16),
                                    Color(red: 0.10, green: 0.18, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var cardGreen: Color { Color(red: 0.18, green: 0.85, blue: 0.45) }

    private func statBlock(icon: String, tint: Color, value: String, caption: String) -> some View {
        HStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(caption)
                    .font(.system(size: 36, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func stripColor(_ bucket: Int?) -> Color {
        guard let bucket else { return .white.opacity(0.08) }
        switch bucket {
        case 0:  return .white.opacity(0.16)
        case 1:  return cardGreen.opacity(0.30)
        case 2:  return cardGreen.opacity(0.50)
        case 3:  return cardGreen.opacity(0.75)
        default: return cardGreen
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { InsightsHomeView() }
        .environmentObject(AppModel())
        .environment(\.managedObjectContext, PreviewStack.context)
}
#endif
