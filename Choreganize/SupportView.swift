import SwiftUI

struct SupportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var onboarding: OnboardingCoordinator

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "heart.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.pink)
                        Text("Support Choreganize")
                            .font(.title3.bold())
                        Text("Thanks for using the app! We’ll add ways to support development soon. In the meantime, your feedback is invaluable.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("Learn the app") {
                    Button {
                        onboarding.requestReplay(OnboardingStep.all)
                        dismiss()
                    } label: {
                        Label("Take the tour", systemImage: "play.circle")
                    }
                    ForEach(OnboardingStep.all) { step in
                        Button {
                            onboarding.requestReplay([step])
                            dismiss()
                        } label: {
                            Label(step.title, systemImage: step.systemImage)
                        }
                    }
                }

                Section {
                    Button {
                        // TODO: Integrate StoreKit 2 tips or Pro unlock
                    } label: {
                        Label("Coming Soon", systemImage: "sparkles")
                    }
                    .disabled(true)
                }
            }
            .navigationTitle("Support")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    SupportView()
        .environmentObject(OnboardingCoordinator())
}
#endif
