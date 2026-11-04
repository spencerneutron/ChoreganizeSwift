#if os(iOS)
import SwiftUI
import UIKit

/// Where the Work pager is, for the day rail: the fractional right-page index of the spread
/// on screen. 6 is the spread ending on today; halfway through a swipe to the next spread it
/// reads 7, since spreads step two days. Kept in its own observable object, read only by the
/// pill, so the per-frame scroll updates redraw the pill and nothing else.
@Observable
final class DayRailTracker {
    var rightIndex: CGFloat = 6
}

/// The open iPhone Duo's day rail: a quiet top-to-bottom line with one tick per day in the
/// Work pager's range (no text) and a glass pill over the two days the spread shows. The
/// pill follows the pager as it scrolls; grab it and it follows the finger while the pager
/// steps a spread per tick pair underneath, then settles back onto the pager. It lives in
/// the margin the left page gives up to mirror the side bar, in the app icon's amber →
/// periwinkle gradient (stepped per appearance for contrast).
struct DayRail: View {
    /// Days in the pager's range; today is the middle one.
    let dayCount: Int
    let tracker: DayRailTracker
    /// Right-page indices of the spreads, in step with the focused day (see `WeekPager`).
    let spreadRights: [Int]
    /// The focused spread's right page: what VoiceOver reads and adjusts from (the tracker
    /// is mid-animation after a step).
    let focusedRight: Int
    /// The two days a spread shows, for VoiceOver ("Sunday, November 1 and Monday, November 2").
    let spreadDescription: (Int) -> String
    /// Pages to the spread with this right-page index.
    let onSelect: (Int) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // The skeleton: line and ticks, filled with the gradient at low opacity. It
                // takes no touches, so a resting thumb or a page swipe passes through to the
                // pager; only the pill is grabbable.
                Rectangle()
                    .fill(DayRailStyle.gradient)
                    .mask { skeleton(size: geo.size) }
                    .opacity(contrast == .increased ? 0.75 : (colorScheme == .dark ? 0.45 : 0.4))
                    .allowsHitTesting(false)
                RailPill(dayCount: dayCount, tracker: tracker, spreadRights: spreadRights,
                         size: geo.size, rimWidth: contrast == .increased ? 2.5 : 1.5,
                         onSelect: onSelect)
            }
            .coordinateSpace(.named(DayRailStyle.space))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Days shown")
        .accessibilityValue(spreadDescription(focusedRight))
        .accessibilityAdjustableAction { direction in
            guard let i = spreadRights.firstIndex(of: focusedRight) else { return }
            switch direction {
            case .increment where i + 1 < spreadRights.count: onSelect(spreadRights[i + 1])
            case .decrement where i > 0: onSelect(spreadRights[i - 1])
            default: break
            }
        }
    }

    private func skeleton(size: CGSize) -> some View {
        let x = size.width / 2
        let y = { (day: Int) in DayRailMath.y(day: CGFloat(day), height: size.height, dayCount: dayCount) }
        return Path { path in
            path.addRoundedRect(in: CGRect(x: x - 1, y: y(0), width: 2, height: y(dayCount - 1) - y(0)),
                                cornerSize: CGSize(width: 1, height: 1))
            for day in 0..<dayCount {
                let half: CGFloat = day == dayCount / 2 ? 9 : 5   // today's tick is longer
                path.addRoundedRect(in: CGRect(x: x - half, y: y(day) - 1, width: half * 2, height: 2),
                                    cornerSize: CGSize(width: 1, height: 1))
            }
        }
    }
}

/// The in-view cursor: a glass pill over the spread's two days, the skeleton showing through
/// it. The only part of the rail that reads the tracker, so it alone redraws per frame.
private struct RailPill: View {
    let dayCount: Int
    let tracker: DayRailTracker
    let spreadRights: [Int]
    let size: CGSize
    let rimWidth: CGFloat
    let onSelect: (Int) -> Void

    /// The finger's height and the spread under it while the pill is held. Gesture state
    /// resets itself when a drag ends or is cancelled (a call, Control Center), so the pill
    /// can't stay stuck where the finger was.
    @GestureState private var drag: RailDrag?

    var body: some View {
        let height = DayRailMath.pillHeight(height: size.height, dayCount: dayCount)
        let center = DayRailMath.clampedCenter(
            drag?.y ?? DayRailMath.pillCenter(rightIndex: tracker.rightIndex, height: size.height,
                                              dayCount: dayCount),
            pillHeight: height, railHeight: size.height)
        let slice = DayRailMath.rimSlice(center: center, pillHeight: height, railHeight: size.height,
                                         dayCount: dayCount)
        GlassPill(rim: DayRailStyle.rim(from: slice.from, span: slice.span), rimWidth: rimWidth)
            .frame(width: 26, height: height)
            .contentShape(Capsule())
            .gesture(dragGesture)
            .position(x: size.width / 2, y: center)
            .animation(drag == nil ? .snappy : nil, value: drag == nil)
            // A tick each time the held pill moves to another spread, not on touch-down or
            // release (the state goes nil ↔ value then).
            .sensoryFeedback(.selection, trigger: drag?.spread) { old, new in
                old != nil && new != nil
            }
            .onChange(of: drag?.spread) { old, new in
                if let old, let new, old != new { onSelect(new) }
            }
    }

