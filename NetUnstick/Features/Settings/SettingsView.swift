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
                    Text("Helper może odnowić DHCP jednego potwierdzonego interfejsu albo usunąć zweryfikowane trasy pozostałe po VPN, które nakładają się na sieć lokalną. Każda zmiana wymaga osobnego potwierdzenia. Diagnostyka działa bez helpera.")
                    Button("Zarejestruj helper") { store.registerHelper() }.accessibilityIdentifier("helper.register")
                    Button("Otwórz Elementy logowania") { store.openHelperSettings() }.accessibilityIdentifier("helper.settings")
                }
                if store.helper != .unavailable {
                    Text("Po aktualizacji aplikacji wyrejestruj helper, aby launchd zakończył starą instancję; ponowna rejestracja może wymagać zgody.")
                        .foregroundStyle(.secondary)
                    Button("Wyrejestruj helper") { store.unregisterHelper() }.accessibilityIdentifier("helper.unregister")
                }
            }
            Section("privacy") { Text("privacy_detail") }
        }.formStyle(.grouped).navigationTitle("settings")
    }

}
