import SwiftUI
import NetUnstickCore
import NetUnstickNetwork
import NetUnstickRepair

@main
struct NetUnstickApp: App {
    var body: some Scene {
        WindowGroup("NetUnstick") {
            ContentView()
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--ui-light") ? .light : ProcessInfo.processInfo.arguments.contains("--ui-dark") ? .dark : nil)
        }
    }
}
