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

    func testRouteScopeFlagIsPreservedForDeletionPolicy() {
        let table = """
        Destination Gateway Flags Netif Expire
        192.168.44.32/27 10.5.0.1 UGSc utun4
        192.168.45.32/27 10.5.0.1 UGScI utun4
        """
        let routes = NetstatRouteParser.parse(table, family: "ipv4")
        XCTAssertEqual(routes.count, 2)
        XCTAssertFalse(routes[0].isScoped)
        XCTAssertTrue(routes[1].isScoped)
    }

    func testScopedDNSRetainsTunnelInterfaceWithoutLeakingToDescription() throws {
        let resolvers = ScutilDNSParser.parse(try fixture("scutil-dns.txt"))
        XCTAssertEqual(resolvers.count, 3)
        XCTAssertEqual(resolvers.filter { $0.interfaceName == "utun4" }.count, 2)
        XCTAssertEqual(resolvers[1].domain, "corp.example.test")
        XCTAssertFalse(String(describing: resolvers).contains("corp.example.test"))
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
