import Foundation
import SwiftUI
import NetUnstickCore
import NetUnstickNetwork

enum NetworkPresentationState: String {
    /// `residual`: the checks pass and the VPN service reports disconnected, but the VPN
    /// client left tunnel devices behind. The network works; ordinary repairs stay blocked.
    /// `serverNotReady`: every network check passed, but this Mac's own file sharing cannot
    /// accept logins from other Macs; that is a settings change, not a network repair.
    /// `residualRoutes`: all basic network checks passed, but disconnected VPN services
    /// left forwarding routes. This observation never relaxes the executor's VPN gate.
    case healthy, problem, investigating, unknown, residual, residualRoutes, serverNotReady
    var title: String {
        switch self {
        case .healthy: L10n.text("state_healthy")
        case .problem: L10n.text("state_problem")
        case .investigating: L10n.text("state_investigating")
        case .unknown: L10n.text("state_unknown")
        case .residual: L10n.text("state_residual")
        case .residualRoutes: L10n.text("state_residual_routes")
        case .serverNotReady: L10n.text("state_sharing")
        }
    }
    var explanation: String {
        switch self {
        case .healthy: L10n.text("state_healthy_detail")
        case .problem: L10n.text("state_problem_detail")
        case .investigating: L10n.text("state_investigating_detail")
        case .unknown: L10n.text("state_unknown_detail")
        case .residual: L10n.text("state_residual_detail")
        case .residualRoutes: L10n.text("state_residual_routes_detail")
        case .serverNotReady: L10n.text("state_sharing_detail")
        }
    }
    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle"
        case .problem: "exclamationmark.triangle"
        case .investigating: "waveform.path"
        case .unknown: "questionmark.circle"
        case .residual, .residualRoutes: "checkmark.circle.trianglebadge.exclamationmark"
        case .serverNotReady: "person.crop.circle.badge.exclamationmark"
        }
    }
}

enum HelperPresentationState: String {
    case available, approvalRequired, denied, unavailable
    var title: String {
        switch self {
        case .available: L10n.text("helper_available")
        case .approvalRequired: L10n.text("helper_approvalRequired")
        case .denied: L10n.text("helper_denied")
        case .unavailable: L10n.text("helper_unavailable")
        }
    }
    var symbol: String { switch self { case .available: "checkmark.circle"; case .approvalRequired: "hand.raised"; case .denied: "xmark.circle"; case .unavailable: "questionmark.circle" } }
}

/// Result of the read-only helper handshake shown in Settings.
enum HelperHandshakePresentation: Equatable {
    case notRun, responding(version: Int), failed(code: String)
    var text: String {
        switch self {
        case .notRun: L10n.text("helper_unchecked")
        case .responding(let version): L10n.format("helper_protocol", version)
        case .failed(let code): L10n.format("helper_error", code)
        }
    }
    var symbol: String {
        switch self {
        case .notRun: "questionmark.circle"
        case .responding: "checkmark.seal"
        case .failed: "xmark.seal"
        }
    }
}

/// Outcome of the device connection test; the host stays in the text field only.
struct DeviceConnectionPresentation: Equatable {
    let outcome: String
    let reason: String
    let technicalDetail: String
    let symbol: String
    let resultOutcome: OperationOutcome
}

struct CheckPresentation: Identifiable {
    let id: String
    let title: String
    let outcome: String
    let reason: String?
    let technicalDetail: String
    let symbol: String
    let resultOutcome: OperationOutcome
}

struct RepairCandidatePresentation {
    let change: String
    let reason: String
    let resource: String
    let impact: String
    let permission: String
    let verification: String
    var allowsWhenResidualRoute = false
    var requiresHelper = false
}

