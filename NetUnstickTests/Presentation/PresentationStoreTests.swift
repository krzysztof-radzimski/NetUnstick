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

@MainActor final class PresentationStoreTests: XCTestCase {
    private func settle(_ store: PresentationStore) async {
        for _ in 0..<30 {
            if !store.isRunning { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
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
