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
