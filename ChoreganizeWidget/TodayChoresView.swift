import WidgetKit
import SwiftUI
import AppIntents

/// Renders the published snapshot.
///
/// - systemSmall/Medium: a checklist where each row's circle is an interactive
///   `Button(intent:)` (CG-02) that fires the shared `CompleteChoreIntent`, and the
///   row text deep-links into the app via `widgetURL`/`Link` (CG-05).
/// - accessoryCircular/Rectangular: a glanceable "remaining today" Lock Screen
///   accessory (CG-04) reusing the snapshot's precomputed `remaining`/`total`.
struct TodayChoresView: View {
    @Environment(\.widgetFamily) private var family
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

    // MARK: - Home-screen (small / medium)

    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if snapshot.items.isEmpty {
                Spacer(minLength: 0)
                Text("No chores today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                ForEach(snapshot.items.prefix(4)) { item in
                    row(for: item)
                }
                if snapshot.items.count > 4 {
                    Text("+\(snapshot.items.count - 4) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        // CG-05: tapping anywhere not on a row's toggle opens the app to today.
        .widgetURL(WidgetDeepLink.url(choreID: nil))
    }

    /// One chore row: an interactive completion toggle (CG-02) plus a deep-link to
    /// the chore's day (CG-05).
    private func row(for item: ChoreWidgetSnapshot.Item) -> some View {
        HStack(spacing: 6) {
            // The completion control reuses the existing CompleteChoreIntent — it
            // runs in the app's process and writes to Core Data. (Marking complete
            // only; the widget never un-completes.)
            Button(intent: CompleteChoreIntent(choreID: item.id, name: item.name)) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(item.isDone)

            // The label deep-links to this chore's day.
            Link(destination: WidgetDeepLink.url(choreID: item.id)) {
                Text(item.name)
                    .font(.caption)
                    .strikethrough(item.isDone)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Today").font(.headline)
            Spacer()
            Text(snapshot.remaining == 0 ? "All done" : "\(snapshot.remaining) left")
                .font(.caption.bold())
                .foregroundStyle(snapshot.remaining == 0 ? .green : .secondary)
        }
    }

    // MARK: - Lock Screen accessories (CG-04)

    private var accessoryCircular: some View {
        Gauge(value: Double(snapshot.total - snapshot.remaining),
              in: 0...Double(max(snapshot.total, 1))) {
            Image(systemName: "checklist")
        } currentValueLabel: {
            Text("\(snapshot.remaining)")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(WidgetDeepLink.url(choreID: nil))
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Today's Chores", systemImage: "checklist")
                .font(.caption.bold())
                .widgetAccentable()
            if snapshot.total == 0 {
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
