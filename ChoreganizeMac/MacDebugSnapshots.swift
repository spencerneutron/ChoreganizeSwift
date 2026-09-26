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
