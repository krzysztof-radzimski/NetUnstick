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
    private let failAt: Int?
    init(failAt: Int? = nil) { self.failAt = failAt }
    func run(executable: String, arguments: [String]) async throws {
        commands.append((executable, arguments))
        if let failAt, commands.count == failAt { throw PrivilegedExecutionError.nonZeroExit }
    }
    func count() -> Int { commands.count }
    func arguments() -> [[String]] { commands.map(\.1) }
}

/// Three leftover entries of a split LAN prefix; the third read drops whichever were deleted.
private actor ResidualRouteSequenceCollector: NetworkStateCollecting {
    private var reads = 0
    let removed: Set<String>
    init(removed: Set<String>) { self.removed = removed }
    func collect() async -> RawNetworkSnapshot {
        reads += 1
        let stale = ["192.168.44/32", "192.168.44.32/27", "192.168.44.128/25"].map {
            RawRoute(destination: $0, gateway: "10.5.0.1", interfaceName: "utun4", isDefault: false)
        }
        let routes: [RawRoute] = [
            .init(destination: "0.0.0.0/0", gateway: "192.168.44.1", interfaceName: "en0", isDefault: true),
            .init(destination: "192.168.44.0/24", gateway: "link#8", interfaceName: "en0",
                  isDefault: false, isLocal: true)
        ] + (reads >= 3 ? stale.filter { !removed.contains($0.destination) } : stale)
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

/// A collector whose observation never completes on its own, like a system API that blocks in the daemon context.
private struct HangingCollector: NetworkStateCollecting {
    func collect() async -> RawNetworkSnapshot {
        try? await Task.sleep(for: .seconds(30))
        return await FixtureCollector(vpn: false).collect()
    }
}

/// Fails the test if anything observes the network during a handshake.
private actor CountingCollector: NetworkStateCollecting {
    private(set) var calls = 0
    func collect() async -> RawNetworkSnapshot {
        calls += 1
        return await FixtureCollector(vpn: false).collect()
    }
}

extension PrivilegedExecutorTests {
    func testHandshakeAnswersWithoutObservingOrChangingAnything() async throws {
        let collector = CountingCollector()
        let runner = RecordingRunner()
        let executor = PrivilegedRepairExecutor(collector: collector, dhcp: FixtureDHCP(), runner: runner)
        let reply = await executor.perform(.init(action: .handshake))
        XCTAssertEqual(reply.code, .success)
        XCTAssertEqual(reply.result.name, "helper_handshake")
        XCTAssertEqual(reply.result.outcome, .success)
        XCTAssertEqual(reply.result.after.values[.count], String(PrivilegedProtocol.version))
        let stale = await executor.perform(.init(version: PrivilegedProtocol.version + 1, action: .handshake))
        XCTAssertEqual(stale.code, .incompatibleVersion)
        XCTAssertEqual(stale.result.outcome, .failure)
        let observed = await collector.calls
        let commands = await runner.count()
        XCTAssertEqual(observed, 0)
        XCTAssertEqual(commands, 0)
        let encoded = try JSONEncoder().encode(PrivilegedRequest(action: .handshake))
        XCTAssertEqual(try JSONDecoder().decode(PrivilegedRequest.self, from: encoded).action, .handshake)
    }

    func testBlockedObservationYieldsTimedOutReplyInsteadOfHanging() async {
        let runner = RecordingRunner()
        let started = ContinuousClock().now
        let reply = await PrivilegedRepairExecutor(collector: HangingCollector(), dhcp: FixtureDHCP(),
            runner: runner, collectionTimeout: .milliseconds(100)).perform(.init(action: .removeStaleTunnelRoutes(routes: Self.groupTargets)))
        XCTAssertEqual(reply.code, .timedOut)
        XCTAssertEqual(reply.result.outcome, .timedOut)
        XCTAssertLessThan(started.duration(to: ContinuousClock().now), .seconds(5))
        let issued = await runner.count()
        XCTAssertEqual(issued, 0, "Nothing may change while the observation is incomplete")
    }

    static let groupTargets = [("192.168.44.0", 32), ("192.168.44.32", 27), ("192.168.44.128", 25)]
        .map { PrivilegedRouteTarget(destination: $0.0, prefix: $0.1, interface: "utun4") }
    static let all: Set<String> = ["192.168.44/32", "192.168.44.32/27", "192.168.44.128/25"]

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

    func testGroupedRemovalIssuesOneExactUnscopedDeletePerEntryAndRequiresObservation() async {
        let request = PrivilegedRequest(action: .removeStaleTunnelRoutes(routes: Self.groupTargets.reversed()))
        let runner = RecordingRunner()
        let success = await PrivilegedRepairExecutor(
            collector: ResidualRouteSequenceCollector(removed: Self.all),
            dhcp: FixtureDHCP(), runner: runner).perform(request)
        XCTAssertEqual(success.code, .success)
        let arguments = await runner.arguments()
        XCTAssertEqual(arguments, [
            ["-n", "delete", "-net", "192.168.44.0/32", "10.5.0.1"],
            ["-n", "delete", "-net", "192.168.44.32/27", "10.5.0.1"],
            ["-n", "delete", "-net", "192.168.44.128/25", "10.5.0.1"]
        ], "Sorted, normalised, unscoped and without any shell")

        let partial = RecordingRunner()
        let unresolved = await PrivilegedRepairExecutor(
            collector: ResidualRouteSequenceCollector(removed: ["192.168.44/32", "192.168.44.32/27"]),
            dhcp: FixtureDHCP(), runner: partial).perform(request)
        XCTAssertEqual(unresolved.code, .nonZeroExit, "Exit code zero is not proof while one entry remains")
        let issued = await partial.count()
        XCTAssertEqual(issued, 3)

        let failing = RecordingRunner(failAt: 2)
        let stopped = await PrivilegedRepairExecutor(
            collector: ResidualRouteSequenceCollector(removed: Self.all),
            dhcp: FixtureDHCP(), runner: failing).perform(request)
        XCTAssertEqual(stopped.code, .nonZeroExit)
        let attempted = await failing.count()
        XCTAssertEqual(attempted, 2, "The first failing command stops the sequence")

        let mismatched = PrivilegedRequest(action: .removeStaleTunnelRoutes(routes: Array(Self.groupTargets.prefix(2))))
        let refusedRunner = RecordingRunner()
        let refused = await PrivilegedRepairExecutor(
            collector: ResidualRouteSequenceCollector(removed: Self.all),
            dhcp: FixtureDHCP(), runner: refusedRunner).perform(mismatched)
        XCTAssertEqual(refused.code, .ambiguousResource)
        XCTAssertEqual(refused.result.outcome, .skipped)
        let untouched = await refusedRunner.count()
        XCTAssertEqual(untouched, 0)
    }
}
