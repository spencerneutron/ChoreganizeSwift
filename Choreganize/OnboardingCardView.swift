import SwiftUI

/// Card presentation for an onboarding step (used for concept steps, and as the
/// fallback for spotlight steps until chunk 2 wires up coachmarks).
struct OnboardingCardView: View {
    let step: OnboardingStep
    let hasNext: Bool
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // The step's text is never cut short. Where the sheet is too short for all of it
            // (the medium detent on the open iPhone Duo in landscape, or large text), the
            // decorative symbol goes first, and then the text scrolls.
            ViewThatFits(in: .vertical) {
                stepText(showsSymbol: true)
                stepText(showsSymbol: false)
                ScrollView { stepText(showsSymbol: false) }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: .infinity)
            VStack(spacing: 10) {
                Button(action: onNext) {
                    Text(hasNext ? "Next" : "Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if hasNext {
                    Button("Skip", action: onSkip)
                        .font(.subheadline)
                }
            }
        }
        .padding(28)
        .presentationDetents([.medium, .large])
    }

    private func stepText(showsSymbol: Bool) -> some View {
        VStack(spacing: 20) {
            if showsSymbol {
                Image(systemName: step.systemImage)
                    .font(.system(size: 60))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            Text(step.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            step.message
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview {
    OnboardingCardView(step: .step(.welcome), hasNext: true, onNext: {}, onSkip: {})
}
#endif
