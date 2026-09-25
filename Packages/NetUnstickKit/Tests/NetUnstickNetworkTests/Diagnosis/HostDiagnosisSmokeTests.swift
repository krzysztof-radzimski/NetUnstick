import XCTest
import NetUnstickNetwork

/// Opt-in host integration: NETUNSTICK_READ_ONLY_SMOKE=1 swift test --filter HostDiagnosisSmokeTests
final class HostDiagnosisSmokeTests: XCTestCase {
    func testCurrentHostDiagnosisIsReadOnlyAndConservative() async throws {
        guard ProcessInfo.processInfo.environment["NETUNSTICK_READ_ONLY_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in read-only host smoke test")
        }
        let report = await DiagnosisEngine().diagnose()
        XCTAssertEqual(report.results.count, NetworkCheckKind.allCases.count)
        XCTAssertTrue(report.results.allSatisfy { $0.kind == .diagnostic && $0.endedAt >= $0.startedAt })
        if report.vpn.state != .inactive {
            XCTAssertTrue(report.candidates.allSatisfy(\.unsafeWhileVPNPresent))
        }
        if let internet = report.results.first(where: { $0.operationID == NetworkCheckKind.internetPath.id }),
           internet.after.values[.errorCode] == NetworkCheckReason.internetUnavailable.rawValue {
            XCTAssertEqual(internet.outcome, .skipped)
        }
    }
}
