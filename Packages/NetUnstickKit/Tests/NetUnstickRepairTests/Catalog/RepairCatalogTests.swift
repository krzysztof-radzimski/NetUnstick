import Foundation
import XCTest
import NetUnstickCore
import NetUnstickNetwork
@testable import NetUnstickRepair

private struct CatalogCollector: NetworkStateCollecting {
    let snapshot: RawNetworkSnapshot
    func collect() async -> RawNetworkSnapshot { snapshot }
}
private struct CatalogProbe: NetworkConnectivityProbing {
    func resolveFixedName() async -> ProbeOutcome { .failed }
    func probeInternet() async -> ProbeOutcome { .reachable }
}
private struct CatalogBrowser: BonjourBrowsing {
    func browse(_ service: BonjourService, timeout: Duration) async -> BonjourObservation {
        .init(count: 0, reason: .noServices)
    }
}

final class RepairCatalogTests: XCTestCase {
    private func snapshot(address: String = "192.168.1.2", proxy: RawProxy? = nil,
                          route: RawRoute? = nil, tunnel: Bool = false) -> RawNetworkSnapshot {
        let now = Date(timeIntervalSince1970: 1_000)
        return RawNetworkSnapshot(startedAt: now, endedAt: now,
            path: .init(status: "satisfied", availableInterfaces: ["en0"], selectedInterfaces: ["en0"],
                        supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: ["192.168.1.1"]),
            interfaces: [RawInterface(name: "en0", type: "wifi", isUp: true, addresses: [address])] +
                (tunnel ? [RawInterface(name: "utun1", type: "other", isUp: false, addresses: [])] : []),
            routes: [RawRoute(destination: "0.0.0.0/0", gateway: "192.168.1.1", interfaceName: "en0", isDefault: true)] +
                (route.map { [$0] } ?? []),
            resolvers: [RawResolver(domain: nil, searchDomains: [], nameservers: ["192.168.1.1"], interfaceName: "en0")],
            proxy: proxy, dynamicStoreVPNKeys: [], errors: [])
    }
    private func plans(_ snap: RawNetworkSnapshot, dhcp: Set<String> = ["en0"]) async -> RepairPlanningResult {
        let engine = DiagnosisEngine(collector: CatalogCollector(snapshot: snap), probe: CatalogProbe(),
                                     bonjourBrowser: CatalogBrowser())
        let report = await engine.diagnose()
        return RepairPlanBuilder().build(report: report, snapshot: snap, dhcpInterfaces: dhcp)
    }

    func testOnlyExactResourcesArePlanned() async {
        let dns = await plans(snapshot())
        XCTAssertTrue(dns.plans.contains { $0.kind == .refreshResolverCache && $0.checkID == "unicast_dns_resolution" })
        XCTAssertTrue(dns.plans.contains { $0.kind == .retryCheck && $0.checkID == "bonjour_discovery" })
        let dhcp = await plans(snapshot(address: "169.254.1.3"))
        XCTAssertTrue(dhcp.plans.contains { $0.kind == .renewDHCP && $0.checkID == "physical_link" })
        let noDHCP = await plans(snapshot(address: "169.254.1.3"), dhcp: [])
        XCTAssertFalse(noDHCP.plans.contains { $0.kind == .renewDHCP })
        let route = RawRoute(destination: "10.2.3.0/24", gateway: "10.2.3.1", interfaceName: "en1", isDefault: false, isLocal: true)
        let orphan = await plans(snapshot(route: route))
        XCTAssertFalse(orphan.plans.contains { $0.kind == .removeOrphanedRoute })
        XCTAssertTrue(orphan.nextSteps.contains(NextStep.contactSupport.rawValue))
        let defaultRoute = await plans(snapshot(route: .init(destination: "0.0.0.0/0", gateway: "10.2.3.1", interfaceName: "en1", isDefault: true)))
        XCTAssertFalse(defaultRoute.plans.contains { $0.kind == .removeOrphanedRoute })
    }

    func testVPNAndProxyDoNotOfferChanges() async {
        let vpn = await plans(snapshot(tunnel: true))
        XCTAssertTrue(vpn.plans.isEmpty)
        XCTAssertEqual(vpn.nextSteps, [NextStep.verifyVPN.rawValue])
        let proxy = await plans(snapshot(proxy: RawProxy(settings: ["HTTPEnable": "1"])))
        XCTAssertFalse(proxy.plans.contains { $0.checkID == "proxy_configuration" })
    }

    func testMissingTunnelRouteIsUnknownAndCannotCrossHelperPolicy() async {
        let route = RawRoute(destination: "10.2.3.0/24", gateway: "10.2.3.1",
                             interfaceName: "utun9", isDefault: false, isLocal: true)
        let snap = snapshot(route: route)
        XCTAssertEqual(VPNStateDetector().assess(snap).state, .unknown)
        let planned = await plans(snap)
        XCTAssertTrue(planned.plans.isEmpty)
        XCTAssertEqual(planned.nextSteps, [NextStep.verifyVPN.rawValue])
        XCTAssertThrowsError(try RepairPolicy.authorize(
            .init(action: .removeOrphanedRoute(destination: "10.2.3.0", prefix: 24, interface: "utun9")),
            snapshot: snap, dhcpInterfaces: []))
    }

    func testConfirmationSummariesDescribeActionsWithoutSensitiveValues() async {
        let candidates = await plans(snapshot(address: "192.168.1.2"))
        XCTAssertFalse(candidates.plans.isEmpty)
        for plan in candidates.plans {
            let summary = plan.summary
            let text = [summary.change, summary.resource, summary.purpose,
                        summary.possibleImpact, summary.verification].joined(separator: " ")
            XCTAssertFalse(text.contains("en0"))
            XCTAssertFalse(text.contains("192.168.1.2"))
            XCTAssertFalse(text.contains("utun"))
            XCTAssertFalse(summary.verification.isEmpty)
        }
    }
}