@MainActor protocol PresentationService {
    var scenario: String { get }
    var helper: HelperPresentationState { get }
    var helperRegistrationIssue: String? { get }
    /// Aggregate status of the configured VPN services from the latest observation.
    var vpnServices: VPNServiceStatus { get }
    func diagnose() async throws -> [OperationResult]
    func diagnose(onCheck: @escaping @Sendable (OperationResult, Int, Int) -> Void) async throws -> [OperationResult]
    func repairCandidate() -> RepairCandidatePresentation?
    func repairCandidates() -> [RepairCandidatePresentation]
    func selectRepairCandidate(_ index: Int)
    func executeRepair(onPhase: @escaping @Sendable (String, OperationOutcome) -> Void) async -> OperationResult?
    func recordCancellation() async
    func refreshVPN(stabilize: Bool) async -> VPNAssessment
    func loadSessions() async throws -> [ActivitySession]
    func clearHistory() async throws
    func preview(_ session: ActivitySession) -> String
    func registerHelper() -> HelperPresentationState
    func unregisterHelper() -> HelperPresentationState
    func verifyHelper() async -> HelperHandshakePresentation
    /// Read-only TCP connect to a device chosen by the user; the result carries codes only.
    func testDeviceConnection(host: String, port: UInt16) async -> OperationResult?
    func openHelperSettings()
}

extension PresentationService {
    var helperRegistrationIssue: String? { nil }
    var vpnServices: VPNServiceStatus { .unknown }
    func repairCandidates() -> [RepairCandidatePresentation] { repairCandidate().map { [$0] } ?? [] }
    func selectRepairCandidate(_ index: Int) {}
    func diagnose(onCheck: @escaping @Sendable (OperationResult, Int, Int) -> Void) async throws -> [OperationResult] {
        let results = try await diagnose()
        for (index, result) in results.enumerated() { onCheck(result, index + 1, results.count) }
        return results
    }
    func executeRepair(onPhase: @escaping @Sendable (String, OperationOutcome) -> Void) async -> OperationResult? { nil }
    func recordCancellation() async {}
    func refreshVPN(stabilize: Bool) async -> VPNAssessment {
        switch scenario {
        case "vpn-active": .init(state: .active, reasonCode: .tunnelPath)
        case "vpn-residual": .init(state: .unknown, reasonCode: .residualTunnel)
        case "vpn-unknown", "default": .init(state: .unknown, reasonCode: .incompleteSnapshot)
        default: .init(state: .inactive, reasonCode: .noVPNSignals)
        }
    }
    func loadSessions() async throws -> [ActivitySession] { [] }
    func clearHistory() async throws {}
    func preview(_ session: ActivitySession) -> String { ReportRenderer().preview(session: session).body }
    func registerHelper() -> HelperPresentationState { helper }
    func unregisterHelper() -> HelperPresentationState { helper }
    func verifyHelper() async -> HelperHandshakePresentation { .notRun }
    func testDeviceConnection(host: String, port: UInt16) async -> OperationResult? { nil }
    func openHelperSettings() {}
}

