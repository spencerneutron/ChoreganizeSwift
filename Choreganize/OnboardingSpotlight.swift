import SwiftUI

// MARK: - Anchor publishing

/// Collects the on-screen frames of controls that onboarding can spotlight.
struct SpotlightAnchorsKey: PreferenceKey {
    static var defaultValue: [OnboardingStep.Spotlight: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [OnboardingStep.Spotlight: Anchor<CGRect>],
                       nextValue: () -> [OnboardingStep.Spotlight: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as the target for a spotlight onboarding step.
    func onboardingAnchor(_ target: OnboardingStep.Spotlight) -> some View {
        anchorPreference(key: SpotlightAnchorsKey.self, value: .bounds) { [target: $0] }
    }
}

// MARK: - Overlay

/// Presents spotlight onboarding steps full-screen: dims the screen with a cutout
/// around the target control (when its anchor resolves) and floats a callout.
/// Falls back to a centered callout when the anchor can't be located.
struct OnboardingSpotlightOverlay: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let anchors: [OnboardingStep.Spotlight: Anchor<CGRect>]

    var body: some View {
        if let step = coordinator.current, step.spotlight != nil {
            GeometryReader { proxy in
                let rect = resolvedRect(for: step, in: proxy)
                ZStack {
                    SpotlightDim(size: proxy.size, cutout: rect)
                    callout(step: step, rect: rect, size: proxy.size)
                }
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    private func resolvedRect(for step: OnboardingStep, in proxy: GeometryProxy) -> CGRect? {
        guard let target = step.spotlight, let anchor = anchors[target] else { return nil }
        let rect = proxy[anchor]
        // Ignore anchors that resolve off-screen or degenerate (e.g. an inactive
        // tab page), so the step degrades to a centered callout instead.
        let bounds = CGRect(origin: .zero, size: proxy.size)
        guard rect.width > 1, rect.height > 1, bounds.intersects(rect) else { return nil }
        return rect
    }

    @ViewBuilder
    private func callout(step: OnboardingStep, rect: CGRect?, size: CGSize) -> some View {
        let card = OnboardingCalloutCard(
            step: step,
            hasNext: coordinator.hasNext,
            onNext: { withAnimation { coordinator.advance() } },
            onSkip: { withAnimation { coordinator.finish() } }
        )
        .frame(maxWidth: 360)
        .padding(.horizontal, 20)

        if let rect {
            let placeBelow = rect.midY < size.height / 2
            let y = placeBelow
                ? min(rect.maxY + 120, size.height - 120)
                : max(rect.minY - 120, 120)
            card.position(x: size.width / 2, y: y)
        } else {
            card.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Full-screen dim with an optional rounded-rect hole punched out (even-odd fill).
struct SpotlightDim: View {
    let size: CGSize
    let cutout: CGRect?

    var body: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            if let cutout {
                path.addRoundedRect(in: cutout.insetBy(dx: -10, dy: -10),
                                    cornerSize: CGSize(width: 16, height: 16))
            }
        }
        .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
        .contentShape(Rectangle())   // capture taps over the whole overlay
    }
}

/// Compact callout card used by a spotlight step.
struct OnboardingCalloutCard: View {
    let step: OnboardingStep
    let hasNext: Bool
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Label(step.title, systemImage: step.systemImage)
                .font(.headline)
            Text(step.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                if hasNext {
                    Button("Skip", action: onSkip).font(.subheadline)
                }
                Spacer()
                Button(hasNext ? "Next" : "Done", action: onNext)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 12)
    }
}
