import Foundation
import XCTest
import NetUnstickCore
import NetUnstickNetwork
@testable import NetUnstick

@MainActor private final class SuspendedHistoryService: PresentationService {
    let scenario = "unavailable"
    let helper = HelperPresentationState.unavailable
    var deletion: CheckedContinuation<Void, Error>?
    var diagnosisCalls = 0
    var deviceCalls = 0
    var repairCalls = 0
    func diagnose() async throws -> [OperationResult] { diagnosisCalls += 1; return [] }
    func repairCandidate() -> RepairCandidatePresentation? {
        .init(change: "fixture", reason: "fixture", resource: "fixture", impact: "fixture",
              permission: "fixture", verification: "fixture")
    }
    func clearHistory() async throws {
        try await withCheckedThrowingContinuation { deletion = $0 }
    }
    func testDeviceConnection(host: String, port: UInt16) async -> OperationResult? { deviceCalls += 1; return nil }
    func executeRepair(onPhase: @escaping @Sendable (String, OperationOutcome) -> Void) async -> OperationResult? {
        repairCalls += 1; return nil
    }
}

@MainActor final class HistoryPresentationTests: XCTestCase {
    private func awaitDeletion(_ service: SuspendedHistoryService) async {
        for _ in 0..<200 {
            if service.deletion != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Deletion did not reach its controlled persistence boundary")
    }

    func testEraseSerializesOperationsAndClearsSelectionOnlyAfterPersistence() async throws {
        let service = SuspendedHistoryService()
        let store = PresentationStore(service: service)
        let session = ActivitySession(startedAt: Date(), appVersion: "1", macOSVersion: "14")
        store.sessions = [session]; store.selectedSessionID = session.id
        store.deviceHost = "example.invalid"
        let deletion = Task { try await store.clearHistory() }
        await awaitDeletion(service)
        XCTAssertTrue(store.historyClearRunning)
        XCTAssertEqual(store.sessions.map(\.id), [session.id])
        store.startDiagnosis(); store.testDeviceConnection(); store.confirmRepair()
        await Task.yield()
        XCTAssertFalse(store.isRunning)
        XCTAssertFalse(store.deviceTestRunning)
        XCTAssertEqual(service.diagnosisCalls + service.deviceCalls + service.repairCalls, 0)
        service.deletion?.resume()
        try await deletion.value
        XCTAssertFalse(store.historyClearRunning)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selectedSessionID)
    }

    func testFailedEraseKeepsDisplayedHistoryAndReleasesBusyState() async throws {
        let service = SuspendedHistoryService()
        let store = PresentationStore(service: service)
        let session = ActivitySession(startedAt: Date(), appVersion: "1", macOSVersion: "14")
        store.sessions = [session]; store.selectedSessionID = session.id
        let deletion = Task { try await store.clearHistory() }
        await awaitDeletion(service)
        service.deletion?.resume(throwing: SessionStoreError.permissionDenied)
        do { try await deletion.value; XCTFail("Expected permission failure") }
        catch { XCTAssertEqual(error as? SessionStoreError, .permissionDenied) }
        XCTAssertFalse(store.historyClearRunning)
        XCTAssertEqual(store.sessions.map(\.id), [session.id])
        XCTAssertEqual(store.selectedSessionID, session.id)
    }
}
