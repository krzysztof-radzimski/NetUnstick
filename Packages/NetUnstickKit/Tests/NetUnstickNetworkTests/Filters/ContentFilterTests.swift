import Foundation
import XCTest
import NetUnstickCore
import NetUnstickNetwork

private struct FixedFilterProbe: ContentFilterProbing {
    let observation: ContentFilterObservation
    func observe() async -> ContentFilterObservation { observation }
}

final class ContentFilterTests: XCTestCase {
    func testKernelCounterAndFirewallOutputAreParsedStrictly() {
        XCTAssertEqual(SystemContentFilterProbe.parseCount("1\n"), 1)
        XCTAssertEqual(SystemContentFilterProbe.parseCount("  0 "), 0)
        XCTAssertNil(SystemContentFilterProbe.parseCount("-1"))
        XCTAssertNil(SystemContentFilterProbe.parseCount("net.cfil.active_count: 1"))
        XCTAssertEqual(SystemContentFilterProbe.parseFirewallState("Firewall is enabled. (State = 1)\n"), true)
        XCTAssertEqual(SystemContentFilterProbe.parseFirewallState("Firewall is disabled. (State = 0)"), false)
        XCTAssertEqual(SystemContentFilterProbe.parseFirewallState("Firewall has block all state set to disabled."), false)
        XCTAssertEqual(SystemContentFilterProbe.parseFirewallState("Firewall has block all state set to enabled."), true)
        XCTAssertNil(SystemContentFilterProbe.parseFirewallState("permission denied"))
    }

    func testDecisionTableSeparatesFirewallFromOtherFilters() {
        let cases: [(ContentFilterObservation, ContentFilterReason)] = [
            (.init(activeFilters: nil, attachedSockets: nil, firewallEnabled: true, blockAllIncoming: false), .dataIncomplete),
            (.init(activeFilters: 0, attachedSockets: 0, firewallEnabled: true, blockAllIncoming: false), .noFilter),
            (.init(activeFilters: 1, attachedSockets: 11, firewallEnabled: true, blockAllIncoming: false), .firewallFilterActive),
            (.init(activeFilters: 1, attachedSockets: 3, firewallEnabled: false, blockAllIncoming: false), .thirdPartyFilterActive),
            (.init(activeFilters: 2, attachedSockets: 3, firewallEnabled: nil, blockAllIncoming: nil), .filterActive)
        ]
        for (observation, expected) in cases {
            XCTAssertEqual(ContentFilterCheck.decide(observation), expected, expected.rawValue)
        }
    }

    func testCheckIsInformationalAndCarriesOnlyCountsAndFlags() async throws {
        let firewall = ContentFilterObservation(activeFilters: 1, attachedSockets: 11, firewallEnabled: true, blockAllIncoming: false)
        let result = await ContentFilterCheck(probe: FixedFilterProbe(observation: firewall)).run(context: .init())
        XCTAssertEqual(result.operationID, "content_filter")
        XCTAssertEqual(result.outcome, .success, "a filter is a setting, not a fault")
        XCTAssertEqual(result.after.values[.errorCode], ContentFilterReason.firewallFilterActive.rawValue)
        XCTAssertEqual(result.after.values[.count], "1")
        XCTAssertEqual(result.after.values[.firewallStatus], "active")
        XCTAssertEqual(result.after.values[.contentFilterStatus], "active")
        XCTAssertNil(result.error)
        let missing = await ContentFilterCheck(probe: FixedFilterProbe(observation: .init(activeFilters: nil, attachedSockets: nil, firewallEnabled: nil, blockAllIncoming: nil))).run(context: .init())
        XCTAssertEqual(missing.outcome, .skipped)
        XCTAssertEqual(missing.nextStep, NextStep.retryCheck.rawValue)
        XCTAssertNil(missing.after.values[.count])
    }

    /// Opt-in host check: NETUNSTICK_READ_ONLY_SMOKE=1 prints counters and flags only.
    func testLiveHostFiltersWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["NETUNSTICK_READ_ONLY_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in read-only host smoke test")
        }
        let observation = await SystemContentFilterProbe().observe()
        print("NETUNSTICK_CONTENT_FILTER: active=\(observation.activeFilters.map(String.init) ?? "nil") attached=\(observation.attachedSockets.map(String.init) ?? "nil") " +
              "firewall=\(observation.firewallEnabled.map(String.init) ?? "nil") blockAll=\(observation.blockAllIncoming.map(String.init) ?? "nil") " +
              "decision=\(ContentFilterCheck.decide(observation).rawValue)")
    }
}
