import Foundation
import XCTest
import NetUnstickCore
import NetUnstickNetwork
import NetUnstickRepair
@testable import NetUnstick

private struct FixtureCollector: NetworkStateCollecting {
    let snapshot: RawNetworkSnapshot
    func collect() async -> RawNetworkSnapshot { snapshot }
}
private actor MutableFixtureCollector: NetworkStateCollecting {
    private var snapshot: RawNetworkSnapshot
    init(_ snapshot: RawNetworkSnapshot) { self.snapshot = snapshot }
    func collect() async -> RawNetworkSnapshot { snapshot }
    func set(_ value: RawNetworkSnapshot) { snapshot = value }
}
private struct FixtureProbe: NetworkConnectivityProbing {
    let dns: ProbeOutcome
    func resolveFixedName() async -> ProbeOutcome { dns }
    func probeInternet() async -> ProbeOutcome { .reachable }
}
private struct FixtureFileSharing: FileSharingProbing {
    let accountEnabled: Bool
    func observe() async -> FileSharingObservation {
        .init(smbListening: true, accountEnabledForSMB: accountEnabled, sharedFolderCount: 1, guestFolderCount: 1)
    }
}
private struct FixtureBonjour: BonjourBrowsing {
    func browse(_ service: BonjourService, timeout: Duration) async -> BonjourObservation {
        .init(count: 1, reason: .servicesFound)
    }
}
private actor FixtureRepairChecks: RepairCheckRunning {
    private let recheckSucceeds: Bool
    private var calls = 0
    init(recheckSucceeds: Bool) { self.recheckSucceeds = recheckSucceeds }
    func run(_ id: String, snapshot: RawNetworkSnapshot, context: OperationContext) async -> OperationResult? {
        calls += 1
        let fixed = calls > 1 && recheckSucceeds
        let now = Date()
        let reason = id == "physical_link" ? "noAddressLease" : "dnsFailure"
        return try? OperationResult(operationID: id, name: id, kind: .diagnostic,
            startedAt: now, endedAt: now, outcome: fixed ? .success : .failure,
            after: EvidenceSanitizer.sanitize([.errorCode: .errorCode(fixed ? "healthy" : reason)]),
            error: fixed ? nil : OperationError(domain: "fixture", code: reason))
    }
}
private actor FixtureRepairHelper: RepairHelperCalling {
    let code: PrivilegedCode
    private(set) var calls = 0
    init(code: PrivilegedCode = .success) { self.code = code }
    func perform(_ action: PrivilegedAction) async -> PrivilegedReply {
        calls += 1
        if code != .success { return PrivilegedRequestClient.failure(code) }
        let now = Date()
        return .init(code: .success, result: try! OperationResult(operationID: "fixture.helper",
            name: "fixture_helper", kind: .repair, startedAt: now, endedAt: now, outcome: .success))
    }
}
private struct FixtureRepairWait: RepairWaiting {
    func settle() async throws {}
}

@MainActor final class CompositionIntegrationTests: XCTestCase {
    private func snapshot(_ vpn: String = "inactive", leaseFailure: Bool = false) -> RawNetworkSnapshot {
        let now = Date()
        let tunnel = vpn == "inactive" ? [] : [RawInterface(name: "utun1", type: "other", isUp: vpn == "active", addresses: [])]
        let routes = [RawRoute(destination: "0.0.0.0/0", gateway: "192.0.2.1", interfaceName: "en0", isDefault: true),
                      RawRoute(destination: "192.0.2.0/24", gateway: nil, interfaceName: "en0", isDefault: false, isLocal: true)]
        let vpnRoutes = vpn == "active" ? [RawRoute(destination: "10.0.0.0/8", gateway: nil, interfaceName: "utun1", isDefault: false)] : []
        return .init(startedAt: now, endedAt: now,
            path: .init(status: "satisfied", availableInterfaces: ["en0"], selectedInterfaces: ["en0"],
                supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: ["192.0.2.1"]),
            interfaces: [RawInterface(name: "en0", type: "wifi", isUp: true, addresses: [leaseFailure ? "169.254.1.2/16" : "192.0.2.2/24"])] + tunnel,
            routes: routes + vpnRoutes,
            resolvers: [RawResolver(domain: "secret.corp", searchDomains: ["secret.corp"],
                nameservers: ["192.0.2.53"], interfaceName: "en0")],
            proxy: nil, dynamicStoreVPNKeys: [], errors: [])
    }
    private func environment(_ vpn: String = "inactive", dns: ProbeOutcome = .reachable, leaseFailure: Bool = false,
                             smbAccountEnabled: Bool = true,
                             checks: any RepairCheckRunning = FixtureRepairChecks(recheckSucceeds: true),
                             helper: any RepairHelperCalling = FixtureRepairHelper()) throws -> AppEnvironment {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("DerivedData/IntegrationSessions/\(UUID().uuidString)/sessions.json")
        return try AppEnvironment(collector: FixtureCollector(snapshot: snapshot(vpn, leaseFailure: leaseFailure)), probe: FixtureProbe(dns: dns),
            bonjour: FixtureBonjour(), store: try BoundedSessionStore(fileURL: dir),
            fileSharing: FixtureFileSharing(accountEnabled: smbAccountEnabled),
            repairChecks: checks, repairHelper: helper, repairWait: FixtureRepairWait(),
            dhcpInterfaces: { leaseFailure ? ["en0"] : [] })
    }

