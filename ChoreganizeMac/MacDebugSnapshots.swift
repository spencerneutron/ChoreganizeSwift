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
        if let storeDirectory {
            runStoreCapture(to: storeDirectory)
            return
        }
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

    // MARK: - App Store capture (the deploy skill)

    /// `CHOREGANIZE_MAC_STORE_SHOTS=<dir>`: Mac App Store screenshots. The main window
    /// is set to 1440×900 pt and rendered at 2× — 2880×1800 px, a Mac App Store size —
    /// in light and dark, over the seeded demo data with Plus on (so Insights shows).
    /// Describe Chores and Snap a Room (with `CHOREGANIZE_ROOM_PHOTO`) are captured as
    /// their sheets over the window. While capturing, the shell draws its sidebar without
    /// the window-server vibrancy an in-process render can't reproduce, and hides the
    /// debug-only data label. Takes focus for about a minute.
    static let storeDirectory: URL? = {
        guard let path = ProcessInfo.processInfo.environment["CHOREGANIZE_MAC_STORE_SHOTS"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static var isStoreCapture: Bool { storeDirectory != nil }

    /// The size App Store screenshots are taken at (points; rendered at 2×).
    static let storeWindowSize = CGSize(width: 1440, height: 900)

    private static let storeDescribeText =
        "Vacuum the living room on Saturdays, feed the cat every morning, clean out the garage every other month, and change the air filter once a month."

    private static func runStoreCapture(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            await pause(2.5)
            UserDefaults.standard.set("on", forKey: EntitlementStore.debugOverrideKey)
            EntitlementStore.shared.applyDebugOverride()
            guard let window = mainWindow else {
                Log.error("Store shots: no main window")
                NSApp.terminate(nil)
                return
            }
            window.setFrame(NSRect(origin: .zero, size: storeWindowSize), display: true)
            window.center()
            // Key and active, so the shots show the colored window controls and default
            // buttons (this takes focus for the length of the capture).
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            await pause(1)
            Log.info("Store shots: window \(Int(window.frame.width))×\(Int(window.frame.height)) pt")
            let ui = MacUIState.shared
            for (name, surface) in [("1-work", AppMode.work), ("4-calendar", .calendar),
                                    ("5-insights", .insights), ("6-edit", .edit)] {
                ui.surface = surface
                await pause(1.5)
                await writeStoreShots(window, name: name, to: directory)
            }
            if RoomVisionAvailability.describeChores.isAvailable {
                ui.surface = .work
                await pause(1)
                ui.describeChores = MacDescribeRequest(text: storeDescribeText)
                await pause(10)   // real on-device inference
                await writeStoreShots(window, name: "2-describe", to: directory)
                ui.describeChores = nil
                await pause(1)
            }
            if let photo = RoomPhoto.testPhotoFromEnvironment, RoomVisionAvailability.current.isAvailable {
                ui.surface = .work
                await pause(1)
                ui.roomSnap = MacPhotoRequest(photo: photo)
                await pause(14)
                await writeStoreShots(window, name: "3-snap", to: directory)
                ui.roomSnap = nil
                await pause(1)
            }
            NSApp.appearance = nil
            Log.info("Store shots → \(directory.path)")
            NSApp.terminate(nil)
        }
    }

    /// The window (and its sheet, if one is up) in light, then dark.
    private static func writeStoreShots(_ window: NSWindow, name: String, to directory: URL) async {
        for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            await pause(1.2)
            writeStoreShot(window, to: directory.appendingPathComponent("mac-\(label)-\(name).png"))
        }
    }

    /// Renders the window's frame view at exactly 2× onto an opaque canvas (App Store
    /// screenshots can't have transparency; the rounded window corners get the window
    /// background), then draws an attached sheet where it sits, with a soft shadow.
    private static func writeStoreShot(_ window: NSWindow, to url: URL) {
        guard let frameView = window.contentView?.superview,
              let base = render(frameView, scale: 2) else { return }
        let width = base.width, height = base.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        var background = CGColor(gray: 1, alpha: 1)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview,
           let sheetImage = render(sheetView, scale: 2) {
            let origin = CGPoint(x: (sheet.frame.minX - window.frame.minX) * 2, y: (sheet.frame.minY - window.frame.minY) * 2)
            context.setShadow(offset: CGSize(width: 0, height: -16), blur: 60, color: CGColor(gray: 0, alpha: 0.35))
            context.draw(sheetImage, in: CGRect(origin: origin, size: CGSize(width: sheetImage.width, height: sheetImage.height)))
        }
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// A view drawn into a bitmap at a fixed scale, whatever the screen's.
    private static func render(_ view: NSView, scale: CGFloat) -> CGImage? {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
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