    /// The finger holds the pill's middle, between its two days; each tick pair it crosses
    /// pages to the next spread.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DayRailStyle.space))
            .updating($drag) { value, state, _ in
                let day = DayRailMath.day(atY: value.location.y, height: size.height, dayCount: dayCount)
                state = RailDrag(y: value.location.y,
                                 spread: DayRailMath.spread(atDay: day, rights: spreadRights))
            }
    }
}

private struct RailDrag: Equatable {
    var y: CGFloat
    var spread: Int?
}

/// The rail's arithmetic, kept pure for unit tests. Heights are in the rail's coordinates;
/// days are indices into the pager's range; a spread is identified by its right page.
enum DayRailMath {
    /// The first and last ticks sit this far in from the rail's ends.
    static let endInset: CGFloat = 28

    static func spacing(height: CGFloat, dayCount: Int) -> CGFloat {
        dayCount > 1 ? max(height - endInset * 2, 0) / CGFloat(dayCount - 1) : 0
    }

    /// The height of a (fractional) day's tick.
    static func y(day: CGFloat, height: CGFloat, dayCount: Int) -> CGFloat {
        endInset + day * spacing(height: height, dayCount: dayCount)
    }

    /// The (fractional) day at a height.
    static func day(atY y: CGFloat, height: CGFloat, dayCount: Int) -> CGFloat {
        let spacing = spacing(height: height, dayCount: dayCount)
        return spacing > 0 ? (y - endInset) / spacing : 0
    }

    /// The pager's position as a fractional right-page index, from its scroll offset: spreads
    /// step two days, one page width apart.
    static func rightIndex(firstRight: Int, offset: CGFloat, pageWidth: CGFloat) -> CGFloat {
        pageWidth > 0 ? CGFloat(firstRight) + 2 * offset / pageWidth : CGFloat(firstRight)
    }

    /// The spread whose two days straddle a (fractional) day: its right page is the day
    /// plus a half, rounded to the nearest spread in step.
    static func spread(atDay day: CGFloat, rights: [Int]) -> Int? {
        rights.min { abs(CGFloat($0) - (day + 0.5)) < abs(CGFloat($1) - (day + 0.5)) }
    }

    /// The pill spans its spread's two ticks with a little room either side.
    static func pillHeight(height: CGFloat, dayCount: Int) -> CGFloat {
        spacing(height: height, dayCount: dayCount) + 22
    }

    /// The pill's centre for the pager's position: midway between the spread's two ticks
    /// (an edge spread, with a side outside the range, sits on its one real day).
    static func pillCenter(rightIndex: CGFloat, height: CGFloat, dayCount: Int) -> CGFloat {
        let last = CGFloat(dayCount - 1)
        let top = y(day: min(max(rightIndex - 1, 0), last), height: height, dayCount: dayCount)
        let bottom = y(day: min(max(rightIndex, 0), last), height: height, dayCount: dayCount)
        return (top + bottom) / 2
    }

    /// Keeps the whole pill inside the rail.
    static func clampedCenter(_ center: CGFloat, pillHeight: CGFloat, railHeight: CGFloat) -> CGFloat {
        let half = pillHeight / 2
        guard railHeight > pillHeight else { return railHeight / 2 }
        return min(max(center, half), railHeight - half)
    }

    /// The stretch of the rail's gradient the pill's rim shows: where the pill sits,
    /// exaggerated to twice its span so the rim's two stages read — gold at the top of the
    /// rail, periwinkle at the bottom. As fractions of the gradient (0 = first tick, 1 = last).
    static func rimSlice(center: CGFloat, pillHeight: CGFloat, railHeight: CGFloat,
                         dayCount: Int) -> (from: CGFloat, span: CGFloat) {
        let first = y(day: 0, height: railHeight, dayCount: dayCount)
        let railSpan = max(y(day: CGFloat(dayCount - 1), height: railHeight, dayCount: dayCount) - first, 1)
        let span = min(2 * pillHeight / railSpan, 1)
        let middle = (center - first) / railSpan
        return (min(max(middle - span / 2, 0), 1 - span), span)
    }
}

/// The rail's colours: the app icon's gradient stops (CGZ2.icon: Display P3 amber →
/// periwinkle), stepped in OKLab lightness per appearance so the pill's rim keeps ≥ 3:1
/// non-text contrast on the grouped background (validated: light #BB7400 / #7A7CC6 on
/// #F2F2F7 and white; dark #C48500 / #888ACF on #000000 and #1C1C1E).
enum DayRailStyle {
    static let space = "dayRail"

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

    /// Blended perceptually: an sRGB blend of amber and periwinkle goes muddy grey midway.
    static var colors: AnyGradient {
        Gradient(colors: [amber, periwinkle]).colorSpace(.perceptual)
    }

    static var gradient: some ShapeStyle {
        .linearGradient(colors, startPoint: .top, endPoint: .bottom)
    }

    /// The gradient laid over the pill so its own top and bottom show `from…from + span`.
    static func rim(from: CGFloat, span: CGFloat) -> some ShapeStyle {
        .linearGradient(colors, startPoint: UnitPoint(x: 0.5, y: -from / span),
                        endPoint: UnitPoint(x: 0.5, y: (1 - from) / span))
    }
}

/// The cursor: a vertical Liquid Glass capsule (iOS 26; a material before that) with a thin
/// gradient rim.
private struct GlassPill<Rim: ShapeStyle>: View {
    let rim: Rim
    let rimWidth: CGFloat

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular.interactive(), in: .capsule)
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay(Capsule().strokeBorder(rim, lineWidth: rimWidth))
    }
}
#endif
