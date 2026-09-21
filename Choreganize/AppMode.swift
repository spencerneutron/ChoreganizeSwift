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
