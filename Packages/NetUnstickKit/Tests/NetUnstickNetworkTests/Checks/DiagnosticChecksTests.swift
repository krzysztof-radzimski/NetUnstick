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

}
