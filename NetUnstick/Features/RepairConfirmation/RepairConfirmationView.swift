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
            Text("mock_repair_notice").foregroundStyle(.secondary)
            HStack { Spacer(); Button("cancel") { dismiss() }.accessibilityIdentifier("repair.cancel"); Button("simulate_repair") { store.simulateRepair(); dismiss() }.buttonStyle(.borderedProminent).accessibilityIdentifier("repair.confirm") }
        }.padding(28).frame(width: 560)
    }

}
