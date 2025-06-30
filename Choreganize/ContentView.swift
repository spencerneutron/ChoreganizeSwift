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

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Mode", selection: $mode) {
                    ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                ZStack {
                    switch mode {
                    case .work:
                        WorkHomeView()
                    case .edit:
                        EditHomeView()
                    case .calendar:
                        CalendarHomeView()
                    }
                }
                .transition(.opacity)
            }
            .navigationTitle("Choreganize")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if model.sharingEnabled {
                        Button("Stop Sharing") { stopSharing() }
                    } else {
                        Button("Share\u{2026}") { share() }
                    }
                }
            }
            .animation(.easeInOut, value: mode)
        }
    }

    private func share() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        Task { await model.startSharing(from: root) }
    }

    private func stopSharing() {
        Task { await model.stopSharing() }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
