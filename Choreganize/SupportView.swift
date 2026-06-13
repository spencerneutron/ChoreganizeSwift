import SwiftUI

struct StoreKitPlaceholderView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cart")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundColor(.accentColor)
            
            Text("Store Coming Soon")
                .font(.title)
                .fontWeight(.semibold)
            
            Text("This area will soon feature in-app purchases and subscriptions.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            // Placeholder for future buttons
            HStack(spacing: 20) {
                Button(action: {}) {
                    Text("Buy Now")
                        .fontWeight(.medium)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(8)
                }
                .disabled(true)
                
                Button(action: {}) {
                    Text("Subscribe")
                        .fontWeight(.medium)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(8)
                }
                .disabled(true)
            }
            .padding(.horizontal)
        }
        .padding()
    }
}

#Preview {
    StoreKitPlaceholderView()
}
