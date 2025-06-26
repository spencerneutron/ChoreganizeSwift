import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case work = "Work"
    case edit = "Edit"
    case calendar = "Calendar"
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

                switch mode {
                case .work:
                    WorkHomeView()
                case .edit:
                    EditHomeView()
                case .calendar:
                    CalendarHomeView()
                }
            }
            .navigationTitle("Choreganize")
        }
        .environmentObject(model)
    }
}

#Preview {
    ContentView()
}
