import SwiftUI
import NetUnstickCore

struct SettingsView: View {
    @ObservedObject var store: PresentationStore
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingErase = false
    @State private var eraseFailed = false

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.text("settings_version")) {
                    Text(appVersion)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.version")
                }
            } header: {
                Label("NetUnstick", systemImage: "point.3.connected.trianglepath.dotted")
                    .labelStyle(StatusLabelStyle())
            }
            Section {
                Label(store.helper.title, systemImage: store.helper.symbol)
                    .labelStyle(StatusLabelStyle(tone: store.helper == .available ? handshakeTone : .attention))
                    .accessibilityIdentifier("settings.helper")
                if store.helperSetupRunning {
                    ProgressView(L10n.text("helper_checking")).controlSize(.small)
                }
                if store.helper == .available {
                    Label(store.helperHandshake.text, systemImage: store.helperHandshake.symbol)
                        .labelStyle(StatusLabelStyle(tone: handshakeTone))
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
            } header: {
                Label(L10n.text("helper"), systemImage: "wrench.and.screwdriver")
                    .labelStyle(StatusLabelStyle(tone: .accent))
            }
            Section {
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
            } header: {
                Label(L10n.text("privacy"), systemImage: "hand.raised")
                    .labelStyle(StatusLabelStyle())
            }
            Section {
                Button(L10n.text("help_gettingStarted")) {
                    HelpNavigation.shared.show(.gettingStarted, openWindow: openWindow)
                }.accessibilityIdentifier("help.open")
                Button(L10n.text("help_safety")) {
                    HelpNavigation.shared.show(.safety, openWindow: openWindow)
                }
                Text(L10n.text("settings_language")).foregroundStyle(.secondary)
            } header: {
                Label(L10n.text("help_title"), systemImage: "questionmark.circle")
                    .labelStyle(StatusLabelStyle(tone: .accent))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.text("settings"))
        .alert(L10n.text("history_erase_failed"), isPresented: $eraseFailed) {
            Button(L10n.text("ok"), role: .cancel) { }
        } message: { Text(L10n.text("history_erase_failed_detail")) }
    }

    private var handshakeTone: StatusTone {
        switch store.helperHandshake {
        case .notRun: .neutral
        case .responding: .success
        case .failed: .failure
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}
