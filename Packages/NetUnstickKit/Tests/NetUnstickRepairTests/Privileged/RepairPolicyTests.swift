import XCTest
import NetUnstickRepair
import NetUnstickNetwork
import Security

final class RepairPolicyTests: XCTestCase {
    private func snapshot(interfaces: [RawInterface] = [.init(name: "en0", type: "wifi", isUp: true, addresses: [])],
                          routes: [RawRoute] = [], errors: [NetworkCollectionError] = [], vpnKeys: [String] = []) -> RawNetworkSnapshot {
        RawNetworkSnapshot(startedAt: Date(), endedAt: Date(),
            path: .init(status: "satisfied", availableInterfaces: ["en0"], selectedInterfaces: ["en0"],
                        supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: []),
            interfaces: interfaces, routes: routes, resolvers: [], proxy: nil,
            dynamicStoreVPNKeys: vpnKeys, errors: errors)
    }
    func testProtocolAndPhysicalDHCP() throws {
        let good = PrivilegedRequest(action: .renewDHCP(interface: "en0"))
        XCTAssertEqual(try RepairPolicy.authorize(good, snapshot: snapshot(), dhcpInterfaces: ["en0"]), .renewDHCP("en0"))
        XCTAssertThrowsError(try RepairPolicy.authorize(.init(version: PrivilegedProtocol.version + 1, action: good.action), snapshot: snapshot(), dhcpInterfaces: ["en0"]))
        for name in ["utun0", "en*", "en0;id", "en99"] {
            XCTAssertThrowsError(try RepairPolicy.authorize(.init(action: .renewDHCP(interface: name)), snapshot: snapshot(), dhcpInterfaces: [name]))
        }
        XCTAssertThrowsError(try RepairPolicy.authorize(good, snapshot: snapshot(), dhcpInterfaces: []))
    }
    func testVPNAndExactRoute() throws {
        let request = PrivilegedRequest(action: .removeOrphanedRoute(destination: "192.168.40.0", prefix: 24, interface: "en8"))
        let route = RawRoute(destination: "192.168.40.0/24", gateway: "192.168.1.1", interfaceName: "en8", isDefault: false)
        XCTAssertEqual(try RepairPolicy.authorize(request, snapshot: snapshot(routes: [route]), dhcpInterfaces: []),
                       .removeRoute(destination: "192.168.40.0", prefix: 24, interface: "en8", gateway: "192.168.1.1"))
        for candidate in [PrivilegedRequest(action: .removeOrphanedRoute(destination: "0.0.0.0", prefix: 0, interface: "en8")),
                          .init(action: .removeOrphanedRoute(destination: "8.8.8.0", prefix: 24, interface: "en8")),
                          .init(action: .removeOrphanedRoute(destination: "192.168.40.0", prefix: 24, interface: "utun0"))] {
            XCTAssertThrowsError(try RepairPolicy.authorize(candidate, snapshot: snapshot(routes: [route]), dhcpInterfaces: []))
        }
        XCTAssertThrowsError(try RepairPolicy.authorize(request, snapshot: snapshot(routes: [route, route]), dhcpInterfaces: []))
        XCTAssertThrowsError(try RepairPolicy.authorize(request, snapshot: snapshot(routes: [route], vpnKeys: ["vpn"]), dhcpInterfaces: []))
        XCTAssertThrowsError(try RepairPolicy.authorize(request, snapshot: snapshot(routes: [route], errors: [.init(code: "read_failed")]), dhcpInterfaces: []))
    }

