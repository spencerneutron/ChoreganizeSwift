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
    @State private var showingLogs: Bool = false

    var body: some View {
        NavigationStack {
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
                // Solo vs Household scope switch. (CloudKit sharing of the
                // Household returns in Phase 3.)
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Scope", selection: Binding(
                            get: { model.scope },
                            set: { model.setScope($0) }
                        )) {
                            ForEach(AppScope.allCases) { scope in
                                Label(scope.title, systemImage: scope.systemImage).tag(scope)
                            }
                        }
                    } label: {
                        Label(model.scope.title, systemImage: model.scope.systemImage)
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
            .sheet(isPresented: $showingLogs) {
                LogViewerView()
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
                .contentShape(Rectangle())
                .simultaneousGesture(LongPressGesture().onEnded { _ in
                    showingLogs = true
                })
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
        .environment(\.managedObjectContext, PreviewStack.context)
}
