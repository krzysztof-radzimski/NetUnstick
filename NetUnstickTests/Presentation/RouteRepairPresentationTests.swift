import XCTest
import NetUnstickCore
import NetUnstickNetwork
@testable import NetUnstick

/// The reported combination: routing failures collected during a VPN transition,
/// followed by an inactive VPN observation, with no executable route plan yet.
@MainActor private final class RouteRecheckService: PresentationService {
    let scenario = "production"
    let helper = HelperPresentationState.available
    let vpnServices = VPNServiceStatus.disconnected
    let assessment: VPNAssessment
    let settlesOnRetry: Bool
    let hasRouteFailure: Bool
    private(set) var diagnosisCalls = 0
    private(set) var repairCalls = 0

    init(vpn: VPNAssessment = .init(state: .inactive, reasonCode: .noVPNSignals),
         settlesOnRetry: Bool = false, hasRouteFailure: Bool = true) {
        assessment = vpn; self.settlesOnRetry = settlesOnRetry; self.hasRouteFailure = hasRouteFailure
    }

    func diagnose() async throws -> [OperationResult] {
        diagnosisCalls += 1
        let settled = settlesOnRetry && diagnosisCalls > 1
        let now = Date()
        func check(_ kind: NetworkCheckKind, _ code: NetworkCheckReason, fails: Bool) -> OperationResult {
            try! OperationResult(operationID: kind.id, name: kind.id, kind: .diagnostic,
                startedAt: now, endedAt: now, outcome: fails ? .failure : .success,
                after: EvidenceSanitizer.sanitize([.errorCode: .errorCode(code.rawValue)]),
                error: fails ? try! OperationError(domain: "network_diagnosis", code: code.rawValue) : nil)
        }
        return [
            check(.defaultRoute, settled ? .healthy : .residualDefaultRoute, fails: !settled),
            check(.localSubnetRoute, hasRouteFailure ? .localRouteViaTunnel : .healthy, fails: hasRouteFailure),
            check(.interfaceConsistency, settled ? .healthy : .unstableAfterDisconnect, fails: !settled)
        ]
    }
    func repairCandidate() -> RepairCandidatePresentation? {
        guard settlesOnRetry, diagnosisCalls > 1 else { return nil }
        return .init(change: "Validated LAN routes", reason: "localRouteViaTunnel", resource: "Exact route set",
            impact: "LAN only", permission: "Helper required", verification: "Fresh local-route check",
            allowsWhenResidualRoute: true, requiresHelper: true)
    }
    func refreshVPN(stabilize: Bool) async -> VPNAssessment { assessment }
    func executeRepair(onPhase: @escaping @Sendable (String, OperationOutcome) -> Void) async -> OperationResult? {
        repairCalls += 1
        return nil
    }
}

@MainActor final class RouteRepairPresentationTests: XCTestCase {
    private func diagnose(_ store: PresentationStore) async {
        store.startDiagnosis()
        for _ in 0..<100 {
            if !store.isRunning { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isRunning)
    }

    func testReportedTransitionKeepsRoutePanelWithoutInventingExecutablePlan() async {
        let service = RouteRecheckService()
        let store = PresentationStore(service: service)
        await diagnose(store)

        XCTAssertEqual(store.state, .problem)
        XCTAssertEqual(store.vpn.state, .inactive)
        XCTAssertTrue(store.routeRepairNeedsRecheck)
        XCTAssertEqual(store.checks.first { $0.id == "local_subnet_route" }?.reasonCode, "localRouteViaTunnel")
        XCTAssertNil(store.candidate)
        XCTAssertFalse(store.canConfirmRepair)
        store.confirmRepair()
        XCTAssertEqual(service.repairCalls, 0)
    }

    func testExplicitRecheckReplacesPendingPanelWithFreshCandidateWithoutExecutingIt() async {
        let service = RouteRecheckService(settlesOnRetry: true)
        let store = PresentationStore(service: service)
        await diagnose(store)
        XCTAssertTrue(store.routeRepairNeedsRecheck)

        await diagnose(store)

        XCTAssertEqual(service.diagnosisCalls, 2)
        XCTAssertFalse(store.routeRepairNeedsRecheck)
        XCTAssertTrue(store.candidate?.allowsWhenResidualRoute == true)
        XCTAssertTrue(store.canConfirmRepair)
        XCTAssertEqual(service.repairCalls, 0, "A visible panel or fresh diagnosis is never repair consent")
    }

    func testPersistentBlockRetainsPanelAndDoesNotRelaxVPNGate() async {
        for vpn in [VPNAssessment(state: .active, reasonCode: .tunnelPath),
                    VPNAssessment(state: .unknown, reasonCode: .pathTransition)] {
            let service = RouteRecheckService(vpn: vpn)
            let store = PresentationStore(service: service)
            await diagnose(store)
            await diagnose(store)

            XCTAssertTrue(store.routeRepairNeedsRecheck)
            XCTAssertNil(store.candidate)
            XCTAssertFalse(store.canConfirmRepair)
            store.confirmRepair()
            XCTAssertEqual(service.repairCalls, 0)
        }
    }

    func testOtherFailuresDoNotShowRouteRemovalPanel() async {
        let store = PresentationStore(service: RouteRecheckService(hasRouteFailure: false))
        await diagnose(store)
        XCTAssertEqual(store.state, .problem)
        XCTAssertFalse(store.routeRepairNeedsRecheck)
        XCTAssertNil(store.candidate)
    }
}
