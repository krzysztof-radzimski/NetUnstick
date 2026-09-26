import Foundation
import SwiftUI
import NetUnstickCore

enum NetworkPresentationState: String {
    case healthy, problem, investigating, unknown
    var title: String {
        switch self {
        case .healthy: String(localized: "state_healthy")
        case .problem: String(localized: "state_problem")
        case .investigating: String(localized: "state_investigating")
        case .unknown: String(localized: "state_unknown")
        }
    }
    var explanation: String {
        switch self {
        case .healthy: String(localized: "state_healthy_detail")
        case .problem: String(localized: "state_problem_detail")
        case .investigating: String(localized: "state_investigating_detail")
        case .unknown: String(localized: "state_unknown_detail")
        }
    }
    var symbol: String { switch self { case .healthy: "checkmark.circle"; case .problem: "exclamationmark.triangle"; case .investigating: "waveform.path"; case .unknown: "questionmark.circle" } }
}

enum HelperPresentationState: String {
    case available, approvalRequired, denied, unavailable
    var title: String {
        switch self {
        case .available: String(localized: "helper_available")
        case .approvalRequired: String(localized: "helper_approvalRequired")
        case .denied: String(localized: "helper_denied")
        case .unavailable: String(localized: "helper_unavailable")
        }
    }
    var symbol: String { switch self { case .available: "checkmark.circle"; case .approvalRequired: "hand.raised"; case .denied: "xmark.circle"; case .unavailable: "questionmark.circle" } }
}

struct CheckPresentation: Identifiable {
    let id: String
    let title: String
    let outcome: String
    let technicalDetail: String
    let symbol: String
}

struct RepairCandidatePresentation {
    let change: String
    let reason: String
    let resource: String
    let impact: String
    let permission: String
    let verification: String
}

@MainActor protocol PresentationService {
    var scenario: String { get }
    var helper: HelperPresentationState { get }
    func diagnose() async throws -> [OperationResult]
    func repairCandidate() -> RepairCandidatePresentation?
}

