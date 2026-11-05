import SwiftUI

/// Which toggle look the Work rows use. `.system` is the default and the only look in
/// release builds; `.promise` is a prototype, selectable in DEBUG with the launch
/// argument `-toggleLook promise`.
enum ToggleLook {
    case system, promise

    static var current: ToggleLook {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "toggleLook") == "promise" { return .promise }
        #endif
        return .system
    }
}

/// A toggle whose colours carry the app's day language: an unfilled toggle is a dull
/// amber (the gold end of the day gradient: morning, sunrise, a promise for the day not
/// yet kept) and a filled one is a strong lavender (evening, sunset, rest, the promise
/// kept).
///
/// SwiftUI's switch has no off-track colour API (and `SwitchToggleStyle(tint:)` is
/// deprecated), so this is a custom `ToggleStyle`.
///
/// The off track must not read as active, so it is the system switch's own grey warmed a
/// hint toward gold, no stronger (the user's call, 2026-11-05; a true amber looked "on").
/// The on track is a lavender a shade softer than the icon's, still 3.5:1 or better
/// against the white thumb, so the state reads by lightness and not only by hue:
///
///     off  light #E8DFC8                      dark #433D31
///     on   light #7370CF 4.1:1 vs the thumb   dark #8285DF 3.5:1 vs the thumb
///
/// A custom control loses what `UISwitch` gives for free, so it is restored here: the
/// switch trait and an On/Off value for VoiceOver, a selection haptic, and a glyph for
/// Differentiate Without Color (a checkmark when on, an open circle when off).
struct PromiseToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    private var off: Color { scheme == .dark ? Color(red: 0x43 / 255, green: 0x3D / 255, blue: 0x31 / 255)
                                              : Color(red: 0xE8 / 255, green: 0xDF / 255, blue: 0xC8 / 255) }
    private var on: Color { scheme == .dark ? Color(red: 0x82 / 255, green: 0x85 / 255, blue: 0xDF / 255)
                                             : Color(red: 0x73 / 255, green: 0x70 / 255, blue: 0xCF / 255) }

    func makeBody(configuration: Configuration) -> some View {
        // Only the control toggles, like the system switch: a tap on the chore's name must not
        // complete it. The row content already dims itself when a chore needs no attention, so
        // a locked row dims the control alone.
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Button {
                configuration.isOn.toggle()
            } label: {
                control(isOn: configuration.isOn)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .sensoryFeedback(.selection, trigger: configuration.isOn)
        }
    }

    @ViewBuilder
    private func control(isOn: Bool) -> some View {
        #if os(macOS)
        ZStack {
            Circle().strokeBorder(off, lineWidth: 1.5)
            if isOn {
                Circle().fill(on)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 16, height: 16)
        #else
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? on : off)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .padding(2)
                .overlay {
                    if differentiate {
                        Image(systemName: isOn ? "checkmark" : "circle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isOn ? on : off)
                    }
                }
        }
        .frame(width: 51, height: 31)
        .animation(.snappy, value: isOn)
        #endif
    }
}

extension View {
    /// Applies `PromiseToggleStyle` when the prototype look is on; otherwise leaves the
    /// system style untouched.
    @ViewBuilder
    func toggleLook(_ look: ToggleLook = .current) -> some View {
        if look == .promise {
            toggleStyle(PromiseToggleStyle())
        } else {
            self
        }
    }
}