    func testRealCompositionStreamsChecksPersistsSessionAndRedactsReport() async throws {
        let environment = try environment()
        let results = try await environment.diagnose()
        XCTAssertEqual(results.count, DiagnosisEngine.checkCount)
        XCTAssertEqual(environment.vpn.state, .inactive)
        let sessions = try await environment.loadSessions()
        XCTAssertEqual(sessions.last?.entries, results)
        let text = environment.preview(try XCTUnwrap(sessions.last))
        XCTAssertFalse(text.contains("secret.corp"))
        XCTAssertFalse(text.contains("192.0.2.53"))
        XCTAssertFalse(text.contains("utun1"))
    }

    func testAccountWithoutSMBPasswordIsReportedWithoutARepair() async throws {
        let environment = try environment(smbAccountEnabled: false)
        let results = try await environment.diagnose()
        let sharing = try XCTUnwrap(results.first { $0.operationID == FileSharingReadinessCheck.checkID })
        XCTAssertEqual(sharing.outcome, .failure)
        XCTAssertEqual(sharing.after.values[.errorCode], FileSharingReason.accountNotEnabledForSMB.rawValue)
        XCTAssertEqual(sharing.nextStep, NextStep.enableSMBAccount.rawValue)
        // No network change can fix an account setting; the app must not offer a repair for it.
        XCTAssertNil(environment.repairCandidate())
        let sessions = try await environment.loadSessions()
        XCTAssertFalse(environment.preview(try XCTUnwrap(sessions.last)).contains(NSUserName()))
    }

    func testActiveAndUnknownVPNDoNotOfferCandidate() async throws {
        for state in ["active", "unknown"] {
            let environment = try environment(state, dns: .failed)
            _ = try await environment.diagnose()
            XCTAssertNotEqual(environment.vpn.state, .inactive, state)
            XCTAssertNil(environment.repairCandidate(), state)
        }
    }

    func testDiagnosisFaultOffersCatalogCandidate() async throws {
        let environment = try environment(dns: .failed)
        let results = try await environment.diagnose()
        XCTAssertTrue(results.contains { $0.after.values[.errorCode] == NetworkCheckReason.dnsFailure.rawValue })
        XCTAssertTrue(environment.repairCandidate()?.reason.contains("Weryfikacja") == true)
    }

    func testConfirmedPrivilegedPlanPersistsOnlyRecheckedSuccess() async throws {
        for resolved in [true, false] {
            let helper = FixtureRepairHelper()
            let environment = try environment(leaseFailure: true,
                checks: FixtureRepairChecks(recheckSucceeds: resolved), helper: helper)
            _ = try await environment.diagnose()
            XCTAssertTrue(environment.repairCandidates().contains { $0.change.contains("DHCP") })
            environment.selectRepairCandidate(0)
            let actual = await environment.executeRepair(onPhase: { _, _ in })
            let result = try XCTUnwrap(actual)
            XCTAssertEqual(result.outcome, resolved ? .success : .failure)
            XCTAssertEqual(result.error?.code, resolved ? nil : "recheck_failed")
            let calls = await helper.calls
            XCTAssertEqual(calls, 1)
            let saved = try await environment.loadSessions()
            XCTAssertEqual(saved.last?.entries.last, result)
            XCTAssertTrue(saved.last?.entries.contains(where: { $0.name == "before_snapshot" }) == true)
            XCTAssertTrue(saved.last?.entries.contains(where: { $0.name == "recheck" }) == true)
        }
    }

    func testStaleCandidateCannotChangeNetworkAfterVPNBecomesActiveOrUnknown() async throws {
        for changed in ["active", "unknown"] {
            let collector = MutableFixtureCollector(snapshot(leaseFailure: true))
            let helper = FixtureRepairHelper()
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let url = root.appendingPathComponent("DerivedData/IntegrationSessions/\(UUID().uuidString)/sessions.json")
            let environment = try AppEnvironment(collector: collector, probe: FixtureProbe(dns: .failed),
                bonjour: FixtureBonjour(), store: try BoundedSessionStore(fileURL: url),
                repairChecks: FixtureRepairChecks(recheckSucceeds: true), repairHelper: helper,
                repairWait: FixtureRepairWait(), dhcpInterfaces: { ["en0"] })
            _ = try await environment.diagnose()
            environment.selectRepairCandidate(0)
            XCTAssertNotNil(environment.repairCandidate())
            await collector.set(snapshot(changed, leaseFailure: true))
            let actual = await environment.executeRepair(onPhase: { _, _ in })
            let result = try XCTUnwrap(actual)
            XCTAssertEqual(result.outcome, .skipped)
            XCTAssertEqual(result.error?.code, changed == "active" ? "vpn_active" : "vpn_unknown")
            let calls = await helper.calls
            XCTAssertEqual(calls, 0)
        }
    }
}
