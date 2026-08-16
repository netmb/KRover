import SwiftUI
import UIKit

@main
struct KRoverApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { updateIdleTimer(for: scenePhase) }
                .onChange(of: scenePhase) { _, phase in updateIdleTimer(for: phase) }
        }
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = phase == .active
    }
}
