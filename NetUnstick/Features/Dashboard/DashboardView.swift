import SwiftUI
import NetUnstickCore
import NetUnstickNetwork

struct DashboardView: View {
    @ObservedObject var store: PresentationStore
    @State private var expandedCheckIDs: Set<String> = []
    @State private var networkDetailsExpanded = false
    @State private var deviceTestExpanded = false
    let highContrast: Bool
    let confirmingRepair: Bool
    let showRepair: () -> Void
    let dismissRepair: () -> Void
    let showReport: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                if confirmingRepair, store.candidate != nil {
                    RepairConfirmationView(store: store, dismiss: dismissRepair)
                }
                repairCandidates
                networkDetails
                deviceTest
            }
            .padding(28)
            .frame(maxWidth: 800, alignment: .leading)
        }
        .navigationTitle(L10n.text("status"))
        .onChange(of: store.isRunning) { wasRunning, isRunning in
            guard wasRunning, !isRunning else { return }
            networkDetailsExpanded = needsAttention
            if needsAttention {
                expandedCheckIDs = Set(store.checks.filter { $0.reason != nil }.map(\.id))
            }
        }
        .onChange(of: store.deviceTestRunning) { _, isRunning in
            if isRunning { deviceTestExpanded = true }
        }
    }

    private var needsAttention: Bool {
        switch store.state {
        case .problem, .unknown, .serverNotReady: true
        case .healthy, .investigating, .residual, .residualRoutes: false
        }
    }

    private var hasResult: Bool {
        !store.isRunning && store.lastResultText != L10n.text("no_result")
    }

    private var changesPaused: Bool {
        store.vpn.state != .inactive && store.candidate?.allowsWhenResidualRoute != true
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: store.state.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(store.state.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dashboard.state")

            if store.disconnectBanner {
                Label(L10n.text("dashboard_vpn_disconnected"), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dashboard.disconnect")
            }
            if changesPaused {
                Label(L10n.text("dashboard_changes_paused"), systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dashboard.repairGate")
            }
            if hasResult, needsAttention {
                resultSummary
            }
            HStack(spacing: 12) {
                Button(L10n.text("run_diagnosis")) { store.startDiagnosis() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.isRunning || store.historyClearRunning)
                    .accessibilityIdentifier("diagnosis.start")
                    .accessibilityHint(L10n.text("diagnosis_hint"))
                if store.isRunning {
                    Button(L10n.text("cancel")) { store.cancel() }
                        .accessibilityIdentifier("diagnosis.cancel")
                }
            }
            if store.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: store.progress)
                        .accessibilityIdentifier("diagnosis.progress")
                    if store.repairPhase.isEmpty {
                        Text(L10n.text("diagnosis_running")).foregroundStyle(.secondary)
                            .accessibilityIdentifier("operation.active")
                    } else {
                        Text(store.repairPhase).foregroundStyle(.secondary)
                            .accessibilityIdentifier("repair.phase")
                    }
                }
            } else if !store.repairPhase.isEmpty {
                Text(store.repairPhase).foregroundStyle(.secondary)
                    .accessibilityIdentifier("repair.phase")
            }
        }
        .dashboardPanel(highContrast: highContrast)
    }

    private var resultSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.lastResultText).accessibilityIdentifier("dashboard.result")
            if !store.nextStep.isEmpty {
                Text(store.nextStep).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dashboard.nextStep")
            }
        }
    }

    private var repairCandidates: some View {
        ForEach(Array(store.candidates.enumerated()), id: \.offset) { index, candidate in
            if store.vpn.state == .inactive || candidate.allowsWhenResidualRoute {
                HStack(alignment: .top, spacing: 12) {
                    Label(candidate.change, systemImage: "wrench.adjustable")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L10n.text("review_candidate")) {
                        store.selectCandidate(index)
                        showRepair()
                    }
                    .disabled(store.isRunning)
                    .accessibilityIdentifier(index == 0 ? "repair.open" : "repair.open.\(index)")
                }
                .dashboardPanel(highContrast: highContrast)
            }
        }
    }

    private var networkDetails: some View {
        DisclosureGroup(isExpanded: $networkDetailsExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                Text(store.state.explanation).foregroundStyle(.secondary)
                Label(store.vpnStatus, systemImage: "network.badge.shield.half.filled")
                    .accessibilityIdentifier("dashboard.vpn")
                if hasResult, !needsAttention {
                    resultSummary
                }
                if !store.checks.isEmpty {
                    Text(L10n.text("checks")).font(.headline)
                    ForEach(store.checks) { check in
                        checkRow(check)
                    }
                } else {
                    Text(L10n.text("no_checks")).foregroundStyle(.secondary)
                }
                Button(L10n.text("preview_report")) { showReport() }
                    .disabled(store.sessions.isEmpty)
                    .accessibilityIdentifier("report.preview.open")
            }
            .padding(.top, 12)
        } label: {
            HStack {
                Label(L10n.text("dashboard_network_details"), systemImage: "list.bullet.clipboard")
                Spacer()
                if !store.checks.isEmpty {
                    Text(store.checks.count.formatted())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(L10n.format("dashboard_check_count %lld", store.checks.count)))
                }
            }
        }
        .accessibilityIdentifier("dashboard.details")
        .dashboardPanel(highContrast: highContrast)
    }

    private func checkRow(_ check: CheckPresentation) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedCheckIDs.contains(check.id) },
            set: { expanded in
                if expanded { expandedCheckIDs.insert(check.id) }
                else { expandedCheckIDs.remove(check.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 8) {
                if let reason = check.reason {
                    Text(reason).foregroundStyle(.secondary)
                        .accessibilityIdentifier("check.\(check.id).reason")
                }
                Text(check.technicalDetail).font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("check.\(check.id).detail")
            }
            .padding(.vertical, 6)
        } label: {
            HStack {
                Image(systemName: check.symbol).accessibilityHidden(true)
                Text(check.title)
                Spacer(minLength: 8)
                Text(check.outcome).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("check.\(check.id)")
    }

    private var deviceTest: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(isExpanded: $deviceTestExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("device_test_hint")).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            deviceHostField
                            devicePortPicker
                            deviceTestButton
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            deviceHostField
                            HStack { devicePortPicker; deviceTestButton }
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                Label(L10n.text("device_test"), systemImage: "point.3.connected.trianglepath.dotted")
            }
            .accessibilityIdentifier("device.section")
            // Keep the last result visible even if the input section is collapsed.
            if let connection = store.deviceConnection {
                VStack(alignment: .leading, spacing: 8) {
                    Label(connection.outcome, systemImage: connection.symbol).bold()
                        .accessibilityIdentifier("device.outcome")
                    Text(connection.reason).foregroundStyle(.secondary)
                        .accessibilityIdentifier("device.result")
                    DisclosureGroup(L10n.text("dashboard_technical_details")) {
                        Text(connection.technicalDetail).font(.caption.monospaced()).textSelection(.enabled)
                            .padding(.top, 6)
                            .accessibilityIdentifier("device.detail")
                    }
                }
            }
        }
        .dashboardPanel(highContrast: highContrast)
    }

    private var deviceHostField: some View {
        TextField(L10n.text("device_host"), text: $store.deviceHost)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 120, idealWidth: 280)
            .accessibilityIdentifier("device.host")
            .onSubmit { store.testDeviceConnection() }
    }

    private var devicePortPicker: some View {
        Picker(L10n.text("device_port"), selection: $store.devicePort) {
            Text("SMB · 445").tag("445")
            Text("AFP · 548").tag("548")
            Text(L10n.text("device_screen_sharing_port")).tag("5900")
            Text("SSH · 22").tag("22")
            Text("HTTP · 80").tag("80")
        }
        .labelsHidden()
        .frame(width: 190)
        .accessibilityIdentifier("device.port")
    }

    private var deviceTestButton: some View {
        HStack {
            Button(L10n.text("device_test_run")) { store.testDeviceConnection() }
                .disabled(store.deviceTestRunning || store.historyClearRunning)
                .accessibilityIdentifier("device.test")
            if store.deviceTestRunning { ProgressView().controlSize(.small) }
        }
    }
}

private extension View {
    func dashboardPanel(highContrast: Bool) -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(highContrast ? Color.primary : Color.clear, lineWidth: 2))
    }
}
