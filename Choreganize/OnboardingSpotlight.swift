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
/// A target in the system's own bars (the tab bar on iPad and iPhone Duo, the scope
/// menu in a toolbar) has no anchor, and UIKit offers no public way to find it, so
/// those steps don't dim (which would light up nothing, or only the status bar);
/// the callout sits beside where the system puts the control instead.
struct OnboardingSpotlightOverlay: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let anchors: [OnboardingStep.Spotlight: Anchor<CGRect>]

    var body: some View {
        if let step = coordinator.current, step.spotlight != nil {
            Group {
                #if os(iOS)
                VerticalBarReader { sideBar in overlay(for: step, sideBar: sideBar) }
                #else
                overlay(for: step, sideBar: false)
                #endif
            }
            .transition(.opacity)
        }
    }

    private func overlay(for step: OnboardingStep, sideBar: Bool) -> some View {
        // The outer reader keeps the safe area to report the insets (a side bar); the
        // inner one covers the whole screen for the dim.
        GeometryReader { outer in
            GeometryReader { proxy in
                let rect = resolvedRect(for: step, in: proxy, sideBar: sideBar)
                ZStack {
                    if rect != nil {
                        SpotlightDim(size: proxy.size, cutout: rect)
                    } else {
                        Color.clear.contentShape(Rectangle())   // still capture taps
                    }
                    callout(step: step, rect: rect, in: proxy, insets: outer.safeAreaInsets,
                            sideBar: sideBar)
                }
            }
            .ignoresSafeArea()
        }
    }

    private func resolvedRect(for step: OnboardingStep, in proxy: GeometryProxy, sideBar: Bool) -> CGRect? {
        guard let target = step.spotlight, let anchor = anchors[target] else { return nil }
        // A toolbar item in a vertical bar (iPhone Duo) reports a frame at the screen's
        // corner, not where the bar draws it.
        if sideBar && target == .scopeSwitch { return nil }
        let rect = proxy[anchor]
        // Ignore anchors that resolve off-screen or degenerate (e.g. an inactive
        // tab page), so the step degrades to a centered callout instead.
        let bounds = CGRect(origin: .zero, size: proxy.size)
        guard rect.width > 1, rect.height > 1, bounds.intersects(rect) else { return nil }
        return rect
    }

    @ViewBuilder
    private func callout(step: OnboardingStep, rect: CGRect?, in proxy: GeometryProxy,
                         insets: EdgeInsets, sideBar: Bool) -> some View {
        let size = proxy.size
        let column = calloutColumn(for: rect, in: proxy, insets: insets, sideBar: sideBar)
        let card = OnboardingCalloutCard(
            step: step,
            hasNext: coordinator.hasNext,
            onNext: { withAnimation { coordinator.advance() } },
            onSkip: { withAnimation { coordinator.finish() } }
        )
        .frame(maxWidth: max(0, min(360, column.upperBound - column.lowerBound - 40)))
        .accessibilityAddTraits(.isModal)

        if let rect {
            let placeBelow = rect.midY < size.height / 2
            let y = placeBelow
                ? min(rect.maxY + 120, size.height - 120)
                : max(rect.minY - 120, 120)
            card.position(x: (column.lowerBound + column.upperBound) / 2, y: y)
        } else {
            let safeHeight = max(0, size.height - insets.top - insets.bottom)
            let alignment = Self.unanchoredAlignment(for: step.spotlight)
            // The safe area here is the screen's, outside the tab view: a top bar's row (the
            // iPad tab bar, the scope menu) and a bottom tab bar (the iPhone Duo upright) sit
            // inside it, so the callout clears one more bar height. A side bar is in it.
            card.padding(.vertical, 16)
                .padding(.top, alignment == .top ? 52 : 0)
                .padding(.bottom, alignment == .bottom && !sideBar ? 60 : 0)
                .frame(width: column.upperBound - column.lowerBound, height: safeHeight,
                       alignment: alignment)
                .position(x: (column.lowerBound + column.upperBound) / 2,
                          y: insets.top + safeHeight / 2)
        }
    }

    /// Where the system puts a control that has no anchor: the mode tabs at the foot of
    /// the iPhone Duo's side bar or tab bar and at the top on iPad, the scope menu at
    /// the top. By idiom, unlike the shell's layout rules, because the size classes are
    /// the same for the iPad's top tab bar and the upright Duo's bottom one.
    private static func unanchoredAlignment(for target: OnboardingStep.Spotlight?) -> Alignment {
        switch target {
        case .modePicker:
            #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .pad ? .top : .bottom
            #else
            .center
            #endif
        case .scopeSwitch: .top
        case .doneButton, nil: .center
        }
    }

    /// The horizontal strip the callout is centred in. Where the device folds (iPhone
    /// Duo) it keeps to one page so it never lies across the fold: the target's page, or
    /// with no target the page by the side bar (the control is in it), else the right
    /// page, the one the outer display shows. It stays clear of a side bar or notch.
    /// Elsewhere it's the whole width, as before.
    private func calloutColumn(for rect: CGRect?, in proxy: GeometryProxy,
                               insets: EdgeInsets, sideBar: Bool) -> ClosedRange<CGFloat> {
        var minX = insets.leading
        var maxX = proxy.size.width - insets.trailing
        let split = SpreadSplit(in: proxy)
        if split.gap > 0 {
            let leadingPage = rect.map { $0.midX < split.leadingWidth }
                ?? (sideBar && insets.leading > insets.trailing)
            if leadingPage {
                maxX = min(maxX, split.leadingWidth)
            } else {
                minX = max(minX, split.leadingWidth + split.gap)
            }
        }
        return minX...max(minX, maxX)
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
            step.message
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
