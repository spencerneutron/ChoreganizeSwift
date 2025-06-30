import SwiftUI

@main
struct ChoreganizeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model: AppModel

    init() {
#if DEBUG
        SharedCloudKitController.configure(container: MockCloudContainer())
#endif
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        }
    }
}
