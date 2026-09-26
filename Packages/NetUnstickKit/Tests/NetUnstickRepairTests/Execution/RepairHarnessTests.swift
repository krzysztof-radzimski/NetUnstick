import Foundation
import XCTest
import NetUnstickCore
import NetUnstickNetwork
@testable import NetUnstickRepair

private struct FakeCollector: NetworkStateCollecting {
    let snapshots: [RawNetworkSnapshot]
    let index = Index()
    func collect() async -> RawNetworkSnapshot { await index.next(snapshots) }
    actor Index {
        var value = 0
        func next(_ items: [RawNetworkSnapshot]) -> RawNetworkSnapshot {
            let item = items[min(value, items.count - 1)]
            value += 1
            return item
        }
    }
}

private struct FakeChecks: RepairCheckRunning {
    let reasons: [String]
    let index = FakeCollector.Index()
    func run(_ id: String, snapshot: RawNetworkSnapshot, context: OperationContext) async -> OperationResult? {
        let number = await index.nextNumber()
        let reason = reasons[min(number, reasons.count - 1)]
        let outcome: OperationOutcome = reason == "healthy" ? .success : .failure
        return try! OperationResult(operationID: id, name: id, kind: .diagnostic,
            startedAt: context.clock.now(), endedAt: context.clock.now(), outcome: outcome,
            after: EvidenceSanitizer.sanitize([.errorCode: .errorCode(reason)]),
            error: outcome == .failure ? try! OperationError(domain: "fake", code: reason) : nil)
    }
}

private extension FakeCollector.Index {
    func nextNumber() -> Int {
        let number = value
        value += 1
        return number
    }
}

private actor FakeHelper: RepairHelperCalling {
    let code: PrivilegedCode
    let resultOutcome: OperationOutcome
    private(set) var calls = 0
    init(_ code: PrivilegedCode, resultOutcome: OperationOutcome = .success) {
        self.code = code; self.resultOutcome = resultOutcome
    }
    func perform(_ action: PrivilegedAction) async -> PrivilegedReply {
        calls += 1
        if code != .success { return PrivilegedRequestClient.failure(code) }
        let now = Date()
        return .init(code: .success, result: try! OperationResult(operationID: UUID().uuidString,
            name: "fake_helper", kind: .repair, startedAt: now, endedAt: now, outcome: resultOutcome,
            error: resultOutcome == .failure ? try! OperationError(domain: "fake", code: "helper_failed") : nil))
    }
}

private struct ImmediateWait: RepairWaiting {
    let fails: Bool
    func settle() async throws { if fails { throw TimeoutError() } }
    struct TimeoutError: Error {}
}

private struct FakeClock: OperationClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_000) }
}

private struct FakeCancellation: CancellationChecking {
    let cancelled: Bool
    func checkCancellation() throws { if cancelled { throw CancellationError() } }
}

final class RepairHarnessTests: XCTestCase {
    private func journal() -> (BoundedSessionStore, ActivitySession) {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = package.appendingPathComponent(".build/repair-test-sessions/\(UUID().uuidString)/session.json")
        return (try! BoundedSessionStore(fileURL: file),
                ActivitySession(startedAt: Date(), appVersion: "1.0", macOSVersion: "14.0"))
    }
    private func snapshot(_ state: String = "inactive", address: String = "192.168.1.2") -> RawNetworkSnapshot {
        let time = Date(timeIntervalSince1970: 1_000)
        let tunnel = state == "active" ? [RawInterface(name: "utun1", type: "other", isUp: true, addresses: [])] :
                     state == "unknown" ? [RawInterface(name: "utun1", type: "other", isUp: false, addresses: [])] : []
        let routes = state == "active" ? [RawRoute(destination: "0.0.0.0/0", gateway: nil, interfaceName: "utun1", isDefault: true)] : []
        return RawNetworkSnapshot(startedAt: time, endedAt: time,
            path: .init(status: "satisfied", availableInterfaces: ["en0"], selectedInterfaces: ["en0"],
                        supportsDNS: true, supportsIPv4: true, supportsIPv6: false, gateways: []),
            interfaces: [RawInterface(name: "en0", type: "wifi", isUp: true, addresses: [address])] + tunnel,
            routes: routes, resolvers: [], proxy: nil, dynamicStoreVPNKeys: [], errors: [])
    }
    private func plan(_ kind: RepairKind = .refreshResolverCache, resource: RepairResource = .resolverCache) -> RepairPlan {
        .init(kind: kind, reasonCode: "dnsFailure", checkID: "unicast_dns_resolution", resource: resource,
              summary: .init(change: "cache", resource: "resolver", purpose: "check", requiresAdministrator: true,
                             possibleImpact: "brief", verification: "recheck"))
    }

