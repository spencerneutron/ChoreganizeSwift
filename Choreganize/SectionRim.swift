import SwiftUI

/// Pure maths for the section rim (`SectionRim.metal` mirrors the geometry): the light on a
/// section card's edge, drawn as a fraction of its perimeter equal to the section's progress.
///
/// The path starts at the lower trailing corner (where the bottom-right arc begins on the
/// right edge, in left-to-right layout), runs along the bottom toward leading, up the leading
/// side, across the top and down the trailing side. Right-to-left layouts mirror x.
enum SectionRim {
    /// How far the rim's layer extends past the card on every side, in points.
    static let reach: CGFloat = 48

    /// The flourish's clock, shared with the day wash.
    static let flourishDuration: Double = 8

    // MARK: Geometry

    /// Length of the card's outline (straight edges plus the four corner arcs).
    static func perimeter(size: CGSize, cornerRadius: CGFloat) -> Double {
        let r = clampedRadius(size, cornerRadius)
        return 2 * (Double(size.width) - 2 * r) + 2 * (Double(size.height) - 2 * r) + 2 * Double.pi * r
    }

    /// Arc parameter 0...1 of the outline point nearest to `point`, in card coordinates
    /// (origin top-left, y down). 0 is the start of the path, 1 its end.
    static func arcParameter(of point: CGPoint, size: CGSize, cornerRadius: CGFloat,
                             rightToLeft: Bool = false) -> Double {
        let g = Geometry(size: size, cornerRadius: cornerRadius)
        var x = Double(point.x) - Double(size.width) / 2
        let y = Double(point.y) - Double(size.height) / 2
        if rightToLeft { x = -x }
        let s = g.arcLength(x: x, y: y)
        // The path is closed: its end is its start.
        return s >= g.perimeter - 1e-9 ? 0 : s / g.perimeter
    }

    /// The outline point `s` (0...1) along the path, in card coordinates.
    static func point(atArc s: Double, size: CGSize, cornerRadius: CGFloat,
                      rightToLeft: Bool = false) -> CGPoint {
        let g = Geometry(size: size, cornerRadius: cornerRadius)
        var (x, y) = g.point(at: min(max(s, 0), 1) * g.perimeter)
        if rightToLeft { x = -x }
        return CGPoint(x: x + Double(size.width) / 2, y: y + Double(size.height) / 2)
    }

    private static func clampedRadius(_ size: CGSize, _ radius: CGFloat) -> Double {
        Double(min(max(radius, 0), min(size.width, size.height) / 2))
    }

    private struct Geometry {
        let ix: Double, iy: Double, r: Double, arc: Double, lineH: Double, lineV: Double, perimeter: Double

        init(size: CGSize, cornerRadius: CGFloat) {
            r = SectionRim.clampedRadius(size, cornerRadius)
            ix = Double(size.width) / 2 - r
            iy = Double(size.height) / 2 - r
            arc = Double.pi / 2 * r
            lineH = 2 * ix
            lineV = 2 * iy
            perimeter = 4 * arc + 2 * lineH + 2 * lineV
        }

        func arcLength(x: Double, y: Double) -> Double {
            let outX = abs(x) > ix, outY = abs(y) > iy
            if outX && outY {
                let vx = x - min(max(x, -ix), ix), vy = y - min(max(y, -iy), iy)
                var theta = atan2(vy, vx)
                if theta < 0 { theta += 2 * Double.pi }
                let k: Double = y > 0 ? (x > 0 ? 0 : 1) : (x < 0 ? 2 : 3)
                let base = k == 0 ? 0 : k == 1 ? arc + lineH : k == 2 ? 2 * arc + lineH + lineV
                                                              : 3 * arc + 2 * lineH + lineV
                return base + r * min(max(theta - k * Double.pi / 2, 0), Double.pi / 2)
            }
            if outY {
                return y > 0 ? arc + (ix - x) : 3 * arc + lineH + lineV + (x + ix)
            }
            if outX {
                return x > 0 ? 4 * arc + 2 * lineH + lineV + (y + iy) : 2 * arc + lineH + (iy - y)
            }
            return 0
        }

        func point(at distance: Double) -> (Double, Double) {
            var s = distance
            if s < arc { let t = s / max(r, 1e-4); return (ix + r * cos(t), iy + r * sin(t)) }
            s -= arc
            if s < lineH { return (ix - s, iy + r) }
            s -= lineH
            if s < arc { let t = Double.pi / 2 + s / max(r, 1e-4); return (-ix + r * cos(t), iy + r * sin(t)) }
            s -= arc
            if s < lineV { return (-ix - r, iy - s) }
            s -= lineV
            if s < arc { let t = Double.pi + s / max(r, 1e-4); return (-ix + r * cos(t), -iy + r * sin(t)) }
            s -= arc
            if s < lineH { return (-ix + s, -iy - r) }
            s -= lineH
            if s < arc { let t = 1.5 * Double.pi + s / max(r, 1e-4); return (ix + r * cos(t), -iy + r * sin(t)) }
            s -= arc
            return (ix + r, -iy + min(s, lineV))
        }
    }

