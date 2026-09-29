import Foundation
import XCTest
@testable import NetUnstickNetwork

final class VPNStateDetectorTests: XCTestCase {
    private let detector = VPNStateDetector()

    func testFixtureDecisionsConservativelyBlockChanges() {
        let cases: [(VPNFixtures.Scenario, VPNState, VPNReasonCode)] = [
            (.noVPN, .inactive, .noVPNSignals),
            (.activeTunnel, .active, .tunnelRoute),
            (.residualTunnel, .unknown, .residualTunnel),
            (.scopedDNS, .active, .tunnelDNS),
            (.splitTunnel, .active, .tunnelRoute),
            (.fullTunnel, .active, .tunnelRoute),
            (.conflicting, .unknown, .conflictingSignals),
            (.timeout, .unknown, .partialReadFailure),
            (.permissionDenied, .unknown, .partialReadFailure),
            (.pathTransition, .unknown, .pathTransition)
        ]
        for (fixture, expectedState, expectedReason) in cases {
            let result = detector.assess(VPNFixtures.snapshot(fixture))
            XCTAssertEqual(result.state, expectedState)
            XCTAssertEqual(result.reasonCode, expectedReason)
            XCTAssertEqual(result.permitsNetworkChange, expectedState == .inactive)
        }
    }

    /// Modern macOS keeps link-local-only utun devices for its own services. They must not
    /// block "inactive"; a leftover VPN tunnel with a routable address still does.
    func testSystemLinkLocalTunnelsAreNotVPNSignals() {
        let base = VPNFixtures.snapshot(.noVPN)
        func snapshot(interfaces: [RawInterface], routes: [RawRoute]) -> RawNetworkSnapshot {
            RawNetworkSnapshot(startedAt: base.startedAt, endedAt: base.endedAt,
                path: RawPathState(status: "satisfied", availableInterfaces: ["en0", "utun0", "utun1"],
                                   selectedInterfaces: ["en0"], supportsDNS: true, supportsIPv4: true,
                                   supportsIPv6: true, gateways: ["192.0.2.1"]),
                interfaces: base.interfaces + interfaces, routes: base.routes + routes,
                resolvers: base.resolvers, proxy: nil, dynamicStoreVPNKeys: [], errors: [], vpnServices: .disconnected)
        }
        let system = [RawInterface(name: "utun0", type: "tunnel", isUp: true, addresses: ["fe80::1%utun0"]),
                      RawInterface(name: "utun1", type: "tunnel", isUp: true, addresses: ["fe80::2%utun1"])]
        let systemRoutes = [RawRoute(destination: "fe80::%utun0/64", gateway: "fe80::1%utun0", interfaceName: "utun0", isDefault: false, isScoped: true),
                            RawRoute(destination: "fe80::%utun1/64", gateway: "fe80::2%utun1", interfaceName: "utun1", isDefault: false, isScoped: true),
                            RawRoute(destination: "ff02::%utun0/32", gateway: "link#18", interfaceName: "utun0", isDefault: false, isLocal: true)]
        let onlySystem = detector.assess(snapshot(interfaces: system, routes: systemRoutes))
        XCTAssertEqual(onlySystem, .init(state: .inactive, reasonCode: .noVPNSignals))
        XCTAssertTrue(TunnelSignals.vpnTunnelNames(in: snapshot(interfaces: system, routes: systemRoutes)).isEmpty)

        let leftover = RawInterface(name: "utun4", type: "tunnel", isUp: true, addresses: ["10.100.101.10"])
        let ownHost = RawRoute(destination: "10.100.101.10", gateway: "10.100.101.10", interfaceName: "utun4", isDefault: false, isLocal: true)
        let residual = detector.assess(snapshot(interfaces: system + [leftover], routes: systemRoutes + [ownHost]))
        XCTAssertEqual(residual, .init(state: .unknown, reasonCode: .residualTunnel))

        let shadow = RawRoute(destination: "192.0.2.32/27", gateway: "10.100.101.10", interfaceName: "utun4", isDefault: false)
        let active = detector.assess(snapshot(interfaces: system + [leftover], routes: systemRoutes + [ownHost, shadow]))
        XCTAssertEqual(active, .init(state: .active, reasonCode: .tunnelRoute))

        let referenced = RawRoute(destination: "10.9.0.0/16", gateway: "link#18", interfaceName: "utun0", isDefault: false)
        let promoted = detector.assess(snapshot(interfaces: system, routes: systemRoutes + [referenced]))
        XCTAssertEqual(promoted.state, .active, "A forwarding route turns a system-looking utun into VPN evidence")

        let missing = detector.assess(snapshot(interfaces: system, routes: systemRoutes + [RawRoute(destination: "fe80::%utun7/64", gateway: "fe80::7%utun7", interfaceName: "utun7", isDefault: false)]))
        XCTAssertEqual(missing.reasonCode, .conflictingSignals)
    }

