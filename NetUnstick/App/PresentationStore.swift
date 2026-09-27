import Foundation
import SwiftUI
import NetUnstickCore
import NetUnstickNetwork

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
    let reason: String?
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
    func diagnose(onCheck: @escaping @Sendable (OperationResult, Int, Int) -> Void) async throws -> [OperationResult]
    func repairCandidate() -> RepairCandidatePresentation?
    func repairCandidates() -> [RepairCandidatePresentation]
    func selectRepairCandidate(_ index: Int)
    func executeRepair(onPhase: @escaping @Sendable (String, OperationOutcome) -> Void) async -> OperationResult?
    func recordCancellation() async
    func refreshVPN(stabilize: Bool) async -> VPNAssessment
    func loadSessions() async throws -> [ActivitySession]
    func preview(_ session: ActivitySession) -> String
    func registerHelper() -> HelperPresentationState
    func openHelperSettings()
}

extension PresentationService {
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
        case "vpn-unknown", "default": .init(state: .unknown, reasonCode: .incompleteSnapshot)
        default: .init(state: .inactive, reasonCode: .noVPNSignals)
        }
    }
    func loadSessions() async throws -> [ActivitySession] { [] }
    func preview(_ session: ActivitySession) -> String { ReportRenderer().preview(session: session).body }
    func registerHelper() -> HelperPresentationState { helper }
    func openHelperSettings() {}
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
    @Published var vpn: VPNAssessment = .init(state: .unknown, reasonCode: .stabilizationPending)
    @Published var disconnectBanner = false
    @Published var repairPhase = ""
    @Published var selectedSessionID: UUID?
    @Published var helperState: HelperPresentationState = .unavailable
    private let service: any PresentationService
    private var task: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var candidateValue: RepairCandidatePresentation?
    @Published private(set) var candidates: [RepairCandidatePresentation] = []
    var helper: HelperPresentationState { helperState }
    var candidate: RepairCandidatePresentation? { vpn.state == .inactive ? candidateValue : nil }
    func selectCandidate(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        service.selectRepairCandidate(index)
        candidateValue = candidates[index]
    }
    var vpnStatus: String {
        switch vpn.state {
        case .active: return "VPN aktywny. Zmiany sieci są zablokowane."
        case .inactive: return "VPN nieaktywny. Możesz uruchomić diagnostykę."
        case .unknown: return "Stan VPN niepewny. Zmiany sieci są zablokowane do ponownej oceny."
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
        if service.scenario == "production" {
            watcher = Task { [weak self] in
                await self?.refreshSessions()
                while !Task.isCancelled {
                    await self?.observeVPN()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        #if DEBUG
        if service.scenario != "production" && service.scenario != "unavailable" {
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
        if previous == .active && assessment.state == .inactive {
            disconnectBanner = true
            nextStep = "VPN został rozłączony. Uruchom diagnostykę, aby sprawdzić połączenie."
        }
        helperState = service.helper
    }
    func refreshSessions() async {
        do {
            sessions = try await service.loadSessions()
            if selectedSessionID == nil { selectedSessionID = sessions.last?.id }
        } catch {
            nextStep = "Nie można odczytać historii. Sprawdź uprawnienia do Application Support."
        }
    }
    func selectSession(_ id: UUID) { selectedSessionID = id }
    func registerHelper() { helperState = service.registerHelper() }
    func openHelperSettings() { service.openHelperSettings() }

    func startDiagnosis() {
        guard !isRunning else { return }
        task?.cancel()
        isRunning = true; progress = 0; state = .investigating; checks = []; candidateValue = nil; candidates = []
        lastResultText = String(localized: "diagnosis_running")
        nextStep = String(localized: "wait_or_cancel")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await service.diagnose(onCheck: { [weak self] result, done, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning else { return }
                        self.progress = Double(done) / Double(max(total, 1))
                        self.checks.append(Self.present(result))
                    }
                })
                guard !Task.isCancelled else { return }
                progress = 1; isRunning = false
                candidates = service.repairCandidates()
                candidateValue = candidates.first
                vpn = await service.refreshVPN(stabilize: false)
                accept(results)
                await refreshSessions()
                if service.scenario == "production" { selectedSessionID = sessions.last?.id }
                #if DEBUG
                if service.scenario != "production", sessions.isEmpty {
                    sessions = [ActivitySession(startedAt: Date(), appVersion: "0.1.0", macOSVersion: "14.0", entries: results)]
                }
                #endif
            } catch is CancellationError {
                isRunning = false; state = .unknown; lastResultText = String(localized: "cancelled_result")
                nextStep = String(localized: "start_next")
                // A new uncancelled task from cancel() refreshes the journal.
            } catch {
                isRunning = false; state = .unknown
                lastResultText = "Nie udało się zapisać lub wykonać diagnozy."
                nextStep = "Sprawdź uprawnienia do Application Support i spróbuj ponownie."
            }
        }
    }
    func cancel() {
        guard isRunning else { return }
        task?.cancel(); isRunning = false; state = .unknown
        lastResultText = String(localized: "cancelled_result")
        nextStep = String(localized: "start_next")
        #if DEBUG
        if service.scenario != "production" {
            let now = Date()
            if let result = try? OperationResult(operationID: "fake.cancelled", name: "diagnosis_cancelled",
                kind: .diagnostic, startedAt: now, endedAt: now, outcome: .cancelled) {
                sessions.append(ActivitySession(startedAt: now, appVersion: "0.1.0", macOSVersion: "14.0", entries: [result]))
            }
        }
        #endif
        if service.scenario == "production" {
            Task { await service.recordCancellation(); await refreshSessions() }
        }
    }
    func confirmRepair() {
        guard !isRunning, candidateValue != nil else { return }
        isRunning = true; repairPhase = "before / ponowna ocena VPN i warunków"
        task = Task { [weak self] in
            guard let self else { return }
            vpn = await service.refreshVPN(stabilize: false)
            // The executor repeats this gate and records a structured skipped result.
            guard let result = await service.executeRepair(onPhase: { [weak self] phase, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    self.repairPhase = phase
                }
            }) else {
                isRunning = false; repairPhase = "skipped"; return
            }
            isRunning = false
            repairPhase = result.outcome.rawValue
            lastResultText = result.outcome == .success ? "Naprawiono — ponowny check potwierdził poprawę." :
                "Naprawa: \(Self.outcomeTitle(result.outcome)); \(result.error?.code ?? "bez kodu")"
            nextStep = result.nextStep ?? "Przejrzyj szczegóły operacji."
            candidateValue = nil
            candidates = []
            if service.scenario == "production" { await refreshSessions() }
            #if DEBUG
            if service.scenario != "production" {
                sessions.append(ActivitySession(startedAt: Date(), appVersion: "0.1.0", macOSVersion: "14.0", entries: [result]))
            }
            #endif
        }
    }
    private func accept(_ results: [OperationResult]) {
        checks = results.map(Self.present)
        let failed = results.contains { $0.outcome == .failure || $0.outcome == .permissionDenied || $0.outcome == .timedOut }
        state = vpn.state != .inactive ? .unknown : failed ? .problem : .healthy
        lastResultText = vpn.state != .inactive ? String(localized: "result_vpn_unknown") : failed ? String(localized: "result_problem") : String(localized: "result_healthy")
        nextStep = vpn.state != .inactive ? String(localized: "next_vpn_unknown") : failed ? String(localized: "next_problem") : String(localized: "next_healthy")
        if results.contains(where: { $0.outcome == .permissionDenied }) {
            lastResultText = String(localized: "result_permission"); nextStep = String(localized: "next_permission")
        } else if results.contains(where: { $0.outcome == .timedOut }) {
            lastResultText = String(localized: "result_timeout"); nextStep = String(localized: "next_timeout")
        }
    }
    private static func present(_ result: OperationResult) -> CheckPresentation {
        let code = result.after.values[.errorCode] ?? result.error?.code
        let reason: String? = if let code, let network = NetworkCheckReason(rawValue: code) {
            network.message
        } else if let code, let bonjour = BonjourReason(rawValue: code) {
            switch bonjour {
            case .noServices: "Nie znaleziono odbiornika; może go nie być w tej sieci."
            case .permissionDenied: "System odmówił dostępu do sieci lokalnej. Sprawdź zgodę aplikacji."
            case .timedOut: "Odkrywanie lokalne nie zakończyło się na czas. Spróbuj ponownie."
            case .browserFailed: "Odkrywanie lokalne nie powiodło się. Spróbuj ponownie."
            case .noPhysicalInterface, .noLocalPath: "Brak potwierdzonej ścieżki lokalnej. Sprawdź połączenie."
            case .cancelled: "Sprawdzenie zostało anulowane."
            case .inconclusive: "Nie można potwierdzić działania odkrywania lokalnego."
            case .servicesFound: nil
            }
        } else { nil }
        let evidence = result.after.values.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue): \($0.value)" }.joined(separator: " · ")
        return .init(id: result.operationID, title: result.name.replacingOccurrences(of: "_", with: " "),
                     outcome: outcomeTitle(result.outcome),
                     reason: result.outcome == .success ? nil : reason,
                     technicalDetail: "\(evidence) \(result.error.map { "\($0.domain)/\($0.code)" } ?? "")",
                     symbol: result.outcome == .success ? "checkmark.circle" : result.outcome == .skipped ? "minus.circle" : "exclamationmark.triangle")
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