@MainActor final class PresentationStore: ObservableObject {
    @Published var state: NetworkPresentationState = .unknown
    @Published var checks: [CheckPresentation] = []
    @Published var sessions: [ActivitySession] = []
    @Published var progress = 0.0
    @Published var isRunning = false
    @Published var lastResultText = L10n.text("no_result")
    @Published var nextStep = L10n.text("start_next")
    @Published var filter = "all"
    @Published var vpn: VPNAssessment = .init(state: .unknown, reasonCode: .stabilizationPending)
    @Published var vpnServices: VPNServiceStatus = .unknown
    @Published var disconnectBanner = false
    @Published var repairPhase = ""
    @Published var selectedSessionID: UUID?
    @Published var helperState: HelperPresentationState = .unavailable
    @Published var helperHandshake: HelperHandshakePresentation = .notRun
    @Published private(set) var helperSetupRunning = false
    @Published private(set) var historyClearRunning = false
    @Published var deviceHost = ""
    @Published var devicePort = "445"
    @Published var deviceTestRunning = false
    @Published var deviceConnection: DeviceConnectionPresentation?
    private let service: any PresentationService
    private var task: Task<Void, Never>?
    private var operationGeneration = UUID()
    private var watcher: Task<Void, Never>?
    private var candidateValue: RepairCandidatePresentation?
    @Published private(set) var candidates: [RepairCandidatePresentation] = []
    var helper: HelperPresentationState { helperState }
    private var isPersistentService: Bool { service.scenario == "production" }
    var candidate: RepairCandidatePresentation? {
        vpn.state == .inactive || candidateValue?.allowsWhenResidualRoute == true ? candidateValue : nil
    }
    var canConfirmRepair: Bool {
        guard !isRunning, !historyClearRunning, let candidate else { return false }
        if !candidate.requiresHelper { return true }
        guard helperState == .available, !helperSetupRunning else { return false }
        if case .failed = helperHandshake { return false }
        return true
    }
    var helperSetupGuidance: String {
        if helperSetupRunning { return L10n.text("helper_preparing") }
        if let issue = service.helperRegistrationIssue { return issue }
        if helperState == .available, case .failed = helperHandshake {
            return L10n.text("helper_not_responding")
        }
        switch helperState {
        case .unavailable:
            return L10n.text("helper_setup_required")
        case .approvalRequired:
            return L10n.text("helper_approve_guidance")
        case .denied:
            return L10n.text("helper_unavailable_guidance")
        case .available:
            return L10n.text("helper_ready_guidance")
        }
    }
    func selectCandidate(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        service.selectRepairCandidate(index)
        candidateValue = candidates[index]
    }
    /// Leftover tunnel devices after a disconnect the VPN service itself confirms.
    var residualTunnelOnly: Bool {
        vpn.state == .unknown && vpn.reasonCode == .residualTunnel && vpnServices == .disconnected
    }
    var vpnStatus: String {
        switch vpn.state {
        case .active:
            if candidateValue?.allowsWhenResidualRoute == true {
                return L10n.text("vpn_stale_repair")
            }
            if vpn.reasonCode == .tunnelRoute, vpnServices == .disconnected {
                return L10n.text("vpn_leftover_routes")
            }
            return L10n.text("vpn_active_guidance")
        case .inactive: return L10n.text("vpn_inactive_guidance")
        case .unknown:
            switch vpn.reasonCode {
            case .residualTunnel where vpnServices == .disconnected:
                return L10n.text("vpn_leftover_interfaces")
            case .residualTunnel:
                return L10n.text("vpn_unknown_interface")
            case .pathTransition:
                return L10n.text("vpn_changing")
            case .partialReadFailure, .incompleteSnapshot:
                return L10n.text("vpn_incomplete")
            case .conflictingSignals:
                return L10n.text("vpn_missing_tunnel")
            default:
                return L10n.text("vpn_uncertain")
            }
        }
    }
    var reportText: String {
        guard let session = sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.last else { return "" }
        return service.preview(session)
    }
    var filteredSessions: [ActivitySession] {
        sessions.filter { session in
            switch filter {
            case "success": session.entries.allSatisfy { $0.outcome == .success }
            case "problems": session.entries.contains { $0.outcome != .success }
            default: true
            }
        }
    }

