import SwiftUI

/// The app's primary surfaces. On iOS the floating switcher (ContentView)
/// iterates `allCases`; the macOS companion drives the same cases from its
/// sidebar and ⌘1–⌘4 commands — shared here so both shells stay in lockstep.
enum AppMode: String, CaseIterable, Identifiable {
    case work = "Work"
    case edit = "Edit"
    case calendar = "Calendar"
    /// CG-21 / #103: the Insights dashboard, the 4th primary surface (Plus).
    /// Every switcher variant iterates `allCases`, so the case is all they need.
    case insights = "Insights"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .work: "checklist"
        case .edit: "slider.horizontal.3"
        case .calendar: "calendar"
        case .insights: "chart.bar.xaxis"
        }
    }
}

private struct ClearsModeSwitcherKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// Whether the floating mode switcher (the iPhone pill) sits over the bottom of a mode's
    /// content, so lists and floating day buttons leave room for it. The iOS shell sets it
    /// false where the modes are in the system tab bar (iPad, iPhone Duo), which takes its
    /// own space; elsewhere the clearances stay as they were.
    var clearsModeSwitcher: Bool {
        get { self[ClearsModeSwitcherKey.self] }
        set { self[ClearsModeSwitcherKey.self] = newValue }
    }
}
