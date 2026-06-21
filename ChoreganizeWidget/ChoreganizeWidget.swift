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
}

struct TodayChoresProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayChoresEntry {
        TodayChoresEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayChoresEntry) -> Void) {
        completion(TodayChoresEntry(date: Date(), snapshot: Self.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayChoresEntry>) -> Void) {
        let entry = TodayChoresEntry(date: Date(), snapshot: Self.load())
        // The app pushes a reload whenever data changes; this is just a fallback
        // refresh at the next hour boundary so a left-open widget stays current.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date())
            ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
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
        // Home-screen checklist (small/medium) + Lock Screen "remaining today"
        // accessories (circular/rectangular). CG-04.
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

@main
struct ChoreganizeWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayChoresWidget()
    }
}
