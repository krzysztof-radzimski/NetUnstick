import XCTest
import NetUnstickCore
import NetUnstickNetwork
@testable import NetUnstick

@MainActor private final class TransitionPresentationService: PresentationService {
    let scenario = "production"
    let helper = HelperPresentationState.unavailable
    private(set) var calls: [Bool] = []
    func diagnose() async throws -> [OperationResult] { [] }
    func repairCandidate() -> RepairCandidatePresentation? { nil }
    func refreshVPN(stabilize: Bool) async -> VPNAssessment {
        calls.append(stabilize)
        return calls.count == 1 ? .init(state: .active, reasonCode: .tunnelPath) :
            .init(state: .inactive, reasonCode: .noVPNSignals)
    }
}

/// Checks pass, the VPN service reports disconnected, but the client left a tunnel device behind.
@MainActor private final class ResidualPresentationService: PresentationService {
    let scenario = "production"
    let helper = HelperPresentationState.available
    let vpnServices = VPNServiceStatus.disconnected
    func diagnose() async throws -> [OperationResult] {
        let now = Date()
        func result(_ id: String, _ reason: String, failure: Bool) -> OperationResult {
            try! OperationResult(operationID: id, name: id, kind: .diagnostic, startedAt: now, endedAt: now,
                outcome: failure ? .failure : .success,
                after: EvidenceSanitizer.sanitize([.errorCode: .errorCode(reason)]),
                error: failure ? try! OperationError(domain: "network_diagnosis", code: reason) : nil)
        }
        return [result("local_subnet_route", "healthy", failure: false),
                result("interface_consistency", "orphanedTunnel", failure: true)]
    }
    func repairCandidate() -> RepairCandidatePresentation? { nil }
    func refreshVPN(stabilize: Bool) async -> VPNAssessment { .init(state: .unknown, reasonCode: .residualTunnel) }
}

/// Every network check passes; only this Mac's file sharing rejects account logins. With `residual`
/// the VPN client also left a tunnel device behind, as on a Mac that just disconnected FortiClient.
@MainActor private final class SharingPresentationService: PresentationService {
    let scenario = "production"
    let helper = HelperPresentationState.available
    let vpnServices = VPNServiceStatus.disconnected
    private let residual: Bool
    private let code: String
    init(residual: Bool = false, code: String = FileSharingReason.accountNotEnabledForSMB.rawValue) {
        self.residual = residual; self.code = code
    }
    func diagnose() async throws -> [OperationResult] {
        let now = Date()
        func result(_ id: String, _ reason: String, failure: Bool) -> OperationResult {
            try! OperationResult(operationID: id, name: id, kind: .diagnostic, startedAt: now, endedAt: now,
                outcome: failure ? .failure : .success,
                after: EvidenceSanitizer.sanitize([.errorCode: .errorCode(reason)]),
                error: failure ? try! OperationError(domain: "file_sharing", code: reason) : nil)
        }
        return [result("local_subnet_route", "healthy", failure: false),
                result(FileSharingReadinessCheck.checkID, code, failure: true)] +
            (residual ? [result("interface_consistency", NetworkCheckReason.orphanedTunnel.rawValue, failure: true)] : [])
    }
    func repairCandidate() -> RepairCandidatePresentation? { nil }
    func refreshVPN(stabilize: Bool) async -> VPNAssessment {
        residual ? .init(state: .unknown, reasonCode: .residualTunnel) : .init(state: .inactive, reasonCode: .noVPNSignals)
    }
}

/// Real check IDs and outcomes from the host: LAN and internet work, but private
/// routes outside the LAN still reference a tunnel whose VPN service disconnected.
@MainActor private final class ResidualRoutesPresentationService: PresentationService {
    let scenario = "production"
    let helper = HelperPresentationState.available
    let vpnServices: VPNServiceStatus
    private let assessment: VPNAssessment
    private let before: [OperationResult]
    private let after: [OperationResult]
    private let repairOutcome: OperationOutcome
    private let offersRepair: Bool
    private let failsFollowUpDiagnosis: Bool
    private var repaired = false
    private var recordedSessions: [ActivitySession] = []
    private(set) var diagnosisCalls = 0
    private(set) var repairCalls = 0
    private(set) var repairSessionID: UUID?

    init(vpnServices: VPNServiceStatus = .disconnected,
         assessment: VPNAssessment = .init(state: .active, reasonCode: .tunnelRoute),
         before: [OperationResult]? = nil, after: [OperationResult]? = nil,
         offersRepair: Bool = false, repairOutcome: OperationOutcome = .success,
         failsFollowUpDiagnosis: Bool = false) {
        self.vpnServices = vpnServices; self.assessment = assessment
        self.before = before ?? Self.hostResults()
        self.after = after ?? Self.hostResults()
        self.offersRepair = offersRepair; self.repairOutcome = repairOutcome
        self.failsFollowUpDiagnosis = failsFollowUpDiagnosis
    }

