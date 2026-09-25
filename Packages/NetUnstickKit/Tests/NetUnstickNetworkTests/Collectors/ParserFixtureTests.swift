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
        XCTAssertTrue(routes.contains { $0.interfaceName == "utun4" && $0.isLocal })
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
