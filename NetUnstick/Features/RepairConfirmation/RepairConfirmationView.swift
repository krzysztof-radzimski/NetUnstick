import SwiftUI
import NetUnstickCore

struct RepairConfirmationView: View {
    @ObservedObject var store: PresentationStore
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("repair_candidate").font(.title.bold()).accessibilityIdentifier("repair.confirmation")
            if let item = store.candidate {
                LabeledContent("change", value: item.change)
                LabeledContent("why", value: item.reason)
                LabeledContent("resource", value: item.resource)
                LabeledContent("impact", value: item.impact)
                LabeledContent("permission", value: item.permission)
                LabeledContent("verification", value: item.verification)
            }
            Text(store.candidate?.allowsWhenResidualRoute == true ?
                 "Aplikacja ponownie potwierdzi rozłączenie usług VPN i tę jedną trasę, usunie ją, a następnie sprawdzi trasę lokalną." :
                 "Po potwierdzeniu aplikacja ponownie sprawdzi VPN i warunki, następnie wykona akcję i powtórzy check.")
                .foregroundStyle(.secondary)
            HStack { Spacer(); Button("cancel") { dismiss() }.accessibilityIdentifier("repair.cancel"); Button("Potwierdź i wykonaj") { store.confirmRepair(); dismiss() }.buttonStyle(.borderedProminent).accessibilityIdentifier("repair.confirm") }
        }.padding(28).frame(width: 560)
    }

}
