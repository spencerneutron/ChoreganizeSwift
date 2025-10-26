import SwiftUI
import UIKit

enum AppMode: String, CaseIterable, Identifiable {
    case work = "Work"
    case edit = "Edit"
    case calendar = "Calendar"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var mode: AppMode = .work
    @State private var showingSupport: Bool = false
    @State private var showingError: Bool = false

    var body: some View {
        NavigationStack {
            // Environment banner
            if model.sharingEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.environmentName)
                            .font(.headline)
                        Text(model.environmentRole == .owner ? "You Own This" : (model.environmentRole == .subscriber ? "You Subscribe" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            VStack {
                switch mode {
                case .work:
                    WorkHomeView()
                case .edit:
                    EditHomeView()
                case .calendar:
                    CalendarHomeView()
                }
            }
            .toolbar(.visible, for: .automatic)
            .animation(.easeInOut, value: mode)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if model.sharingEnabled {
                        Button("Stop Sharing") { stopSharing() }
                    } else {
                        Button("Share") { share() }
                    }
                }
                ToolbarItem(placement: .principal) {
                    if model.sharingEnabled {
                        Text(model.environmentRole == .owner ? "Owner" : "Subscriber")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .status) {
                    if model.isSyncing {
                        ProgressView().controlSize(.small)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Support") { showingSupport = true }
                }
            }
            .alert("Error", isPresented: $showingError, actions: {
                Button("OK", role: .cancel) { model.lastError = nil }
            }, message: {
                Text(model.lastError ?? "Unknown error")
            })
            .onChange(of: model.lastError) { _, newValue in
                showingError = newValue != nil
            }
            .sheet(isPresented: $showingSupport) {
                SupportView()
            }
            .safeAreaInset(edge: .bottom) {
                ZStack {
                    // Match the system bar appearance
                    Rectangle()
                        .fill(.bar)
                        .ignoresSafeArea()
                        .frame(height: 60)

                    Picker("Mode", selection: $mode) {
                        ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }
            }
        }
    }

    private func share() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        Task {
            await model.startSharing(from: root)
            await model.refreshEnvironmentInfo()
        }
    }

    private func stopSharing() {
        Task {
            await model.stopSharing()
            await model.refreshEnvironmentInfo()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
