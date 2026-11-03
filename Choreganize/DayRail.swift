#if os(iOS)
import SwiftUI
import UIKit

/// Where the Work pager is, for the day rail: the fractional right-page index of the spread
/// on screen. 6 is the spread ending on today; halfway through a swipe to the next spread it
/// reads 7, since spreads step two days. Kept in its own observable object so the per-frame
/// scroll updates redraw only the rail, not the pager's day pages.
@Observable
final class DayRailTracker {
    var rightIndex: CGFloat = 6
}

/// The open iPhone Duo's day rail: a quiet top-to-bottom line with one tick per day in the
/// Work pager's range (no text) and a glass pill over the two days the spread shows. The
/// pill follows the pager as it scrolls; grab it and it follows the finger while the pager
/// steps a spread per tick pair underneath, then settles back onto the pager. It lives in the margin the left page gives up to mirror the side bar, in
/// the app icon's amber → periwinkle gradient (stepped per appearance for contrast).
struct DayRail: View {
    /// Days in the pager's range; today is the middle one.
    let dayCount: Int
    let tracker: DayRailTracker
    /// Right-page indices of the spreads, in step with the focused day (see `WeekPager`).
    let spreadRights: [Int]
    /// The two days a spread shows, for VoiceOver ("Sunday, November 1 and Monday, November 2").
    let spreadDescription: (Int) -> String
    /// Pages to the spread with this right-page index.
    let onSelect: (Int) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragTarget: Int?
    /// The finger's height while the pill is held.
    @State private var dragY: CGFloat?

    private var todayIndex: Int { dayCount / 2 }

    var body: some View {
        GeometryReader { geo in
            let layout = RailLayout(height: geo.size.height, dayCount: dayCount)
            let x = geo.size.width / 2
            ZStack(alignment: .topLeading) {
                // The skeleton: line and ticks, filled with the gradient at low opacity.
                Rectangle()
                    .fill(gradient)
                    .mask { skeleton(layout: layout, x: x) }
                    .opacity(colorScheme == .dark ? 0.45 : 0.4)
                // The in-view cursor: a glass pill over the spread's two days, the skeleton
                // showing through it, rimmed in the gradient.
                cursor(layout: layout, x: x)
                    .animation(dragY == nil ? .snappy : nil, value: dragY == nil)
            }
            .contentShape(Rectangle())
            .gesture(drag(layout: layout))
            .sensoryFeedback(.selection, trigger: dragTarget)
        }
        .accessibilityElement()
        .accessibilityLabel("Days shown")
        .accessibilityValue(spreadDescription(Int(tracker.rightIndex.rounded())))
        .accessibilityHint("Swipe up or down to move between days.")
        .accessibilityAdjustableAction { direction in
            let current = Int(tracker.rightIndex.rounded())
            guard let i = spreadRights.firstIndex(of: current) else { return }
            switch direction {
            case .increment where i + 1 < spreadRights.count: onSelect(spreadRights[i + 1])
            case .decrement where i > 0: onSelect(spreadRights[i - 1])
            default: break
            }
        }
    }

    // MARK: Drawing

    /// The rail's gradient, blended perceptually: an sRGB blend of amber and periwinkle goes
    /// muddy grey midway.
    private var colors: AnyGradient {
        Gradient(colors: [RailColors.amber, RailColors.periwinkle]).colorSpace(.perceptual)
    }

    private var gradient: some ShapeStyle {
        .linearGradient(colors, startPoint: .top, endPoint: .bottom)
    }

    /// The pill's rim: the stretch of the rail's gradient where the pill sits, exaggerated
    /// to twice the pill's span so its two stages read — gold at the top of the rail,
    /// periwinkle at the bottom. `top`/`bottom` are the pill's ends, as fractions of the
    /// rail (0 = first tick, 1 = last).
    private func rim(top: CGFloat, bottom: CGFloat) -> some ShapeStyle {
        let span = min((bottom - top) * 2, 1)
        let middle = (top + bottom) / 2
        let from = min(max(middle - span / 2, 0), 1 - span)
        // Map the whole gradient (0…1) so the pill's own top and bottom land on from…from+span.
        return .linearGradient(colors,
                               startPoint: UnitPoint(x: 0.5, y: -from / span),
                               endPoint: UnitPoint(x: 0.5, y: (1 - from) / span))
    }

