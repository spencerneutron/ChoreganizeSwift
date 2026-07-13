import SwiftUI

/// Renders one queued `AppModel.BannerMessage`. Tapping the action (if any) runs it;
/// the close button dismisses. Styling keys off the banner's style; the banner's own
/// timer auto-dismisses it (see `AppModel.present`). Shared by both shells: iOS
/// mounts it in ContentView's top safe-area inset, macOS above the split view.
struct AppBannerView: View {
    let banner: AppModel.BannerMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.headline)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                if let title = banner.title {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                Text(banner.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let actionTitle = banner.actionTitle {
                Button(actionTitle) { onDismiss(); banner.action?() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var iconName: String {
        switch banner.style {
        case .info:    "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error:   "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch banner.style {
        case .info:    .accentColor
        case .success: .green
        case .warning: .orange
        case .error:   .red
        }
    }
}
