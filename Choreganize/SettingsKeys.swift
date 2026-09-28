import Foundation

/// Stable UserDefaults keys shared across the app (display name, future prefs).
/// In their own file (not HubView) because both shells read them: the iOS Hub
/// and Work view, and the macOS Settings scene.
enum SettingsKeys {
    static let displayName = "displayName"
    static let workGrouping = "workGrouping"
    static let switcherStyle = "switcherStyle"
    /// #128: lifts the 3-at-a-time one-off limit for Personal on this device. A
    /// household's setting is synced instead (`CDHousehold.oneOffsUnlimited`).
    static let oneOffsUnlimitedPersonal = "oneOffsUnlimitedPersonal"
    /// #128: the one-offs list shows everything instead of 3 + "Show all".
    static let oneOffsExpanded = "oneOffsExpanded"
}
