import SwiftUI

struct SupportView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.pink)

                Text("Support Choreganize")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Thanks for using the app! We’ll add ways to support development soon. In the meantime, your feedback is invaluable.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Spacer()

                // Placeholder for future StoreKit integration
                Button {
                    // TODO: Integrate StoreKit 2 tips or Pro unlock
                } label: {
                    Label("Coming Soon", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("Support")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SupportView()
}
