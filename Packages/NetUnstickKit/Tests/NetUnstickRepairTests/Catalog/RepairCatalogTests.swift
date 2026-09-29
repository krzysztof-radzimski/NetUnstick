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
        XCTAssertFalse(dns.plans.contains { $0.kind == .refreshResolverCache })
        XCTAssertTrue(dns.plans.contains { $0.kind == .retryCheck && $0.checkID == "unicast_dns_resolution" })
        XCTAssertTrue(dns.plans.contains { $0.kind == .retryCheck && $0.checkID == "bonjour_discovery" })
        let dhcp = await plans(snapshot(address: "169.254.1.3"))
        XCTAssertTrue(dhcp.plans.contains { $0.kind == .renewDHCP && $0.checkID == "physical_link" })
        let noDHCP = await plans(snapshot(address: "169.254.1.3"), dhcp: [])
        XCTAssertFalse(noDHCP.plans.contains { $0.kind == .renewDHCP })
        let route = RawRoute(destination: "10.2.3.0/24", gateway: "10.2.3.1", interfaceName: "en1", isDefault: false, isLocal: true)
        let orphan = await plans(snapshot(route: route))
        XCTAssertFalse(orphan.plans.contains { $0.kind == .removeStaleTunnelRoutes })
        XCTAssertTrue(orphan.nextSteps.contains(NextStep.contactSupport.rawValue))
        let defaultRoute = await plans(snapshot(route: .init(destination: "0.0.0.0/0", gateway: "10.2.3.1", interfaceName: "en1", isDefault: true)))
        XCTAssertFalse(defaultRoute.plans.contains { $0.kind == .removeStaleTunnelRoutes })
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
        XCTAssertThrowsError(try RepairPolicy.authorize(
            .init(action: .removeStaleTunnelRoutes(routes: [.init(destination: "10.2.3.0", prefix: 24, interface: "utun9")])),
            snapshot: snap, dhcpInterfaces: []))
    }

    private func splitLeftoverSnapshot(count: Int = 8) -> RawNetworkSnapshot {
        let now = Date(timeIntervalSince1970: 1_000)
        let split = ["192.168.44/32", "192.168.44.2/31", "192.168.44.4/30", "192.168.44.8/29",
                     "192.168.44.16/28", "192.168.44.32/27", "192.168.44.64/26", "192.168.44.128/25"]
        return RawNetworkSnapshot(startedAt: now, endedAt: now,
            path: .init(status: "satisfied", availableInterfaces: ["en0", "utun4"],
                        selectedInterfaces: ["en0"], supportsDNS: true, supportsIPv4: true,
                        supportsIPv6: false, gateways: ["192.168.44.1"]),
            interfaces: [.init(name: "en0", type: "wifi", isUp: true, addresses: ["192.168.44.40"]),
                         .init(name: "utun0", type: "tunnel", isUp: true, addresses: ["fe80::1%utun0"]),
                         .init(name: "utun4", type: "tunnel", isUp: true, addresses: ["10.5.0.2"])],
            routes: [.init(destination: "0.0.0.0/0", gateway: "192.168.44.1",
                           interfaceName: "en0", isDefault: true),
                     .init(destination: "192.168.44", gateway: "link#8",
                           interfaceName: "en0", isDefault: false, isLocal: true),
                     .init(destination: "192.168.44.40/32", gateway: "link#8",
                           interfaceName: "en0", isDefault: false, isLocal: true),
                     .init(destination: "fe80::%utun0/64", gateway: "fe80::1%utun0",
                           interfaceName: "utun0", isDefault: false, isScoped: true),
                     .init(destination: "10.5.0.2", gateway: "10.5.0.2",
                           interfaceName: "utun4", isDefault: false, isLocal: true)] +
                split.prefix(count).map { .init(destination: $0, gateway: "10.5.0.1", interfaceName: "utun4", isDefault: false) },
            resolvers: [.init(domain: nil, searchDomains: [], nameservers: ["192.168.44.1"],
                              interfaceName: "en0")], proxy: nil, dynamicStoreVPNKeys: [],
            errors: [], vpnServices: .disconnected)
    }

    func testDisconnectedTunnelShadowingLANOffersOneGroupedRepair() async {
        let snap = splitLeftoverSnapshot()
        let result = await plans(snap)
        XCTAssertEqual(result.plans.map(\.kind), [.removeStaleTunnelRoutes])
        let plan = try? XCTUnwrap(result.plans.first)
        XCTAssertEqual(plan?.checkID, "local_subnet_route")
        XCTAssertEqual(plan?.reasonCode, NetworkCheckReason.localRouteViaTunnel.rawValue)
        XCTAssertTrue(plan.map(RepairCatalog.permits) ?? false)
        guard case .tunnelRoutes(let routes)? = plan?.resource else { return XCTFail("Grouped resource expected") }
        XCTAssertEqual(routes.count, 8)
        XCTAssertEqual(routes.first?.cidr, "192.168.44.0/32")
        XCTAssertEqual(routes.last?.cidr, "192.168.44.128/25")
        XCTAssertEqual(plan?.summary.change, "Usunięcie tras pozostałych po VPN (8)")
        XCTAssertEqual(plan?.summary.resource, "8 tras tunelowych nakładających się na lokalną sieć")
        XCTAssertTrue(plan?.summary.requiresAdministrator == true)
        XCTAssertTrue(result.nextSteps.isEmpty)

        let single = await plans(splitLeftoverSnapshot(count: 1))
        XCTAssertEqual(single.plans.first?.summary.resource, "1 trasa tunelowa nakładająca się na lokalną sieć")
        XCTAssertEqual(RepairPlanBuilder.routeLabel(3), "3 trasy tunelowe nakładające się na lokalną sieć")
        XCTAssertEqual(RepairPlanBuilder.routeLabel(12), "12 tras tunelowych nakładających się na lokalną sieć")
        XCTAssertEqual(RepairPlanBuilder.routeLabel(22), "22 trasy tunelowe nakładające się na lokalną sieć")

        let oversized = RepairPlan(kind: .removeStaleTunnelRoutes, reasonCode: NetworkCheckReason.localRouteViaTunnel.rawValue,
            checkID: "local_subnet_route",
            resource: .tunnelRoutes((0...RepairPolicy.maximumStaleTunnelRoutes).map {
                StaleTunnelRoute(destination: "192.168.44.\($0)", prefix: 32, interface: "utun4", gateway: "10.5.0.1") }),
            summary: plan!.summary)
        XCTAssertFalse(RepairCatalog.permits(oversized))
        XCTAssertFalse(RepairCatalog.permits(RepairPlan(kind: .removeStaleTunnelRoutes, reasonCode: plan!.reasonCode,
            checkID: plan!.checkID, resource: .tunnelRoutes([]), summary: plan!.summary)))
    }

    func testConfirmationSummariesDescribeActionsWithoutSensitiveValues() async {
        let candidates = await plans(snapshot(address: "192.168.1.2"))
        XCTAssertFalse(candidates.plans.isEmpty)
        let grouped = await plans(splitLeftoverSnapshot())
        for plan in candidates.plans + grouped.plans {
            let summary = plan.summary
            let text = [summary.change, summary.resource, summary.purpose,
                        summary.possibleImpact, summary.verification].joined(separator: " ")
            XCTAssertFalse(text.contains("en0"))
            XCTAssertFalse(text.contains("192.168"))
            XCTAssertFalse(text.contains("utun"))
            XCTAssertFalse(text.contains("10.5.0"))
            XCTAssertFalse(summary.verification.isEmpty)
        }
    }
}
