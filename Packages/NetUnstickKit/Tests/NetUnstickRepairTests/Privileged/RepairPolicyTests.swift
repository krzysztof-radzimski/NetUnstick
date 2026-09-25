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
