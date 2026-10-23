import SwiftUI
import NetUnstickCore
import NetUnstickNetwork

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
        .commands { NetUnstickHelpCommands() }
        Window(L10n.text("help_title"), id: "help") {
            HelpView()
        }.defaultSize(width: 820, height: 600)
    }
}
