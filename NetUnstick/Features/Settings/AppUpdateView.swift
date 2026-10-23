import SwiftUI
import NetUnstickCore

struct AppUpdateView: View {
    @EnvironmentObject private var updates: AppUpdateStore
    @ObservedObject var store: PresentationStore
    private var operationBusy: Bool {
        store.isRunning || store.deviceTestRunning || store.helperSetupRunning || store.historyClearRunning
    }

    var body: some View {
        Toggle(L10n.text("updates_startup"), isOn: $updates.checksAtStartup)
            .accessibilityIdentifier("updates.automatic")
        Text(L10n.text("updates_privacy")).font(.callout).foregroundStyle(.secondary)
        Group {
            switch updates.phase {
            case .idle: Text(L10n.text("updates_idle"))
            case .checking: ProgressView(L10n.text("updates_checking"))
            case .current: Label(L10n.text("updates_current"), systemImage: "checkmark.circle")
            case .available: Text(availableText)
            case .downloading:
                ProgressView(value: updates.progress) { Text(L10n.text("updates_downloading")) }
            case .verifying: ProgressView(L10n.text("updates_verifying"))
            case .ready: Label(L10n.text("updates_ready"), systemImage: "checkmark.shield")
            case .openingInstaller: ProgressView(L10n.text("updates_opening_installer"))
            case .installerOpened: Text(L10n.text("updates_installer_opened"))
            case .failed: Text(L10n.text("updates_failed"))
            case .rejected: Text(L10n.text("updates_rejected"))
            case .incompatible: Text(L10n.text("updates_incompatible"))
            }
        }
        .accessibilityIdentifier("updates.status")
        if updates.phase == .available {
            Button(L10n.text("updates_download")) { updates.download() }
                .accessibilityIdentifier("updates.download")
        }
        if updates.phase == .ready {
            Button(L10n.text("updates_install")) { updates.install { !operationBusy } }
                .disabled(operationBusy)
                .accessibilityIdentifier("updates.install")
            Text(L10n.text(operationBusy ? "updates_operation_busy" : "updates_install_hint"))
                .font(.callout).foregroundStyle(.secondary)
        }
        if updates.isBusy, updates.phase != .openingInstaller {
            Button(L10n.text("cancel"), role: .cancel) { updates.cancel() }
                .accessibilityIdentifier("updates.cancel")
        } else if updates.phase != .installerOpened {
            Button(L10n.text("updates_check")) { updates.checkForUpdates() }
                .accessibilityIdentifier("updates.check")
        }
    }

    private var availableText: String {
        L10n.format("updates_available %@", updates.release.map { "\($0.version) (\($0.build))" } ?? "")
    }
}
