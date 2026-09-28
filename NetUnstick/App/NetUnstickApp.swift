import SwiftUI
import NetUnstickCore
import NetUnstickNetwork
import NetUnstickRepair

@main
struct NetUnstickApp: App {
    @Environment(\.dynamicTypeSize) private var systemTextSize
    var body: some Scene {
        WindowGroup("NetUnstick") {
            ContentView()
                .preferredColorScheme(CompositionRoot.testOption("--ui-light") ? .light : CompositionRoot.testOption("--ui-dark") ? .dark : nil)
                .environment(\.dynamicTypeSize, CompositionRoot.testOption("--ui-large-text") ? .accessibility2 : systemTextSize)
                .transaction { transaction in
                    if CompositionRoot.testOption("--ui-reduce-motion") { transaction.disablesAnimations = true }
                }
        }
    }
}
