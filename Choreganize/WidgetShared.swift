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

/// A lightweight, Codable view of "today's chores" that the app writes and the
/// widget reads — so the widget never has to touch Core Data, the model, or the
/// scheduling code.
struct ChoreWidgetSnapshot: Codable {
    struct Item: Codable, Identifiable {
        var id: String
        var name: String
        var isDone: Bool
    }

    /// Start-of-day this snapshot describes.
    var date: Date
    /// Scope label shown on the widget ("Personal" or the household name).
    var scopeLabel: String
    var items: [Item]

    var remaining: Int { items.filter { !$0.isDone }.count }
    var total: Int { items.count }

    static let empty = ChoreWidgetSnapshot(date: Date(), scopeLabel: "", items: [])
}
