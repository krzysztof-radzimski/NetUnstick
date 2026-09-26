import SwiftUI

struct ContentView: View {
    @State private var helper = PrivilegedHelperClient()
    @State private var helperStatus: HelperRegistrationStatus = .notRegistered

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("NetUnstick").font(.largeTitle.bold())
            Text("Diagnostyka nie jest jeszcze podłączona do okna. Naprawy sieci nie są jeszcze dostępne.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            DisclosureGroup("Opcjonalny helper napraw") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(helperStatus.guidance)
                    if let error = helper.lastRegistrationError { Text(error).foregroundStyle(.secondary) }
                    if helperStatus == .notRegistered {
                        Button("Zarejestruj helper") { helperStatus = helper.registerForSelectedRepair() }
                    }
                    if helperStatus == .requiresApproval {
                        Button("Otwórz Elementy logowania") { helper.openLoginItems() }
                    }
                    Button("Odśwież status") { helperStatus = helper.status }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(32)
        .frame(minWidth: 460, minHeight: 280)
        .onAppear { helperStatus = helper.status }
    }
}