    // MARK: Levels

    /// Hairline opacity at rest: none at 0 %, 0.25 at the first completion, 0.60 at 100 %.
    static func hairlineOpacity(fraction f: Double) -> Double {
        let f = min(max(f, 0), 1)
        return f <= 0 ? 0 : 0.25 + 0.35 * f
    }

    /// Halo level at rest: 0 at 0 %, 0.14 at 100 %.
    static func haloLevel(fraction f: Double) -> Double { 0.14 * min(max(f, 0), 1) }

    /// Everything the shader needs to draw one frame.
    struct Frame: Equatable, VectorArithmetic {
        var baseFill: Double = 0       // fraction of the perimeter the resting hairline covers
        var baseOpacity: Double = 0
        var lineFill: Double = 0       // the flourish line's fill (and where the head sits)
        var lineOpacity: Double = 0
        var headOpacity: Double = 0
        var haloLevel: Double = 0

        static var zero: Frame { Frame() }

        private var fields: [Double] { [baseFill, baseOpacity, lineFill, lineOpacity, headOpacity, haloLevel] }
        private init(_ v: [Double]) {
            self.init(baseFill: v[0], baseOpacity: v[1], lineFill: v[2], lineOpacity: v[3],
                      headOpacity: v[4], haloLevel: v[5])
        }
        init(baseFill: Double = 0, baseOpacity: Double = 0, lineFill: Double = 0,
             lineOpacity: Double = 0, headOpacity: Double = 0, haloLevel: Double = 0) {
            self.baseFill = baseFill; self.baseOpacity = baseOpacity; self.lineFill = lineFill
            self.lineOpacity = lineOpacity; self.headOpacity = headOpacity; self.haloLevel = haloLevel
        }
        static func + (a: Frame, b: Frame) -> Frame { Frame(zip(a.fields, b.fields).map(+)) }
        static func - (a: Frame, b: Frame) -> Frame { Frame(zip(a.fields, b.fields).map(-)) }
        mutating func scale(by rhs: Double) { self = Frame(fields.map { $0 * rhs }) }
        var magnitudeSquared: Double { fields.reduce(0) { $0 + $1 * $1 } }
    }

    /// The resting rim for a section at `fraction` complete.
    static func rest(fraction f: Double) -> Frame {
        let f = min(max(f, 0), 1)
        return Frame(baseFill: f, baseOpacity: hairlineOpacity(fraction: f), haloLevel: haloLevel(fraction: f))
    }

    // MARK: Flourish

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Retrace fill 0...1 at `t` seconds: 0.8 s to 5.8 s, eased.
    static func flourishFill(at t: Double) -> Double { smoothstep(0.8, 5.8, t) }

    /// The flourish on its 8 s clock. The resting rim at `from` (the fraction before the
    /// completion) stays underneath at 0.3 opacity while a 0.65 line retraces the whole
    /// perimeter with a bright head at its tip (0.8 s to 5.8 s); the halo then rises to 0.40
    /// by 7.4 s and, with the line, settles to the resting 100 % values (0.60 line, 0.14 halo)
    /// by 8 s. Unlike the playground (which keeps a 0.65 line and 0.32 halo afterwards) it
    /// ends on exactly `rest(fraction: 1)`, as BEHAVIOR.md section 3.1 says.
    static func flourish(at t: Double, from: Double) -> Frame {
        if t >= flourishDuration { return rest(fraction: 1) }
        let from = min(max(from, 0), 1)
        let t = max(t, 0)
        let fill = flourishFill(at: t)
        let settle = smoothstep(7.4, 8.0, t)
        let intro = smoothstep(0, 0.5, t)
        let drawn = from + (1 - from) * fill
        let halo: Double
        if t < 7.4 {
            halo = haloLevel(fraction: drawn) + (0.40 - haloLevel(fraction: 1)) * smoothstep(5.8, 7.4, t)
        } else {
            halo = 0.40 + (haloLevel(fraction: 1) - 0.40) * settle
        }
        let baseOpacity = hairlineOpacity(fraction: from) + (0.3 - hairlineOpacity(fraction: from)) * intro
        let head = min(1, fill / 0.02, (1 - fill) / 0.02)
        return Frame(baseFill: from + (1 - from) * settle,
                     baseOpacity: baseOpacity + (hairlineOpacity(fraction: 1) - baseOpacity) * settle,
                     lineFill: fill,
                     lineOpacity: 0.65 * (1 - settle),
                     headOpacity: max(0, head),
                     haloLevel: halo)
    }

    // MARK: Shader

    static func shader(frame: Frame, size: CGSize, cornerRadius: CGFloat, scale: CGFloat,
                       dark: Bool, rightToLeft: Bool) -> Shader {
        ShaderLibrary.sectionRim(
            .float2(size), .float(Float(cornerRadius)), .float(Float(reach)),
            .float(rightToLeft ? 1 : 0), .float(dark ? 1 : 0), .float(Float(scale)),
            .float(Float(frame.baseFill)), .float(Float(frame.baseOpacity)),
            .float(Float(frame.lineFill)), .float(Float(frame.lineOpacity)),
            .float(Float(frame.headOpacity)), .float(Float(frame.haloLevel)),
            .color(dark ? CompletionWash.lavender : CompletionWash.honey))
    }

