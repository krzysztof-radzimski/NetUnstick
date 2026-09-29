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
            Text("repair_candidate").font(.title2.bold()).accessibilityIdentifier("repair.confirmation")
            if let item = store.candidate {
                LabeledContent("change", value: item.change)
                LabeledContent("why", value: item.reason)
                LabeledContent("resource", value: item.resource)
                LabeledContent("impact", value: item.impact)
                LabeledContent("permission", value: item.permission)
                LabeledContent("verification", value: item.verification)
            }
            Text(store.candidate?.allowsWhenResidualRoute == true ?
                 "Aplikacja ponownie potwierdzi rozłączenie usług VPN i dokładnie te trasy, usunie każdą z nich osobnym poleceniem, a następnie sprawdzi trasę lokalną." :
                 "Po potwierdzeniu aplikacja ponownie sprawdzi VPN i warunki, następnie wykona akcję i powtórzy check.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("cancel") { dismiss() }
                    .accessibilityIdentifier("repair.cancel")
                Button("Potwierdź i wykonaj") { store.confirmRepair(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("repair.confirm")
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, lineWidth: 2))
        .accessibilityElement(children: .contain)
    }

}
