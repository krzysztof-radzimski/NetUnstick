import Foundation
import XCTest
import Network
import NetUnstickCore
import NetUnstickStoreNetwork
@testable import NetUnstickAppStore

private struct FixedStoreProbes: StoreNetworkProbing {
    var failure: StoreCheck?
    func run(_ check: StoreCheck) async -> OperationResult {
        StoreNetworkProbe.result(id: check.rawValue, started: Date(),
            outcome: check == failure ? .failure : .success,
            reason: check == failure ? "dnsFailure" : "healthy")
    }
    func device(host: String, port: UInt16) async -> OperationResult {
        StoreNetworkProbe.result(id: "device_connection", started: Date(), outcome: .success, reason: "reachable")
    }
}

private struct StoreBonjourFixture: BonjourBrowsing {
    func browse(_ service: BonjourService, timeout: Duration) async -> BonjourObservation {
        .init(count: 0, reason: .noServices)
    }
}

@MainActor final class AppStoreEnvironmentTests: XCTestCase {
    private func environment(probes: any StoreNetworkProbing = FixedStoreProbes()) throws -> AppStoreEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try BoundedSessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        return try AppStoreEnvironment(store: store, probes: probes, bonjour: StoreBonjourFixture())
    }

    func testSandboxDiagnosisPersistsOnlySupportedChecksWithoutRepairOrVPNClaim() async throws {
        let service = try environment()
        let results = try await service.diagnose()
        XCTAssertEqual(results.map(\.operationID), ["physical_link", "unicast_dns_resolution", "internet_path", "bonjour_discovery"])
        XCTAssertEqual(results.last?.outcome, .skipped, "No AirPlay receiver does not imply network failure")
        XCTAssertFalse(service.supportsRepairs)
        XCTAssertNil(service.repairCandidate())
        XCTAssertTrue(service.repairCandidates().isEmpty)
        let vpn = await service.refreshVPN(stabilize: true)
        XCTAssertEqual(vpn.state, .unknown, "A sandbox must not claim to establish global VPN disconnection")
        let sessions = try await service.loadSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].entries, results)
    }

    func testProbeFailureIsStoredWithStableCode() async throws {
        let service = try environment(probes: FixedStoreProbes(failure: .dns))
        let results = try await service.diagnose()
        let failed = try XCTUnwrap(results.first { $0.operationID == "unicast_dns_resolution" })
        XCTAssertEqual(failed.outcome, .failure)
        XCTAssertEqual(failed.error?.code, "dnsFailure")
        let sessions = try await service.loadSessions()
        XCTAssertEqual(sessions.first?.entries.first { $0.operationID == failed.operationID }, failed)
    }

    func testDeviceTestCreatesHistoryWithoutStoringPrivateHostOrSMBSession() async throws {
        let service = try environment()
        let response = await service.testDeviceConnection(host: "private-server.internal", port: 445)
        let result = try XCTUnwrap(response)
        XCTAssertEqual(result.outcome, .success)
        XCTAssertNil(result.after.values[.smbResult], "The Store edition performs TCP only, including port 445")
        let sessions = try await service.loadSessions()
        XCTAssertEqual(sessions.first?.entries, [result])
        let report = service.preview(try XCTUnwrap(sessions.first))
        XCTAssertFalse(report.contains("private-server"))
        XCTAssertFalse(report.contains("internal"))
        XCTAssertFalse(report.contains("445"))
        let json = String(decoding: try JSONEncoder().encode(sessions), as: UTF8.self)
        XCTAssertFalse(json.contains("private-server"))
    }

    func testClearHistoryErasesCurrentSessionAndNextDeviceTestStartsNewOne() async throws {
        let service = try environment()
        _ = try await service.diagnose()
        let previous = try await service.loadSessions().first?.id
        try await service.clearHistory()
        let cleared = try await service.loadSessions()
        XCTAssertTrue(cleared.isEmpty)
        _ = await service.testDeviceConnection(host: "example.invalid", port: 80)
        let next = try await service.loadSessions()
        XCTAssertEqual(next.count, 1)
        XCTAssertNotEqual(next.first?.id, previous)
    }

    func testCancellationProducesStructuredHistoryEntry() async throws {
        let service = try environment()
        _ = try await service.diagnose()
        await service.recordCancellation()
        let last = try await service.loadSessions().last?.entries.last
        XCTAssertEqual(last?.outcome, .cancelled)
        XCTAssertEqual(last?.operationID, "diagnosis_cancelled")
    }

    func testInvalidHostDoesNotStartNetworkProbeAndNeverEntersEvidence() async throws {
        let result = await StoreNetworkProbe().device(host: "secret value ; invalid", port: 445)
        XCTAssertEqual(result.outcome, .skipped)
        XCTAssertEqual(result.after.values[.errorCode], "invalidInput")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("secret"))
    }

    func testLocalNetworkPolicyDenialIsNotMisreportedAsUnknownDeviceName() {
        XCTAssertEqual(StoreNetworkProbe.classify(.dns(-65570)), .permissionDenied)
        XCTAssertEqual(StoreNetworkProbe.classify(.dns(-65538)), .nameUnresolved)
        XCTAssertEqual(StoreNetworkProbe.classify(.posix(.EACCES)), .permissionDenied)
        XCTAssertEqual(StoreNetworkProbe.classify(.posix(.ECONNREFUSED)), .refused)
    }

    func testOneShotGateRetainsCancellationBeforeInstallAndIgnoresLateReply() async {
        let gate = StoreProbeGate<Int>(cancelled: -1)
        gate.cancel()
        let value = await withCheckedContinuation { continuation in
            XCTAssertFalse(gate.install(continuation))
            gate.finish(99)
        }
        XCTAssertEqual(value, -1)
    }

    func testOneShotGateCompletesOnceWhenDeadlineAndReplyBothArrive() async {
        let gate = StoreProbeGate<Int>(cancelled: -1)
        let value = await withCheckedContinuation { continuation in
            XCTAssertTrue(gate.install(continuation))
            gate.finish(3)
            gate.finish(4)
        }
        XCTAssertEqual(value, 3)
    }
}
