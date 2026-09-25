import Foundation
import XCTest
import NetUnstickCore
import NetUnstickNetwork

private enum FortinetFixtures {
    enum Mode { case split, full, localLANBlocked, dnsResidue, proxyResidue, multiSegment }
    static func snapshot(_ mode: Mode) -> RawNetworkSnapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let wifi = RawInterface(name: "en0", type: "wifi", isUp: true, addresses: ["192.0.2.10"])
        let tunnel = RawInterface(name: "utun5", type: "other", isUp: mode != .dnsResidue && mode != .proxyResidue, addresses: [])
        let full = mode == .full || mode == .localLANBlocked
        let active = mode == .split || full
        let routes = [RawRoute(destination: "192.0.2.0/24", gateway: nil,
                               interfaceName: mode == .localLANBlocked ? "utun5" : "en0", isDefault: false, isLocal: true),
                      RawRoute(destination: "default", gateway: nil, interfaceName: full ? "utun5" : "en0", isDefault: true)]
        let resolver = RawResolver(domain: nil, searchDomains: mode == .dnsResidue ? ["private.example"] : [],
                                   nameservers: ["192.0.2.53"], interfaceName: "en0")
        return RawNetworkSnapshot(startedAt: now, endedAt: now, path: RawPathState(status: "satisfied",
            availableInterfaces: ["en0"] + (active ? ["utun5"] : []), selectedInterfaces: full ? ["utun5"] : ["en0"],
            supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: []),
            interfaces: mode == .multiSegment ? [wifi] : [wifi, tunnel], routes: routes, resolvers: [resolver],
            proxy: RawProxy(settings: mode == .proxyResidue ? ["HTTPEnable": "1", "HTTPProxy": "private.example"] : [:]),
            dynamicStoreVPNKeys: [], errors: [])
    }
    static func result(_ reason: String, id: String = "test") -> OperationResult {
        let now = Date()
        return try! OperationResult(operationID: id, name: id, kind: .diagnostic, startedAt: now, endedAt: now,
            outcome: .skipped, after: EvidenceSanitizer.sanitize([.errorCode: .errorCode(reason)]))
    }
}

final class FortinetScenarioTests: XCTestCase {
    func testSplitFullAndLocalLANBlockedRemainHypotheses() {
        let classifier = FortinetScenarioClassifier()
        let split = FortinetFixtures.snapshot(.split)
        let splitFindings = classifier.classify(snapshot: split, vpn: .init(state: .active, reasonCode: .tunnelRoute),
            checks: [FortinetFixtures.result(NetworkCheckReason.localRouteViaTunnel.rawValue)])
        XCTAssertTrue(splitFindings.contains { $0.scenario == .localSubnetViaTunnel })
        let full = FortinetFixtures.snapshot(.full)
        XCTAssertFalse(classifier.classify(snapshot: full, vpn: .init(state: .active, reasonCode: .tunnelRoute), checks: []).contains { $0.scenario == .managedLocalLANRestriction })
        let blocked = FortinetFixtures.snapshot(.localLANBlocked)
        let blockedFindings = classifier.classify(snapshot: blocked, vpn: .init(state: .active, reasonCode: .tunnelRoute),
            checks: [FortinetFixtures.result(NetworkCheckReason.localRouteViaTunnel.rawValue)], productVersion: "FortiClient 7.2.11")
        XCTAssertTrue(blockedFindings.contains { $0.scenario == .managedLocalLANRestriction && $0.neededToConfirm.contains(.gatewayPolicyReviewNeeded) })
        XCTAssertTrue(blockedFindings.allSatisfy { $0.status == "hypothesis" && $0.nextStep == NextStep.contactSupport.rawValue && $0.productVersion == "FortiClient 7.2.11" && $0.versionedGuidance?.contains("7.2.11") == true })
    }
    func testResidueAndInfrastructureNeedComparison() throws {
        let classifier = FortinetScenarioClassifier()
        let prior = FortinetFixtures.snapshot(.split)
        let dns = classifier.classify(snapshot: FortinetFixtures.snapshot(.dnsResidue), vpn: .init(state: .unknown, reasonCode: .residualTunnel),
            checks: [], previous: prior)
        XCTAssertTrue(dns.contains { $0.scenario == .residualResolver && $0.neededToConfirm.contains(.compareWithoutVPNNeeded) }, "findings: \(dns.map(\.scenario))")
        let proxy = classifier.classify(snapshot: FortinetFixtures.snapshot(.proxyResidue), vpn: .init(state: .unknown, reasonCode: .residualTunnel),
            checks: [FortinetFixtures.result(NetworkCheckReason.activeProxy.rawValue)], previous: prior)
        XCTAssertTrue(proxy.contains { $0.scenario == .residualProxy })
        XCTAssertTrue(proxy.contains { $0.scenario == .orphanedTunnel })
        let activeProxy = classifier.classify(snapshot: prior, vpn: .init(state: .active, reasonCode: .tunnelRoute),
            checks: [FortinetFixtures.result(NetworkCheckReason.activePAC.rawValue)])
        XCTAssertTrue(activeProxy.contains { $0.scenario == .activeProxy && $0.observed.contains(.proxyActive) })
        let multi = classifier.classify(snapshot: FortinetFixtures.snapshot(.multiSegment), vpn: .init(state: .inactive, reasonCode: .noVPNSignals),
            checks: [FortinetFixtures.result(BonjourReason.noServices.rawValue, id: "bonjour_discovery")], multipleSegmentsReported: true)
        XCTAssertTrue(multi.contains { $0.scenario == .infrastructureMDNSCandidate && $0.neededToConfirm.contains(.directIPTestNeeded) })
        let json = String(decoding: try JSONEncoder().encode(multi), as: UTF8.self)
        XCTAssertFalse(json.contains("192.0.2"))
        XCTAssertFalse(json.contains("private.example"))
        XCTAssertFalse(json.contains("FortiGate"))
    }
}
