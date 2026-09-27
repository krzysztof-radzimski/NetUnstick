import SwiftUI
import NetUnstickCore

struct SettingsView: View {
    @ObservedObject var store: PresentationStore
    var body: some View {
        Form {
            Section("helper") {
                Label(store.helper.title, systemImage: store.helper.symbol).accessibilityIdentifier("settings.helper")
                Text("helper_note").foregroundStyle(.secondary)
                if store.helper != .available {
                    Text("Helper może odświeżyć cache DNS lub odnowić DHCP tylko po jawnym potwierdzeniu naprawy. Diagnostyka działa bez helpera.")
                    Button("Zarejestruj helper") { store.registerHelper() }.accessibilityIdentifier("helper.register")
                    Button("Otwórz Elementy logowania") { store.openHelperSettings() }.accessibilityIdentifier("helper.settings")
                }
            }
            Section("privacy") { Text("privacy_detail") }
        }.formStyle(.grouped).navigationTitle("settings")
    }

}
