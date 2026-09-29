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
        XCTAssertThrowsError(try RepairPolicy.authorize(.init(version: 2, action: good.action), snapshot: snapshot(), dhcpInterfaces: ["en0"]))
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
    func testDisconnectedVPNAllowsOnlyProvenSingleLocalTunnelRoute() throws {
        let tunnel = RawRoute(destination: "192.168.44.32/27", gateway: "10.5.0.1",
                              interfaceName: "utun4", isDefault: false)
        let lan = RawRoute(destination: "192.168.44.0/24", gateway: "link#8",
                           interfaceName: "en0", isDefault: false, isLocal: true)
        let defaultRoute = RawRoute(destination: "0.0.0.0/0", gateway: "192.168.44.1",
                                    interfaceName: "en0", isDefault: true)
        let now = Date()
        func observed(_ routes: [RawRoute], service: VPNServiceStatus = .disconnected,
                      storeInterfaces: [String] = []) -> RawNetworkSnapshot {
            RawNetworkSnapshot(startedAt: now, endedAt: now,
                path: .init(status: "satisfied", availableInterfaces: ["en0", "utun4"],
                            selectedInterfaces: ["en0"], supportsDNS: true,
                            supportsIPv4: true, supportsIPv6: false, gateways: ["192.168.44.1"]),
                interfaces: [.init(name: "en0", type: "wifi", isUp: true, addresses: ["192.168.44.40"]),
                             .init(name: "utun4", type: "tunnel", isUp: true, addresses: ["10.5.0.2"])],
                routes: routes, resolvers: [], proxy: nil, dynamicStoreVPNKeys: [], errors: [],
                dynamicStoreTunnelInterfaces: storeInterfaces, vpnServices: service)
        }
        let request = PrivilegedRequest(action: .removeOrphanedRoute(
            destination: "192.168.44.32", prefix: 27, interface: "utun4"))
        let routes = [defaultRoute, lan, tunnel]
        XCTAssertEqual(VPNStateDetector().assess(observed(routes)).state, .active)
        XCTAssertEqual(try RepairPolicy.authorize(request, snapshot: observed(routes), dhcpInterfaces: []),
                       .removeRoute(destination: "192.168.44.32", prefix: 27,
                                    interface: "utun4", gateway: "10.5.0.1"))
        for invalid in [observed(routes, service: .connected),
                        observed(routes, service: .unknown),
                        observed(routes, storeInterfaces: ["utun4"]),
                        observed([defaultRoute, lan, .init(destination: tunnel.destination,
                            gateway: tunnel.gateway, interfaceName: "utun4", isDefault: false,
                            isScoped: true)]),
                        observed([defaultRoute, tunnel]),
                        observed(routes + [tunnel])] {
            XCTAssertThrowsError(try RepairPolicy.authorize(request, snapshot: invalid, dhcpInterfaces: []))
        }
        XCTAssertThrowsError(try RepairPolicy.authorize(.init(action: .removeOrphanedRoute(
            destination: "192.168.44.64", prefix: 27, interface: "utun4")),
            snapshot: observed(routes), dhcpInterfaces: []))
    }
    func testLiveHostRecognizesResidualRouteWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["NETUNSTICK_ROUTE_LIVE"] == "1" else {
            throw XCTSkip("Opt-in read-only test for the current post-VPN host state")
        }
        let current = await SystemNetworkStateCollector().collect()
        XCTAssertTrue(current.errors.isEmpty, "Network collection must be complete")
        XCTAssertEqual(current.vpnServices, .disconnected, "Configured VPN services must report disconnected")
        let physical = current.interfaces.first(where: { $0.name == "en0" })
        let tunnel = current.routes.filter { $0.interfaceName == "utun4" && !$0.isDefault }
        let details = "selectedInterfaces=\(current.path?.selectedInterfaces ?? []), " +
            "physicalType=\(physical?.type ?? "none"), defaultPhysical=\(current.routes.contains { $0.isDefault && $0.interfaceName == "en0" }), " +
            "localRouteCount=\(current.routes.filter { $0.interfaceName == "en0" && $0.isLocal }.count), " +
            "tunnelRouteCount=\(tunnel.count), tunnelStore=\(current.dynamicStoreTunnelInterfaces.contains("utun4"))"
        XCTAssertNotNil(RepairPolicy.staleLocalTunnelRoute(in: current),
                        "Expected one precise tunnel route that shadows the physical LAN: \(details)")
        let localCheck = await LocalSubnetRouteCheck(snapshot: current).run(context: .init())
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
    }
}