    func testOutcomeMatrixUsesOnlyFakes() async {
        struct Scenario {
            let name: String; let snapshots: [RawNetworkSnapshot]; let reasons: [String]
            let helperCode: PrivilegedCode; let waitFails: Bool; let cancelled: Bool
            let expected: OperationOutcome; let error: String?; let calls: Int
        }
        let clean = snapshot(), active = snapshot("active"), unknown = snapshot("unknown")
        let cases: [Scenario] = [
            .init(name: "resolved", snapshots: [clean], reasons: ["dnsFailure", "healthy"], helperCode: .success, waitFails: false, cancelled: false, expected: .success, error: nil, calls: 1),
            .init(name: "exit zero recheck fails", snapshots: [clean], reasons: ["dnsFailure", "dnsFailure"], helperCode: .success, waitFails: false, cancelled: false, expected: .failure, error: "recheck_failed", calls: 1),
            .init(name: "active vpn", snapshots: [active], reasons: ["dnsFailure"], helperCode: .success, waitFails: false, cancelled: false, expected: .skipped, error: "vpn_active", calls: 0),
            .init(name: "unknown vpn", snapshots: [unknown], reasons: ["dnsFailure"], helperCode: .success, waitFails: false, cancelled: false, expected: .skipped, error: "vpn_unknown", calls: 0),
            .init(name: "diagnosis vanished", snapshots: [clean], reasons: ["healthy"], helperCode: .success, waitFails: false, cancelled: false, expected: .skipped, error: nil, calls: 0),
            .init(name: "helper denied", snapshots: [clean], reasons: ["dnsFailure"], helperCode: .permissionDenied, waitFails: false, cancelled: false, expected: .permissionDenied, error: "permissionDenied", calls: 1),
            .init(name: "xpc lost", snapshots: [clean], reasons: ["dnsFailure"], helperCode: .disconnected, waitFails: false, cancelled: false, expected: .failure, error: "disconnected", calls: 1),
            .init(name: "helper timeout", snapshots: [clean], reasons: ["dnsFailure"], helperCode: .timedOut, waitFails: false, cancelled: false, expected: .timedOut, error: "timedOut", calls: 1),
            .init(name: "settle timeout", snapshots: [clean], reasons: ["dnsFailure"], helperCode: .success, waitFails: true, cancelled: false, expected: .timedOut, error: "settle_timeout", calls: 1),
            .init(name: "cancelled", snapshots: [clean], reasons: ["dnsFailure"], helperCode: .success, waitFails: false, cancelled: true, expected: .cancelled, error: nil, calls: 0),
            .init(name: "resource changed", snapshots: [clean, snapshot(address: "192.168.1.3")], reasons: ["dnsFailure"], helperCode: .success, waitFails: false, cancelled: false, expected: .skipped, error: nil, calls: 0)
        ]
        for item in cases {
            let helper = FakeHelper(item.helperCode)
            let (store, session) = journal()
            let target = item.name == "resource changed" ? RepairPlan(kind: .renewDHCP,
                reasonCode: "noAddressLease", checkID: "physical_link", resource: .physicalInterface("en0"),
                summary: plan().summary) : plan()
            let checks = item.name == "resource changed" ? FakeChecks(reasons: ["noAddressLease"]) : FakeChecks(reasons: item.reasons)
            let executor = RepairExecutor(collector: FakeCollector(snapshots: item.snapshots),
                checks: checks, helper: helper, wait: ImmediateWait(fails: item.waitFails),
                dhcpInterfaces: { ["en0"] }, store: store, session: session)
            let result = await executor.execute(target, context: .init(clock: FakeClock(),
                cancellation: FakeCancellation(cancelled: item.cancelled)))
            XCTAssertEqual(result.outcome, item.expected, item.name)
            XCTAssertEqual(result.error?.code, item.error, item.name)
            let calls = await helper.calls
            XCTAssertEqual(calls, item.calls, item.name)
        }
    }

    func testEveryActionRechecksAndOnlyMutatingActionsCallHelper() async {
        let clean = snapshot()
        let cases: [(RepairPlan, [RawNetworkSnapshot], String, Int)] = [
            (plan(.retryCheck, resource: .check("unicast_dns_resolution")), [clean], "dnsFailure", 0),
            (plan(.refreshResolverCache), [clean], "dnsFailure", 1),
            (.init(kind: .renewDHCP, reasonCode: "noAddressLease", checkID: "physical_link",
                   resource: .physicalInterface("en0"), summary: plan().summary), [snapshot(address: "169.254.1.2"), snapshot(address: "169.254.1.2"), snapshot(address: "169.254.1.2"), clean], "noAddressLease", 1)
        ]
        for (target, snapshots, reason, callsExpected) in cases {
            for resolved in [true, false] {
                let helper = FakeHelper(.success)
                let (store, session) = journal()
                let evidence = resolved ? snapshots : Array(snapshots.dropLast()) + [snapshots[0]]
                let executor = RepairExecutor(collector: FakeCollector(snapshots: evidence),
                    checks: FakeChecks(reasons: [reason, resolved ? "healthy" : reason]), helper: helper,
                    wait: ImmediateWait(fails: false), dhcpInterfaces: { ["en0"] }, store: store, session: session)
                let result = await executor.execute(target, context: .init(clock: FakeClock()))
                XCTAssertEqual(result.outcome, resolved ? .success : .failure, "\(target.kind) resolved=\(resolved)")
                let calls = await helper.calls
                XCTAssertEqual(calls, callsExpected, target.kind.rawValue)
            }
        }
    }

