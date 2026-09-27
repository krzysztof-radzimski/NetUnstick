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
