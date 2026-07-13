import AppKit
import SwiftUI

/// Turns free-running horizontal trackpad/wheel scrolls into discrete day flips
/// for the Work week (`WeekView`). `.scrollTargetBehavior(.paging)` only
/// constrains legacy line scrolls on macOS — momentum gestures settle between
/// pages — so the pager claims horizontal-dominant scroll events in its window
/// BEFORE the scroll view sees them and reports one flip per gesture (or per
/// threshold of wheel ticks). Vertical-dominant events pass through untouched
/// to the day list; events for other windows (Settings, the menu-bar extra)
/// are never touched.
final class MacHorizontalPager {
    /// The window whose events this pager owns (wired by `MacPagerHost`).
    weak var hostWindow: NSWindow?
    /// +1 = next day, −1 = previous. Set by the hosting view.
    var onFlip: ((Int) -> Void)?

    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var flippedThisGesture = false

    /// Finger travel (points) that commits a trackpad gesture to a flip.
    private static let gestureThreshold: CGFloat = 40
    /// Accumulated legacy-wheel delta per flip (wheels send no gesture phases).
    private static let wheelThreshold: CGFloat = 30

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns the event to pass through, or nil to consume it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow else { return event }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }

        if event.phase.contains(.began) {
            accumulated = 0
            flippedThisGesture = false
        }
        if event.phase == [] && event.momentumPhase == [] {
            // Legacy scroll wheel: discrete ticks, no phases — flip per threshold.
            accumulated += event.scrollingDeltaX
            if abs(accumulated) >= Self.wheelThreshold {
                onFlip?(accumulated < 0 ? 1 : -1)
                accumulated = 0
            }
        } else if event.momentumPhase == [] {
            // Live trackpad gesture: one flip once the travel commits. Momentum
            // events fall through to the consume below — the flip animation owns
            // the motion, so leftover momentum must never pan the scroll view.
            accumulated += event.scrollingDeltaX
            if !flippedThisGesture, abs(accumulated) >= Self.gestureThreshold {
                flippedThisGesture = true
                onFlip?(accumulated < 0 ? 1 : -1)
            }
        }
        return nil   // horizontal scrolls never reach the scroll view
    }
}

/// Zero-size view that wires the pager to the window hosting the Work week.
struct MacPagerHost: NSViewRepresentable {
    let pager: MacHorizontalPager

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            pager.hostWindow = view?.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            pager.hostWindow = window
        }
    }
}