    func testRoutePlanIsRejectedByCurrentVPNAndHelperContract() async {
        let helper = FakeHelper(.success)
        let (store, session) = journal()
        let route = RepairPlan(kind: .removeOrphanedRoute, reasonCode: "expectedInterfaceMissing",
            checkID: "interface_consistency",
            resource: .route(destination: "10.2.3.0", prefix: 24, interface: "en1", gateway: "10.2.3.1"),
            summary: plan().summary)
        let executor = RepairExecutor(collector: FakeCollector(snapshots: [snapshot()]),
            checks: FakeChecks(reasons: ["expectedInterfaceMissing"]), helper: helper,
            wait: ImmediateWait(fails: false), dhcpInterfaces: { ["en0"] }, store: store, session: session)
        let result = await executor.execute(route, context: .init(clock: FakeClock()))
        XCTAssertEqual(result.error?.code, "invalid_plan")
        let calls = await helper.calls
        XCTAssertEqual(calls, 0)
    }

    func testPhaseRecordContainsNoRawNetworkEvidence() async throws {
        let (store, session) = journal()
        let helper = FakeHelper(.success)
        let executor = RepairExecutor(collector: FakeCollector(snapshots: [snapshot(address: "192.168.1.2")]),
            checks: FakeChecks(reasons: ["dnsFailure", "healthy"]), helper: helper,
            wait: ImmediateWait(fails: false), dhcpInterfaces: { ["en0"] }, store: store, session: session)
        let result = await executor.execute(plan(), context: .init(clock: FakeClock()))
        XCTAssertEqual(result.outcome, .success)
        let sessions = try await store.sessions()
        let names = sessions[0].entries.map(\.name)
        XCTAssertTrue(names.contains("before_snapshot"))
        XCTAssertTrue(names.contains("after_snapshot"))
        XCTAssertTrue(names.contains("recheck"))
        let bytes = try JSONEncoder().encode(sessions)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("192.168.1.2"))
        XCTAssertFalse(text.contains("en0"))
    }

    func testSessionFailureStopsBeforeHelper() async throws {
        let helper = FakeHelper(.success)
        // An existing directory cannot be replaced by the store's JSON file.
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let store = try BoundedSessionStore(fileURL: directory)
        let session = ActivitySession(startedAt: Date(), appVersion: "1.0", macOSVersion: "14.0")
        let executor = RepairExecutor(collector: FakeCollector(snapshots: [snapshot()]),
            checks: FakeChecks(reasons: ["dnsFailure", "healthy"]), helper: helper,
            wait: ImmediateWait(fails: false), dhcpInterfaces: { ["en0"] }, store: store, session: session)
        let result = await executor.execute(plan(), context: .init(clock: FakeClock()))
        XCTAssertEqual(result.outcome, .failure)
        XCTAssertEqual(result.error?.code, "session_write_failed")
        let calls = await helper.calls
        XCTAssertEqual(calls, 0)
    }

    func testObservedDeteriorationNeverReportsSuccess() async {
        let clean = snapshot()
        let degraded = RawNetworkSnapshot(startedAt: clean.startedAt, endedAt: clean.endedAt,
            path: .init(status: "unsatisfied", availableInterfaces: ["en0"], selectedInterfaces: [],
                        supportsDNS: false, supportsIPv4: false, supportsIPv6: false, gateways: []),
            interfaces: clean.interfaces, routes: clean.routes, resolvers: clean.resolvers,
            proxy: nil, dynamicStoreVPNKeys: [], errors: [])
        let (store, session) = journal()
        let helper = FakeHelper(.success)
        let executor = RepairExecutor(collector: FakeCollector(snapshots: [clean, clean, clean, degraded]),
            checks: FakeChecks(reasons: ["dnsFailure", "healthy"]), helper: helper,
            wait: ImmediateWait(fails: false), dhcpInterfaces: { ["en0"] }, store: store, session: session)
        let result = await executor.execute(plan(), context: .init(clock: FakeClock()))
        XCTAssertEqual(result.outcome, .failure)
        XCTAssertEqual(result.error?.code, "state_worsened")
        XCTAssertEqual(result.nextStep, NextStep.contactSupport.rawValue)
    }

    func testInconsistentHelperReplyNeverReportsSuccess() async {
        let helper = FakeHelper(.success, resultOutcome: .failure)
        let (store, session) = journal()
        let executor = RepairExecutor(collector: FakeCollector(snapshots: [snapshot()]),
            checks: FakeChecks(reasons: ["dnsFailure", "healthy"]), helper: helper,
            wait: ImmediateWait(fails: false), dhcpInterfaces: { ["en0"] }, store: store, session: session)
        let result = await executor.execute(plan(), context: .init(clock: FakeClock()))
        XCTAssertEqual(result.outcome, .failure)
        XCTAssertEqual(result.error?.code, "helper_result_mismatch")
        let calls = await helper.calls
        XCTAssertEqual(calls, 1)
    }
}
