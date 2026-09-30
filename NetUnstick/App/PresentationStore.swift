import Foundation
import SwiftUI
import NetUnstickCore
import NetUnstickNetwork

enum NetworkPresentationState: String {
    /// `residual`: the checks pass and the VPN service reports disconnected, but the VPN
    /// client left tunnel devices behind. The network works; ordinary repairs stay blocked.
    /// `serverNotReady`: every network check passed, but this Mac's own file sharing cannot
    /// accept logins from other Macs; that is a settings change, not a network repair.
    case healthy, problem, investigating, unknown, residual, serverNotReady
    var title: String {
        switch self {
        case .healthy: String(localized: "state_healthy")
        case .problem: String(localized: "state_problem")
        case .investigating: String(localized: "state_investigating")
        case .unknown: String(localized: "state_unknown")
        case .residual: String(localized: "state_residual")
        case .serverNotReady: String(localized: "state_sharing")
        }
    }
    var explanation: String {
        switch self {
        case .healthy: String(localized: "state_healthy_detail")
        case .problem: String(localized: "state_problem_detail")
        case .investigating: String(localized: "state_investigating_detail")
        case .unknown: String(localized: "state_unknown_detail")
        case .residual: String(localized: "state_residual_detail")
        case .serverNotReady: String(localized: "state_sharing_detail")
        }
    }
    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle"
        case .problem: "exclamationmark.triangle"
        case .investigating: "waveform.path"
        case .unknown: "questionmark.circle"
        case .residual: "checkmark.circle.trianglebadge.exclamationmark"
        case .serverNotReady: "person.crop.circle.badge.exclamationmark"
        }
    }
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

