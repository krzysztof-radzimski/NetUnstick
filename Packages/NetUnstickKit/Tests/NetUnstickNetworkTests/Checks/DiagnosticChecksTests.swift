import Foundation
import XCTest
import NetUnstickNetwork

private struct FixedProbe: NetworkConnectivityProbing {
    let dns: ProbeOutcome
    let internet: ProbeOutcome
    var delay: Duration = .zero
    func resolveFixedName() async -> ProbeOutcome { try? await Task.sleep(for: delay); return dns }
    func probeInternet() async -> ProbeOutcome { try? await Task.sleep(for: delay); return internet }
}

final class DiagnosticChecksTests: XCTestCase {
    private func result(_ kind: NetworkCheckKind, _ snapshot: RawNetworkSnapshot,
                        probe: any NetworkConnectivityProbing = FixedProbe(dns: .reachable, internet: .reachable),
                        timeout: Duration? = nil) async -> String? {
        let output = await SnapshotDiagnosticCheck(kind: kind, snapshot: snapshot, probe: probe, timeout: timeout).run(context: .init())
        return output.after.values[.errorCode]
    }

    func testVPNFixturesProduceDistinctReasons() async {
        let cases: [(VPNFixtures.Scenario, NetworkCheckKind, NetworkCheckReason)] = [
            (.noVPN, .physicalLink, .healthy),
            (.noVPN, .defaultRoute, .healthy),
            (.noVPN, .resolverConfiguration, .healthy),
            (.noVPN, .unicastDNSResolution, .healthy),
            (.noVPN, .internetPath, .internetReachable),
            (.fullTunnel, .defaultRoute, .healthy),
            (.scopedDNS, .resolverConfiguration, .residualScopedDNS),
            (.residualTunnel, .interfaceConsistency, .orphanedTunnel),
            (.pathTransition, .interfaceConsistency, .unstableAfterDisconnect),
            (.timeout, .defaultRoute, .timedOut),
            (.permissionDenied, .resolverConfiguration, .dataIncomplete)
        ]
        for (scenario, kind, expected) in cases {
            let actual = await result(kind, VPNFixtures.snapshot(scenario))
            XCTAssertEqual(actual, expected.rawValue)
        }
    }