    static func result(_ id: String, reason: String = NetworkCheckReason.healthy.rawValue,
                       outcome: OperationOutcome = .success) -> OperationResult {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let needsError = [.failure, .permissionDenied, .timedOut].contains(outcome)
        return try! OperationResult(operationID: id, name: id, kind: .diagnostic,
            startedAt: now, endedAt: now.addingTimeInterval(0.1), outcome: outcome,
            after: EvidenceSanitizer.sanitize([.errorCode: .errorCode(reason)]),
            error: needsError ? try! OperationError(domain: "network_diagnosis", code: reason) : nil)
    }

    static func hostResults() -> [OperationResult] {
        NetworkCheckKind.allCases.map {
            result($0.id, reason: $0 == .internetPath ? NetworkCheckReason.internetReachable.rawValue :
                NetworkCheckReason.healthy.rawValue)
        } + [
            result("local_multicast_path", reason: BonjourReason.inconclusive.rawValue, outcome: .skipped),
            result("bonjour_discovery", reason: BonjourReason.servicesFound.rawValue),
            result("bonjour_permission", reason: BonjourReason.inconclusive.rawValue, outcome: .skipped),
            result(FileSharingReadinessCheck.checkID, reason: FileSharingReason.guestRejected.rawValue),
            result(ContentFilterCheck.checkID, reason: ContentFilterReason.noFilter.rawValue)
        ]
    }

    func diagnose() async throws -> [OperationResult] {
        diagnosisCalls += 1
        if repaired, failsFollowUpDiagnosis {
            throw DiagnosisFailure.unavailable
        }
        let results = repaired ? after : before
        recordedSessions.append(ActivitySession(startedAt: Date(), appVersion: "test", macOSVersion: "14.0", entries: results))
        return results
    }
    private enum DiagnosisFailure: Error { case unavailable }
    func repairCandidate() -> RepairCandidatePresentation? {
        guard offersRepair, !repaired else { return nil }
        return .init(change: "Usuń pozostałe trasy LAN", reason: "Trasa lokalna prowadzi przez tunel",
                     resource: "Grupa tras lokalnych", impact: "Przywrócenie fizycznej ścieżki LAN",
                     permission: "Administrator", verification: "Ponowna kontrola lokalnej trasy",
                     allowsWhenResidualRoute: true)
    }
    func refreshVPN(stabilize: Bool) async -> VPNAssessment { assessment }
    func loadSessions() async throws -> [ActivitySession] { recordedSessions }
    func executeRepair(onPhase: @escaping @Sendable (String, OperationOutcome) -> Void) async -> OperationResult? {
        repairCalls += 1
        repaired = repairOutcome == .success
        let now = Date()
        let result = try! OperationResult(operationID: "repair.routes", name: "removeStaleTunnelRoutes", kind: .repair,
            startedAt: now, endedAt: now, outcome: repairOutcome,
            error: repairOutcome == .failure ? try! OperationError(domain: "repair", code: "recheck_failed") : nil,
            nextStep: "Sprawdź dostęp do urządzenia.")
        let session = ActivitySession(startedAt: now, appVersion: "test", macOSVersion: "14.0", entries: [result])
        recordedSessions.append(session)
        repairSessionID = session.id
        return result
    }
}

/// Intentionally ignores cancellation until the test releases each request. This
/// reproduces a late callback from a native probe without a long-running process.
@MainActor private final class ControlledDiagnosisPresentationService: PresentationService {
    let scenario = "production"
    let helper = HelperPresentationState.unavailable
    let vpnServices = VPNServiceStatus.disconnected
    private(set) var diagnosisCalls = 0
    private var callbacks: [Int: @Sendable (OperationResult, Int, Int) -> Void] = [:]
    private var pending: [Int: CheckedContinuation<[OperationResult], Never>] = [:]

    func diagnose() async throws -> [OperationResult] {
        try await diagnose(onCheck: { _, _, _ in })
    }
    func diagnose(onCheck: @escaping @Sendable (OperationResult, Int, Int) -> Void) async throws -> [OperationResult] {
        diagnosisCalls += 1
        let call = diagnosisCalls
        callbacks[call] = onCheck
        return await withCheckedContinuation { pending[call] = $0 }
    }
    func repairCandidate() -> RepairCandidatePresentation? { nil }
    func refreshVPN(stabilize: Bool) async -> VPNAssessment { .init(state: .inactive, reasonCode: .noVPNSignals) }
    func emit(call: Int, result: OperationResult) { callbacks[call]?(result, 1, DiagnosisEngine.checkCount) }
    func complete(call: Int, results: [OperationResult]) { pending.removeValue(forKey: call)?.resume(returning: results) }
    func completeAll() {
        let remaining = Array(pending.values)
        pending.removeAll()
        remaining.forEach { $0.resume(returning: []) }
    }
}

/// Stan helpera zmienia się wyłącznie po jawnej rejestracji; fixture nie wykonuje
/// żadnej operacji uprzywilejowanej ani automatycznej naprawy.
@MainActor private final class HelperRequirementPresentationService: PresentationService {
    let scenario = "production"
    var helper: HelperPresentationState
    let vpnServices = VPNServiceStatus.disconnected
    private let requiresHelper: Bool
    private let registrationResult: HelperPresentationState
    var verificationResult: HelperHandshakePresentation
    private var pauseVerificationAfterRegistration: Bool
    private var pendingVerification: CheckedContinuation<HelperHandshakePresentation, Never>?
    private var repaired = false
    private(set) var registerCalls = 0
    private(set) var repairCalls = 0
    private(set) var verifyCalls = 0
    var verificationWaiting: Bool { pendingVerification != nil }

