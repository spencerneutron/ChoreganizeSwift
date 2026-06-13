import SwiftUI

/// Single entry point for onboarding. Plays a sequence (the first-run tour) or a
/// lone step (a Help replay). `hasSeenOnboarding` gates *only* the automatic
/// first-run tour — replaying any step never depends on it, which is what makes
/// steps reusable outside the onboarding flow.
@MainActor
final class OnboardingCoordinator: ObservableObject {
    /// The step currently presented (nil = nothing showing).
    @Published var current: OnboardingStep?
    /// Steps queued to play once another sheet (e.g. Support) has dismissed.
    @Published private(set) var pending: [OnboardingStep] = []

    private var queue: [OnboardingStep] = []
    private let defaults: UserDefaults
    private let seenKey = "hasSeenOnboarding"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasSeenOnboarding: Bool { defaults.bool(forKey: seenKey) }
    var hasNext: Bool { !queue.isEmpty }

    /// Show the first-run tour, once.
    func startFirstRunIfNeeded() {
        guard !hasSeenOnboarding, current == nil else { return }
        play(OnboardingStep.all)
    }

    /// Play an ordered sequence (the tour, or any subset).
    func play(_ steps: [OnboardingStep]) {
        guard let first = steps.first else { return }
        queue = Array(steps.dropFirst())
        current = first
    }

    /// Replay a single step, independent of the tour or completion.
    func play(_ step: OnboardingStep) {
        queue = []
        current = step
    }

    /// Advance to the next step, or finish the sequence.
    func advance() {
        if queue.isEmpty {
            finish()
        } else {
            current = queue.removeFirst()
        }
    }

    /// Dismiss whatever's showing and mark the first-run tour as seen.
    func finish() {
        current = nil
        queue = []
        defaults.set(true, forKey: seenKey)
    }

    /// Queue steps to play after the currently-open sheet dismisses (used so a
    /// Help replay doesn't try to stack a sheet on top of Support).
    func requestReplay(_ steps: [OnboardingStep]) { pending = steps }

    func playPendingIfNeeded() {
        guard !pending.isEmpty else { return }
        let steps = pending
        pending = []
        play(steps)
    }
}
