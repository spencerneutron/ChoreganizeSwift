import WidgetKit
import SwiftUI
import AppIntents

/// Renders the published snapshot.
///
/// - systemSmall/Medium/Large: a checklist where each row's circle is an interactive
///   `Button(intent:)` (CG-02) that fires the shared `CompleteChoreIntent`, and the
///   row text deep-links into the app via `widgetURL`/`Link` (CG-05). Large adds the
///   scope and a progress bar, and lists more chores in bigger rows.
/// - accessoryCircular/Rectangular: a glanceable "remaining today" Lock Screen
///   accessory (CG-04) reusing the snapshot's precomputed `remaining`/`total`.
struct TodayChoresView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize
    var entry: TodayChoresEntry

    private var snapshot: ChoreWidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular:
            accessoryCircular
        case .accessoryRectangular:
            accessoryRectangular
        default:
            homeScreen
        }
    }

    // MARK: - Home-screen (small / medium / large)

    /// The large widget: iPad and iPhone home screens, and Today View on the open
    /// iPhone Duo, where a longer list is the point.
    private var isLarge: Bool { family == .systemLarge }

    /// How many chores to try listing, most first; the widget shows the longest list
    /// that fits. The large widget's height runs from about 305 pt (iPad mini) to 382 pt
    /// (the biggest iPhones), and larger text sizes fit fewer rows. Small and medium
    /// keep their 4 at the default text size, where 4 only fit by running into the
    /// content margins.
    private var rowLimits: [Int] {
        if isLarge { return [10, 9, 8, 7, 6, 5, 4, 3] }
        return typeSize <= .large ? [4] : [3, 2, 1]
    }

    private var homeScreen: some View {
        ViewThatFits(in: .vertical) {
            ForEach(rowLimits, id: \.self) { checklist(limit: $0) }
        }
        // If even the shortest list overflows, it loses its last rows, not the header.
        .frame(maxHeight: .infinity, alignment: .top)
        // CG-05: tapping anywhere not on a row's toggle opens the app to today.
        .widgetURL(WidgetDeepLink.url(choreID: nil))
    }

    private func checklist(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isLarge && snapshot.total > 0 {
                ProgressView(value: Double(snapshot.total - snapshot.remaining),
                             total: Double(snapshot.total))
                    .tint(snapshot.remaining == 0 ? .green : .accentColor)
                    .accessibilityHidden(true)   // the header already says how many are left
            }
            if snapshot.items.isEmpty {
                Spacer(minLength: 0)
                Text(entry.isStale ? "Open Choreganize to see today's chores" : "No chores today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                ForEach(snapshot.items.prefix(limit)) { item in
                    row(for: item)
                }
                let hidden = snapshot.items.dropFirst(limit)
                if !hidden.isEmpty {
                    // Done chores sort last, so the hidden ones are often all done.
                    Text(hidden.allSatisfy(\.isDone) ? "+\(hidden.count) done" : "+\(hidden.count) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// One chore row: an interactive completion toggle (CG-02) plus a deep-link to
    /// the chore's day (CG-05).
    private func row(for item: ChoreWidgetSnapshot.Item) -> some View {
        HStack(spacing: isLarge ? 8 : 6) {
            // The completion control reuses the existing CompleteChoreIntent — it
            // runs in the app's process and writes to Core Data. (Marking complete
            // only; the widget never un-completes.)
            Button(intent: CompleteChoreIntent(choreID: item.id, name: item.name)) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(item.isDone)
            .accessibilityLabel(item.isDone ? "\(item.name), done" : "Mark \(item.name) done")

            // The label deep-links to this chore's day.
            Link(destination: WidgetDeepLink.url(choreID: item.id)) {
                Text(item.name)
                    .font(isLarge ? .subheadline : .caption)
                    .strikethrough(item.isDone)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Today").font(.headline)
            if isLarge && !snapshot.scopeLabel.isEmpty {
                Text(snapshot.scopeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !entry.isStale {
                Text(snapshot.remaining == 0 ? "All done" : "\(snapshot.remaining) left")
                    .font(.caption.bold())
                    .foregroundStyle(snapshot.remaining == 0 ? .green : .secondary)
            }
        }
    }

    // MARK: - Lock Screen accessories (CG-04)

    private var accessoryCircular: some View {
        Gauge(value: Double(snapshot.total - snapshot.remaining),
              in: 0...Double(max(snapshot.total, 1))) {
            Image(systemName: "checklist")
        } currentValueLabel: {
            Text(entry.isStale ? "–" : "\(snapshot.remaining)")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(WidgetDeepLink.url(choreID: nil))
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Today's Chores", systemImage: "checklist")
                .font(.caption.bold())
                .widgetAccentable()
            if entry.isStale {
                Text("Open Choreganize to update").font(.caption2)
            } else if snapshot.total == 0 {
                Text("No chores today").font(.caption2)
            } else if snapshot.remaining == 0 {
                Text("All done").font(.caption2)
            } else {
                Text("\(snapshot.remaining) of \(snapshot.total) left")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(WidgetDeepLink.url(choreID: nil))
    }
}
