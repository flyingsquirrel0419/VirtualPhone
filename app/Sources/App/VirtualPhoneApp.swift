import SwiftUI
import UIKit

@main
struct VirtualPhoneApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { phase in
            // A JIT enabler attaches while the app is in the background.
            if phase == .active { model.refreshJIT() }
            if phase == .background { AppLogger.shared.flush() }
        }
    }
}
