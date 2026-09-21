import Foundation

/// Stable UserDefaults keys shared across the app (display name, future prefs).
/// In their own file (not HubView) because both shells read them: the iOS Hub
/// and Work view, and the macOS Settings scene.
enum SettingsKeys {
    static let displayName = "displayName"
    static let workGrouping = "workGrouping"
    static let switcherStyle = "switcherStyle"
}
