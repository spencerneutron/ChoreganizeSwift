import SwiftUI

@main
struct ChoreganizeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background, .inactive:
                        model.flushPendingSavesNow()
                    default:
                        break
                    }
                }
        }
    }
}