@MainActor final class PresentationStore: ObservableObject {
    @Published var state: NetworkPresentationState = .unknown
    @Published var checks: [CheckPresentation] = []
    @Published var sessions: [ActivitySession] = []
    @Published var progress = 0.0
    @Published var isRunning = false
    @Published var lastResultText = String(localized: "no_result")
    @Published var nextStep = String(localized: "start_next")
    @Published var filter = "all"
    let service: any PresentationService
    private var task: Task<Void, Never>?
    var helper: HelperPresentationState { service.helper }
    var vpnStatus: String {
        switch service.scenario {
        case "vpn-active": String(localized: "vpn_active")
        case "vpn-unknown", "default": String(localized: "vpn_unknown")
        default: String(localized: "vpn_inactive_mock")
        }
    }
    var candidate: RepairCandidatePresentation? { service.repairCandidate() }
    var reportText: String { sessions.last.map { ReportRenderer().preview(session: $0).body } ?? "" }
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
        switch service.scenario {
        case "healthy", "repair-success": state = .healthy
        case "default": state = .unknown
        case "operation-progress": state = .investigating
        case "vpn-unknown": state = .unknown
        default: state = .problem
        }
        if service.scenario != "default" && service.scenario != "operation-progress" { seed() }
        if service.scenario == "operation-progress" { startDiagnosis() }
    }

    private func seed() {
        task = Task {
            if let results = try? await service.diagnose() { accept(results) }
            if service.scenario == "repair-success" { lastResultText = String(localized: "repair_verified_mock") }
            if service.scenario == "repair-failure" { lastResultText = String(localized: "repair_failed_mock") }
        }
    }

    func startDiagnosis() {
        guard !isRunning else { return }
        isRunning = true; progress = 0.1; state = .investigating
        lastResultText = String(localized: "diagnosis_running")
        nextStep = String(localized: "wait_or_cancel")
        task = Task {
            do {
                let results = try await service.diagnose()
                guard !Task.isCancelled else { return }
                progress = 1; isRunning = false; accept(results)
            } catch is CancellationError {
                isRunning = false; state = .unknown
                recordCancellation()
            } catch {
                isRunning = false; state = .unknown
                let now = Date()
                if let code = try? OperationError(domain: "Mock", code: "unexpected"),
                   let result = try? OperationResult(operationID: "mock.unexpected", name: "Simulated diagnosis", kind: .diagnostic, startedAt: now, endedAt: now, outcome: .failure, error: code) {
                    sessions = Array((sessions + [ActivitySession(startedAt: now, appVersion: "0.1.0", macOSVersion: "14.0", entries: [result])]).suffix(20))
                }
                lastResultText = String(localized: "unknown_error")
                nextStep = String(localized: "start_next")
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel(); isRunning = false; state = .unknown
        recordCancellation()
    }

    private func recordCancellation() {
        guard lastResultText != String(localized: "cancelled_result") else { return }
        let now = Date()
        if let result = try? OperationResult(operationID: "mock.cancelled", name: "Simulated diagnosis", kind: .diagnostic, startedAt: now, endedAt: now, outcome: .cancelled) {
            sessions = Array((sessions + [ActivitySession(startedAt: now, appVersion: "0.1.0", macOSVersion: "14.0", entries: [result])]).suffix(20))
        }
        lastResultText = String(localized: "cancelled_result")
        nextStep = String(localized: "start_next")
    }

    private func accept(_ results: [OperationResult]) {
        checks = results.map { result in
            CheckPresentation(id: result.name, title: Self.checkTitle(result.name), outcome: Self.outcomeTitle(result.outcome), technicalDetail: "\(result.operationID): \(result.outcome.rawValue) \(result.error?.code ?? "")", symbol: result.outcome == .success ? "checkmark.circle" : result.outcome == .skipped ? "minus.circle" : "exclamationmark.triangle")
        }
        let failed = results.contains { $0.outcome != .success }
        state = ["vpn-active", "vpn-unknown"].contains(service.scenario) ? .unknown : failed ? .problem : .healthy
        lastResultText = ["vpn-active", "vpn-unknown"].contains(service.scenario) ? String(localized: "result_vpn_unknown") : failed ? String(localized: "result_problem") : String(localized: "result_healthy")
        nextStep = ["vpn-active", "vpn-unknown"].contains(service.scenario) ? String(localized: "next_vpn_unknown") : failed ? String(localized: "next_problem") : String(localized: "next_healthy")
        switch service.scenario {
        case "permission-denied", "bonjour-denied":
            lastResultText = String(localized: "result_permission")
            nextStep = String(localized: "next_permission")
        case "timeout":
            lastResultText = String(localized: "result_timeout")
            nextStep = String(localized: "next_timeout")
        case "no-receiver":
            lastResultText = String(localized: "result_no_receiver")
            nextStep = String(localized: "next_no_receiver")
        default: break
        }
        let session = ActivitySession(startedAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "0.1.0", macOSVersion: "14.0", entries: results)
        sessions = Array((sessions + [session]).suffix(20))
    }

    func simulateRepair() {
        let now = Date()
        let failed = service.scenario == "repair-failure"
        if let result = try? OperationResult(operationID: "mock.repair", name: "Simulated repair", kind: .repair, startedAt: now, endedAt: now, outcome: failed ? .failure : .skipped, error: failed ? try? OperationError(domain: "Mock", code: "repair_failure") : nil, nextStep: "Simulation only. No network settings changed.") {
            sessions = Array((sessions + [ActivitySession(startedAt: now, appVersion: "0.1.0", macOSVersion: "14.0", entries: [result])]).suffix(20))
        }
        lastResultText = service.scenario == "repair-failure" ? String(localized: "repair_failed_mock") : String(localized: "repair_verified_mock")
        nextStep = String(localized: "start_next")
    }

    private static func checkTitle(_ name: String) -> String {
        switch name {
        case "network": String(localized: "check_network")
        case "dns": String(localized: "check_dns")
        case "route": String(localized: "check_route")
        default: String(localized: "check_bonjour")
        }
    }

    static func outcomeTitle(_ outcome: OperationOutcome) -> String {
        switch outcome {
        case .success: String(localized: "check_ok")
        case .failure: String(localized: "check_problem")
        case .skipped: String(localized: "check_skipped")
        case .cancelled: String(localized: "check_cancelled")
        case .permissionDenied: String(localized: "check_permission")
        case .timedOut: String(localized: "check_timeout")
        }
    }
}
