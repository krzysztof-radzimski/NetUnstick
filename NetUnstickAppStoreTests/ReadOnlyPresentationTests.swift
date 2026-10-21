import Foundation
import XCTest
import NetUnstickCore
import NetUnstickStoreNetwork
@testable import NetUnstickAppStore

@MainActor private final class ReadOnlyPresentationService: PresentationService {
    let scenario = "app-store"
    let supportsRepairs = false
    let helper = HelperPresentationState.available
    var results: [OperationResult] = []
    var mutationCalls = 0
    var helperCalls = 0
    func diagnose() async throws -> [OperationResult] { results }
    func repairCandidate() -> RepairCandidatePresentation? {
        .init(change: "fixture", reason: "fixture", resource: "fixture", impact: "fixture",
              permission: "fixture", verification: "fixture", allowsWhenResidualRoute: true, requiresHelper: true)
    }
    func registerHelper() -> HelperPresentationState { mutationCalls += 1; return .available }
    func unregisterHelper() -> HelperPresentationState { mutationCalls += 1; return .unavailable }
    func verifyHelper() async -> HelperHandshakePresentation { helperCalls += 1; return .responding(version: 2) }
    func executeRepair(onPhase: @escaping @Sendable (String, OperationOutcome) -> Void) async -> OperationResult? {
        mutationCalls += 1; return nil
    }
    func refreshVPN(stabilize: Bool) async -> VPNAssessment {
        .init(state: .unknown, reasonCode: .incompleteSnapshot)
    }
}

@MainActor final class ReadOnlyPresentationTests: XCTestCase {
    private func result(_ id: String, _ outcome: OperationOutcome = .success) -> OperationResult {
        StoreNetworkProbe.result(id: id, started: Date(), outcome: outcome,
                                 reason: outcome == .permissionDenied ? "permissionDenied" : "healthy")
    }
    private func settle(_ store: PresentationStore) async {
        for _ in 0..<200 {
            if !store.isRunning { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Diagnosis exceeded the deterministic fixture deadline")
    }

    func testReadOnlyPresentationCannotRegisterOrRunARepairEvenIfServiceOffersOne() async {
        let service = ReadOnlyPresentationService()
        service.results = [result("physical_link"), result("unicast_dns_resolution"), result("internet_path")]
        let store = PresentationStore(service: service)
        store.startDiagnosis()
        await settle(store)
        store.registerHelper(); store.unregisterHelper(); store.verifyHelper(); store.confirmRepair()
        await Task.yield()
        XCTAssertTrue(store.candidates.isEmpty)
        XCTAssertNil(store.candidate)
        XCTAssertFalse(store.canConfirmRepair)
        XCTAssertEqual(service.mutationCalls, 0)
        XCTAssertEqual(service.helperCalls, 0, "Store launch must not contact a helper")
        XCTAssertEqual(store.state, .healthy)
        XCTAssertEqual(store.vpn.state, .unknown, "Connectivity success must not invent a VPN assessment")
        XCTAssertEqual(store.vpnStatus, L10n.text("store_diagnostic_scope"))
    }

    func testMissingInternetOrDeniedBonjourCannotProduceAnUnqualifiedPassedSummary() async {
        let base = [result("physical_link"), result("unicast_dns_resolution"), result("internet_path")]
        for (results, state) in [
            (Array(base.dropLast()), NetworkPresentationState.unknown),
            (base + [result("bonjour_discovery", .permissionDenied)], .problem),
            ([result("physical_link"), result("unicast_dns_resolution", .failure), result("internet_path")], .problem)
        ] {
            let service = ReadOnlyPresentationService()
            service.results = results
            let store = PresentationStore(service: service)
            store.startDiagnosis()
            await settle(store)
            XCTAssertEqual(store.state, state)
            XCTAssertEqual(store.lastResultText, L10n.text("store_result_incomplete"))
            XCTAssertTrue(store.candidates.isEmpty)
        }
    }
}
