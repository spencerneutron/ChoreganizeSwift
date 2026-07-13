import SwiftUI

/// Window-level UI state for the Mac shell. A singleton so menu-bar Commands
/// (which live outside the view tree) can drive the same state the window
/// observes — the pragmatic macOS equivalent of ContentView's local @State.
@MainActor
final class MacUIState: ObservableObject {
    static let shared = MacUIState()

    /// The surface shown in the split view's detail column (⌘1–⌘4).
    @Published var surface: AppMode = .work
    /// Presents the Plus paywall sheet.
    @Published var showPaywall = false
    /// Presents the guided add-chores wizard (⌘N). Carries the chosen lens.
    @Published var addFlowLens: AddFlowGrouping?
}
