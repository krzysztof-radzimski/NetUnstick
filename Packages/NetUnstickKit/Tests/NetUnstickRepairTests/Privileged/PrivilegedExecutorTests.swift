import XCTest
import NetUnstickRepair
import NetUnstickNetwork

private struct FixtureCollector: NetworkStateCollecting {
    let vpn: Bool
    func collect() async -> RawNetworkSnapshot {
        RawNetworkSnapshot(startedAt: Date(), endedAt: Date(),
            path: .init(status: "satisfied", availableInterfaces: vpn ? ["en0", "utun0"] : ["en0"], selectedInterfaces: ["en0"],
                        supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: []),
            interfaces: [.init(name: "en0", type: "wifi", isUp: true, addresses: [])] +
                (vpn ? [.init(name: "utun0", type: "tunnel", isUp: true, addresses: [])] : []),
            routes: vpn ? [.init(destination: "10.20.0.0/16", gateway: "link#1", interfaceName: "utun0", isDefault: false)] : [], resolvers: [],
            proxy: nil, dynamicStoreVPNKeys: vpn ? ["vpn"] : [], errors: [])
    }
}
private struct FixtureDHCP: DHCPConfigurationChecking {
    func configuredInterfaces() -> Set<String> { ["en0"] }
    func refresh(_ name: String) -> Bool { true }
}
private struct FixtureRunner: PrivilegedCommandRunning {
    let error: PrivilegedExecutionError?
    func run(executable: String, arguments: [String]) async throws { if let error { throw error } }
}
final class PrivilegedExecutorTests: XCTestCase {
    func testOutcomeMappingAndNoChangeOnVPN() async {
        let request = PrivilegedRequest(action: .refreshResolverCache)
        for (error, expected) in [(nil, PrivilegedCode.success), (.timedOut, .timedOut),
                                  (.nonZeroExit, .nonZeroExit), (.outputLimit, .outputLimit),
                                  (.permissionDenied, .permissionDenied)] as [(PrivilegedExecutionError?, PrivilegedCode)] {
            let reply = await PrivilegedRepairExecutor(collector: FixtureCollector(vpn: false),
                dhcp: FixtureDHCP(), runner: FixtureRunner(error: error)).perform(request)
            XCTAssertEqual(reply.code, expected)
            XCTAssertNotNil(reply.result.nextStep)
        }
        let blocked = await PrivilegedRepairExecutor(collector: FixtureCollector(vpn: true),
            dhcp: FixtureDHCP(), runner: FixtureRunner(error: nil)).perform(request)
        XCTAssertEqual(blocked.code, .vpnActive)
    }
}

private final class RouteSequenceCollector: NetworkStateCollecting, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let removed: Bool
    init(removed: Bool) { self.removed = removed }
    func collect() async -> RawNetworkSnapshot {
        lock.lock(); reads += 1; let ordinal = reads; lock.unlock()
        let route = RawRoute(destination: "192.168.40.0/24", gateway: "192.168.1.1", interfaceName: "en8", isDefault: false)
        return RawNetworkSnapshot(startedAt: Date(), endedAt: Date(),
            path: .init(status: "satisfied", availableInterfaces: ["en0"], selectedInterfaces: ["en0"],
                        supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: []),
            interfaces: [.init(name: "en0", type: "wifi", isUp: true, addresses: [])],
            routes: removed && ordinal >= 3 ? [] : [route], resolvers: [], proxy: nil,
            dynamicStoreVPNKeys: [], errors: [])
    }
}
extension PrivilegedExecutorTests {
    func testRouteRequiresObservedRemovalAfterSuccessfulCommand() async {
        let action = PrivilegedRequest(action: .removeOrphanedRoute(destination: "192.168.40.0", prefix: 24, interface: "en8"))
        let success = await PrivilegedRepairExecutor(collector: RouteSequenceCollector(removed: true),
            dhcp: FixtureDHCP(), runner: FixtureRunner(error: nil)).perform(action)
        XCTAssertEqual(success.code, .success)
        let unresolved = await PrivilegedRepairExecutor(collector: RouteSequenceCollector(removed: false),
            dhcp: FixtureDHCP(), runner: FixtureRunner(error: nil)).perform(action)
        XCTAssertEqual(unresolved.code, .nonZeroExit)
        XCTAssertEqual(unresolved.result.outcome, .failure)
    }
}