    init(service: any PresentationService) {
        self.service = service
        self.helperState = service.helper
        if isPersistentService {
            watcher = Task { [weak self] in
                await self?.refreshSessions()
                await self?.verifyHelperNow()
                while !Task.isCancelled {
                    await self?.observeVPN()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        #if DEBUG
        if !isPersistentService && service.scenario != "unavailable" {
            if service.scenario == "operation-progress" { startDiagnosis() }
            else if service.scenario != "default" { startDiagnosis() }
        }
        #endif
    }
    deinit { watcher?.cancel() }

    private func observeVPN() async {
        let previous = vpn.state
        let assessment = await service.refreshVPN(stabilize: previous == .active)
        vpn = assessment
        vpnServices = service.vpnServices
        if previous == .active && assessment.state == .inactive {
            disconnectBanner = true
            nextStep = L10n.text("vpn_disconnected_next")
        }
        helperState = service.helper
    }
    func refreshSessions() async {
        do {
            sessions = try await service.loadSessions()
            if selectedSessionID == nil { selectedSessionID = sessions.last?.id }
        } catch {
            nextStep = L10n.text("history_unavailable")
        }
    }
    func selectSession(_ id: UUID) { selectedSessionID = id }
    func clearHistory() async throws {
        guard !isRunning, !deviceTestRunning, !historyClearRunning else { return }
        historyClearRunning = true
        defer { historyClearRunning = false }
        try await service.clearHistory()
        sessions = []; selectedSessionID = nil
        candidates = []; candidateValue = nil
    }
    func registerHelper() {
        guard !isRunning, !helperSetupRunning else { return }
        helperState = service.registerHelper()
        helperHandshake = .notRun
        if helperState == .available { verifyHelper() }
        nextStep = helperSetupGuidance
    }
    func unregisterHelper() {
        guard !isRunning, !helperSetupRunning else { return }
        helperState = service.unregisterHelper()
        helperHandshake = .notRun
    }
    func verifyHelper() {
        guard !isRunning, !helperSetupRunning else { return }
        helperSetupRunning = true
        Task { [weak self] in
            guard let self else { return }
            await verifyHelperNow()
            helperSetupRunning = false
            if !isRunning { nextStep = helperSetupGuidance }
        }
    }
    func testDeviceConnection() {
        guard !deviceTestRunning, !historyClearRunning else { return }
        guard let port = DeviceConnectionInput.port(from: devicePort), DeviceConnectionInput.isValidHost(deviceHost) else {
            deviceConnection = .init(outcome: Self.outcomeTitle(.skipped), reason: DeviceConnectionReason.invalidInput.message,
                                     technicalDetail: "errorCode: invalidInput", symbol: "minus.circle", resultOutcome: .skipped)
            return
        }
        deviceTestRunning = true
        Task { [weak self] in
            guard let self else { return }
            let result = await service.testDeviceConnection(host: deviceHost, port: port)
            deviceTestRunning = false
            guard let result else { deviceConnection = nil; return }
            deviceConnection = Self.presentDevice(result)
            if isPersistentService { await refreshSessions() }
        }
    }
    static func presentDevice(_ result: OperationResult) -> DeviceConnectionPresentation {
        let code = result.after.values[.errorCode] ?? result.error?.code ?? ""
        var reason = code == "permissionDenied" ? L10n.text("bonjour_permissionDenied") :
            DeviceConnectionReason(rawValue: code)?.message ?? L10n.text("device_unknown_result")
        if result.after.values[.networkStatus] == "active" {
            reason += " " + L10n.text("device_via_tunnel")
        }
        if let families = Self.addressFamilyNote(result.after) { reason += " " + families }
        if let session = Self.smbSessionNote(result.after) { reason += " " + session }
        let evidence = result.after.values.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue): \($0.value)" }.joined(separator: " · ")
        return .init(outcome: outcomeTitle(result.outcome), reason: reason,
                     technicalDetail: "\(evidence) \(result.error.map { "\($0.domain)/\($0.code)" } ?? "")",
                     symbol: result.outcome.statusSymbol, resultOutcome: result.outcome)
    }
    /// Explains a split verdict: the device answers over one address family but not the other.
    /// Explains what this Mac's own SMB client got once port 445 answered, and where a block sits.
    static func smbSessionNote(_ evidence: SafeEvidence) -> String? {
        guard let raw = evidence.values[.smbResult], let smb = SMBSessionOutcome(rawValue: raw) else { return nil }
        switch smb {
        case .sharesListed:
            return L10n.text("smb_guest_accepted")
        case .authRejected:
            return L10n.text("smb_login_required")
        case .sessionFailed:
            let filter = evidence.values[.contentFilterStatus] == "active"
            var text = L10n.text("smb_session_failed")
            if filter {
                text += " " + L10n.text("smb_filter_present")
            }
            return text
        case .timedOut:
            return L10n.text("smb_timeout")
        case .otherExit:
            return L10n.text("smb_other_exit")
        case .unknown:
            return L10n.text("smb_unknown")
        }
    }
    static func addressFamilyNote(_ evidence: SafeEvidence) -> String? {
        let ipv4 = evidence.values[.ipv4Result].flatMap(DeviceConnectionReason.init(rawValue:))
        let ipv6 = evidence.values[.ipv6Result].flatMap(DeviceConnectionReason.init(rawValue:))
        func label(_ reason: DeviceConnectionReason) -> String {
            switch reason {
            case .reachable: L10n.text("address_reachable")
            case .refused: L10n.text("address_refused")
            case .timedOut: L10n.text("address_timeout")
            case .unreachable: L10n.text("address_unreachable")
            default: reason.rawValue
            }
        }
        switch (ipv4, ipv6) {
        case (.some(.reachable), .some(let v6)) where v6 != .reachable:
            return L10n.format("address_ipv4_works", label(v6))
        case (.some(let v4), .some(.reachable)) where v4 != .reachable:
            return L10n.format("address_ipv6_works", label(v4))
        case (.some(let v4), .some(let v6)):
            return L10n.format("address_summary", label(v4), label(v6))
        case (.some, .none):
            return L10n.text("address_ipv4_only")
        case (.none, .some):
            return L10n.text("address_ipv6_only")
        case (.none, .none):
            return nil
        }
    }
    private func verifyHelperNow() async {
        helperSetupRunning = true
        defer { helperSetupRunning = false }
        helperHandshake = await service.verifyHelper()
        helperState = service.helper
    }
    func openHelperSettings() { service.openHelperSettings() }

    func startDiagnosis() {
        guard !isRunning, !historyClearRunning else { return }
        task?.cancel()
        let generation = UUID()
        operationGeneration = generation
        isRunning = true; progress = 0; state = .investigating; checks = []; candidateValue = nil; candidates = []
        repairPhase = ""
        lastResultText = L10n.text("diagnosis_running")
        nextStep = L10n.text("wait_or_cancel")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await service.diagnose(onCheck: { [weak self] result, done, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning, self.operationGeneration == generation else { return }
                        self.progress = Double(done) / Double(max(total, 1))
                        self.checks.append(Self.present(result))
                    }
                })
                guard !Task.isCancelled, operationGeneration == generation else { return }
                candidates = service.repairCandidates()
                candidateValue = candidates.first
                let assessment = await service.refreshVPN(stabilize: false)
                guard !Task.isCancelled, operationGeneration == generation else { return }
                vpn = assessment
                vpnServices = service.vpnServices
                accept(results)
                progress = 1; isRunning = false
                await refreshSessions()
                guard !Task.isCancelled, operationGeneration == generation else { return }
                if isPersistentService { selectedSessionID = sessions.last?.id }
                #if DEBUG
                if !isPersistentService, sessions.isEmpty {
                    sessions = [ActivitySession(startedAt: Date(), appVersion: "0.1.0", macOSVersion: "14.0", entries: results)]
                }
                #endif
            } catch is CancellationError {
                guard operationGeneration == generation else { return }
                isRunning = false; state = .unknown; lastResultText = L10n.text("cancelled_result")
                nextStep = L10n.text("start_next")
                // A new uncancelled task from cancel() refreshes the journal.
            } catch {
                guard !Task.isCancelled, operationGeneration == generation else { return }
                isRunning = false; state = .unknown
                lastResultText = L10n.text("diagnosis_failed")
                nextStep = L10n.text("support_permissions")
            }
        }
    }
    func cancel() {
        guard isRunning else { return }
        task?.cancel(); operationGeneration = UUID(); isRunning = false; state = .unknown
        repairPhase = ""
        lastResultText = L10n.text("cancelled_result")
        nextStep = L10n.text("start_next")
        #if DEBUG
        if !isPersistentService {
            let now = Date()
            if let result = try? OperationResult(operationID: "fake.cancelled", name: "diagnosis_cancelled",
                kind: .diagnostic, startedAt: now, endedAt: now, outcome: .cancelled) {
                sessions.append(ActivitySession(startedAt: now, appVersion: "0.1.0", macOSVersion: "14.0", entries: [result]))
            }
        }
        #endif
        if isPersistentService {
            Task { await service.recordCancellation(); await refreshSessions() }
        }
    }
    func confirmRepair() {
        guard !isRunning, !historyClearRunning, let selectedCandidate = candidate else { return }
        helperState = service.helper
        guard !selectedCandidate.requiresHelper || canConfirmRepair else {
            lastResultText = L10n.text("repair_waiting_helper")
            nextStep = helperSetupGuidance
            return
        }
        let generation = UUID()
        operationGeneration = generation
        isRunning = true; repairPhase = L10n.text("repair_reassessing")
        task = Task { [weak self] in
            guard let self else { return }
            let assessment = await service.refreshVPN(stabilize: false)
            guard !Task.isCancelled, operationGeneration == generation else { return }
            vpn = assessment
            // The executor repeats this gate and records a structured skipped result.
            let repairResult = await service.executeRepair(onPhase: { [weak self] phase, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning, self.operationGeneration == generation else { return }
                    self.repairPhase = Self.phaseLabel(phase)
                }
            })
            guard !Task.isCancelled, operationGeneration == generation else { return }
            guard let result = repairResult else {
                isRunning = false; repairPhase = ""; return
            }
            // The outcome is carried by the result text below; no raw phase name stays on screen.
            repairPhase = ""
            lastResultText = result.outcome == .success ? L10n.text("repair_verified") :
                L10n.format("repair_outcome", Self.outcomeTitle(result.outcome), result.error?.code ?? L10n.text("no_error_code"))
            nextStep = result.nextStep.map(L10n.nextStep) ?? L10n.text("review_details")
            candidateValue = nil
            candidates = []
            if isPersistentService {
                await refreshSessions()
                guard !Task.isCancelled, operationGeneration == generation else { return }
                selectedSessionID = sessions.last?.id
            }
            #if DEBUG
            if !isPersistentService {
                sessions.append(ActivitySession(startedAt: Date(), appVersion: "0.1.0", macOSVersion: "14.0", entries: [result]))
            }
            #endif
            if result.outcome == .success, !Task.isCancelled {
                await refreshAfterVerifiedRepair()
            } else {
                isRunning = false
            }
        }
    }

    /// The targeted repair recheck proves only its own change. Refresh every displayed
    /// check before presenting the overall network state; retain the repair in the journal.
    private func refreshAfterVerifiedRepair() async {
        let generation = UUID()
        operationGeneration = generation
        isRunning = true; progress = 0; state = .investigating; checks = []
        repairPhase = L10n.text("repair_checking")
        nextStep = L10n.text("wait_or_cancel")
        do {
            let results = try await service.diagnose(onCheck: { [weak self] result, done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning, self.operationGeneration == generation else { return }
                    self.progress = Double(done) / Double(max(total, 1))
                    self.checks.append(Self.present(result))
                }
            })
            try Task.checkCancellation()
            guard operationGeneration == generation else { return }
            let assessment = await service.refreshVPN(stabilize: false)
            try Task.checkCancellation()
            guard operationGeneration == generation else { return }
            vpn = assessment
            vpnServices = service.vpnServices
            candidates = service.repairCandidates()
            candidateValue = candidates.first
            accept(results)
            lastResultText = L10n.text("repair_verified") + " " + lastResultText
            progress = 1
            if isPersistentService {
                await refreshSessions()
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            // cancel() already published the outcome; a new operation may now be running.
            guard !Task.isCancelled, operationGeneration == generation else { return }
            state = .unknown
            lastResultText = L10n.text("repair_followup_cancelled")
            nextStep = L10n.text("start_next")
        } catch {
            guard !Task.isCancelled, operationGeneration == generation else { return }
            state = .unknown
            lastResultText = L10n.text("repair_followup_failed")
            nextStep = L10n.text("repair_check_again")
        }
        guard operationGeneration == generation else { return }
        isRunning = false; repairPhase = ""
    }
    private func accept(_ results: [OperationResult]) {
        checks = results.map(Self.present)
        let failing = results.filter { $0.outcome == .failure || $0.outcome == .permissionDenied || $0.outcome == .timedOut }
        // Leftover tunnel devices after a confirmed disconnect are a nuisance, not an unknown network.
        let leftoverTunnels = failing.filter {
            $0.operationID == "interface_consistency" && $0.after.values[.errorCode] == NetworkCheckReason.orphanedTunnel.rawValue
        }
        let sharingFailures = failing.filter { $0.operationID == "file_sharing_readiness" }
        let networkFailures = failing.count - leftoverTunnels.count - sharingFailures.count
        let disconnectedRoutes = vpn.state == .active && vpn.reasonCode == .tunnelRoute && vpnServices == .disconnected
        // Missing/skipped checks cannot prove that LAN and internet work. Keep the
        // conservative VPN assessment; this affects presentation, never repair permission.
        let basicChecksPassed = NetworkCheckKind.allCases.allSatisfy { kind in
            results.contains { $0.operationID == kind.id && $0.outcome == .success }
        }
        let verifiedRemainingRoutes = disconnectedRoutes && basicChecksPassed
        let vpnSettled = vpn.state == .inactive || residualTunnelOnly || verifiedRemainingRoutes
        if vpnSettled, networkFailures == 0, leftoverTunnels.isEmpty || residualTunnelOnly, !sharingFailures.isEmpty {
            // The network works; only this Mac's own file sharing keeps other Macs from logging in.
            state = .serverNotReady
            let noLogin = sharingFailures.contains { $0.after.values[.errorCode] == FileSharingReason.noLoginMethod.rawValue }
            lastResultText = L10n.text(noLogin ? "result_sharing_nologin" : "result_sharing")
            nextStep = L10n.text(noLogin ? "next_sharing_nologin" : "next_sharing")
        } else if residualTunnelOnly && networkFailures == 0 && sharingFailures.isEmpty {
            state = .residual
            lastResultText = L10n.text("result_residual")
            nextStep = L10n.text("next_residual")
        } else if verifiedRemainingRoutes && failing.isEmpty {
            state = .residualRoutes
            lastResultText = L10n.text("result_residual_routes")
            nextStep = L10n.text("next_residual_routes")
        } else if disconnectedRoutes && networkFailures > 0 {
            state = .problem
            lastResultText = L10n.text("result_problem")
            nextStep = L10n.text("next_problem")
        } else if vpn.state != .inactive {
            state = .unknown
            lastResultText = L10n.text("result_vpn_unknown")
            nextStep = L10n.text("next_vpn_unknown")
        } else {
            state = failing.isEmpty ? .healthy : .problem
            lastResultText = failing.isEmpty ? L10n.text("result_healthy") : L10n.text("result_problem")
            nextStep = failing.isEmpty ? L10n.text("next_healthy") : L10n.text("next_problem")
        }
        if results.contains(where: { $0.outcome == .permissionDenied }) {
            lastResultText = L10n.text("result_permission"); nextStep = L10n.text("next_permission")
        } else if results.contains(where: { $0.outcome == .timedOut }) {
            lastResultText = L10n.text("result_timeout"); nextStep = L10n.text("next_timeout")
        }
    }
    private static func present(_ result: OperationResult) -> CheckPresentation {
        let code = result.after.values[.errorCode] ?? result.error?.code
        let reason: String? = if let code, let network = NetworkCheckReason(rawValue: code) {
            network.message
        } else if let code, let filter = ContentFilterReason(rawValue: code) {
            filter.message
        } else if let code, let sharing = FileSharingReason(rawValue: code) {
            sharing.message
        } else if let code, let bonjour = BonjourReason(rawValue: code) {
            switch bonjour {
            case .noServices: L10n.text("bonjour_noServices")
            case .permissionDenied: L10n.text("bonjour_permissionDenied")
            case .timedOut: L10n.text("bonjour_timedOut")
            case .browserFailed: L10n.text("bonjour_browserFailed")
            case .noPhysicalInterface, .noLocalPath: L10n.text("bonjour_noLocalPath")
            case .cancelled: L10n.text("bonjour_cancelled")
            case .inconclusive: L10n.text("bonjour_inconclusive")
            case .servicesFound: nil
            }
        } else { nil }
        let evidence = result.after.values.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue): \($0.value)" }.joined(separator: " · ")
        return .init(id: result.operationID, title: operationTitle(result.name),
                     outcome: outcomeTitle(result.outcome),
                     reason: result.outcome == .success ? nil : reason,
                     technicalDetail: "\(evidence) \(result.error.map { "\($0.domain)/\($0.code)" } ?? "")",
                     symbol: result.outcome.statusSymbol, resultOutcome: result.outcome)
    }
    static func operationTitle(_ stableName: String) -> String {
        return L10n.operationTitle(stableName)
    }
    /// Plain-language labels for the executor's phase names shown while a repair runs.
    static func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "revalidate": L10n.text("phase_revalidate")
        case "fresh_vpn": L10n.text("phase_fresh_vpn")
        case "vpn_gate": L10n.text("phase_vpn_gate")
        case "before_snapshot": L10n.text("phase_before_snapshot")
        case "helper_request": L10n.text("phase_helper_request")
        case "read_only_retry": L10n.text("phase_read_only_retry")
        case "settle": L10n.text("phase_settle")
        case "after_snapshot": L10n.text("phase_after_snapshot")
        case "recheck": L10n.text("phase_recheck")
        case "result": L10n.text("phase_result")
        default: phase
        }
    }
    static func outcomeTitle(_ outcome: OperationOutcome) -> String {
        switch outcome {
        case .success: L10n.text("check_ok")
        case .failure: L10n.text("check_problem")
        case .skipped: L10n.text("check_skipped")
        case .cancelled: L10n.text("check_cancelled")
        case .permissionDenied: L10n.text("check_permission")
        case .timedOut: L10n.text("check_timeout")
        }
    }
}
