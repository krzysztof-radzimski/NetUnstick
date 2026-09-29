import Foundation
import XCTest
@testable import NetUnstickNetwork

final class ParserFixtureTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures")
        return try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func testIPv4RoutesRetainDefaultAndLocalAssociation() throws {
        let routes = NetstatRouteParser.parse(try fixture("netstat-ipv4.txt"), family: "ipv4")
        XCTAssertEqual(routes.count, 4)
        XCTAssertEqual(routes.filter(\.isDefault).map(\.interfaceName), ["en0"])
        XCTAssertTrue(routes.contains { $0.interfaceName == "utun4" && !$0.isDefault })
        XCTAssertTrue(routes.contains { $0.destination == "192.0.2" && $0.isLocal })
    }

    func testIPv6FullTunnelDefaultAndLocalRoute() throws {
        let routes = NetstatRouteParser.parse(try fixture("netstat-ipv6.txt"), family: "ipv6")
        XCTAssertEqual(routes.filter(\.isDefault).map(\.interfaceName), ["utun4"])
        XCTAssertFalse(routes.contains { $0.interfaceName == "utun5" })
        XCTAssertTrue(routes.contains { $0.interfaceName == "utun4" && $0.isLocal })
    }

    func testInterfaceScopedDefaultsDoNotInventSystemDefault() {
        let table = """
        Destination Gateway Flags Netif Expire
        default fe80::1%utun4 UGcIg utun4
        default fe80::2%utun5 UGcIg utun5
        """
        XCTAssertTrue(NetstatRouteParser.parse(table, family: "ipv6").isEmpty)
    }

    func testRouteScopeAndCloneFlagsArePreservedForDeletionPolicy() {
        let table = """
        Destination Gateway Flags Netif Expire
        192.168.44.32/27 10.5.0.1 UGSc utun4
        192.168.45.32/27 10.5.0.1 UGScI utun4
        192.168.44/32 10.5.0.1 UGSc utun4
        192.168.44.1 0:11:22:33:44:55 UHLWIir en0 1185
        192.168.44.40 2:51:b5:16:dd:73 UHLWI lo0
        """
        let routes = NetstatRouteParser.parse(table, family: "ipv4")
        XCTAssertEqual(routes.count, 5)
        XCTAssertFalse(routes[0].isScoped)
        XCTAssertFalse(routes[0].isCloned)
        XCTAssertTrue(routes[1].isScoped)
        XCTAssertEqual(routes[2].destination, "192.168.44/32", "netstat abbreviates the network; the parser keeps the text")
        XCTAssertFalse(routes[2].isLocal)
        XCTAssertTrue(routes[3].isCloned)
        XCTAssertTrue(routes[3].isLocal)
        XCTAssertTrue(routes[4].isCloned)
    }

    func testScopedDNSRetainsTunnelInterfaceWithoutLeakingToDescription() throws {
        let resolvers = ScutilDNSParser.parse(try fixture("scutil-dns.txt"))
        XCTAssertEqual(resolvers.count, 3)
        XCTAssertEqual(resolvers.filter { $0.interfaceName == "utun4" }.count, 2)
        XCTAssertEqual(resolvers[1].domain, "corp.example.test")
        XCTAssertFalse(String(describing: resolvers).contains("corp.example.test"))
    }

    func testNetworkConnectionListYieldsOnlyAggregateStatus() throws {
        XCTAssertEqual(ScutilNetworkConnectionParser.parse(try fixture("scutil-nc-list.txt")), .disconnected)
        let connected = """
        Available network connection services in the current set (*=enabled):
        * (Connected)      43A2222A-C174-4250-9445-5C75ABDD9708 VPN (com.example.vpn.client) "VPN" [VPN:com.example.vpn.client]
        """
        XCTAssertEqual(ScutilNetworkConnectionParser.parse(connected), .connected)
        XCTAssertEqual(ScutilNetworkConnectionParser.parse(connected.replacingOccurrences(of: "Connected", with: "Connecting")), .connected)
        XCTAssertEqual(ScutilNetworkConnectionParser.parse(connected.replacingOccurrences(of: "Connected", with: "Invalid")), .unknown)
        XCTAssertEqual(ScutilNetworkConnectionParser.parse("Available network connection services in the current set (*=enabled):\n"), .unknown)
        XCTAssertEqual(ScutilNetworkConnectionParser.parse(""), .unknown)
        XCTAssertEqual(ScutilNetworkConnectionParser.parse("permission denied"), .unknown)
    }

    func testMalformedTablesDoNotInventRoutesOrResolvers() {
        XCTAssertTrue(NetstatRouteParser.parse("permission denied", family: "ipv4").isEmpty)
        XCTAssertTrue(ScutilDNSParser.parse("DNS configuration\nresolver #1\nif_index : malformed").isEmpty)
    }

    func testPathTransitionIsFlaggedOnChangedObservation() {
        let tracker = PathTransitionTracker()
        func path(_ selected: String) -> RawPathState {
            RawPathState(status: "satisfied", availableInterfaces: ["en0", "utun4"],
                         selectedInterfaces: [selected], supportsDNS: true, supportsIPv4: true,
                         supportsIPv6: true, gateways: [])
        }
        XCTAssertFalse(tracker.observe(path("utun4")).transitionObserved)
        XCTAssertFalse(tracker.observe(path("utun4")).transitionObserved)
        XCTAssertTrue(tracker.observe(path("en0")).transitionObserved)
        XCTAssertFalse(tracker.observe(path("en0")).transitionObserved)
    }
}
