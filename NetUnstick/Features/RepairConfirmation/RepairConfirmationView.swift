import SwiftUI
import NetUnstickCore

/// Rendered inside the main window rather than as a sheet: an attached sheet window is
/// invisible to some accessibility drivers, and an in-window panel keeps the candidate,
/// its consequences and the decision visible together.
struct RepairConfirmationView: View {
    @ObservedObject var store: PresentationStore
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.text("repair_candidate"), systemImage: "wrench.adjustable")
                .labelStyle(StatusLabelStyle(tone: .attention))
                .font(.title2.bold()).accessibilityIdentifier("repair.confirmation")
            if let item = store.candidate {
                LabeledContent(L10n.text("change"), value: item.change)
                LabeledContent(L10n.text("why"), value: item.reason)
                LabeledContent(L10n.text("resource"), value: item.resource)
                LabeledContent(L10n.text("impact"), value: item.impact)
                LabeledContent(L10n.text("permission"), value: item.permission)
                LabeledContent(L10n.text("verification"), value: item.verification)
                if item.requiresHelper {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(store.helper.title, systemImage: store.helper.symbol)
                            .accessibilityIdentifier("repair.helper.status")
                        Text(store.helperSetupGuidance).foregroundStyle(.secondary)
                            .accessibilityIdentifier("repair.helper.guidance")
                        if store.helperSetupRunning {
                            ProgressView(L10n.text("helper_checking")).controlSize(.small)
                                .accessibilityIdentifier("repair.helper.progress")
                        } else if store.helper == .available {
                            Button(L10n.text("helper_verify")) { store.verifyHelper() }
                                .disabled(store.isRunning)
                                .accessibilityIdentifier("repair.helper.verify")
                        }
                        if store.helper != .available {
                            if store.helper != .approvalRequired {
                                Button(L10n.text("helper_register")) { store.registerHelper() }
                                    .disabled(store.isRunning || store.helperSetupRunning)
                                    .accessibilityIdentifier("repair.helper.register")
                            }
                            Button(L10n.text("helper_open_settings")) { store.openHelperSettings() }
                                .accessibilityIdentifier("repair.helper.settings")
                        }
                    }
                }
            }
            Text(store.candidate?.allowsWhenResidualRoute == true ?
                 L10n.text("repair_confirm_routes") :
                 L10n.text("repair_confirm_generic"))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.text("cancel")) { dismiss() }
                    .accessibilityIdentifier("repair.cancel")
                Button(L10n.text("repair_confirm")) {
                    store.confirmRepair()
                    if store.isRunning { dismiss() }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canConfirmRepair)
                    .accessibilityIdentifier("repair.confirm")
            }
        }
        .statusPanel(tone: .attention, emphasized: true)
        .accessibilityElement(children: .contain)
    }

}