    /// A VPN client that excluded the gateway from the LAN prefix leaves the binary split of
    /// the /24 behind: eight unscoped entries through the old tunnel, one of them abbreviated by netstat.
    static let splitDestinations = ["192.168.44/32", "192.168.44.2/31", "192.168.44.4/30", "192.168.44.8/29",
                                    "192.168.44.16/28", "192.168.44.32/27", "192.168.44.64/26", "192.168.44.128/25"]
    static let splitTargets = [("192.168.44.0", 32), ("192.168.44.2", 31), ("192.168.44.4", 30), ("192.168.44.8", 29),
                               ("192.168.44.16", 28), ("192.168.44.32", 27), ("192.168.44.64", 26), ("192.168.44.128", 25)]
        .map { PrivilegedRouteTarget(destination: $0.0, prefix: $0.1, interface: "utun4") }
    static func splitRoutes(gateway: String = "10.5.0.1", scoped: Bool = false, cloned: Bool = false) -> [RawRoute] {
        splitDestinations.map { RawRoute(destination: $0, gateway: gateway, interfaceName: "utun4",
                                         isDefault: false, isScoped: scoped, isCloned: cloned) }
    }
    static func observed(_ routes: [RawRoute], service: VPNServiceStatus = .disconnected,
                         storeInterfaces: [String] = [], resolvers: [RawResolver] = [],
                         tunnelUp: Bool = true) -> RawNetworkSnapshot {
        let now = Date()
        return RawNetworkSnapshot(startedAt: now, endedAt: now,
            path: .init(status: "satisfied", availableInterfaces: ["en0", "utun4"],
                        selectedInterfaces: ["en0"], supportsDNS: true,
                        supportsIPv4: true, supportsIPv6: false, gateways: ["192.168.44.1"]),
            interfaces: [.init(name: "en0", type: "wifi", isUp: true, addresses: ["192.168.44.40", "fe80::1%en0"]),
                         .init(name: "utun4", type: "tunnel", isUp: tunnelUp, addresses: ["10.5.0.2"])],
            routes: routes, resolvers: resolvers, proxy: nil, dynamicStoreVPNKeys: [], errors: [],
            dynamicStoreTunnelInterfaces: storeInterfaces, vpnServices: service)
    }
    static let defaultRoute = RawRoute(destination: "default", gateway: "192.168.44.1", interfaceName: "en0", isDefault: true)
    static let lan = RawRoute(destination: "192.168.44", gateway: "link#8", interfaceName: "en0", isDefault: false, isLocal: true)
    static let selfHost = RawRoute(destination: "192.168.44.40/32", gateway: "link#8", interfaceName: "en0", isDefault: false, isLocal: true)
    static let arpClone = RawRoute(destination: "192.168.44.1", gateway: "0:11:22:33:44:55", interfaceName: "en0",
                                   isDefault: false, isLocal: true, isCloned: true)
    static let tunnelSelf = RawRoute(destination: "10.5.0.2", gateway: "10.5.0.2", interfaceName: "utun4", isDefault: false, isLocal: true)

    func testDisconnectedVPNOffersExactlyTheLeftoverSplitOfTheLAN() throws {
        let routes = [Self.defaultRoute, Self.lan, Self.selfHost, Self.arpClone, Self.tunnelSelf] + Self.splitRoutes()
        let snapshot = Self.observed(routes)
        XCTAssertEqual(VPNStateDetector().assess(snapshot).state, .active, "The leftover still looks like a tunnel to the detector")
        let stale = RepairPolicy.staleLocalTunnelRoutes(in: snapshot)
        XCTAssertEqual(stale.map(\.target), Self.splitTargets, "Every entry of the split, normalised and sorted")
        XCTAssertTrue(stale.allSatisfy { $0.gateway == "10.5.0.1" && $0.interface == "utun4" })
        XCTAssertEqual(stale.first?.cidr, "192.168.44.0/32")
        let request = PrivilegedRequest(action: .removeStaleTunnelRoutes(routes: Self.splitTargets.reversed()))
        XCTAssertEqual(try RepairPolicy.authorize(request, snapshot: snapshot, dhcpInterfaces: []), .removeRoutes(stale))
        XCTAssertTrue(stale[5].matches(Self.splitRoutes()[5]))
        XCTAssertFalse(stale[5].matches(Self.splitRoutes(scoped: false, cloned: true)[5]))
        XCTAssertFalse(stale[5].matches(RawRoute(destination: "192.168.44.32/27", gateway: "10.5.0.1", interfaceName: "utun5", isDefault: false)))
    }