    func testSensitiveFixtureValuesNeverAppearInResult() async throws {
        let raw = VPNFixtures.snapshot(.scopedDNS)
        let result = await SnapshotDiagnosticCheck(kind: .resolverConfiguration, snapshot: raw).run(context: .init())
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for secret in ["private.example", "10.0.0.53", "192.0.2.10", "utun5", "en0"] {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testDNSProbeClassifiesNXDomainAndTimeout() async {
        let snapshot = VPNFixtures.snapshot(.noVPN)
        let nxdomain = await result(.unicastDNSResolution, snapshot, probe: FixedProbe(dns: .nxdomain, internet: .reachable))
        XCTAssertEqual(nxdomain, NetworkCheckReason.dnsNXDomain.rawValue)
        let dnsTimeout = await result(.unicastDNSResolution, snapshot, probe: FixedProbe(dns: .timeout, internet: .reachable))
        XCTAssertEqual(dnsTimeout, NetworkCheckReason.dnsTimeout.rawValue)
        let checkTimeout = await result(.unicastDNSResolution, snapshot, probe: FixedProbe(dns: .reachable, internet: .reachable, delay: .seconds(1)), timeout: .milliseconds(10))
        XCTAssertEqual(checkTimeout, NetworkCheckReason.timedOut.rawValue)
    }

    func testConcurrentCancellationReturnsCancelled() async {
        let snapshot = VPNFixtures.snapshot(.noVPN)
        let probe = FixedProbe(dns: .reachable, internet: .reachable, delay: .seconds(5))
        let tasks = (0..<8).map { _ in Task {
            await SnapshotDiagnosticCheck(kind: .unicastDNSResolution, snapshot: snapshot, probe: probe).run(context: .init())
        }}
        tasks.forEach { $0.cancel() }
        for task in tasks { let output = await task.value; XCTAssertEqual(output.outcome, .cancelled) }
    }
    func testRouteLeaseProxyAndResolverDecisionTable() async {
        let base = VPNFixtures.snapshot(.noVPN)
        func changed(interfaces: [RawInterface]? = nil, routes: [RawRoute]? = nil,
                     resolvers: [RawResolver]? = nil, proxy: RawProxy? = nil,
                     path: RawPathState? = nil) -> RawNetworkSnapshot {
            RawNetworkSnapshot(startedAt: base.startedAt, endedAt: base.endedAt,
                path: path ?? base.path, interfaces: interfaces ?? base.interfaces,
                routes: routes ?? base.routes, resolvers: resolvers ?? base.resolvers,
                proxy: proxy ?? RawProxy(settings: [:]), dynamicStoreVPNKeys: [], errors: [])
        }
        let local = RawRoute(destination: "192.0.2.0/24", gateway: nil, interfaceName: "en0", isDefault: false, isLocal: true)
        let hijacked = RawRoute(destination: "192.0.2.0/24", gateway: nil, interfaceName: "utun5", isDefault: false)
        let tunnelDNS = RawResolver(domain: "private.example", searchDomains: ["private.example"], nameservers: ["10.0.0.53"], interfaceName: "utun5")
        let cases: [(NetworkCheckKind, RawNetworkSnapshot, NetworkCheckReason)] = [
            (.localSubnetRoute, changed(routes: base.routes + [local]), .healthy),
            (.localSubnetRoute, changed(routes: base.routes + [hijacked]), .localRouteViaTunnel),
            (.localSubnetRoute, changed(routes: base.routes + [local, hijacked]), .localRouteViaTunnel),
            (.interfaceConsistency, changed(routes: base.routes + [local, hijacked]), .expectedInterfaceMissing),
            (.interfaceConsistency, changed(interfaces: base.interfaces + [RawInterface(name: "utun5", type: "tunnel", isUp: true, addresses: ["10.1.2.4"])], routes: base.routes + [local, hijacked]), .routingConflict),
            (.physicalLink, changed(interfaces: [RawInterface(name: "en0", type: "wifi", isUp: true, addresses: ["169.254.1.1"])]), .noAddressLease),
            (.defaultRoute, changed(routes: []), .dataIncomplete),
            (.defaultRoute, changed(routes: [local]), .noDefaultRoute),
            (.resolverConfiguration, changed(interfaces: base.interfaces + [RawInterface(name: "utun5", type: "tunnel", isUp: true, addresses: ["10.1.2.4"])], resolvers: [tunnelDNS] + base.resolvers), .resolverOrder),
            (.proxyConfiguration, changed(proxy: RawProxy(settings: ["HTTPEnable": "1", "HTTPProxy": "secret.corp"])), .activeProxy),
            (.proxyConfiguration, changed(proxy: RawProxy(settings: ["ProxyAutoConfigEnable": "1", "ProxyAutoConfigURLString": "https://secret.corp/pac"])), .activePAC),
            (.physicalLink, changed(path: RawPathState(status: "unsatisfied", availableInterfaces: [], selectedInterfaces: [], supportsDNS: false, supportsIPv4: false, supportsIPv6: false, gateways: [])), .environmentLimited)
        ]
        for (kind, snapshot, expected) in cases {
            let actual = await result(kind, snapshot)
            XCTAssertEqual(actual, expected.rawValue)
        }
    }

    /// The host's own /32 stays physical while a VPN client's split of the LAN prefix
    /// diverts every neighbour into the old tunnel. System utun devices never count.
    func testSplitLANShadowIsDetectedDespitePhysicalHostRoute() async {
        let base = VPNFixtures.snapshot(.noVPN)
        let loopback = RawInterface(name: "lo0", type: "loopback", isUp: true, addresses: ["127.0.0.1", "::1"])
        func changed(interfaces: [RawInterface], routes: [RawRoute]) -> RawNetworkSnapshot {
            RawNetworkSnapshot(startedAt: base.startedAt, endedAt: base.endedAt,
                path: base.path, interfaces: base.interfaces + [loopback] + interfaces, routes: base.routes + routes,
                resolvers: base.resolvers, proxy: RawProxy(settings: [:]), dynamicStoreVPNKeys: [], errors: [],
                vpnServices: .disconnected)
        }
        let lan = RawRoute(destination: "192.0.2", gateway: "link#14", interfaceName: "en0", isDefault: false, isLocal: true)
        let selfHost = RawRoute(destination: "192.0.2.10/32", gateway: "link#14", interfaceName: "en0", isDefault: false, isLocal: true)
        let selfLoopback = RawRoute(destination: "192.0.2.10", gateway: "2:51:b5:16:dd:73", interfaceName: "lo0", isDefault: false, isLocal: true, isCloned: true)
        let arp = RawRoute(destination: "192.0.2.1", gateway: "d8:33:b7:3d:30:0", interfaceName: "en0", isDefault: false, isLocal: true, isCloned: true)
        let system = RawInterface(name: "utun0", type: "tunnel", isUp: true, addresses: ["fe80::1%utun0"])
        let systemRoutes = [RawRoute(destination: "fe80::%utun0/64", gateway: "fe80::1%utun0", interfaceName: "utun0", isDefault: false, isScoped: true),
                            RawRoute(destination: "ff02::%utun0/32", gateway: "link#18", interfaceName: "utun0", isDefault: false, isLocal: true)]
        let leftover = RawInterface(name: "utun4", type: "tunnel", isUp: true, addresses: ["10.100.101.10"])
        let split = ["192.0.2/32", "192.0.2.2/31", "192.0.2.4/30", "192.0.2.8/29", "192.0.2.16/28", "192.0.2.32/27", "192.0.2.64/26", "192.0.2.128/25"]
            .map { RawRoute(destination: $0, gateway: "10.100.101.10", interfaceName: "utun4", isDefault: false) }
        let ownHost = RawRoute(destination: "10.100.101.10", gateway: "10.100.101.10", interfaceName: "utun4", isDefault: false, isLocal: true)
        let clean = changed(interfaces: [system], routes: [lan, selfHost, selfLoopback, arp] + systemRoutes)
        let shadowed = changed(interfaces: [system, leftover], routes: [lan, selfHost, selfLoopback, arp, ownHost] + systemRoutes + split)
        let stale = changed(interfaces: [system, leftover], routes: [lan, selfHost, selfLoopback, arp, ownHost] + systemRoutes)
        let cases: [(String, NetworkCheckKind, RawNetworkSnapshot, NetworkCheckReason)] = [
            ("clean LAN", .localSubnetRoute, clean, .healthy),
            ("split shadow", .localSubnetRoute, shadowed, .localRouteViaTunnel),
            ("tunnel without routes", .localSubnetRoute, stale, .healthy),
            ("system utun only", .interfaceConsistency, clean, .healthy),
            ("shadow keeps tunnel referenced", .interfaceConsistency, shadowed, .healthy),
            ("leftover tunnel without routes", .interfaceConsistency, stale, .orphanedTunnel),
            ("system utun default", .defaultRoute, clean, .healthy)
        ]
        for (name, kind, snapshot, expected) in cases {
            let actual = await result(kind, snapshot)
            XCTAssertEqual(actual, expected.rawValue, name)
        }
    }

    /// A desktop with Ethernet and Wi-Fi on the same network carries interface-scoped copies of
    /// the connected route; that is consistent. An unscoped copy through a tunnel, or a route
    /// through a tunnel that is not up, is not.
    func testSecondInterfaceOnTheSameNetworkIsNotARoutingConflict() async {
        let base = VPNFixtures.snapshot(.noVPN)
        func changed(interfaces: [RawInterface], routes: [RawRoute]) -> RawNetworkSnapshot {
            RawNetworkSnapshot(startedAt: base.startedAt, endedAt: base.endedAt,
                path: base.path, interfaces: base.interfaces + interfaces, routes: base.routes + routes,
                resolvers: base.resolvers, proxy: RawProxy(settings: [:]), dynamicStoreVPNKeys: [], errors: [],
                vpnServices: .disconnected)
        }
        let ethernet = RawInterface(name: "en1", type: "ethernet", isUp: true, addresses: ["192.0.2.11"])
        let wifiLAN = RawRoute(destination: "192.0.2", gateway: "link#14", interfaceName: "en0", isDefault: false, isLocal: true)
        let ethernetLAN = RawRoute(destination: "192.0.2", gateway: "link#15", interfaceName: "en1", isDefault: false, isLocal: true, isScoped: true)
        let ethernetGateway = RawRoute(destination: "192.0.2.1/32", gateway: "link#15", interfaceName: "en1", isDefault: false, isLocal: true, isScoped: true)
        let wifiGateway = RawRoute(destination: "192.0.2.1/32", gateway: "link#14", interfaceName: "en0", isDefault: false, isLocal: true)
        let dualHomed = changed(interfaces: [ethernet], routes: [wifiLAN, wifiGateway, ethernetLAN, ethernetGateway])
        let downTunnel = RawInterface(name: "utun4", type: "tunnel", isUp: false, addresses: ["10.5.0.2"])
        let staleForwarding = RawRoute(destination: "10.20.0.0/16", gateway: "10.5.0.1", interfaceName: "utun4", isDefault: false)
        let inactiveTunnel = changed(interfaces: [ethernet, downTunnel], routes: [wifiLAN, ethernetLAN, staleForwarding])
        let upTunnel = RawInterface(name: "utun5", type: "tunnel", isUp: true, addresses: ["10.1.2.4"])
        let hijacked = RawRoute(destination: "192.0.2", gateway: "10.1.2.1", interfaceName: "utun5", isDefault: false)
        let conflict = changed(interfaces: [ethernet, upTunnel], routes: [wifiLAN, ethernetLAN, hijacked])
        let cases: [(String, RawNetworkSnapshot, NetworkCheckReason)] = [
            ("ethernet and wifi on one network", dualHomed, .healthy),
            ("forwarding route through a down tunnel", inactiveTunnel, .routeViaInactiveTunnel),
            ("unscoped tunnel copy of the connected network", conflict, .routingConflict)
        ]
        for (name, snapshot, expected) in cases {
            let actual = await result(.interfaceConsistency, snapshot)
            XCTAssertEqual(actual, expected.rawValue, name)
        }
        let local = await result(.localSubnetRoute, dualHomed)
        XCTAssertEqual(local, NetworkCheckReason.healthy.rawValue, "Both physical interfaces serve the LAN")
    }

    func testIPv6LocalRouteAndDuplicateDefault() async {
        let base = VPNFixtures.snapshot(.noVPN)
        let ipv6 = RawInterface(name: "en0", type: "wifi", isUp: true, addresses: ["2001:db8:1::2"])
        let ipv6Local = RawRoute(destination: "2001:db8:1::/64", gateway: nil, interfaceName: "en0", isDefault: false, isLocal: true)
        let duplicate = RawRoute(destination: "0.0.0.0/0", gateway: "192.0.2.2", interfaceName: "en0", isDefault: true)
        let raw = RawNetworkSnapshot(startedAt: base.startedAt, endedAt: base.endedAt,
            path: base.path, interfaces: [ipv6], routes: base.routes + [ipv6Local, duplicate],
            resolvers: base.resolvers, proxy: RawProxy(settings: [:]), dynamicStoreVPNKeys: [], errors: [])
        let localResult = await result(.localSubnetRoute, raw)
        let defaultResult = await result(.defaultRoute, raw)
        XCTAssertEqual(localResult, NetworkCheckReason.healthy.rawValue)
        XCTAssertEqual(defaultResult, NetworkCheckReason.duplicateDefaultRoute.rawValue)
    }

    func testScopedIPv6DefaultsDoNotReportResidualVPNDefault() async {
        let base = VPNFixtures.snapshot(.noVPN)
        let table = """
        Destination Gateway Flags Netif Expire
        default fe80::1%utun4 UGcIg utun4
        default fe80::2%utun5 UGcIg utun5
        """
        let raw = RawNetworkSnapshot(startedAt: base.startedAt, endedAt: base.endedAt,
            path: base.path, interfaces: base.interfaces,
            routes: base.routes + NetstatRouteParser.parse(table, family: "ipv6"),
            resolvers: base.resolvers, proxy: base.proxy, dynamicStoreVPNKeys: [], errors: [])
        let defaultResult = await result(.defaultRoute, raw)
        XCTAssertEqual(defaultResult, NetworkCheckReason.healthy.rawValue)
    }

}