    init(helper: HelperPresentationState, requiresHelper: Bool = true,
         registrationResult: HelperPresentationState = .available,
         verificationResult: HelperHandshakePresentation = .responding(version: 2),
         pauseVerificationAfterRegistration: Bool = false) {
        self.helper = helper
        self.requiresHelper = requiresHelper
        self.registrationResult = registrationResult
        self.verificationResult = verificationResult
        self.pauseVerificationAfterRegistration = pauseVerificationAfterRegistration
    }

    func diagnose() async throws -> [OperationResult] {
        if repaired { return ResidualRoutesPresentationService.hostResults() }
        return [ResidualRoutesPresentationService.result(NetworkCheckKind.physicalLink.id,
            reason: NetworkCheckReason.noAddressLease.rawValue, outcome: .failure)]
    }
    func repairCandidate() -> RepairCandidatePresentation? {
        guard !repaired else { return nil }
        return .init(change: "Wybrana naprawa", reason: "Brak adresacji fizycznego interfejsu",
                     resource: "Jeden interfejs", impact: "Jawna operacja użytkownika",
                     permission: "Opis uprawnień nie steruje walidacją", verification: "Ponowny check",
                     requiresHelper: requiresHelper)
    }
    func refreshVPN(stabilize: Bool) async -> VPNAssessment { .init(state: .inactive, reasonCode: .noVPNSignals) }
    func registerHelper() -> HelperPresentationState {
        registerCalls += 1
        helper = registrationResult
        return helper
    }
    func verifyHelper() async -> HelperHandshakePresentation {
        verifyCalls += 1
        if registerCalls > 0, pauseVerificationAfterRegistration {
            return await withCheckedContinuation { pendingVerification = $0 }
        }
        return verificationResult
    }
    func completeVerification() {
        pauseVerificationAfterRegistration = false
        let continuation = pendingVerification
        pendingVerification = nil
        continuation?.resume(returning: verificationResult)
    }
    func executeRepair(onPhase: @escaping @Sendable (String, OperationOutcome) -> Void) async -> OperationResult? {
        repairCalls += 1
        repaired = true
        let now = Date()
        return try! OperationResult(operationID: "repair.helper_requirement", name: "fixtureRepair", kind: .repair,
            startedAt: now, endedAt: now, outcome: .success)
    }
}

