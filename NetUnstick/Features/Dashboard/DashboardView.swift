import SwiftUI
import NetUnstickCore

struct DashboardView: View {
    @ObservedObject var store: PresentationStore
    let highContrast: Bool
    let showRepair: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("status").font(.largeTitle.bold())
                Text("demo_notice").foregroundStyle(.secondary)
                Label(store.vpnStatus, systemImage: "network.badge.shield.half.filled")
                    .accessibilityIdentifier("dashboard.vpn")
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: store.state.symbol).font(.title).foregroundStyle(.tint).accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(store.state.title).font(.title2.bold())
                        Text(store.state.explanation).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(highContrast ? Color.primary : Color.clear, lineWidth: 2))
                    .accessibilityElement(children: .combine).accessibilityIdentifier("dashboard.state")
                HStack {
                    Button("run_diagnosis") { store.startDiagnosis() }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.isRunning)
                        .accessibilityIdentifier("diagnosis.start").accessibilityHint("diagnosis_hint")
                    if store.isRunning {
                        ProgressView(value: store.progress).frame(width: 130).accessibilityIdentifier("diagnosis.progress")
                        Button("cancel") { store.cancel() }.accessibilityIdentifier("diagnosis.cancel")
                    }
                }
                if store.isRunning { Text("diagnosis_running").accessibilityIdentifier("operation.active") }
                VStack(alignment: .leading, spacing: 8) {
                    Text("last_result").font(.headline)
                    Text(store.lastResultText).accessibilityIdentifier("dashboard.result")
                    Text(store.nextStep).foregroundStyle(.secondary).accessibilityIdentifier("dashboard.nextStep")
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(highContrast ? Color.primary : Color.clear, lineWidth: 2))
                if let candidate = store.candidate {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("repair_candidate", systemImage: "wrench.adjustable").font(.headline)
                        Text(candidate.reason)
                        Button("review_candidate") { showRepair() }.accessibilityIdentifier("repair.open")
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(highContrast ? Color.primary : Color.clear, lineWidth: 2))
                }
                Text("checks").font(.headline)
                if store.checks.isEmpty { ContentUnavailableView("no_checks", systemImage: "list.bullet.clipboard") }
                ForEach(store.checks) { check in
                    DisclosureGroup {
                        Text(check.technicalDetail).font(.caption.monospaced()).textSelection(.enabled)
                    } label: {
                        HStack { Image(systemName: check.symbol); Text(check.title); Spacer(); Text(check.outcome).foregroundStyle(.secondary) }
                    }.accessibilityIdentifier("check.\(check.id)")
                }
            }.padding(28).frame(maxWidth: 800, alignment: .leading)
        }.navigationTitle("status")
    }

}
