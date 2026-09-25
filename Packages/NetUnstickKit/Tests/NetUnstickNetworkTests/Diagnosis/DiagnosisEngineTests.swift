import Foundation
import XCTest
import NetUnstickNetwork

private struct DiagnosisFixtureCollector: NetworkStateCollecting {
    let snapshot: RawNetworkSnapshot
    func collect() async -> RawNetworkSnapshot { snapshot }
}
private struct DiagnosisFixedProbe: NetworkConnectivityProbing {
    func resolveFixedName() async -> ProbeOutcome { .reachable }
    func probeInternet() async -> ProbeOutcome { .reachable }
}

final class DiagnosisEngineTests: XCTestCase {
    func testTwoSymptomsRemainSeparateCandidatesAndVPNFlagsRecommendations() async {
        let baseline = VPNFixtures.snapshot(.noVPN)
        let raw = RawNetworkSnapshot(startedAt: baseline.startedAt, endedAt: baseline.endedAt,
            path: baseline.path, interfaces: baseline.interfaces + [RawInterface(name: "utun9", type: "tunnel", isUp: false, addresses: [])],
            routes: baseline.routes + [RawRoute(destination: "default", gateway: nil, interfaceName: "utun9", isDefault: true)],
            resolvers: baseline.resolvers + [RawResolver(domain: "secret.corp", searchDomains: ["secret.corp"], nameservers: ["10.1.2.3"], interfaceName: "utun9")],
            proxy: RawProxy(settings: ["HTTPEnable": "1", "HTTPProxy": "secret.corp"]),
            dynamicStoreVPNKeys: [], errors: [])
        let report = await DiagnosisEngine(collector: DiagnosisFixtureCollector(snapshot: raw), probe: DiagnosisFixedProbe()).diagnose()
        let codes = Set(report.candidates.map(\.reasonCode))
        XCTAssertTrue(codes.contains(NetworkCheckReason.residualDefaultRoute.rawValue))
        XCTAssertTrue(codes.contains(NetworkCheckReason.residualScopedDNS.rawValue))
        XCTAssertTrue(codes.contains(NetworkCheckReason.activeProxy.rawValue))
        XCTAssertTrue(report.candidates.allSatisfy(\.unsafeWhileVPNPresent))
        XCTAssertEqual(report.state, .fault)
    }

    func testIncompleteSnapshotIsInconclusive() async {
        let now = Date()
        let raw = RawNetworkSnapshot(startedAt: now, endedAt: now, path: nil, interfaces: [], routes: [],
                                     resolvers: [], proxy: nil, dynamicStoreVPNKeys: [], errors: [])
        let report = await DiagnosisEngine(collector: DiagnosisFixtureCollector(snapshot: raw), probe: DiagnosisFixedProbe()).diagnose()
        XCTAssertEqual(report.state, .insufficientData)
    }
    func testNormalOfflineIsEnvironmentLimited() async {
        let base = VPNFixtures.snapshot(.noVPN)
        let offline = RawNetworkSnapshot(startedAt: base.startedAt, endedAt: base.endedAt,
            path: RawPathState(status: "unsatisfied", availableInterfaces: [], selectedInterfaces: [],
                               supportsDNS: false, supportsIPv4: false, supportsIPv6: false, gateways: []),
            interfaces: [RawInterface(name: "en0", type: "wifi", isUp: false, addresses: [])],
            routes: [], resolvers: [], proxy: RawProxy(settings: [:]), dynamicStoreVPNKeys: [], errors: [])
        let report = await DiagnosisEngine(collector: DiagnosisFixtureCollector(snapshot: offline), probe: DiagnosisFixedProbe()).diagnose()
        XCTAssertEqual(report.state, .environmentLimited)
        XCTAssertTrue(report.candidates.isEmpty)
    }

    func testCollectionTimeoutProducesIncompleteDiagnosis() async {
        struct SlowCollector: NetworkStateCollecting {
            func collect() async -> RawNetworkSnapshot {
                try? await Task.sleep(for: .seconds(5))
                return VPNFixtures.snapshot(.noVPN)
            }
        }
        let report = await DiagnosisEngine(collector: SlowCollector(), probe: DiagnosisFixedProbe(),
                                           collectionTimeout: .milliseconds(10)).diagnose()
        XCTAssertEqual(report.state, .insufficientData)
        XCTAssertEqual(report.vpn.state, .unknown)
        XCTAssertTrue(report.results.contains(where: { $0.outcome == .timedOut }))
    }

    func testHealthySnapshotHasNoCandidates() async {
        let base = VPNFixtures.snapshot(.noVPN)
        let local = RawRoute(destination: "192.0.2.0/24", gateway: nil, interfaceName: "en0", isDefault: false, isLocal: true)
        let raw = RawNetworkSnapshot(startedAt: base.startedAt, endedAt: base.endedAt,
            path: base.path, interfaces: base.interfaces, routes: base.routes + [local],
            resolvers: base.resolvers, proxy: RawProxy(settings: [:]), dynamicStoreVPNKeys: [], errors: [])
        let report = await DiagnosisEngine(collector: DiagnosisFixtureCollector(snapshot: raw), probe: DiagnosisFixedProbe()).diagnose()
        XCTAssertEqual(report.state, .healthy)
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertEqual(report.results.count, 8)
    }

}
