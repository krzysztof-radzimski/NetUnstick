import SwiftUI
import NetUnstickCore

struct SettingsView: View {
    @ObservedObject var store: PresentationStore
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingErase = false
    @State private var eraseFailed = false

    var body: some View {
        Form {
            Section(L10n.text("settings_edition")) {
                Label(L10n.text(store.supportsRepairs ? "edition_full" : "edition_store"),
                      systemImage: store.supportsRepairs ? "wrench.adjustable" : "magnifyingglass")
                Text(L10n.text(store.supportsRepairs ? "edition_full_detail" : "edition_store_detail"))
                    .foregroundStyle(.secondary)
            }
            if store.supportsRepairs {
                Section(L10n.text("helper")) {
                    Label(store.helper.title, systemImage: store.helper.symbol)
                        .accessibilityIdentifier("settings.helper")
                    if store.helperSetupRunning {
                        ProgressView(L10n.text("helper_checking")).controlSize(.small)
                    }
                    if store.helper == .available {
                        Label(store.helperHandshake.text, systemImage: store.helperHandshake.symbol)
                            .accessibilityIdentifier("settings.helperHandshake")
                    }
                    DisclosureGroup(L10n.text("settings_helper_details")) {
                        Text(store.helperSetupGuidance).foregroundStyle(.secondary)
                        Button(L10n.text("help_repairs")) {
                            HelpNavigation.shared.show(.repairs, openWindow: openWindow)
                        }
                    }
                    if store.helper != .available {
                        Button(L10n.text("helper_register")) { store.registerHelper() }
                            .disabled(store.isRunning || store.helperSetupRunning)
                            .accessibilityIdentifier("helper.register")
                        Button(L10n.text("helper_open_settings")) { store.openHelperSettings() }
                            .accessibilityIdentifier("helper.settings")
                    } else {
                        Button(L10n.text("helper_verify")) { store.verifyHelper() }
                            .disabled(store.isRunning || store.helperSetupRunning)
                            .accessibilityIdentifier("helper.verify")
                    }
                    if store.helper != .unavailable {
                        Button(L10n.text("helper_unregister")) { store.unregisterHelper() }
                            .disabled(store.isRunning || store.helperSetupRunning)
                            .accessibilityIdentifier("helper.unregister")
                    }
                }
            }
            Section(L10n.text("privacy")) {
                Text(L10n.text("settings_privacy_summary")).foregroundStyle(.secondary)
                Button(L10n.text("help_privacy")) {
                    HelpNavigation.shared.show(.privacy, openWindow: openWindow)
                }.accessibilityIdentifier("privacy.open")
                Button(L10n.text("history_erase"), role: .destructive) { confirmingErase = true }
                    .disabled(store.isRunning || store.deviceTestRunning || store.historyClearRunning)
                    .accessibilityIdentifier("history.erase")
                if store.historyClearRunning {
                    ProgressView().controlSize(.small).accessibilityLabel(L10n.text("history_erase"))
                }
                if confirmingErase {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("history_erase_title")).font(.headline)
                        Text(L10n.text("history_erase_detail")).foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.text("cancel"), role: .cancel) { confirmingErase = false }
                                .accessibilityIdentifier("history.erase.cancel")
                            Button(L10n.text("history_erase"), role: .destructive) {
                                confirmingErase = false
                                Task {
                                    do { try await store.clearHistory() }
                                    catch { eraseFailed = true }
                                }
                            }
                            .disabled(store.isRunning || store.deviceTestRunning || store.historyClearRunning)
                            .accessibilityIdentifier("history.erase.confirm")
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("history.erase.confirmation")
                }
            }
            Section(L10n.text("help_title")) {
                Button(L10n.text("help_gettingStarted")) {
                    HelpNavigation.shared.show(.gettingStarted, openWindow: openWindow)
                }.accessibilityIdentifier("help.open")
                Button(L10n.text("help_safety")) {
                    HelpNavigation.shared.show(.safety, openWindow: openWindow)
                }
                Text(L10n.text("settings_language")).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.text("settings"))
        .alert(L10n.text("history_erase_failed"), isPresented: $eraseFailed) {
            Button(L10n.text("ok"), role: .cancel) { }
        } message: { Text(L10n.text("history_erase_failed_detail")) }
    }
}