@MainActor final class PresentationStoreTests: XCTestCase {
    private func settle(_ store: PresentationStore) async {
        for _ in 0..<30 {
            if !store.isRunning { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    private func settleHelper(_ store: PresentationStore) async {
        for _ in 0..<30 {
            if !store.helperSetupRunning { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.helperSetupRunning, "Przygotowanie helpera nie zakończyło się w czasie fixture")
    }

    func testMockDiagnosisDisplaysStructuredOutcomes() async throws {
        let store = PresentationStore(service: MockPresentationService(scenario: "healthy"))
        await settle(store)
        XCTAssertEqual(store.state, .healthy)
        XCTAssertEqual(store.checks.count, 4)
        XCTAssertEqual(store.sessions.last?.entries.count, 4)
        XCTAssertNil(store.candidate)
    }

    func testVPNStatesBlockRepairAtClick() async throws {
        for scenario in ["vpn-active", "vpn-unknown"] {
            let store = PresentationStore(service: MockPresentationService(scenario: scenario))
            await settle(store)
            XCTAssertEqual(store.state, .unknown)
            XCTAssertNil(store.candidate)
            XCTAssertNotEqual(store.vpn.state, .inactive)
        }
    }

    func testPrivilegedRepairPreflightPreservesCandidateUntilHelperIsAvailable() async throws {
        for status in [HelperPresentationState.unavailable, .approvalRequired, .denied] {
            let service = HelperRequirementPresentationService(helper: status)
            let store = PresentationStore(service: service)
            store.startDiagnosis()
            await settle(store)
            await settleHelper(store)
            let candidate = try XCTUnwrap(store.candidate)
            XCTAssertTrue(candidate.requiresHelper)
            XCTAssertFalse(store.canConfirmRepair, "helper=\(status.rawValue)")

            store.confirmRepair()
            await settle(store)

            XCTAssertEqual(service.repairCalls, 0, "Brak helpera ma zatrzymać żądanie przed executorem")
            XCTAssertEqual(service.registerCalls, 0, "Próba naprawy nie rejestruje helpera automatycznie")
            XCTAssertEqual(store.helper, status)
            XCTAssertEqual(store.candidate?.change, candidate.change)
            XCTAssertEqual(store.candidates.count, 1, "Kandydat musi zostać dostępny po rozwiązaniu problemu uprawnień")
            XCTAssertFalse(store.canConfirmRepair)
            XCTAssertFalse(store.isRunning)
            let explanation = (store.lastResultText + " " + store.nextStep).lowercased()
            XCTAssertTrue(explanation.contains("helper"), explanation)
            XCTAssertTrue(["rejestr", "zatwierd", "zgod"].contains(where: explanation.contains), explanation)
            XCTAssertFalse(store.lastResultText.contains("Naprawiono"))
        }
    }

    func testExplicitHelperRegistrationUnlocksRepairWithoutStartingIt() async throws {
        let service = HelperRequirementPresentationService(helper: .unavailable)
        let store = PresentationStore(service: service)
        store.startDiagnosis()
        await settle(store)
        await settleHelper(store)
        let candidate = try XCTUnwrap(store.candidate)
        XCTAssertFalse(store.canConfirmRepair)

        store.registerHelper()

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(store.helper, .available)
        XCTAssertTrue(store.helperSetupRunning, "Rejestracja nie dowodzi jeszcze odpowiedzi helpera")
        XCTAssertFalse(store.canConfirmRepair)
        await settleHelper(store)
        XCTAssertEqual(store.helperHandshake, .responding(version: 2))
        XCTAssertTrue(store.canConfirmRepair)
        XCTAssertEqual(store.candidate?.change, candidate.change)
        XCTAssertEqual(service.repairCalls, 0, "Rejestracja helpera nie jest potwierdzeniem naprawy")
        XCTAssertFalse(store.isRunning)

        store.confirmRepair()
        await settle(store)
        XCTAssertEqual(service.repairCalls, 1, "Dopiero osobne potwierdzenie wykonuje naprawę")
        XCTAssertEqual(service.registerCalls, 1)
    }

    func testRegisteredHelperStillAwaitingSystemApprovalKeepsRepairBlocked() async throws {
        let service = HelperRequirementPresentationService(helper: .unavailable, registrationResult: .approvalRequired)
        let store = PresentationStore(service: service)
        store.startDiagnosis()
        await settle(store)
        await settleHelper(store)
        let candidate = try XCTUnwrap(store.candidate)

        store.registerHelper()
        await settleHelper(store)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(store.helper, .approvalRequired)
        XCTAssertFalse(store.canConfirmRepair)
        XCTAssertEqual(store.candidate?.change, candidate.change)
        XCTAssertEqual(service.repairCalls, 0)
        store.confirmRepair()
        await settle(store)
        XCTAssertEqual(service.repairCalls, 0)
        XCTAssertNotNil(store.candidate)
    }

    func testReadOnlyRepairDoesNotRequireHelperOrImplicitRegistration() async throws {
        let service = HelperRequirementPresentationService(helper: .unavailable, requiresHelper: false)
        let store = PresentationStore(service: service)
        store.startDiagnosis()
        await settle(store)
        await settleHelper(store)
        let candidate = try XCTUnwrap(store.candidate)
        XCTAssertFalse(candidate.requiresHelper)
        XCTAssertTrue(store.canConfirmRepair)

        store.confirmRepair()
        await settle(store)

        XCTAssertEqual(service.repairCalls, 1)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(store.helper, .unavailable)
        XCTAssertTrue(store.lastResultText.contains("Naprawiono"))
    }

    func testFailedHelperHandshakeBlocksRepairDespiteEnabledRegistration() async throws {
        let service = HelperRequirementPresentationService(helper: .available,
            verificationResult: .failed(code: "launch_constraint_violation"))
        let store = PresentationStore(service: service)
        store.startDiagnosis()
        await settle(store)
        await settleHelper(store)
        let candidate = try XCTUnwrap(store.candidate)

        store.verifyHelper()
        await settleHelper(store)

        XCTAssertEqual(store.helper, .available, "Sam status rejestracji może wyglądać poprawnie po zmianie podpisu")
        XCTAssertEqual(store.helperHandshake, .failed(code: "launch_constraint_violation"))
        XCTAssertFalse(store.canConfirmRepair)
        store.confirmRepair()
        await settle(store)
        XCTAssertEqual(service.repairCalls, 0)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(store.candidate?.change, candidate.change)
        XCTAssertFalse(store.isRunning)

        service.verificationResult = .responding(version: 2)
        store.verifyHelper()
        await settleHelper(store)
        XCTAssertTrue(store.canConfirmRepair)
        XCTAssertEqual(service.repairCalls, 0, "Udany handshake również nie potwierdza naprawy za użytkownika")
    }

    func testHelperPreparationBlocksRepairUntilVerifiedResponseArrives() async throws {
        let service = HelperRequirementPresentationService(helper: .unavailable, pauseVerificationAfterRegistration: true)
        let store = PresentationStore(service: service)
        defer { service.completeVerification() }
        store.startDiagnosis()
        await settle(store)
        await settleHelper(store)
        let candidate = try XCTUnwrap(store.candidate)

        store.registerHelper()

        XCTAssertTrue(store.helperSetupRunning)
        XCTAssertEqual(store.helper, .available)
        XCTAssertFalse(store.canConfirmRepair)
        for _ in 0..<30 {
            if service.verificationWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(service.verificationWaiting)
        store.confirmRepair()
        XCTAssertEqual(service.repairCalls, 0, "Dostępna rejestracja bez odpowiedzi procesu nie wystarcza do naprawy")
        XCTAssertTrue(store.helperSetupRunning)
        XCTAssertEqual(store.candidate?.change, candidate.change)

        service.completeVerification()
        await settleHelper(store)

        XCTAssertEqual(store.helperHandshake, .responding(version: 2))
        XCTAssertFalse(store.helperSetupRunning)
        XCTAssertTrue(store.canConfirmRepair)
        XCTAssertEqual(service.repairCalls, 0)
    }

    func testLeftoverTunnelAfterConfirmedDisconnectIsNotAnUnknownNetwork() async throws {
        let store = PresentationStore(service: ResidualPresentationService())
        store.startDiagnosis()
        await settle(store)
        XCTAssertEqual(store.state, .residual)
        XCTAssertTrue(store.lastResultText.contains("tunelowe") || store.lastResultText.contains("tunnel"))
        XCTAssertTrue(store.vpnStatus.contains("rozłączenie"))
        XCTAssertNil(store.candidate)
        XCTAssertTrue(store.repairPhase.isEmpty)
        // Any other failing check keeps the conservative unknown presentation.
        let unknown = PresentationStore(service: MockPresentationService(scenario: "vpn-unknown"))
        await settle(unknown)
        XCTAssertEqual(unknown.state, .unknown)
    }

    func testHealthyLANAndInternetWithDisconnectedVPNRoutesKeepRepairsBlocked() async {
        let service = ResidualRoutesPresentationService()
        let store = PresentationStore(service: service)
        store.startDiagnosis()
        await settle(store)
        XCTAssertEqual(store.state, .residualRoutes)
        XCTAssertEqual(store.checks.count, DiagnosisEngine.checkCount)
        XCTAssertEqual(store.vpn, .init(state: .active, reasonCode: .tunnelRoute))
        XCTAssertFalse(store.vpn.permitsNetworkChange, "Healthy connectivity must not relax the repair gate")
        XCTAssertNil(store.candidate)
        XCTAssertFalse(store.lastResultText.contains("niejednoznaczny"))
        XCTAssertFalse(store.lastResultText.contains("nie pozwala"))
    }

    func testWorkingChecksCannotConfirmNetworkWithConnectedOrUnknownVPNService() async {
        for status in [VPNServiceStatus.connected, .unknown] {
            let store = PresentationStore(service: ResidualRoutesPresentationService(vpnServices: status))
            store.startDiagnosis()
            await settle(store)
            XCTAssertEqual(store.state, .unknown, "service=\(status.rawValue)")
            XCTAssertFalse(store.vpn.permitsNetworkChange)
        }
        for assessment in [VPNAssessment(state: .unknown, reasonCode: .conflictingSignals),
                           .init(state: .active, reasonCode: .tunnelPath),
                           .init(state: .active, reasonCode: .tunnelDNS)] {
            let store = PresentationStore(service: ResidualRoutesPresentationService(assessment: assessment))
            store.startDiagnosis()
            await settle(store)
            XCTAssertEqual(store.state, .unknown, "reason=\(assessment.reasonCode.rawValue)")
            XCTAssertFalse(store.vpn.permitsNetworkChange)
        }
    }

    func testEachBasicCheckMustPassBeforeShowingHealthyConnectivityWithResidualRoutes() async {
        for kind in NetworkCheckKind.allCases {
            for outcome in [OperationOutcome.skipped, .cancelled] {
                let results = ResidualRoutesPresentationService.hostResults().map {
                    $0.operationID == kind.id ? ResidualRoutesPresentationService.result(kind.id,
                        reason: NetworkCheckReason.dataIncomplete.rawValue, outcome: outcome) : $0
                }
                let store = PresentationStore(service: ResidualRoutesPresentationService(before: results))
                store.startDiagnosis()
                await settle(store)
                XCTAssertEqual(store.state, .unknown, "\(kind.id)=\(outcome.rawValue)")
            }
            let missing = ResidualRoutesPresentationService.hostResults().filter { $0.operationID != kind.id }
            let store = PresentationStore(service: ResidualRoutesPresentationService(before: missing))
            store.startDiagnosis()
            await settle(store)
            XCTAssertEqual(store.state, .unknown, "missing=\(kind.id)")
        }
    }

    func testRealLANFailureAfterVPNDisconnectIsShownAsAProblem() async throws {
        let results = ResidualRoutesPresentationService.hostResults().map {
            $0.operationID == NetworkCheckKind.localSubnetRoute.id ? ResidualRoutesPresentationService.result($0.operationID,
                reason: NetworkCheckReason.localRouteViaTunnel.rawValue, outcome: .failure) : $0
        }
        let store = PresentationStore(service: ResidualRoutesPresentationService(before: results))
        store.startDiagnosis()
        await settle(store)
        XCTAssertEqual(store.state, .problem)
        XCTAssertFalse(store.vpn.permitsNetworkChange)
        let route = try XCTUnwrap(store.checks.first { $0.id == NetworkCheckKind.localSubnetRoute.id })
        XCTAssertEqual(route.reason, NetworkCheckReason.localRouteViaTunnel.message)
        XCTAssertTrue(route.technicalDetail.contains(NetworkCheckReason.localRouteViaTunnel.rawValue))
    }

    func testSharingAndBonjourFailuresPreventHealthyResidualRouteSummary() async {
        for failure in [ResidualRoutesPresentationService.result(FileSharingReadinessCheck.checkID,
                            reason: FileSharingReason.noLoginMethod.rawValue, outcome: .failure),
                        ResidualRoutesPresentationService.result("bonjour_permission",
                            reason: BonjourReason.permissionDenied.rawValue, outcome: .permissionDenied)] {
            let results = ResidualRoutesPresentationService.hostResults().map {
                $0.operationID == failure.operationID ? failure : $0
            }
            let store = PresentationStore(service: ResidualRoutesPresentationService(before: results))
            store.startDiagnosis()
            await settle(store)
            XCTAssertNotEqual(store.state, .residualRoutes)
            XCTAssertNotEqual(store.state, .healthy)
            XCTAssertFalse(store.vpn.permitsNetworkChange)
        }
    }

    func testSuccessfulRepairRefreshesDiagnosisAndKeepsItsSessionSelected() async throws {
        let before = ResidualRoutesPresentationService.hostResults().map {
            $0.operationID == NetworkCheckKind.localSubnetRoute.id ? ResidualRoutesPresentationService.result($0.operationID,
                reason: NetworkCheckReason.localRouteViaTunnel.rawValue, outcome: .failure) : $0
        }
        let service = ResidualRoutesPresentationService(before: before, offersRepair: true)
        let store = PresentationStore(service: service)
        store.startDiagnosis()
        await settle(store)
        XCTAssertEqual(store.state, .problem)
        XCTAssertNotNil(store.candidate)

        store.confirmRepair()
        await settle(store)
        XCTAssertEqual(service.repairCalls, 1)
        XCTAssertEqual(service.diagnosisCalls, 2, "A successful scoped recheck must refresh the full dashboard")
        XCTAssertEqual(store.state, .residualRoutes)
        let route = try XCTUnwrap(store.checks.first { $0.id == NetworkCheckKind.localSubnetRoute.id })
        XCTAssertNil(route.reason)
        XCTAssertTrue(route.technicalDetail.contains(NetworkCheckReason.healthy.rawValue))
        XCTAssertNil(store.candidate)
        XCTAssertTrue(store.candidates.isEmpty)
        XCTAssertTrue(store.lastResultText.hasPrefix("Naprawiono"))
        XCTAssertFalse(store.vpn.permitsNetworkChange)
        XCTAssertEqual(store.selectedSessionID, service.repairSessionID)
        let repair = try XCTUnwrap(store.sessions.first { $0.id == service.repairSessionID })
        XCTAssertEqual(repair.entries.last?.outcome, .success)
        XCTAssertEqual(repair.entries.last?.kind, .repair)
        XCTAssertTrue(store.repairPhase.isEmpty)
    }

    func testFailedRepairDoesNotRerunDiagnosisOrReplaceTheFailure() async {
        let before = ResidualRoutesPresentationService.hostResults().map {
            $0.operationID == NetworkCheckKind.localSubnetRoute.id ? ResidualRoutesPresentationService.result($0.operationID,
                reason: NetworkCheckReason.localRouteViaTunnel.rawValue, outcome: .failure) : $0
        }
        let service = ResidualRoutesPresentationService(before: before, offersRepair: true, repairOutcome: .failure)
        let store = PresentationStore(service: service)
        store.startDiagnosis()
        await settle(store)
        store.confirmRepair()
        await settle(store)
        XCTAssertEqual(service.diagnosisCalls, 1)
        XCTAssertEqual(store.state, .problem)
        XCTAssertFalse(store.lastResultText.contains("Naprawiono"))
        XCTAssertTrue(store.lastResultText.contains("recheck_failed"))
        XCTAssertEqual(store.sessions.last?.entries.last?.outcome, .failure)
        XCTAssertNil(store.candidate)
    }

    func testVerifiedRepairWithFailedFullDiagnosisKeepsOverallStateUnknown() async throws {
        let before = ResidualRoutesPresentationService.hostResults().map {
            $0.operationID == NetworkCheckKind.localSubnetRoute.id ? ResidualRoutesPresentationService.result($0.operationID,
                reason: NetworkCheckReason.localRouteViaTunnel.rawValue, outcome: .failure) : $0
        }
        let service = ResidualRoutesPresentationService(before: before, offersRepair: true, failsFollowUpDiagnosis: true)
        let store = PresentationStore(service: service)
        store.startDiagnosis()
        await settle(store)
        store.confirmRepair()
        await settle(store)

        XCTAssertEqual(service.repairCalls, 1)
        XCTAssertEqual(service.diagnosisCalls, 2)
        XCTAssertEqual(store.state, .unknown, "A successful scoped recheck cannot replace the missing overall diagnosis")
        XCTAssertTrue(store.lastResultText.contains("Naprawiono wskazany problem"))
        XCTAssertTrue(store.lastResultText.contains("pełnej diagnozy"))
        XCTAssertTrue(store.nextStep.contains("ponownie"))
        XCTAssertTrue(store.checks.isEmpty)
        XCTAssertNil(store.candidate)
        XCTAssertFalse(store.isRunning)
        XCTAssertTrue(store.repairPhase.isEmpty)
        XCTAssertFalse(store.vpn.permitsNetworkChange)
        XCTAssertEqual(store.selectedSessionID, service.repairSessionID)
        let repair = try XCTUnwrap(store.sessions.first { $0.id == service.repairSessionID })
        XCTAssertEqual(repair.entries.last?.outcome, .success, "The separately verified repair remains in the journal")
    }

    func testCancelledDiagnosisCannotPublishLateProgressOrStopItsReplacement() async throws {
        let service = ControlledDiagnosisPresentationService()
        let store = PresentationStore(service: service)
        defer { service.completeAll(); store.cancel() }
        store.startDiagnosis()
        for _ in 0..<30 {
            if service.diagnosisCalls == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard service.diagnosisCalls == 1 else { return XCTFail("First diagnosis did not reach the controlled probe") }
        store.cancel()
        store.startDiagnosis()
        for _ in 0..<30 {
            if service.diagnosisCalls == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard service.diagnosisCalls == 2 else { return XCTFail("Replacement diagnosis did not reach the controlled probe") }

        let oldFailure = ResidualRoutesPresentationService.result(NetworkCheckKind.localSubnetRoute.id,
            reason: NetworkCheckReason.localRouteViaTunnel.rawValue, outcome: .failure)
        service.emit(call: 1, result: oldFailure)
        service.complete(call: 1, results: [oldFailure])
        // Let the stale MainActor callback and completed old task reach their guards.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(store.isRunning, "The cancelled task must not stop its replacement")
        XCTAssertEqual(store.state, .investigating)
        XCTAssertEqual(store.progress, 0)
        XCTAssertTrue(store.checks.isEmpty, "Late results from the previous generation must be discarded")

        service.complete(call: 2, results: ResidualRoutesPresentationService.hostResults())
        await settle(store)
        XCTAssertEqual(store.state, .healthy)
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.checks.count, DiagnosisEngine.checkCount)
        XCTAssertFalse(store.checks.contains { $0.technicalDetail.contains(NetworkCheckReason.localRouteViaTunnel.rawValue) })
    }

    func testAccountWithoutSMBPasswordIsAServerSettingNotANetworkFault() async throws {
        for residual in [false, true] {
            let store = PresentationStore(service: SharingPresentationService(residual: residual))
            store.startDiagnosis()
            await settle(store)
            XCTAssertEqual(store.state, .serverNotReady, "residual=\(residual)")
            XCTAssertTrue(store.lastResultText.contains("SMB"))
            XCTAssertTrue(store.nextStep.contains("Udostępnianie") || store.nextStep.contains("Sharing"))
            XCTAssertNil(store.candidate)
            let check = try XCTUnwrap(store.checks.first { $0.id == FileSharingReadinessCheck.checkID })
            XCTAssertEqual(check.reason, FileSharingReason.accountNotEnabledForSMB.message)
            XCTAssertTrue(check.technicalDetail.contains("file_sharing/accountNotEnabledForSMB"))
        }
        // Guest rejected as well: the headline names both missing login methods.
        let noLogin = PresentationStore(service: SharingPresentationService(code: FileSharingReason.noLoginMethod.rawValue))
        noLogin.startDiagnosis()
        await settle(noLogin)
        XCTAssertEqual(noLogin.state, .serverNotReady)
        XCTAssertTrue(noLogin.lastResultText.contains("gościa") || noLogin.lastResultText.contains("guest"), noLogin.lastResultText)
        XCTAssertTrue(noLogin.nextStep.contains("Gość") || noLogin.nextStep.contains("Guest"), noLogin.nextStep)
        // A genuine network failure next to the sharing failure keeps the conservative presentation.
        let unknown = PresentationStore(service: MockPresentationService(scenario: "vpn-unknown"))
        await settle(unknown)
        XCTAssertEqual(unknown.state, .unknown)
    }

    func testSMBSessionVerdictNamesTheSideThatBlocks() throws {
        let firewall = EvidenceSanitizer.sanitize([.errorCode: .errorCode("reachable"), .smbResult: .errorCode("sessionFailed"),
                                                   .firewallStatus: .status(.active), .contentFilterStatus: .status(.active)])
        let note = try XCTUnwrap(PresentationStore.smbSessionNote(firewall))
        XCTAssertTrue(note.contains("protocol_vers_map=2") && note.contains("SMB 3"), note)
        XCTAssertTrue(note.contains("filtr treści"), "an active filter is mentioned only as a secondary note")
        let plain = EvidenceSanitizer.sanitize([.smbResult: .errorCode("sessionFailed"), .firewallStatus: .status(.inactive),
                                                .contentFilterStatus: .status(.inactive)])
        let plainNote = try XCTUnwrap(PresentationStore.smbSessionNote(plain))
        XCTAssertTrue(plainNote.contains("protocol_vers_map=2") && !plainNote.contains("filtr treści"), plainNote)
        XCTAssertTrue(try XCTUnwrap(PresentationStore.smbSessionNote(EvidenceSanitizer.sanitize([.smbResult: .errorCode("otherExit")]))).contains("smbutil"))
        let login = EvidenceSanitizer.sanitize([.smbResult: .errorCode("authRejected")])
        XCTAssertTrue(try XCTUnwrap(PresentationStore.smbSessionNote(login)).contains("Połącz jako"))
        XCTAssertNil(PresentationStore.smbSessionNote(SafeEvidence.empty))
        let now = Date()
        let result = try OperationResult(operationID: "device_connection", name: "device_connection", kind: .diagnostic,
                                         startedAt: now, endedAt: now, outcome: .failure, after: firewall,
                                         error: OperationError(domain: "device_connection", code: "smbSessionFailed"))
        let presentation = PresentationStore.presentDevice(result)
        XCTAssertTrue(presentation.reason.contains("Urządzenie przyjęło połączenie"), presentation.reason)
        XCTAssertTrue(presentation.reason.contains("sesja SMB nie została wynegocjowana"), presentation.reason)
        XCTAssertTrue(presentation.technicalDetail.contains("smbResult: sessionFailed"))
    }

    func testSplitAddressFamilyVerdictIsExplained() throws {
        let mixed = EvidenceSanitizer.sanitize([.ipv4Result: .errorCode("reachable"), .ipv6Result: .errorCode("unreachable"),
                                                .errorCode: .errorCode("reachable"), .networkStatus: .status(.inactive)])
        let note = try XCTUnwrap(PresentationStore.addressFamilyNote(mixed))
        XCTAssertTrue(note.contains("IPv6") && note.contains("Finder"), note)
        XCTAssertEqual(PresentationStore.addressFamilyNote(EvidenceSanitizer.sanitize([.ipv4Result: .errorCode("refused")])), "Nazwa ma tylko adres IPv4.")
        XCTAssertNil(PresentationStore.addressFamilyNote(SafeEvidence.empty))
        let now = Date()
        let result = try OperationResult(operationID: "device_connection", name: "device_connection", kind: .diagnostic,
                                         startedAt: now, endedAt: now, outcome: .success, after: mixed)
        let presentation = PresentationStore.presentDevice(result)
        XCTAssertTrue(presentation.reason.contains("Po IPv4"), presentation.reason)
        XCTAssertTrue(presentation.technicalDetail.contains("ipv6Result: unreachable"))
    }

    func testDeviceConnectionTestPublishesOutcomeWithoutTheHost() async throws {
        @MainActor final class DeviceService: PresentationService {
            let scenario = "production"
            let helper = HelperPresentationState.unavailable
            private(set) var received: [(String, UInt16)] = []
            func diagnose() async throws -> [OperationResult] { [] }
            func repairCandidate() -> RepairCandidatePresentation? { nil }
            func refreshVPN(stabilize: Bool) async -> VPNAssessment { .init(state: .inactive, reasonCode: .noVPNSignals) }
            func testDeviceConnection(host: String, port: UInt16) async -> OperationResult? {
                received.append((host, port))
                let now = Date()
                return try? OperationResult(operationID: "device_connection", name: "device_connection", kind: .diagnostic,
                    startedAt: now, endedAt: now, outcome: .failure,
                    after: EvidenceSanitizer.sanitize([.errorCode: .errorCode("refused"), .interfaceType: .interfaceType(.wifi), .networkStatus: .status(.inactive)]),
                    error: OperationError(domain: "device_connection", code: "refused"))
            }
        }
        let service = DeviceService()
        let store = PresentationStore(service: service)
        store.deviceHost = "nas.example.internal"
        store.devicePort = "445"
        store.testDeviceConnection()
        for _ in 0..<30 where store.deviceConnection == nil || store.deviceTestRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        let presentation = try XCTUnwrap(store.deviceConnection)
        XCTAssertEqual(service.received.first?.0, "nas.example.internal")
        XCTAssertEqual(service.received.first?.1, 445)
        XCTAssertTrue(presentation.reason.contains("odrzuca") || presentation.reason.contains("refuses"))
        XCTAssertFalse(presentation.technicalDetail.contains("nas.example"))
        XCTAssertTrue(presentation.technicalDetail.contains("refused"))
        store.deviceHost = "not valid host"
        store.testDeviceConnection()
        XCTAssertEqual(store.deviceConnection?.technicalDetail, "errorCode: invalidInput")
        XCTAssertEqual(service.received.count, 1, "Invalid input never reaches the probe")
    }

    func testCancellationHasDistinctSessionOutcome() {
        let store = PresentationStore(service: MockPresentationService(scenario: "operation-progress"))
        XCTAssertTrue(store.isRunning)
        store.cancel()
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.sessions.last?.entries.last?.outcome, .cancelled)
    }

    func testSuccessAndExitZeroWithoutImprovementHaveDifferentUIResults() async {
        for (scenario, outcome) in [("repair-success", OperationOutcome.success), ("repair-failure", .failure)] {
            let store = PresentationStore(service: MockPresentationService(scenario: scenario))
            await settle(store)
            XCTAssertNotNil(store.candidate)
            store.confirmRepair()
            await settle(store)
            XCTAssertEqual(store.sessions.last?.entries.last?.outcome, outcome)
            XCTAssertEqual(store.lastResultText.contains("Naprawiono"), outcome == .success)
        }
    }

    func testStableVPNDisconnectShowsBannerWithoutAutomaticDiagnosis() async throws {
        let service = TransitionPresentationService()
        let store = PresentationStore(service: service)
        for _ in 0..<45 where !store.disconnectBanner {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(store.disconnectBanner)
        XCTAssertEqual(service.calls.prefix(2).map { $0 }, [false, true])
        XCTAssertTrue(store.checks.isEmpty)
        XCTAssertTrue(store.sessions.isEmpty)
    }
}
