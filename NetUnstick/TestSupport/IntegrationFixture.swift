#if DEBUG
import Foundation
import NetUnstickCore
import NetUnstickNetwork
import NetUnstickRepair

private struct FixtureNetworkCollector: NetworkStateCollecting {
    let snapshot: RawNetworkSnapshot
    func collect() async -> RawNetworkSnapshot { snapshot }
}

private struct FixtureConnectivityProbe: NetworkConnectivityProbing {
    let failsDNS: Bool
    func resolveFixedName() async -> ProbeOutcome { failsDNS ? .failed : .reachable }
    func probeInternet() async -> ProbeOutcome { .reachable }
}

private struct FixtureFileSharingProbe: FileSharingProbing {
    func observe() async -> FileSharingObservation {
        .init(smbListening: true, accountEnabledForSMB: true, sharedFolderCount: 1, guestFolderCount: 1)
    }
}

private struct FixtureBonjourBrowser: BonjourBrowsing {
    func browse(_ service: BonjourService, timeout: Duration) async -> BonjourObservation {
        .init(count: 1, reason: .servicesFound)
    }
}

private actor FixtureRepairCheckRunner: RepairCheckRunning {
    let resolves: Bool
    private var calls = 0
    init(resolves: Bool) { self.resolves = resolves }
    func run(_ id: String, snapshot: RawNetworkSnapshot, context: OperationContext) async -> OperationResult? {
        calls += 1
        let fixed = calls > 1 && resolves
        let now = Date()
        let reason = id == "physical_link" ? "noAddressLease" : "dnsFailure"
        return try? OperationResult(operationID: id, name: id, kind: .diagnostic,
            startedAt: now, endedAt: now, outcome: fixed ? .success : .failure,
            after: EvidenceSanitizer.sanitize([.errorCode: .errorCode(fixed ? "healthy" : reason)]),
            error: fixed ? nil : OperationError(domain: "fixture", code: reason))
    }
}

private struct FixturePrivilegedHelper: RepairHelperCalling {
    func perform(_ action: PrivilegedAction) async -> PrivilegedReply {
        let now = Date()
        return .init(code: .success, result: try! OperationResult(operationID: "fixture.helper", name: "fixture_helper",
            kind: .repair, startedAt: now, endedAt: now, outcome: .success))
    }
}

private struct FixtureWait: RepairWaiting {
    func settle() async throws {}
}

@MainActor enum IntegrationFixture {
    static func make(scenario: String) throws -> AppEnvironment {
        guard ["healthy", "fault", "verified", "unresolved", "vpn-active", "vpn-unknown"].contains(scenario)
        else { throw SessionStoreError.ioFailure }
        let leaseFailure = scenario == "verified" || scenario == "unresolved"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("DerivedData/UITestSessions/\(UUID().uuidString)/sessions.json")
        return try AppEnvironment(collector: FixtureNetworkCollector(snapshot: snapshot(vpn: scenario, leaseFailure: leaseFailure)),
            probe: FixtureConnectivityProbe(failsDNS: ["fault", "vpn-active", "vpn-unknown"].contains(scenario)),
            bonjour: FixtureBonjourBrowser(), store: BoundedSessionStore(fileURL: file),
            fileSharing: FixtureFileSharingProbe(),
            repairChecks: FixtureRepairCheckRunner(resolves: scenario == "verified"),
            repairHelper: FixturePrivilegedHelper(), repairWait: FixtureWait(),
            dhcpInterfaces: { leaseFailure ? ["en0"] : [] })
    }

    private static func snapshot(vpn: String, leaseFailure: Bool) -> RawNetworkSnapshot {
        let now = Date()
        let active = vpn == "vpn-active", unknown = vpn == "vpn-unknown"
        let tunnel = active || unknown ? [RawInterface(name: "utun1", type: "other", isUp: active, addresses: [])] : []
        let route = active ? [RawRoute(destination: "10.0.0.0/8", gateway: nil, interfaceName: "utun1", isDefault: false)] : []
        return RawNetworkSnapshot(startedAt: now, endedAt: now,
            path: RawPathState(status: "satisfied", availableInterfaces: ["en0"], selectedInterfaces: ["en0"],
                supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: ["192.0.2.1"]),
            interfaces: [RawInterface(name: "en0", type: "wifi", isUp: true, addresses: [leaseFailure ? "169.254.1.2/16" : "192.0.2.2/24"])] + tunnel,
            routes: [RawRoute(destination: "0.0.0.0/0", gateway: "192.0.2.1", interfaceName: "en0", isDefault: true),
                RawRoute(destination: "192.0.2.0/24", gateway: nil, interfaceName: "en0", isDefault: false, isLocal: true)] + route,
            resolvers: [RawResolver(domain: "secret.corp", searchDomains: ["secret.corp"],
                nameservers: ["192.0.2.53"], interfaceName: "en0")],
            proxy: nil, dynamicStoreVPNKeys: [], errors: [])
    }
}
#endif
