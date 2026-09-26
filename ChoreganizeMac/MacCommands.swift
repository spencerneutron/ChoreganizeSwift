import SwiftUI

/// Menu-bar commands for the Mac shell. Surfaces get ⌘1–⌘4 in a Go menu
/// (Finder/Mail idiom); ⌘N starts the guided add wizard (replacing New
/// Window — the companion is a one-window app plus its menu-bar extra).
struct MacCommands: Commands {
    @ObservedObject private var ui = MacUIState.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Menu("New Chores") {
                ForEach(AddFlowGrouping.allCases) { lens in
                    Button(lens.title) { ui.addFlowLens = lens }
                }
                // #121: Snap a Room (on-device model, macOS 27 + Apple Intelligence).
                if RoomVisionAvailability.current.isOfferable {
                    Divider()
                    Button("From a Photo…") { ui.roomSnap = MacPhotoRequest() }
                        .keyboardShortcut("n", modifiers: [.command, .option])
                        .disabled(!RoomVisionAvailability.current.isAvailable)
                }
            }
            Button("New Chores — Room by Room") { ui.addFlowLens = .byArea }
                .keyboardShortcut("n", modifiers: .command)
                .hidden()   // hidden twin just to own ⌘N for the default lens
            if RoomVisionAvailability.current.isOfferable {
                Button("Check Off with a Photo…") { ui.photoCheck = MacPhotoRequest() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!RoomVisionAvailability.current.isAvailable)
            }
        }

        CommandMenu("Go") {
            ForEach(Array(AppMode.allCases.enumerated()), id: \.element.id) { index, mode in
                Button {
                    ui.surface = mode
                } label: {
                    Label(mode.rawValue, systemImage: mode.systemImage)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }
}
