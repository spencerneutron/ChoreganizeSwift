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
            Spacer()
            Image(systemName: step.systemImage)
                .font(.system(size: 60))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(step.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(step.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
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
}

#if DEBUG
#Preview {
    OnboardingCardView(step: .step(.welcome), hasNext: true, onNext: {}, onSkip: {})
}
#endif
