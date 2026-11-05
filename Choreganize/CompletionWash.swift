import SwiftUI
#if os(iOS)
import CoreHaptics
#endif

/// Constants and shader plumbing for the completion wash: a one-shot celebration drawn behind
/// a day's cards when its last open chore is completed (`ChoreWash.metal`).
enum CompletionWash {
    /// The user's pick (2026-11-05): a slow roll-through, calm look, 8 s.
    static let duration: Double = 8.0

    // The app icon's pair plus the honey bloom (sRGB; the shader mixes them in OKLab).
    static let amber = Color(.sRGB, red: 1.0, green: 0.760, blue: 0.200)       // #FFC233
    static let lavender = Color(.sRGB, red: 0.682, green: 0.706, blue: 1.0)    // #AEB4FF
    static let honey = Color(.sRGB, red: 1.0, green: 0.851, blue: 0.471)       // #FFD978

    /// Mac rows have no cards and sit directly on the background, so the wash is dialled
    /// down there to keep the row text legible.
    static var strength: Float {
        #if os(macOS)
        0.55
        #else
        1.0
        #endif
    }

    /// Look 1 = calm (the user's pick). DEBUG `-washLook N` overrides; release always ships 1.
    static var look: Float {
        #if DEBUG
        debugOverride("washLook") ?? 1
        #else
        1
        #endif
    }

    /// Motion 1 = roll-through (the user's pick). DEBUG `-washMotion 0` restores expand-and-retreat.
    static var motion: Float {
        #if DEBUG
        debugOverride("washMotion") ?? 1
        #else
        1
        #endif
    }

    #if DEBUG
    private static func debugOverride(_ key: String) -> Float? {
        UserDefaults.standard.object(forKey: key) == nil ? nil : Float(UserDefaults.standard.double(forKey: key))
    }
    #endif

    static func shader(size: CGSize, time: Double, seed: Float, dark: Bool,
                       look: Float = CompletionWash.look,
                       motion: Float = CompletionWash.motion,
                       strength: Float = CompletionWash.strength) -> Shader {
        var shader = ShaderLibrary.choreWash(
            .float2(size), .float(Float(time)), .float(Float(duration)), .float(seed),
            .color(amber), .color(lavender), .color(honey),
            .float(dark ? 1 : 0), .float(look), .float(motion), .float(strength))
        // Banding shows in a soft gradient on a flat background, most of all in dark mode.
        shader.dithersColor = true
        return shader
    }

    #if DEBUG
    /// `CHOREGANIZE_WASH_AT=<seconds>`: freeze a wash at that time on today's page (screenshots).
    static var debugFrozenTime: Double? {
        ProcessInfo.processInfo.environment["CHOREGANIZE_WASH_AT"].flatMap(Double.init)
    }
    /// `CHOREGANIZE_WASH_DEMO=<delay>`: start a wash that long after today's page appears (recordings).
    static var debugDemoDelay: Double? {
        ProcessInfo.processInfo.environment["CHOREGANIZE_WASH_DEMO"].flatMap(Double.init)
    }
    #endif
}

/// Decides whether a day page's completion state change earns the wash. Pure, so the rules
/// are testable without a view.
enum WashTrigger {
    /// How recent the user's own completion must be for it to count as the cause.
    static let window: TimeInterval = 3

    /// A page-load, a sync from another household member and a widget completion all flip
    /// "complete" without a local action on this page, so a recent local completion is
    /// required in addition to the false → true edge.
    static func shouldWash(wasComplete: Bool, isComplete: Bool, isLocked: Bool,
                           lastLocalCompletion: Date?, now: Date) -> Bool {
        guard !wasComplete, isComplete, !isLocked, let last = lastLocalCompletion else { return false }
        let age = now.timeIntervalSince(last)
        return age >= 0 && age <= window
    }
}

/// The page backdrop: `base` always, plus the wash while `start` is set. Sits behind the
/// list because a UIKit/AppKit-backed List can't take a colorEffect (it renders a placeholder).
struct CompletionWashLayer: View {
    var start: Date?
    var seed: Float
    var base: Color
    /// DEBUG: pins the wash at this many seconds in, instead of playing it.
    var frozenTime: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    init(start: Date?, seed: Float, base: Color, frozenTime: Double? = nil) {
        self.start = start
        self.seed = seed
        self.base = base
        self.frozenTime = frozenTime
    }

