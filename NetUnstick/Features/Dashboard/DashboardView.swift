import SwiftUI
import NetUnstickCore
import NetUnstickNetwork

struct DashboardView: View {
    @ObservedObject var store: PresentationStore
    @State private var expandedCheckIDs: Set<String> = []
    let highContrast: Bool
    let confirmingRepair: Bool
    let showRepair: () -> Void
    let dismissRepair: () -> Void
    let showReport: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("status").font(.largeTitle.bold())
                if store.disconnectBanner {
                    Label("VPN został rozłączony. Uruchom diagnostykę, aby sprawdzić sieć.", systemImage: "info.circle")
                        .accessibilityIdentifier("dashboard.disconnect")
                }
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
                if !store.repairPhase.isEmpty { Text(store.repairPhase).accessibilityIdentifier("repair.phase") }
                VStack(alignment: .leading, spacing: 8) {
                    Text("last_result").font(.headline)
                    Text(store.lastResultText).accessibilityIdentifier("dashboard.result")
                    Text(store.nextStep).foregroundStyle(.secondary).accessibilityIdentifier("dashboard.nextStep")
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(highContrast ? Color.primary : Color.clear, lineWidth: 2))
                if confirmingRepair, store.candidate != nil {
                    RepairConfirmationView(store: store, dismiss: dismissRepair)
                }
                ForEach(Array(store.candidates.enumerated()), id: \.offset) { index, candidate in
                    if store.vpn.state == .inactive || candidate.allowsWhenResidualRoute {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("repair_candidate", systemImage: "wrench.adjustable").font(.headline)
                        Text("\(candidate.change): \(candidate.reason)")
                        Button("review_candidate") { store.selectCandidate(index); showRepair() }
                            .accessibilityIdentifier(index == 0 ? "repair.open" : "repair.open.\(index)")
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(highContrast ? Color.primary : Color.clear, lineWidth: 2))
                    }
                }
                Button("preview_report") { showReport() }
                    .disabled(store.sessions.isEmpty).accessibilityIdentifier("report.preview.open")
                VStack(alignment: .leading, spacing: 10) {
                    Label("device_test", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                    Text("device_test_hint").foregroundStyle(.secondary)
                    HStack {
                        TextField("device_host", text: $store.deviceHost)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                            .accessibilityIdentifier("device.host")
                            .onSubmit { store.testDeviceConnection() }
                        Picker("device_port", selection: $store.devicePort) {
                            Text("SMB · 445").tag("445")
                            Text("AFP · 548").tag("548")
                            Text("Udostępnianie ekranu · 5900").tag("5900")
                            Text("SSH · 22").tag("22")
                            Text("HTTP · 80").tag("80")
                        }.labelsHidden().frame(maxWidth: 220).accessibilityIdentifier("device.port")
                        Button("device_test_run") { store.testDeviceConnection() }
                            .disabled(store.deviceTestRunning).accessibilityIdentifier("device.test")
                        if store.deviceTestRunning { ProgressView().controlSize(.small) }
                    }
                    if let connection = store.deviceConnection {
                        HStack { Image(systemName: connection.symbol).accessibilityHidden(true); Text(connection.outcome).bold() }
                            .accessibilityIdentifier("device.outcome")
                        Text(connection.reason).foregroundStyle(.secondary).accessibilityIdentifier("device.result")
                        Text(connection.technicalDetail).font(.caption.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("device.detail")
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(highContrast ? Color.primary : Color.clear, lineWidth: 2))
                Text("checks").font(.headline)
                if store.checks.isEmpty { ContentUnavailableView("no_checks", systemImage: "list.bullet.clipboard") }
                ForEach(store.checks) { check in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            expandedCheckIDs = expandedCheckIDs.symmetricDifference([check.id])
                        } label: {
                            HStack {
                                Image(systemName: expandedCheckIDs.contains(check.id) ? "chevron.down" : "chevron.right")
                                    .accessibilityHidden(true)
                                Image(systemName: check.symbol).accessibilityHidden(true)
                                Text(check.title)
                                Spacer()
                                Text(check.outcome).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("check.\(check.id)")
                        if let reason = check.reason {
                            Text(reason).foregroundStyle(.secondary).accessibilityIdentifier("check.\(check.id).reason")
                        }
                        if expandedCheckIDs.contains(check.id) {
                            Text(check.technicalDetail).font(.caption.monospaced()).textSelection(.enabled)
                                .padding(.leading, 24)
                                .accessibilityIdentifier("check.\(check.id).detail")
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 800, alignment: .leading)
        }.navigationTitle("status")
    }

}
