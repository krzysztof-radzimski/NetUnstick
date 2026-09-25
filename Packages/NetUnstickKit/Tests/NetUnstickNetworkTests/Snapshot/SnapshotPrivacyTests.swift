import XCTest
import NetUnstickNetwork
import NetUnstickCore

final class SnapshotPrivacyTests: XCTestCase {
    func testRawDescriptionAndEncodedSafeSnapshotOmitSensitiveValues() throws {
        let now = Date()
        let raw = RawNetworkSnapshot(
            startedAt: now, endedAt: now, path: RawPathState(status: "satisfied", availableInterfaces: ["en7"],
                selectedInterfaces: ["en7"], supportsDNS: true, supportsIPv4: true, supportsIPv6: false,
                gateways: ["203.0.113.44"]),
            interfaces: [RawInterface(name: "en7", type: "wifi", isUp: true, addresses: ["203.0.113.44"])],
            routes: [RawRoute(destination: "corp.secret.internal", gateway: "203.0.113.44", interfaceName: "en7", isDefault: false)],
            resolvers: [RawResolver(domain: "corp.secret.internal", searchDomains: ["corp.secret.internal"], nameservers: ["203.0.113.44"], interfaceName: "en7")],
            proxy: RawProxy(settings: ["ProxyUser": "top-secret-token"]), dynamicStoreVPNKeys: ["State:/Network/Service/private-name"], errors: []
        )
        let safe = SanitizedNetworkSnapshot(raw: raw, correlationSalt: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let text = String(data: try JSONEncoder().encode(safe), encoding: .utf8)!
        let result = try OperationResult(operationID: "network_state", name: "network_state", kind: .diagnostic,
                                         startedAt: now, endedAt: now, outcome: .success, after: safe.evidence)
        let resultText = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
        for forbidden in ["en7", "203.0.113.44", "corp.secret.internal", "top-secret-token", "private-name"] {
            XCTAssertFalse(raw.description.contains(forbidden))
            XCTAssertFalse(String(reflecting: raw).contains(forbidden))
            XCTAssertFalse(text.contains(forbidden))
            XCTAssertFalse(resultText.contains(forbidden))
        }
        XCTAssertFalse(raw is any Encodable)
        XCTAssertEqual(safe.interfaceTypes, [.wifi])
        XCTAssertEqual(safe.interfaceCorrelationIDs.first?.count, 16)
        XCTAssertEqual(safe.routeCount, 1)
    }

    func testPartialErrorCannotProduceFalseInactiveResult() async {
        let now = Date()
        let raw = RawNetworkSnapshot(startedAt: now, endedAt: now, path: nil, interfaces: [], routes: [],
                                     resolvers: [], proxy: nil, dynamicStoreVPNKeys: [],
                                     errors: [NetworkCollectionError(code: "timed_out")])
        let result = await NetworkStateCheck(collector: FixedCollector(raw: raw)).run(context: OperationContext())
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.after.values[.vpnStatus], "unknown")
        XCTAssertEqual(result.error?.code, "timed_out")
    }

    func testPermissionAndOtherPartialFailuresRemainUnknown() async {
        let now = Date()
        for (code, outcome) in [("network_dns_permission_denied", OperationOutcome.permissionDenied),
                                ("network_routes_parse_failed", .failure)] {
            let raw = RawNetworkSnapshot(startedAt: now, endedAt: now, path: nil, interfaces: [], routes: [],
                                         resolvers: [], proxy: nil, dynamicStoreVPNKeys: [],
                                         errors: [NetworkCollectionError(code: code)])
            let result = await NetworkStateCheck(collector: FixedCollector(raw: raw)).run(context: OperationContext())
            XCTAssertEqual(result.outcome, outcome)
            XCTAssertEqual(result.after.values[.vpnStatus], "unknown")
            XCTAssertNotNil(result.error)
        }
    }

    func testPreCancelledCheckDoesNotCollect() async {
        let collector = CountingCollector()
        let result = await NetworkStateCheck(collector: collector).run(
            context: OperationContext(cancellation: AlwaysCancelled()))
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.after.values[.vpnStatus], "unknown")
        let count = await collector.count
        XCTAssertEqual(count, 0)
    }
}

private struct FixedCollector: NetworkStateCollecting {
    let raw: RawNetworkSnapshot
    func collect() async -> RawNetworkSnapshot { raw }
}

private actor CountingCollector: NetworkStateCollecting {
    private(set) var count = 0
    func collect() async -> RawNetworkSnapshot {
        count += 1
        let now = Date()
        return RawNetworkSnapshot(startedAt: now, endedAt: now, path: nil, interfaces: [], routes: [],
                                  resolvers: [], proxy: nil, dynamicStoreVPNKeys: [], errors: [])
    }
}

private struct AlwaysCancelled: CancellationChecking {
    func checkCancellation() throws { throw CancellationError() }
}