/// Result of the read-only helper handshake shown in Settings.
enum HelperHandshakePresentation: Equatable {
    case notRun, responding(version: Int), failed(code: String)
    var text: String {
        switch self {
        case .notRun: "Helper nie był jeszcze sprawdzany."
        case .responding(let version): "Helper odpowiada (protokół w wersji \(version))."
        case .failed(let code): "Helper nie odpowiada: \(code)."
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
    var allowsWhenResidualRoute = false
}

@MainActor protocol PresentationService {
    var scenario: String { get }
    var helper: HelperPresentationState { get }
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
    func preview(_ session: ActivitySession) -> String
    func registerHelper() -> HelperPresentationState
    func unregisterHelper() -> HelperPresentationState
    func verifyHelper() async -> HelperHandshakePresentation
    /// Read-only TCP connect to a device chosen by the user; the result carries codes only.
    func testDeviceConnection(host: String, port: UInt16) async -> OperationResult?
    func openHelperSettings()
}

extension PresentationService {
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
    @Published var lastResultText = String(localized: "no_result")
    @Published var nextStep = String(localized: "start_next")
    @Published var filter = "all"
    @Published var vpn: VPNAssessment = .init(state: .unknown, reasonCode: .stabilizationPending)
    @Published var vpnServices: VPNServiceStatus = .unknown
    @Published var disconnectBanner = false
    @Published var repairPhase = ""
    @Published var selectedSessionID: UUID?
    @Published var helperState: HelperPresentationState = .unavailable
    @Published var helperHandshake: HelperHandshakePresentation = .notRun
    @Published var deviceHost = ""
    @Published var devicePort = "445"
    @Published var deviceTestRunning = false
    @Published var deviceConnection: DeviceConnectionPresentation?
    private let service: any PresentationService
    private var task: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var candidateValue: RepairCandidatePresentation?
    @Published private(set) var candidates: [RepairCandidatePresentation] = []
    var helper: HelperPresentationState { helperState }
    var candidate: RepairCandidatePresentation? {
        vpn.state == .inactive || candidateValue?.allowsWhenResidualRoute == true ? candidateValue : nil
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
            return candidateValue?.allowsWhenResidualRoute == true ?
                "Wykryto trasy pozostałe po rozłączeniu VPN. Dostępna jest tylko naprawa dokładnie tych tras." :
                "VPN aktywny. Zmiany sieci są zablokowane."
        case .inactive: return "VPN nieaktywny. Możesz uruchomić diagnostykę."
        case .unknown:
            switch vpn.reasonCode {
            case .residualTunnel where vpnServices == .disconnected:
                return "Usługa VPN zgłasza rozłączenie, ale klient VPN zostawił nieaktywne interfejsy tunelowe. Zwykłe zmiany sieci są zablokowane."
            case .residualTunnel:
                return "Pozostał interfejs tunelowy, a stan usługi VPN jest nieznany. Zmiany sieci są zablokowane."
            case .pathTransition:
                return "Sieć właśnie się zmienia. Zmiany sieci są zablokowane do ponownej oceny."
            case .partialReadFailure, .incompleteSnapshot:
                return "Nie udało się w pełni odczytać stanu sieci. Zmiany sieci są zablokowane do ponownej oceny."
            case .conflictingSignals:
                return "Trasa lub resolver wskazuje nieobecny tunel. Zmiany sieci są zablokowane do ponownej oceny."
            default:
                return "Stan VPN niepewny. Zmiany sieci są zablokowane do ponownej oceny."
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
        if service.scenario == "production" {
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
        vpnServices = service.vpnServices
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
    func unregisterHelper() { helperState = service.unregisterHelper() }
    func verifyHelper() { Task { await verifyHelperNow() } }
    func testDeviceConnection() {
        guard !deviceTestRunning else { return }
        guard let port = DeviceConnectionInput.port(from: devicePort), DeviceConnectionInput.isValidHost(deviceHost) else {
            deviceConnection = .init(outcome: Self.outcomeTitle(.skipped), reason: DeviceConnectionReason.invalidInput.message,
                                     technicalDetail: "errorCode: invalidInput", symbol: "minus.circle")
            return
        }
        deviceTestRunning = true
        Task { [weak self] in
            guard let self else { return }
            let result = await service.testDeviceConnection(host: deviceHost, port: port)
            deviceTestRunning = false
            guard let result else { deviceConnection = nil; return }
            deviceConnection = Self.presentDevice(result)
            if service.scenario == "production" { await refreshSessions() }
        }
    }
    static func presentDevice(_ result: OperationResult) -> DeviceConnectionPresentation {
        let code = result.after.values[.errorCode] ?? result.error?.code ?? ""
        var reason = DeviceConnectionReason(rawValue: code)?.message ?? "Nie można ocenić wyniku."
        if result.after.values[.networkStatus] == "active" {
            reason += " Ruch do tego urządzenia idzie przez interfejs tunelowy."
        }
        if let families = Self.addressFamilyNote(result.after) { reason += " " + families }
        let evidence = result.after.values.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue): \($0.value)" }.joined(separator: " · ")
        return .init(outcome: outcomeTitle(result.outcome), reason: reason,
                     technicalDetail: "\(evidence) \(result.error.map { "\($0.domain)/\($0.code)" } ?? "")",
                     symbol: result.outcome == .success ? "checkmark.circle" : result.outcome == .skipped ? "minus.circle" : "exclamationmark.triangle")
    }
    /// Explains a split verdict: the device answers over one address family but not the other.
    static func addressFamilyNote(_ evidence: SafeEvidence) -> String? {
        let ipv4 = evidence.values[.ipv4Result].flatMap(DeviceConnectionReason.init(rawValue:))
        let ipv6 = evidence.values[.ipv6Result].flatMap(DeviceConnectionReason.init(rawValue:))
        func label(_ reason: DeviceConnectionReason) -> String {
            switch reason {
            case .reachable: "osiągalne"
            case .refused: "odrzucone"
            case .timedOut: "bez odpowiedzi"
            case .unreachable: "brak drogi"
            default: reason.rawValue
            }
        }
        switch (ipv4, ipv6) {
        case (.some(.reachable), .some(let v6)) where v6 != .reachable:
            return "Po IPv4 połączenie działa, po IPv6 nie (\(label(v6))): urządzenie rozgłasza adres IPv6, z którego ten komputer nie może skorzystać. Programy wybierające najpierw IPv6, w tym Finder, mogą zgłaszać błąd połączenia. Włącz IPv6 (Automatycznie) na tym komputerze albo na tamtym ustaw IPv6 na „Tylko lokalne łącze”."
        case (.some(let v4), .some(.reachable)) where v4 != .reachable:
            return "Po IPv6 połączenie działa, po IPv4 nie (\(label(v4))). Sprawdź adres IPv4 i maskę podsieci obu komputerów."
        case (.some(let v4), .some(let v6)):
            return "IPv4: \(label(v4)) · IPv6: \(label(v6))."
        case (.some, .none):
            return "Nazwa ma tylko adres IPv4."
        case (.none, .some):
            return "Nazwa ma tylko adres IPv6."
        case (.none, .none):
            return nil
        }
    }
    private func verifyHelperNow() async {
        helperHandshake = await service.verifyHelper()
        helperState = service.helper
    }
    func openHelperSettings() { service.openHelperSettings() }

    func startDiagnosis() {
        guard !isRunning else { return }
        task?.cancel()
        isRunning = true; progress = 0; state = .investigating; checks = []; candidateValue = nil; candidates = []
        repairPhase = ""
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
                vpnServices = service.vpnServices
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
        isRunning = true; repairPhase = "Ponowna ocena VPN i warunków"
        task = Task { [weak self] in
            guard let self else { return }
            vpn = await service.refreshVPN(stabilize: false)
            // The executor repeats this gate and records a structured skipped result.
            guard let result = await service.executeRepair(onPhase: { [weak self] phase, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    self.repairPhase = Self.phaseLabel(phase)
                }
            }) else {
                isRunning = false; repairPhase = ""; return
            }
            isRunning = false
            // The outcome is carried by the result text below; no raw phase name stays on screen.
            repairPhase = ""
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
        let failing = results.filter { $0.outcome == .failure || $0.outcome == .permissionDenied || $0.outcome == .timedOut }
        // Leftover tunnel devices after a confirmed disconnect are a nuisance, not an unknown network.
        let leftoverTunnels = failing.filter {
            $0.operationID == "interface_consistency" && $0.after.values[.errorCode] == NetworkCheckReason.orphanedTunnel.rawValue
        }
        let sharingFailures = failing.filter { $0.operationID == FileSharingReadinessCheck.checkID }
        let networkFailures = failing.count - leftoverTunnels.count - sharingFailures.count
        let vpnSettled = vpn.state == .inactive || residualTunnelOnly
        if vpnSettled, networkFailures == 0, leftoverTunnels.isEmpty || residualTunnelOnly, !sharingFailures.isEmpty {
            // The network works; only this Mac's own file sharing keeps other Macs from logging in.
            state = .serverNotReady
            lastResultText = String(localized: "result_sharing")
            nextStep = String(localized: "next_sharing")
        } else if residualTunnelOnly && networkFailures == 0 && sharingFailures.isEmpty {
            state = .residual
            lastResultText = String(localized: "result_residual")
            nextStep = String(localized: "next_residual")
        } else if vpn.state != .inactive {
            state = .unknown
            lastResultText = String(localized: "result_vpn_unknown")
            nextStep = String(localized: "next_vpn_unknown")
        } else {
            state = failing.isEmpty ? .healthy : .problem
            lastResultText = failing.isEmpty ? String(localized: "result_healthy") : String(localized: "result_problem")
            nextStep = failing.isEmpty ? String(localized: "next_healthy") : String(localized: "next_problem")
        }
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
        } else if let code, let sharing = FileSharingReason(rawValue: code) {
            sharing.message
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
    /// Plain-language labels for the executor's phase names shown while a repair runs.
    static func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "revalidate": "Ponowna walidacja diagnozy"
        case "fresh_vpn": "Świeża ocena VPN"
        case "vpn_gate": "Blokada VPN"
        case "before_snapshot": "Migawka stanu przed zmianą"
        case "helper_request": "Żądanie do helpera"
        case "read_only_retry": "Ponowienie sprawdzenia bez zmian"
        case "settle": "Oczekiwanie na ustabilizowanie"
        case "after_snapshot": "Migawka stanu po zmianie"
        case "recheck": "Ponowne sprawdzenie"
        case "result": "Wynik"
        default: phase
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