    func testDisconnectStabilizationNeedsMultipleConsistentSamples() async {
        let collector = FixtureCollector([.noVPN, .noVPN, .noVPN])
        let result = await detector.stabilizeAfterDisconnect(collecting: collector, interval: .zero)
        XCTAssertEqual(result.state, .inactive)
        let count = await collector.count
        XCTAssertEqual(count, 3)
    }

    func testDisconnectTransitionNeverReportsInactive() async {
        let collector = FixtureCollector([.activeTunnel, .noVPN, .noVPN])
        let result = await detector.stabilizeAfterDisconnect(collecting: collector, interval: .zero)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reasonCode, .conflictingSignals)
    }

    func testResidualObservationKeepsResultUnknownAfterLaterCleanSamples() async {
        let collector = FixtureCollector([.residualTunnel, .noVPN, .noVPN])
        let result = await detector.stabilizeAfterDisconnect(collecting: collector, interval: .zero)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reasonCode, .residualTunnel)
        let count = await collector.count
        XCTAssertEqual(count, 3)
    }

    func testStabilizationWindowExpiresWithoutHostVPN() async {
        let collector = SlowFixtureCollector()
        let start = ContinuousClock().now
        let result = await detector.stabilizeAfterDisconnect(
            collecting: collector, interval: .zero, window: .milliseconds(10))
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reasonCode, .stabilizationTimedOut)
        XCTAssertLessThan(start.duration(to: ContinuousClock().now), .milliseconds(150))
    }

    func testObserverPublishesOnlyChanges() async {
        let raw = AsyncStream<RawNetworkSnapshot> { continuation in
            continuation.yield(VPNFixtures.snapshot(.noVPN))
            continuation.yield(VPNFixtures.snapshot(.noVPN))
            continuation.yield(VPNFixtures.snapshot(.activeTunnel))
            continuation.finish()
        }
        var states: [VPNState] = []
        for await assessment in detector.changes(from: raw) { states.append(assessment.state) }
        XCTAssertEqual(states, [.inactive, .active])
    }

    func testObserverTreatsChangedPathAsUnknown() async {
        let first = VPNFixtures.snapshot(.noVPN)
        let changed = RawNetworkSnapshot(
            startedAt: first.startedAt, endedAt: first.endedAt,
            path: RawPathState(status: "satisfied", availableInterfaces: ["en1"],
                               selectedInterfaces: ["en1"], supportsDNS: true,
                               supportsIPv4: true, supportsIPv6: true, gateways: ["192.0.2.2"]),
            interfaces: [RawInterface(name: "en1", type: "wifi", isUp: true, addresses: [])],
            routes: [], resolvers: [], proxy: nil, dynamicStoreVPNKeys: [], errors: [])
        let input = AsyncStream<RawNetworkSnapshot> { continuation in
            continuation.yield(first)
            continuation.yield(changed)
            continuation.finish()
        }
        var assessments: [VPNAssessment] = []
        for await value in detector.changes(from: input) { assessments.append(value) }
        XCTAssertEqual(assessments.map(\.state), [.inactive, .unknown])
        XCTAssertEqual(assessments.last?.reasonCode, .pathTransition)
    }
}

private struct SlowFixtureCollector: NetworkStateCollecting {
    func collect() async -> RawNetworkSnapshot {
        // This fake deliberately ignores Task cancellation to verify that the
        // stabilizer's deadline does not wait for a misbehaving collector.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                continuation.resume()
            }
        }
        return VPNFixtures.snapshot(.noVPN)
    }
}

private actor FixtureCollector: NetworkStateCollecting {
    private let scenarios: [VPNFixtures.Scenario]
    private(set) var count = 0

    init(_ scenarios: [VPNFixtures.Scenario]) { self.scenarios = scenarios }

    func collect() async -> RawNetworkSnapshot {
        let index = min(count, scenarios.count - 1)
        count += 1
        return VPNFixtures.snapshot(scenarios[index])
    }
}
