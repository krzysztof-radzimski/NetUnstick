import XCTest
@testable import NetUnstick

@MainActor final class PresentationStoreTests: XCTestCase {
    func testScenariosHaveDistinctStructuredOutcomes() async throws {
        let healthy = try await MockPresentationService(scenario: "healthy").diagnose()
        XCTAssertEqual(healthy.count, 4)
        XCTAssertTrue(healthy.allSatisfy { $0.outcome == .success })
        let denied = try await MockPresentationService(scenario: "bonjour-denied").diagnose()
        XCTAssertEqual(denied.last?.outcome, .permissionDenied)
        XCTAssertEqual(denied.last?.error?.code, "bonjour_denied")
        let timedOut = try await MockPresentationService(scenario: "timeout").diagnose()
        XCTAssertEqual(timedOut.first?.outcome, .timedOut)
        let absent = try await MockPresentationService(scenario: "no-receiver").diagnose()
        XCTAssertEqual(absent.last?.outcome, .skipped)
    }

    func testUnknownVPNNeverAppearsHealthy() async throws {
        let store = PresentationStore(service: MockPresentationService(scenario: "vpn-unknown"))
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(store.state, .unknown)
        XCTAssertFalse(store.sessions.isEmpty)
        XCTAssertNil(store.candidate)
    }

    func testAllDocumentedScenariosProduceDeterministicMockResults() async throws {
        let scenarios = ["healthy", "dns-residue", "route-blocked", "bonjour-denied", "no-receiver", "vpn-active", "vpn-unknown", "permission-denied", "timeout", "repair-success", "repair-failure"]
        for scenario in scenarios {
            let service = MockPresentationService(scenario: scenario)
            let first = try await service.diagnose()
            let second = try await service.diagnose()
            XCTAssertEqual(first.map(\.outcome), second.map(\.outcome), scenario)
            XCTAssertEqual(first.map(\.error?.code), second.map(\.error?.code), scenario)
            XCTAssertEqual(first.count, 4, scenario)
        }
        XCTAssertNotNil(MockPresentationService(scenario: "dns-residue").repairCandidate())
        XCTAssertNil(MockPresentationService(scenario: "vpn-active").repairCandidate())
    }

    func testCancellationProducesBoundedSession() {
        let store = PresentationStore(service: MockPresentationService(scenario: "operation-progress"))
        XCTAssertTrue(store.isRunning)
        store.cancel()
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.sessions.last?.entries.last?.outcome, .cancelled)
    }

    func testRepairSimulationDoesNotClaimRealSuccess() async throws {
        let store = PresentationStore(service: MockPresentationService(scenario: "repair-success"))
        XCTAssertNotNil(store.candidate)
        store.simulateRepair()
        XCTAssertEqual(store.sessions.last?.entries.last?.kind, .repair)
        XCTAssertEqual(store.sessions.last?.entries.last?.outcome, .skipped)
        XCTAssertTrue(store.lastResultText.lowercased().contains("symul") || store.lastResultText.lowercased().contains("simulat"))
    }
}
