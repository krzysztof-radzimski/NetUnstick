import SwiftUI
import NetUnstickCore

struct SettingsView: View {
    @ObservedObject var store: PresentationStore
    var body: some View {
        Form {
            Section("helper") {
                Label(store.helper.title, systemImage: store.helper.symbol).accessibilityIdentifier("settings.helper")
                Text("helper_note").foregroundStyle(.secondary)
            }
            Section("privacy") { Text("privacy_detail") }
        }.formStyle(.grouped).navigationTitle("settings")
    }

}
