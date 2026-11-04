import WidgetKit
import SwiftUI

// Widget extension sources. These belong to the *ChoreganizeWidget* target, not
// the app target — keep them out of the app's synchronized source folder so the
// widget's @main bundle doesn't collide with ChoreganizeApp's @main.
//
// The widget reads a snapshot the app publishes to the shared App Group
// (see WidgetShared / WidgetSnapshotWriter in the app target). WidgetShared.swift
// must be added to this target's membership.

struct TodayChoresEntry: TimelineEntry {
    let date: Date
    let snapshot: ChoreWidgetSnapshot
    /// The published snapshot is older than yesterday's next-day list, so the widget
    /// can't know today's chores until the app runs again.
    var isStale = false

    /// The entry for `date` from the published snapshot.
    init(date: Date, published: ChoreWidgetSnapshot) {
        self.date = date
        if let day = published.on(date) {
            snapshot = day
        } else {
            snapshot = .empty
            isStale = true
        }
    }

    init(date: Date, snapshot: ChoreWidgetSnapshot) {
        self.date = date
        self.snapshot = snapshot
    }
}

struct TodayChoresProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayChoresEntry {
        TodayChoresEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayChoresEntry) -> Void) {
        let published = Self.load()
        let now = Date()
        // The gallery shows the last list rather than the stale message.
        completion(TodayChoresEntry(date: now, snapshot: published.on(now) ?? published))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayChoresEntry>) -> Void) {
        let published = Self.load()
        let now = Date()
        let calendar = Calendar.current
        // At midnight the widget turns to the next day's list, which the app publishes
        // with today's, so it never shows yesterday's chores as today's.
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        let entries = [TodayChoresEntry(date: now, published: published),
                       TodayChoresEntry(date: midnight, published: published)]
        // The app pushes a reload whenever data changes; this is just a fallback
        // refresh at the next hour boundary so a left-open widget stays current.
        let next = calendar.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: entries, policy: .after(next)))
    }

    static func load() -> ChoreWidgetSnapshot {
        guard let data = WidgetShared.defaults?.data(forKey: WidgetShared.snapshotKey),
              let snapshot = try? JSONDecoder().decode(ChoreWidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }
}

struct TodayChoresWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.widgetKind, provider: TodayChoresProvider()) { entry in
            TodayChoresView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today's Chores")
        .description("See what still needs doing today.")
        // Home-screen checklist (small/medium/large) + Lock Screen "remaining today"
        // accessories (circular/rectangular). CG-04.
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular])
    }
}

@main
struct ChoreganizeWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayChoresWidget()
    }
}