    private func skeleton(layout: RailLayout, x: CGFloat) -> some View {
        Path { path in
            path.addRoundedRect(in: CGRect(x: x - 1, y: layout.y(0), width: 2,
                                           height: layout.y(dayCount - 1) - layout.y(0)),
                                cornerSize: CGSize(width: 1, height: 1))
            for day in 0..<dayCount {
                let half: CGFloat = day == todayIndex ? 9 : 5
                path.addRoundedRect(in: CGRect(x: x - half, y: layout.y(day) - 1, width: half * 2, height: 2),
                                    cornerSize: CGSize(width: 1, height: 1))
            }
        }
    }

    private func cursor(layout: RailLayout, x: CGFloat) -> some View {
        // The spread (r - 1 | r) spans ticks r - 1 and r; an edge spread clamps to the range.
        let right = tracker.rightIndex
        let height = layout.y(1) - layout.y(0) + 22
        let tracked = (layout.y(fractional: max(right - 1, 0))
                       + layout.y(fractional: min(right, CGFloat(dayCount - 1)))) / 2
        let center = dragY.map { min(max($0, layout.y(0)), layout.y(dayCount - 1)) } ?? tracked
        let railSpan = max(layout.y(dayCount - 1) - layout.y(0), 1)
        let top = (center - height / 2 - layout.y(0)) / railSpan
        let bottom = (center + height / 2 - layout.y(0)) / railSpan
        return GlassPill(rim: rim(top: top, bottom: bottom))
            .frame(width: 26, height: height)
            .position(x: x, y: center)
    }

    // MARK: Dragging

    /// The finger holds the pill's middle, between its two days; each tick pair it crosses
    /// pages to the next spread.
    private func drag(layout: RailLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragY = value.location.y
                let middle = layout.day(atY: value.location.y) + 0.5
                guard let target = spreadRights.min(by: {
                    abs(CGFloat($0) - middle) < abs(CGFloat($1) - middle)
                }), target != dragTarget else { return }
                dragTarget = target
                onSelect(target)
            }
            .onEnded { _ in
                dragTarget = nil
                dragY = nil
            }
    }
}

/// The cursor: a vertical Liquid Glass capsule (iOS 26; a material before that) with a thin
/// gradient rim.
private struct GlassPill<Rim: ShapeStyle>: View {
    let rim: Rim

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular.interactive(), in: .capsule)
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay(Capsule().strokeBorder(rim, lineWidth: 1.5))
    }
}

/// Tick positions down the rail: evenly spaced, inset from the ends.
private struct RailLayout {
    let height: CGFloat
    let dayCount: Int
    private let inset: CGFloat = 28

    private var spacing: CGFloat {
        dayCount > 1 ? (height - inset * 2) / CGFloat(dayCount - 1) : 0
    }

    func y(_ day: Int) -> CGFloat { y(fractional: CGFloat(day)) }
    func y(fractional day: CGFloat) -> CGFloat { inset + day * spacing }

    /// The (fractional) day at a vertical position.
    func day(atY y: CGFloat) -> CGFloat {
        spacing > 0 ? (y - inset) / spacing : 0
    }
}

/// The app icon's gradient stops (CGZ2.icon: Display P3 amber → periwinkle), stepped in
/// OKLab lightness per appearance so the cursor keeps ≥ 3:1 non-text contrast on the grouped
/// background (validated: light #BB7400 / #7A7CC6 on #F2F2F7; dark #C48500 / #888ACF on
/// #000000 and #1C1C1E).
enum RailColors {
    static let amber = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xC4 / 255, green: 0x85 / 255, blue: 0x00 / 255, alpha: 1)
            : UIColor(red: 0xBB / 255, green: 0x74 / 255, blue: 0x00 / 255, alpha: 1)
    })
    static let periwinkle = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x88 / 255, green: 0x8A / 255, blue: 0xCF / 255, alpha: 1)
            : UIColor(red: 0x7A / 255, green: 0x7C / 255, blue: 0xC6 / 255, alpha: 1)
    })
}
#endif
