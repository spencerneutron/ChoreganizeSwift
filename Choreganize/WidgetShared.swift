import Foundation

/// Identifiers and the data contract shared between the app and the widget
/// extension. Lives in the app target; **also add this file to the widget
/// target's membership** (it's the only shared source the widget needs).
enum WidgetShared {
    /// App Group container shared by the app and the widget. Add this App Group
    /// capability to **both** targets in Signing & Capabilities. Until then,
    /// `UserDefaults(suiteName:)` returns nil and writes/reads are safe no-ops.
    static let appGroupIdentifier = "group.com.svk.Choreganize"
    /// Key under which the encoded `ChoreWidgetSnapshot` is stored.
    static let snapshotKey = "widget.snapshot"
    /// The widget's kind identifier (StaticConfiguration + reload calls).
    static let widgetKind = "ChoreganizeTodayWidget"

    /// Shared defaults, or nil when the App Group isn't entitled yet.
    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupIdentifier) }
}

/// Deep-link contract shared by the widget (which *builds* the URLs) and the app
/// (which *parses* them in `onOpenURL`). Scheme: `choreganize://chore/<uuid>` to
/// open a specific chore's day, or `choreganize://today` for today. Registered in
/// the app's Info.plist `CFBundleURLTypes`.
enum WidgetDeepLink {
    static let scheme = "choreganize"

    /// A URL that opens the app — to a specific chore's day when `choreID` is set,
    /// otherwise to today.
    static func url(choreID: UUID?) -> URL {
        if let choreID {
            return URL(string: "\(scheme)://chore/\(choreID.uuidString)")!
        }
        return URL(string: "\(scheme)://today")!
    }

    /// Parses an incoming URL into the chore UUID it targets (`nil` for "today" or
    /// any URL of ours that isn't chore-specific). Returns `nil` for foreign URLs.
    static func choreID(from url: URL) -> UUID?? {
        guard url.scheme == scheme else { return .none }      // not ours
        if url.host == "chore" {
            // path is "/<uuid>"
            let raw = url.pathComponents.first { $0 != "/" }
            return .some(raw.flatMap(UUID.init(uuidString:)))
        }
        return .some(nil)                                     // ours, but "today"
    }
}

/// A lightweight, Codable view of "today's chores" that the app writes and the
/// widget reads — so the widget never has to touch Core Data, the model, or the
/// scheduling code.
struct ChoreWidgetSnapshot: Codable {
    struct Item: Codable, Identifiable {
        /// The chore's stable, synced `UUID` — what `CompleteChoreIntent` resolves
        /// by. (Previously a Core Data objectID URI, which the intent couldn't
        /// reliably resolve; see WidgetSnapshotWriter.)
        var id: UUID
        var name: String
        var isDone: Bool
    }

    /// Start-of-day this snapshot describes.
    var date: Date
    /// Scope label shown on the widget ("Personal" or the household name).
    var scopeLabel: String
    var items: [Item]
    /// The following day's chores, so the widget can turn the page at midnight
    /// without the app. Nil in snapshots written before it existed.
    var nextDay: [Item]? = nil

    var remaining: Int { items.filter { !$0.isDone }.count }
    var total: Int { items.count }

    static let empty = ChoreWidgetSnapshot(date: Date(), scopeLabel: "", items: [])

    /// What the widget shows on `date`: this snapshot on its own day, the next day's
    /// list from midnight on, or nil once both have passed (the app hasn't run since,
    /// so the widget can't know the day's chores).
    func on(_ date: Date, calendar: Calendar = .current) -> ChoreWidgetSnapshot? {
        if calendar.isDate(self.date, inSameDayAs: date) { return self }
        guard let nextDay,
              let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: self.date)),
              calendar.isDate(next, inSameDayAs: date) else { return nil }
        return ChoreWidgetSnapshot(date: next, scopeLabel: scopeLabel, items: nextDay)
    }
}
