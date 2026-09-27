#if DEBUG
import AppKit
import SwiftUI

/// DEBUG-only layout snapshots of the Mac shell, for reviewing windows without a
/// screen recording. Launch with `CHOREGANIZE_MAC_SNAPSHOTS=<dir>`, ideally in an
/// isolated, in-memory run (`-isolatedData YES`, `CHOREGANIZE_UITEST_INMEMORY=1`) so
/// nothing touches real data. The app shows each main-window surface and each
/// Settings pane, renders every window to `<dir>/<name>.png` from its own backing
/// store (so no capture permission is needed), then quits.
@MainActor
enum MacDebugSnapshots {
    /// Handed over by MacRootView: SwiftUI's Settings scene only opens through
    /// the `openSettings` environment action (macOS 14+).
    static var openSettings: (() -> Void)?

    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CHOREGANIZE_MAC_SNAPSHOTS"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            await pause(2.5)
            for mode in AppMode.allCases {
                MacUIState.shared.surface = mode
                await pause(1.2)
                if let window = mainWindow { write(window, to: directory, name: "main-\(mode.rawValue.lowercased())") }
            }
            await snapshotPhotoSheets(to: directory)
            await snapshotDescribeSheet(to: directory)
            openSettings?()
            for pane in MacSettingsPane.allCases {
                UserDefaults.standard.set(pane.rawValue, forKey: MacSettingsPane.storageKey)
                await pause(1.2)
                if let window = settingsWindow { write(window, to: directory, name: "settings-\(pane.rawValue)") }
            }
            Log.info("Mac snapshots → \(directory.path); windows: "
                     + NSApp.windows.map { "\(type(of: $0)) '\($0.title)' visible=\($0.isVisible) style=\($0.toolbarStyle.rawValue)" }.joined(separator: " | "))
            NSApp.terminate(nil)
        }
    }

    /// #121: with a test photo (`CHOREGANIZE_ROOM_PHOTO`) and the on-device model,
    /// the Snap a Room sheet (empty, then analyzed) and the check-off sheet.
    private static func snapshotPhotoSheets(to directory: URL) async {
        guard let photo = RoomPhoto.testPhotoFromEnvironment, RoomVisionAvailability.current.isAvailable else { return }
        let ui = MacUIState.shared
        ui.surface = .edit
        await pause(1)
        if let window = mainWindow { write(window, to: directory, name: "main-edit-snap-row") }
        ui.roomSnap = MacPhotoRequest()
        await pause(1.5)
        writeSheet(to: directory, name: "sheet-snap-capture")
        ui.roomSnap = nil
        await pause(1)
        ui.roomSnap = MacPhotoRequest(photo: photo)
        await pause(12)   // real on-device inference
        writeSheet(to: directory, name: "sheet-snap-review")
        ui.roomSnap = nil
        await pause(1)
        ui.surface = .work
        await pause(1.2)
        if let window = mainWindow { write(window, to: directory, name: "main-work-photo-button") }
        ui.photoCheck = MacPhotoRequest(photo: photo)
        await pause(9)
        writeSheet(to: directory, name: "sheet-check-results")
        ui.photoCheck = nil
        await pause(1)
    }

    /// #106: with the on-device model, the Describe Chores sheet (empty, then read from
    /// `CHOREGANIZE_DESCRIBE_TEXT` or a sample routine).
    private static func snapshotDescribeSheet(to directory: URL) async {
        guard RoomVisionAvailability.describeChores.isAvailable else { return }
        let ui = MacUIState.shared
        ui.surface = .edit
        await pause(1)
        ui.describeChores = MacDescribeRequest()
        await pause(1.5)
        writeSheet(to: directory, name: "sheet-describe-compose")
        ui.describeChores = nil
        await pause(1)
        ui.describeChores = MacDescribeRequest(text: DescribeChoresModel.testTextFromEnvironment
            ?? "Vacuum the living room on Saturdays, do the dishes every night, deep clean the bathroom every other week, and change the air filter once a month.")
        await pause(8)   // real on-device inference
        writeSheet(to: directory, name: "sheet-describe-review")
        ui.describeChores = nil
        await pause(1)
    }

    private static func writeSheet(to directory: URL, name: String) {
        if let sheet = mainWindow?.attachedSheet { write(sheet, to: directory, name: name) }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    /// The Settings window has no identifier; it's the preference-style one.
    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && window !== mainWindow
                && (window.toolbarStyle == .preference
                    || window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true)
        }
    }

    /// Renders the whole window (title bar and toolbar included) via its frame view.
    private static func write(_ window: NSWindow, to directory: URL, name: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
#endif
