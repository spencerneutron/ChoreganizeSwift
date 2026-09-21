import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Cross-platform shims so shared SwiftUI sources compile for both the iOS app
// and the macOS companion (ChoreganizeMac). On iOS every shim resolves to the
// exact modifier/API the code used before, so iOS behavior is unchanged.

extension ToolbarItemPlacement {
    /// Leading bar slot: `.topBarLeading` on iOS, `.navigation` on macOS.
    static var compatLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// Trailing bar slot: `.topBarTrailing` on iOS, `.primaryAction` on macOS.
    static var compatTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension View {
    /// `navigationBarTitleDisplayMode(.inline)` on iOS; macOS has no title modes.
    @ViewBuilder
    func compatInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `textInputAutocapitalization(.words)` on iOS; macOS has no auto-capitalization.
    @ViewBuilder
    func compatAutocapitalizeWords() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.words)
        #else
        self
        #endif
    }
}

extension View {
    /// `.listStyle(.insetGrouped)` on iOS; macOS has no grouped style — `.inset`
    /// is its closest sidebar-content idiom.
    @ViewBuilder
    func compatInsetGroupedList() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }

    /// `.presentationDetents([.medium, .large])` on iOS; macOS sheets don't have detents.
    @ViewBuilder
    func compatMediumLargeDetents() -> some View {
        #if os(iOS)
        self.presentationDetents([.medium, .large])
        #else
        self
        #endif
    }

    /// `.toolbar(_, for: .navigationBar)` on iOS; macOS has no navigation bar to
    /// hide/show (its window toolbar should stay put), so a no-op.
    @ViewBuilder
    func compatNavigationBarVisibility(_ visibility: Visibility) -> some View {
        #if os(iOS)
        self.toolbar(visibility, for: .navigationBar)
        #else
        self
        #endif
    }
}

extension Color {
    /// Grouped-list backdrop: `systemGroupedBackground` on iOS, the window
    /// background on macOS (grouped grays don't exist in AppKit).
    static var compatGroupedBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

/// The success haptic used when an add-flow finishes. Wraps
/// `UINotificationFeedbackGenerator` on iOS (kept warm via `prepare()`, see
/// cz_device11); Macs have no Taptic Engine, so both calls are no-ops there.
struct SuccessHaptic {
    #if os(iOS)
    private let generator = UINotificationFeedbackGenerator()
    #endif

    func prepare() {
        #if os(iOS)
        generator.prepare()
        #endif
    }

    func success() {
        #if os(iOS)
        generator.notificationOccurred(.success)
        #endif
    }
}

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

extension ImageRenderer {
    /// The rendered bitmap as the platform's native image type.
    @MainActor var platformImage: PlatformImage? {
        #if os(iOS)
        uiImage
        #else
        nsImage
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// Opens the system's notification settings for this app: the app's Settings
/// page on iOS, System Settings ▸ Notifications on macOS.
enum SystemSettingsOpener {
    @MainActor
    static func openNotificationSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #else
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}