    /// Pre-compiles the shader off-main so the first rim doesn't hitch. Wire it next to
    /// `GlowPrewarm.run()` at launch.
    static func prewarm() {
        Task.detached(priority: .utility) {
            let shader = SectionRim.shader(frame: .zero, size: CGSize(width: 1, height: 1), cornerRadius: 0,
                                           scale: 1, dark: false, rightToLeft: false)
            try? await shader.compile(as: .colorEffect)
        }
    }
}

/// Timeline entries at display rate from `start` to the end of the 8 s flourish, then stops,
/// so the view ticks only while the flourish plays.
private struct RimSchedule: TimelineSchedule {
    var start: Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> [Date] {
        guard let start else { return [startDate] }
        let end = start.addingTimeInterval(SectionRim.flourishDuration)
        var dates = [startDate]
        if startDate < end {
            var next = max(startDate, start)
            while next < end {
                next = next.addingTimeInterval(1.0 / 60)
                dates.append(min(next, end))
            }
            // One entry clearly past the end, so the last frame drawn is the resting rim. A
            // last frame a tick short of 8 s left a full rim about 2 pt from closing.
            dates.append(end.addingTimeInterval(0.05))
        }
        return dates
    }
}

/// The rim drawn behind one section card. It lays itself out as the card rect outset by
/// `SectionRim.reach` on every side; position it with the card's centre as its own centre,
/// e.g. `.background { SectionRimView(...) }` (a background is centred on the card and may
/// overflow it). It never takes hits and is hidden from accessibility.
struct SectionRimView: View {
    var cardSize: CGSize
    var cornerRadius: CGFloat
    /// The section's progress, 0...1. Changes ease over about 0.22 s.
    var fraction: Double
    /// When a local completion finished the section; the flourish plays for 8 s from here.
    var flourishStart: Date?
    /// The fraction before that completion (the resting rim stays underneath the retrace).
    var flourishFrom: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutDirection) private var layoutDirection

    init(cardSize: CGSize, cornerRadius: CGFloat, fraction: Double,
         flourishStart: Date? = nil, flourishFrom: Double = 0) {
        self.cardSize = cardSize
        self.cornerRadius = cornerRadius
        self.fraction = fraction
        self.flourishStart = flourishStart
        self.flourishFrom = flourishFrom
    }

    var body: some View {
        Group {
            // Reduce Motion or Low Power Mode, like the wash: no retrace, no head; levels
            // cross-fade over 0.3 s (the fill itself snaps).
            if reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled {
                let target = SectionRim.rest(fraction: fraction)
                rim(target, fixedFill: target.baseFill)
                    .animation(.easeInOut(duration: 0.3), value: target)
            } else {
                TimelineView(RimSchedule(start: fraction >= 1 ? flourishStart : nil)) { context in
                    let t = flourishStart.map { context.date.timeIntervalSince($0) }
                    let playing = fraction >= 1 && t != nil && t! >= 0 && t! < SectionRim.flourishDuration
                    let frame = playing ? SectionRim.flourish(at: t!, from: flourishFrom)
                                        : SectionRim.rest(fraction: fraction)
                    rim(frame, fixedFill: nil)
                        // The clock drives the flourish; only resting changes ease.
                        .animation(playing ? nil : .easeOut(duration: 0.22), value: frame)
                }
            }
        }
        .frame(width: cardSize.width + 2 * SectionRim.reach, height: cardSize.height + 2 * SectionRim.reach)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rim(_ frame: SectionRim.Frame, fixedFill: Double?) -> some View {
        // A faint fill so the effect has pixels to run on; the shader ignores the input colour.
        Rectangle()
            .fill(Color.white.opacity(0.01))
            .modifier(RimEffect(frame: frame, fixedFill: fixedFill, size: cardSize, cornerRadius: cornerRadius,
                                scale: displayScale, dark: scheme == .dark,
                                rightToLeft: layoutDirection == .rightToLeft))
    }
}

/// Feeds an animatable `Frame` to the shader, so eased changes redraw every frame.
private struct RimEffect: ViewModifier, Animatable {
    var frame: SectionRim.Frame
    var fixedFill: Double?
    var size: CGSize
    var cornerRadius: CGFloat
    var scale: CGFloat
    var dark: Bool
    var rightToLeft: Bool

    var animatableData: SectionRim.Frame {
        get { frame }
        set { frame = newValue }
    }

    func body(content: Content) -> some View {
        var shown = frame
        if let fixedFill { shown.baseFill = fixedFill }
        return content.colorEffect(SectionRim.shader(frame: shown, size: size, cornerRadius: cornerRadius,
                                                     scale: scale, dark: dark, rightToLeft: rightToLeft))
    }
}
