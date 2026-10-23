import SwiftUI
import NetUnstickCore
import NetUnstickNetwork

struct DashboardView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject var store: PresentationStore
    @State private var expandedCheckIDs: Set<String> = []
    @State private var networkDetailsExpanded = false
    @State private var deviceTestExpanded = false
    @State private var completion = 0
    @State private var observedDiagnosis = false
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
        .onChange(of: store.state, initial: true) { _, state in
            if store.isRunning, state == .investigating { observedDiagnosis = true }
        }
        .onChange(of: store.isRunning) { wasRunning, isRunning in
            if isRunning {
                observedDiagnosis = store.state == .investigating
                return
            }
            guard wasRunning, !isRunning else { return }
            networkDetailsExpanded = needsAttention
            if needsAttention {
                expandedCheckIDs = Set(store.checks.filter { $0.reason != nil }.map(\.id))
            }
            // A failed repair can retain the earlier network verdict. Only celebrate a
            // diagnosis observed in this view, never that stale verdict after a repair.
            if observedDiagnosis, !reduceMotion, store.state == .healthy, store.progress == 1 {
                completion += 1
            }
            observedDiagnosis = false
        }
        .onChange(of: store.deviceTestRunning) { _, isRunning in
            if isRunning { deviceTestExpanded = true }
        }
    }

    private var reduceMotion: Bool {
        systemReduceMotion || CompositionRoot.testOption("--ui-reduce-motion")
    }

    private var resultAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    private var statusTone: StatusTone {
        store.isRunning ? .accent : StatusTone(state: store.state)
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
                StatusIcon(symbol: store.isRunning ? "waveform.path" : store.state.symbol,
                           tone: statusTone, size: 56, isWorking: store.isRunning, completion: completion)
                Text(store.state.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .padding(.top, 5)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dashboard.state")

            if store.disconnectBanner {
                Label(L10n.text("dashboard_vpn_disconnected"), systemImage: "info.circle")
                    .labelStyle(StatusLabelStyle())
                    .accessibilityIdentifier("dashboard.disconnect")
            }
            if changesPaused {
                Label(L10n.text("dashboard_changes_paused"), systemImage: "lock.shield")
                    .labelStyle(StatusLabelStyle(tone: .attention))
                    .font(.callout)
                    .accessibilityIdentifier("dashboard.repairGate")
            }
            if hasResult, needsAttention {
                resultSummary
                    .transition(.opacity)
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
                        .animation(resultAnimation, value: store.progress)
                    if store.repairPhase.isEmpty {
                        Text(L10n.text("diagnosis_running")).foregroundStyle(.secondary)
                            .accessibilityIdentifier("operation.active")
                    } else {
                        Text(store.repairPhase).foregroundStyle(.secondary)
                            .accessibilityIdentifier("repair.phase")
                    }
                }
                .transition(.opacity)
            } else if !store.repairPhase.isEmpty {
                Text(store.repairPhase).foregroundStyle(.secondary)
                    .accessibilityIdentifier("repair.phase")
            }
        }
        .statusPanel(tone: statusTone, emphasized: true)
        .phaseAnimator([false, true, false], trigger: completion) { content, highlight in
            content.overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(statusTone.color.opacity(highlight && !reduceMotion ? 0.6 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } animation: { highlight in
            reduceMotion ? nil : .easeOut(duration: highlight ? 0.14 : 0.4)
        }
        .animation(resultAnimation, value: store.state)
        .animation(resultAnimation, value: store.isRunning)
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
                        .labelStyle(StatusLabelStyle(tone: .attention))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L10n.text("review_candidate")) {
                        store.selectCandidate(index)
                        showRepair()
                    }
                    .disabled(store.isRunning)
                    .accessibilityIdentifier(index == 0 ? "repair.open" : "repair.open.\(index)")
                }
                .statusPanel(tone: .attention)
                .transition(.opacity)
            }
        }
    }

    private var networkDetails: some View {
        DisclosureGroup(isExpanded: $networkDetailsExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                Text(store.state.explanation).foregroundStyle(.secondary)
                Label(store.vpnStatus, systemImage: "network.badge.shield.half.filled")
                    .labelStyle(StatusLabelStyle(tone: store.vpn.state == .inactive ? .information : .attention))
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
                    .labelStyle(StatusLabelStyle())
                Spacer()
                if !store.checks.isEmpty {
                    Text(store.checks.count.formatted())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(L10n.format("dashboard_check_count %lld", store.checks.count)))
                }
            }
        }
        .accessibilityIdentifier("dashboard.details")
        .statusPanel()
        .animation(resultAnimation, value: networkDetailsExpanded)
        .animation(resultAnimation, value: store.checks.map(\.id))
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
                StatusIcon(symbol: check.symbol, tone: StatusTone(outcome: check.resultOutcome), size: 28)
                Text(check.title)
                Spacer(minLength: 8)
                Text(check.outcome).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("check.\(check.id)")
        .transition(.opacity)
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
                    .labelStyle(StatusLabelStyle())
            }
            .accessibilityIdentifier("device.section")
            // Keep the last result visible even if the input section is collapsed.
            if let connection = store.deviceConnection {
                VStack(alignment: .leading, spacing: 8) {
                    Label(connection.outcome, systemImage: connection.symbol).bold()
                        .labelStyle(StatusLabelStyle(tone: StatusTone(outcome: connection.resultOutcome)))
                        .accessibilityIdentifier("device.outcome")
                    Text(connection.reason).foregroundStyle(.secondary)
                        .accessibilityIdentifier("device.result")
                    DisclosureGroup(L10n.text("dashboard_technical_details")) {
                        Text(connection.technicalDetail).font(.caption.monospaced()).textSelection(.enabled)
                            .padding(.top, 6)
                            .accessibilityIdentifier("device.detail")
                    }
                }
                .transition(.opacity)
            }
        }
        .statusPanel()
        .animation(resultAnimation, value: deviceTestExpanded)
        .animation(resultAnimation, value: store.deviceConnection)
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
