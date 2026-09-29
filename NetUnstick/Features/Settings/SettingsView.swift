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
                if store.helper == .available {
                    Label(store.helperHandshake.text, systemImage: store.helperHandshake.symbol)
                        .accessibilityIdentifier("settings.helperHandshake")
                    Text("Sprawdzenie jest wyłącznie odczytowe. Po aktualizacji aplikacja sama odświeża rejestrację, gdy helper nie odpowiada; wcześniejsza zgoda w Elementach logowania zostaje zachowana.")
                        .foregroundStyle(.secondary)
                    Button("Sprawdź helper") { store.verifyHelper() }.accessibilityIdentifier("helper.verify")
                }
                if store.helper != .unavailable {
                    Button("Wyrejestruj helper") { store.unregisterHelper() }.accessibilityIdentifier("helper.unregister")
                }
            }
            Section("privacy") { Text("privacy_detail") }
        }.formStyle(.grouped).navigationTitle("settings")
    }

}