    var body: some View {
        ZStack {
            base
            if let start {
                if reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled {
                    fade(from: start)
                } else {
                    wash(from: start)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func time(at date: Date, from start: Date) -> Double {
        frozenTime ?? date.timeIntervalSince(start)
    }

    private func wash(from start: Date) -> some View {
        GeometryReader { geo in
            TimelineView(.animation) { tl in
                Rectangle()
                    .fill(base)
                    .colorEffect(CompletionWash.shader(size: geo.size, time: time(at: tl.date, from: start),
                                                       seed: seed, dark: scheme == .dark))
            }
        }
    }

    /// Reduce Motion / Low Power: the creative gradient fades in and out in place, with no
    /// travel or swirl.
    private func fade(from start: Date) -> some View {
        let gradient = Gradient(colors: [CompletionWash.amber, CompletionWash.lavender])
            .colorSpace(.perceptual)
        return TimelineView(.animation) { tl in
            Rectangle()
                .fill(.linearGradient(gradient, startPoint: .top, endPoint: .bottom))
                .opacity(Self.fadeOpacity(at: time(at: tl.date, from: start)))
        }
    }

    /// Peaks at 0.7 by 0.4 s, gone by 1.4 s.
    static func fadeOpacity(at t: Double) -> Double {
        let peak = 0.7, rise = 0.4, total = 1.4
        if t <= 0 || t >= total { return 0 }
        return t < rise ? peak * t / rise : peak * (1 - (t - rise) / (total - rise))
    }
}

/// A soft swell for a gassy, not splashy, effect. iPhone only; the Mac has no Taptic Engine.
enum WashHaptics {
    #if os(iOS)
    private static var engine: CHHapticEngine?
    private static let fallback = SuccessHaptic()

    @MainActor
    static func play() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            fallback.success()
            return
        }
        do {
            let engine = try readyEngine()
            let player = try engine.makePlayer(with: try pattern())
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback.success()
        }
    }

    @MainActor
    private static func readyEngine() throws -> CHHapticEngine {
        if let engine { return engine }
        let engine = try CHHapticEngine()
        engine.isAutoShutdownEnabled = true
        // Rebuild on the next play after the system stops or resets the engine.
        engine.resetHandler = { Task { @MainActor in WashHaptics.engine = nil } }
        engine.stoppedHandler = { _ in Task { @MainActor in WashHaptics.engine = nil } }
        self.engine = engine
        return engine
    }

    private static func pattern() throws -> CHHapticPattern {
        func continuous(at time: TimeInterval, for length: TimeInterval, sharpness: Float) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticContinuous,
                          parameters: [.init(parameterID: .hapticIntensity, value: 1),
                                       .init(parameterID: .hapticSharpness, value: sharpness)],
                          relativeTime: time, duration: length)
        }
        let swell = continuous(at: 0, for: 1.0, sharpness: 0.1)
        let tick = CHHapticEvent(eventType: .hapticTransient,
                                 parameters: [.init(parameterID: .hapticIntensity, value: 0.6),
                                              .init(parameterID: .hapticSharpness, value: 0.35)],
                                 relativeTime: 0.05)
        let tail = continuous(at: 1.3, for: 0.9, sharpness: 0.05)
        // The intensity curves scale each continuous event's base intensity of 1.
        let swellCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [.init(relativeTime: 0, value: 0.2), .init(relativeTime: 0.5, value: 0.9),
                            .init(relativeTime: 1.0, value: 0.5)],
            relativeTime: 0)
        let tailCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [.init(relativeTime: 0, value: 0.6), .init(relativeTime: 0.9, value: 0)],
            relativeTime: 1.3)
        return try CHHapticPattern(events: [swell, tick, tail], parameterCurves: [swellCurve, tailCurve])
    }
    #else
    @MainActor
    static func play() {}
    #endif
}