    func testGroupRequestMustEqualTheObservedSet() {
        let routes = [Self.defaultRoute, Self.lan] + Self.splitRoutes()
        let snapshot = Self.observed(routes)
        let subset = PrivilegedRequest(action: .removeStaleTunnelRoutes(routes: Array(Self.splitTargets.prefix(7))))
        let extra = PrivilegedRequest(action: .removeStaleTunnelRoutes(routes: Self.splitTargets +
            [.init(destination: "192.168.44.0", prefix: 24, interface: "utun4")]))
        let otherTunnel = PrivilegedRequest(action: .removeStaleTunnelRoutes(routes: Self.splitTargets.map {
            .init(destination: $0.destination, prefix: $0.prefix, interface: "utun5") }))
        for request in [subset, extra, otherTunnel] {
            XCTAssertThrowsError(try RepairPolicy.authorize(request, snapshot: snapshot, dhcpInterfaces: [])) {
                XCTAssertEqual($0 as? RepairPolicyError, .ambiguousResource)
            }
        }
        let duplicate = PrivilegedRequest(action: .removeStaleTunnelRoutes(routes: Self.splitTargets + [Self.splitTargets[0]]))
        let empty = PrivilegedRequest(action: .removeStaleTunnelRoutes(routes: []))
        for request in [duplicate, empty] {
            XCTAssertThrowsError(try RepairPolicy.authorize(request, snapshot: snapshot, dhcpInterfaces: [])) {
                XCTAssertEqual($0 as? RepairPolicyError, .invalidRequest)
            }
        }
        // The grouped action never falls back to the ordinary VPN gate.
        let clean = Self.observed([Self.defaultRoute, Self.lan])
        XCTAssertThrowsError(try RepairPolicy.authorize(subset, snapshot: clean, dhcpInterfaces: [])) {
            XCTAssertEqual($0 as? RepairPolicyError, .ambiguousResource)
        }
    }

    func testLeftoverProofRejectsEveryWeakerObservation() {
        let split = Self.splitRoutes()
        let routes = [Self.defaultRoute, Self.lan] + split
        let weaker: [(String, RawNetworkSnapshot)] = [
            ("service connected", Self.observed(routes, service: .connected)),
            ("service unknown", Self.observed(routes, service: .unknown)),
            ("tunnel in dynamic store", Self.observed(routes, storeInterfaces: ["utun4"])),
            ("tunnel resolver", Self.observed(routes, resolvers: [.init(domain: nil, searchDomains: [], nameservers: ["10.5.0.53"], interfaceName: "utun4")])),
            ("scoped entries", Self.observed([Self.defaultRoute, Self.lan] + Self.splitRoutes(scoped: true))),
            ("cloned entries", Self.observed([Self.defaultRoute, Self.lan] + Self.splitRoutes(cloned: true))),
            ("no connected LAN", Self.observed([Self.defaultRoute] + split)),
            ("public gateway text", Self.observed([Self.defaultRoute, Self.lan] + Self.splitRoutes(gateway: "link#9"))),
            ("too many entries", Self.observed([Self.defaultRoute, Self.lan] + (0..<25).map {
                RawRoute(destination: "192.168.44.\($0 * 2)/31", gateway: "10.5.0.1", interfaceName: "utun4", isDefault: false) }))
        ]
        for (name, snapshot) in weaker {
            XCTAssertTrue(RepairPolicy.staleLocalTunnelRoutes(in: snapshot).isEmpty, name)
        }
        // A duplicated destination drops only that entry; the remaining set is still offered.
        let duplicated = Self.observed(routes + [split[5]])
        XCTAssertEqual(RepairPolicy.staleLocalTunnelRoutes(in: duplicated).count, 7)
        // Entries outside the connected LAN or at the LAN's own size are not shadows.
        let foreign = Self.observed([Self.defaultRoute, Self.lan,
            .init(destination: "10.20.0.0/16", gateway: "10.5.0.1", interfaceName: "utun4", isDefault: false),
            .init(destination: "192.168.44.0/24", gateway: "10.5.0.1", interfaceName: "utun4", isDefault: false)])
        XCTAssertTrue(RepairPolicy.staleLocalTunnelRoutes(in: foreign).isEmpty)
        // A down tunnel that still owns the entries is acceptable; an absent one is not.
        XCTAssertEqual(RepairPolicy.staleLocalTunnelRoutes(in: Self.observed(routes, tunnelUp: false)).count, 8)
        let absent = RawNetworkSnapshot(startedAt: Date(), endedAt: Date(),
            path: .init(status: "satisfied", availableInterfaces: ["en0"], selectedInterfaces: ["en0"],
                        supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: ["192.168.44.1"]),
            interfaces: [.init(name: "en0", type: "wifi", isUp: true, addresses: ["192.168.44.40"])],
            routes: routes, resolvers: [], proxy: nil, dynamicStoreVPNKeys: [], errors: [], vpnServices: .disconnected)
        XCTAssertTrue(RepairPolicy.staleLocalTunnelRoutes(in: absent).isEmpty)
    }

    func testLiveHostRecognizesResidualRoutesWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["NETUNSTICK_ROUTE_LIVE"] == "1" else {
            throw XCTSkip("Opt-in read-only test for the current post-VPN host state")
        }
        let current = await SystemNetworkStateCollector().collect()
        XCTAssertTrue(current.errors.isEmpty, "Network collection must be complete")
        XCTAssertEqual(current.vpnServices, .disconnected, "Configured VPN services must report disconnected")
        let stale = RepairPolicy.staleLocalTunnelRoutes(in: current)
        let tunnelRoutes = current.routes.filter { $0.interfaceName.map(TunnelSignals.isTunnelName) == true && TunnelSignals.isForwardingRoute($0) }
        let details = "selectedInterfaces=\(current.path?.selectedInterfaces.count ?? 0), " +
            "defaultPhysical=\(current.routes.contains { $0.isDefault && $0.interfaceName == "en0" }), " +
            "localRouteCount=\(current.routes.filter { $0.interfaceName == "en0" && $0.isLocal }.count), " +
            "forwardingTunnelRouteCount=\(tunnelRoutes.count), staleCount=\(stale.count), " +
            "vpn=\(VPNStateDetector().assess(current).reasonCode.rawValue)"
        print("NETUNSTICK_ROUTE_LIVE: \(details)")
        let localCheck = await LocalSubnetRouteCheck(snapshot: current).run(context: .init())
        if stale.isEmpty, localCheck.outcome == .success, tunnelRoutes.isEmpty {
            throw XCTSkip("This host has no leftover tunnel routes right now: \(details)")
        }
        XCTAssertFalse(stale.isEmpty, "Expected the leftover tunnel entries that shadow the physical LAN: \(details)")
        XCTAssertEqual(Set(stale.map(\.interface)).count, 1, "One leftover tunnel expected: \(details)")
        XCTAssertEqual(localCheck.outcome, .failure, "Local route check must expose the conflict")
    }
    func testForeignClientRequirement() {
        let fingerprint = "0123456789abcdef0123456789abcdef01234567"
        let requirement = ClientIdentityPolicy.requirement(forLeafCertificateSHA1: fingerprint)!
        XCTAssertTrue(requirement.contains("org.netunstick.NetUnstick"))
        XCTAssertTrue(requirement.contains("certificate leaf = H\"\(fingerprint)\""))
        XCTAssertFalse(requirement.contains("org.foreign.App"))
        XCTAssertNil(ClientIdentityPolicy.requirement(forLeafCertificateSHA1: "*"))
        XCTAssertNil(ClientIdentityPolicy.requirement(forLeafCertificateSHA1: "ABCD123456"))
        XCTAssertNotEqual(requirement, ClientIdentityPolicy.requirement(forLeafCertificateSHA1: String(repeating: "a", count: 40)))
        var compiled: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(requirement as CFString, [], &compiled), errSecSuccess)
        XCTAssertNotNil(compiled)
    }
    func testClosedXPCDecoderRejectsArguments() throws {
        let data = Data(#"{"version":1,"action":{"run":{"executable":"/bin/sh","arguments":["-c","id"]}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PrivilegedRequest.self, from: data))
        XCTAssertEqual(PrivilegedRepairExecutor.rejectMalformedRequest().code, .invalidRequest)
        let encoded = try JSONEncoder().encode(PrivilegedRequest(action: .removeStaleTunnelRoutes(routes: Self.splitTargets)))
        XCTAssertLessThanOrEqual(encoded.count, PrivilegedProtocol.maximumRequestBytes)
        let capacity = (0..<RepairPolicy.maximumStaleTunnelRoutes).map {
            PrivilegedRouteTarget(destination: "192.168.255.\($0 * 2)", prefix: 31, interface: "utun12") }
        let largest = try JSONEncoder().encode(PrivilegedRequest(action: .removeStaleTunnelRoutes(routes: capacity)))
        XCTAssertLessThanOrEqual(largest.count, PrivilegedProtocol.maximumRequestBytes, "The largest permitted group must fit the helper limit")
    }
}
