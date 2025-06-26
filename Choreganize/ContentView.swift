import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case work = "Work"
    case edit = "Edit"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var mode: AppMode = .work

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Mode", selection: $mode) {
                    ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                if mode == .work {
                    WorkHomeView()
                        .environmentObject(model)
                } else {
                    EditHomeView()
                        .environmentObject(model)
                }
            }
            .navigationTitle("Choreganize")
        }
    }
}

#Preview {
    ContentView()
}
