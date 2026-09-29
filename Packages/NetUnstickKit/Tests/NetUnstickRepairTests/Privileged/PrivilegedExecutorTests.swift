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
        let rejected = await PrivilegedRepairExecutor(collector: FixtureCollector(vpn: false),
            dhcp: FixtureDHCP(), runner: FixtureRunner(error: nil)).perform(request)
        XCTAssertEqual(rejected.code, .invalidRequest)
        let blocked = await PrivilegedRepairExecutor(collector: FixtureCollector(vpn: true),
            dhcp: FixtureDHCP(), runner: FixtureRunner(error: nil)).perform(request)
        XCTAssertEqual(blocked.code, .vpnActive)
    }
}

private actor RouteSequenceCollector: NetworkStateCollecting {
    private var reads = 0
    let removed: Bool
    init(removed: Bool) { self.removed = removed }
    func collect() async -> RawNetworkSnapshot {
        reads += 1
        let ordinal = reads
        let route = RawRoute(destination: "192.168.40.0/24", gateway: "192.168.1.1", interfaceName: "en8", isDefault: false)
        return RawNetworkSnapshot(startedAt: Date(), endedAt: Date(),
            path: .init(status: "satisfied", availableInterfaces: ["en0"], selectedInterfaces: ["en0"],
                        supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: []),
            interfaces: [.init(name: "en0", type: "wifi", isUp: true, addresses: [])],
            routes: removed && ordinal >= 3 ? [] : [route], resolvers: [], proxy: nil,
            dynamicStoreVPNKeys: [], errors: [])
    }
}

private actor RefreshSequenceCollector: NetworkStateCollecting {
    private var reads = 0
    func collect() async -> RawNetworkSnapshot {
        reads += 1
        return await FixtureCollector(vpn: reads >= 2).collect()
    }
}

private actor RecordingRunner: PrivilegedCommandRunning {
    private var commands: [(String, [String])] = []
    func run(executable: String, arguments: [String]) async throws { commands.append((executable, arguments)) }
    func count() -> Int { commands.count }
    func arguments() -> [String]? { commands.first?.1 }
}

private actor ResidualRouteSequenceCollector: NetworkStateCollecting {
    private var reads = 0
    let removed: Bool
    init(removed: Bool) { self.removed = removed }
    func collect() async -> RawNetworkSnapshot {
        reads += 1
        let tunnel = RawRoute(destination: "192.168.44.32/27", gateway: "10.5.0.1",
                              interfaceName: "utun4", isDefault: false)
        let routes: [RawRoute] = [
            .init(destination: "0.0.0.0/0", gateway: "192.168.44.1", interfaceName: "en0", isDefault: true),
            .init(destination: "192.168.44.0/24", gateway: "link#8", interfaceName: "en0",
                  isDefault: false, isLocal: true)
        ] + (removed && reads >= 3 ? [] : [tunnel])
        return RawNetworkSnapshot(startedAt: Date(), endedAt: Date(),
            path: .init(status: "satisfied", availableInterfaces: ["en0", "utun4"],
                        selectedInterfaces: ["en0"], supportsDNS: true, supportsIPv4: true,
                        supportsIPv6: false, gateways: ["192.168.44.1"]),
            interfaces: [.init(name: "en0", type: "wifi", isUp: true, addresses: ["192.168.44.40"]),
                         .init(name: "utun4", type: "tunnel", isUp: true, addresses: ["10.5.0.2"])],
            routes: routes, resolvers: [], proxy: nil, dynamicStoreVPNKeys: [], errors: [],
            vpnServices: .disconnected)
    }
}

extension PrivilegedExecutorTests {
    func testRemovedGlobalRefreshNeverRunsACommand() async {
        let runner = RecordingRunner()
        let reply = await PrivilegedRepairExecutor(collector: RefreshSequenceCollector(),
            dhcp: FixtureDHCP(), runner: runner).perform(.init(action: .refreshResolverCache))
        let count = await runner.count()
        XCTAssertEqual(reply.code, .invalidRequest)
        XCTAssertEqual(count, 0)
    }

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

    func testResidualUnscopedTunnelRouteUsesExactUnscopedDeleteAndRequiresObservation() async {
        let request = PrivilegedRequest(action: .removeOrphanedRoute(
            destination: "192.168.44.32", prefix: 27, interface: "utun4"))
        let runner = RecordingRunner()
        let success = await PrivilegedRepairExecutor(
            collector: ResidualRouteSequenceCollector(removed: true),
            dhcp: FixtureDHCP(), runner: runner).perform(request)
        XCTAssertEqual(success.code, .success)
        let arguments = await runner.arguments()
        XCTAssertEqual(arguments, ["-n", "delete", "-net", "192.168.44.32/27", "10.5.0.1"])

        let unresolved = await PrivilegedRepairExecutor(
            collector: ResidualRouteSequenceCollector(removed: false),
            dhcp: FixtureDHCP(), runner: RecordingRunner()).perform(request)
        XCTAssertEqual(unresolved.code, .nonZeroExit)
    }
}
