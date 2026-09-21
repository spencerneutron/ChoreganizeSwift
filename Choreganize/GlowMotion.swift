#if os(iOS)
import CoreMotion
#endif
import Foundation

/// One shared device-motion source for the calendar's perfect-day glow bars (#57 fast-follow).
///
/// The glow's specular sweep tracks device **roll**, the way Liquid Glass specular does — so the
/// highlight is alive in the hand and settles when the phone is set down (user-caused motion reads
/// as a reward, not a nag). Started/stopped by `CalendarHomeView` (never per-bar, so a single
/// `CMMotionManager` serves the whole grid), sampled at a gentle 30 Hz, and disabled under Low
/// Power Mode. A **no-op where device motion is unavailable** (e.g. the Simulator): `roll` stays 0
/// and the sweep falls back to purely time-driven.
///
/// **Deliberately NOT `ObservableObject`.** `roll` updates ~30×/sec; if the calendar observed it,
/// the whole grid would re-render 30 fps (recomputing every cell) — which tanked the Hub's scroll
/// when it was presented over the Calendar. Instead the bar's own per-frame `TimelineView` reads
/// `roll` at render time, so motion drives the shader without invalidating any SwiftUI view.
@MainActor
final class TiltProvider {
    /// Normalized device roll, clamped to a comfortable −1...1. Plain (unobserved) on purpose.
    private(set) var roll: Double = 0

    #if os(iOS)
    private let manager = CMMotionManager()
    private var running = false

    func start() {
        guard !running,
              manager.isDeviceMotionAvailable,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        running = true
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            self?.roll = max(-0.6, min(0.6, motion.attitude.roll)) / 0.6
        }
    }

    func stop() {
        guard running else { return }
        manager.stopDeviceMotionUpdates()
        running = false
        roll = 0
    }
    #else
    // Macs have no motion sensors: `roll` stays 0 and the glow's specular sweep
    // takes its documented time-driven fallback (same as the Simulator).
    func start() {}
    func stop() {}
    #endif
}
