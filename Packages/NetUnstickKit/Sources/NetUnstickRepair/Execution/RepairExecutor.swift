import Foundation
import os
import NetUnstickCore
import NetUnstickNetwork

public protocol RepairCheckRunning: Sendable {
    func run(_ id: String, snapshot: RawNetworkSnapshot, context: OperationContext) async -> OperationResult?
}

public struct SystemRepairChecks: RepairCheckRunning {
    public init() {}
    public func run(_ id: String, snapshot: RawNetworkSnapshot, context: OperationContext) async -> OperationResult? {
        let check: (any DiagnosticCheck)?
        switch id {
        case "physical_link": check = PhysicalLinkCheck(snapshot: snapshot)
        case "interface_consistency": check = InterfaceConsistencyCheck(snapshot: snapshot)
        case "unicast_dns_resolution": check = UnicastDNSResolutionCheck(snapshot: snapshot)
        case "bonjour_discovery": check = BonjourDiscoveryChecking(snapshot: snapshot)
        default: check = nil
        }
        return await check?.run(context: context)
    }
}

public protocol RepairHelperCalling: Sendable {
    func perform(_ action: PrivilegedAction) async -> PrivilegedReply
}

public struct TransportRepairHelper: RepairHelperCalling, @unchecked Sendable {
    private let transport: any PrivilegedRequestTransport
    public init(transport: any PrivilegedRequestTransport) { self.transport = transport }
    public func perform(_ action: PrivilegedAction) async -> PrivilegedReply {
        await withCheckedContinuation { continuation in
            PrivilegedRequestClient.perform(action, transport: transport) { continuation.resume(returning: $0) }
        }
    }
}

public protocol RepairWaiting: Sendable {
    func settle() async throws
}
public struct BoundedRepairWait: RepairWaiting {
    public init() {}
    public func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }
}

public struct RepairExecutor: Sendable {
    private let collector: any NetworkStateCollecting
    private let checks: any RepairCheckRunning
    private let helper: any RepairHelperCalling
    private let wait: any RepairWaiting
    private let dhcpInterfaces: @Sendable () -> Set<String>
    private let store: BoundedSessionStore
    private let session: ActivitySession
    private let logger = Logger(subsystem: "org.netunstick.NetUnstick", category: "repair")

    public init(collector: any NetworkStateCollecting, checks: any RepairCheckRunning = SystemRepairChecks(),
                helper: any RepairHelperCalling, wait: any RepairWaiting = BoundedRepairWait(),
                dhcpInterfaces: @escaping @Sendable () -> Set<String>,
                store: BoundedSessionStore, session: ActivitySession) {
        self.collector = collector; self.checks = checks; self.helper = helper; self.wait = wait
        self.dhcpInterfaces = dhcpInterfaces; self.store = store; self.session = session
    }

    /// Invoked only after explicit UI confirmation. Never called by diagnosis.
    public func execute(_ plan: RepairPlan, context: OperationContext = .init()) async -> OperationResult {
        let start = context.clock.now()
        var journalHealthy = true
        func record(_ phase: String, _ outcome: OperationOutcome = .success,
                    _ evidence: SafeEvidence = .empty, _ code: String? = nil) async -> Bool {
            let result = try! OperationResult(operationID: UUID().uuidString, name: phase, kind: .repair,
                startedAt: start, endedAt: max(start, context.clock.now()), outcome: outcome,
                after: evidence, error: code.flatMap { try? OperationError(domain: "repair", code: $0) })
            do { try await store.append(result, to: session.id) }
            catch {
                logger.error("Repair session \(session.id.uuidString, privacy: .public) write failed")
                return false
            }
            logger.info("Repair session \(session.id.uuidString, privacy: .public) phase \(phase, privacy: .public): \(outcome.rawValue, privacy: .public)")
            return true
        }
        func finish(_ outcome: OperationOutcome, _ code: String?, _ before: SafeEvidence = .empty,
                    _ after: SafeEvidence = .empty, _ next: NextStep = .reviewDetails) async -> OperationResult {
            let result = try! OperationResult(operationID: UUID().uuidString, name: plan.kind.rawValue, kind: .repair,
                startedAt: start, endedAt: max(start, context.clock.now()), outcome: outcome, before: before,
                after: after, error: code.flatMap { try? OperationError(domain: "repair", code: $0) },
                nextStep: next.rawValue)
            do { try await store.append(result, to: session.id) }
            catch {
                logger.error("Repair session \(session.id.uuidString, privacy: .public) final write failed")
                return try! OperationResult(operationID: UUID().uuidString, name: plan.kind.rawValue,
                    kind: .repair, startedAt: start, endedAt: max(start, context.clock.now()),
                    outcome: .failure, before: before, after: after,
                    error: try! OperationError(domain: "repair", code: "session_write_failed"),
                    nextStep: NextStep.reviewDetails.rawValue)
            }
            logger.info("Repair session \(session.id.uuidString, privacy: .public) final \(outcome.rawValue, privacy: .public), code \(code ?? "none", privacy: .public)")
            return result
        }
        func vpnSkip(_ state: VPNState, before: SafeEvidence = .empty) async -> OperationResult {
            let status: PublicStatus = state == .active ? .active : .unknown
            let evidence = EvidenceSanitizer.sanitize([.vpnStatus: .status(status)])
            let code = state == .active ? "vpn_active" : "vpn_unknown"
            _ = await record("vpn_gate", .skipped, evidence, code)
            return await finish(.skipped, code, before, evidence,
                                state == .active ? .waitForVPN : .verifyVPN)
        }
        do {
            let exists = try await store.sessions().contains { $0.id == session.id }
            if !exists { try await store.startSession(session) }
        }
        catch {
            logger.error("Repair session \(session.id.uuidString, privacy: .public) start failed")
            return try! OperationResult(operationID: UUID().uuidString, name: plan.kind.rawValue,
                kind: .repair, startedAt: start, endedAt: max(start, context.clock.now()), outcome: .failure,
                error: try! OperationError(domain: "repair", code: "session_write_failed"),
                nextStep: NextStep.reviewDetails.rawValue)
        }
        guard RepairCatalog.permits(plan) else {
            return await finish(.failure, "invalid_plan")
        }
        if Task.isCancelled || (try? context.cancellation.checkCancellation()) == nil {
            return await finish(.cancelled, nil)
        }
        guard await record("revalidate") else { return await finish(.failure, "session_write_failed") }
        guard let initial = await collectBounded() else {
            return await finish(Task.isCancelled ? .cancelled : .timedOut,
                                Task.isCancelled ? nil : "collection_timeout")
        }
        let initialVPN = VPNStateDetector().assess(initial)
        if initialVPN.state != .inactive {
            return await vpnSkip(initialVPN.state)
        }
        guard let check = await checkBounded(plan.checkID, snapshot: initial, context: context) else {
            return await finish(Task.isCancelled ? .cancelled : .timedOut,
                                Task.isCancelled ? nil : "check_timeout")
        }
        guard
              check.after.values[.errorCode] == plan.reasonCode,
              check.outcome == .failure || (plan.reasonCode == BonjourReason.noServices.rawValue && check.outcome == .skipped)
        else { return await finish(.skipped, nil, .empty, .empty, .retryCheck) }
        guard await record("fresh_vpn") else { return await finish(.failure, "session_write_failed") }
        guard let beforeRaw = await collectBounded() else {
            return await finish(Task.isCancelled ? .cancelled : .timedOut,
                                Task.isCancelled ? nil : "collection_timeout")
        }
        let before = SanitizedNetworkSnapshot(raw: beforeRaw).evidence
        let beforeVPN = VPNStateDetector().assess(beforeRaw)
        guard beforeVPN.state == .inactive else {
            return await vpnSkip(beforeVPN.state, before: before)
        }
        guard sameResource(plan.resource, initial, beforeRaw), authorized(plan, beforeRaw) else {
            return await finish(.skipped, nil, before, .empty, .contactSupport)
        }
        guard await record("before_snapshot", .success, before) else {
            return await finish(.failure, "session_write_failed", before)
        }
        if Task.isCancelled || (try? context.cancellation.checkCancellation()) == nil {
            return await finish(.cancelled, nil, before)
        }
        if let action = privilegedAction(plan.resource, kind: plan.kind) {
            // Final local observation immediately before helper request; helper repeats the gate.
            guard let latest = await collectBounded() else {
                return await finish(Task.isCancelled ? .cancelled : .timedOut,
                                    Task.isCancelled ? nil : "collection_timeout", before)
            }
            let latestVPN = VPNStateDetector().assess(latest)
            guard latestVPN.state == .inactive else {
                return await vpnSkip(latestVPN.state, before: before)
            }
            guard sameResource(plan.resource, beforeRaw, latest), authorized(plan, latest) else {
                return await finish(.skipped, nil, before, .empty, .contactSupport)
            }
            guard await record("helper_request") else {
                return await finish(.failure, "session_write_failed", before)
            }
            let reply = await helper.perform(action)
            if Task.isCancelled { return await finish(.cancelled, nil, before) }
            guard reply.code == .success, reply.result.outcome == .success else {
                if reply.code == .success {
                    return await finish(.failure, "helper_result_mismatch", before, .empty, .contactSupport)
                }
                let outcome: OperationOutcome = reply.code == .permissionDenied || reply.code == .approvalRequired ? .permissionDenied :
                    reply.code == .timedOut ? .timedOut : [.vpnActive, .vpnUnknown, .ambiguousResource].contains(reply.code) ? .skipped : .failure
                return await finish(outcome, reply.code.rawValue, before, .empty, .contactSupport)
            }
        } else if !(await record("read_only_retry")) {
            return await finish(.failure, "session_write_failed", before)
        }
        do { try await wait.settle() }
        catch is CancellationError { return await finish(.cancelled, nil, before) }
        catch { return await finish(.timedOut, "settle_timeout", before) }
        if Task.isCancelled { return await finish(.cancelled, nil, before) }
        journalHealthy = await record("settle") && journalHealthy
        guard let afterRaw = await collectBounded() else {
            return await finish(Task.isCancelled ? .cancelled : .timedOut,
                                Task.isCancelled ? nil : "collection_timeout", before)
        }
        let after = SanitizedNetworkSnapshot(raw: afterRaw).evidence
        journalHealthy = await record("after_snapshot", .success, after) && journalHealthy
        if stateWorsened(beforeRaw, afterRaw) {
            return await finish(.failure, "state_worsened", before, after, .contactSupport)
        }
        guard afterRaw.errors.isEmpty, VPNStateDetector().assess(afterRaw).state == .inactive else {
            return await finish(.failure, "after_snapshot_invalid", before, after, .contactSupport)
        }
        if case .route(let destination, let prefix, _, _) = plan.resource,
           afterRaw.routes.contains(where: { $0.destination == "\(destination)/\(prefix)" }) {
            return await finish(.failure, "route_still_present", before, after, .contactSupport)
        }
        guard let recheck = await checkBounded(plan.checkID, snapshot: afterRaw, context: context) else {
            return await finish(Task.isCancelled ? .cancelled : .timedOut,
                                Task.isCancelled ? nil : "check_timeout", before, after)
        }
        journalHealthy = await record("recheck", recheck.outcome == .success ? .success : .failure,
                                      recheck.after, recheck.outcome == .success ? nil : "recheck_failed") && journalHealthy
        if !journalHealthy { return await finish(.failure, "session_write_failed", before, after) }
        guard recheck.outcome == .success else {
            return await finish(.failure, "recheck_failed", before, after, .contactSupport)
        }
        return await finish(.success, nil, before, after)
    }

    private func privilegedAction(_ resource: RepairResource, kind: RepairKind) -> PrivilegedAction? {
        switch (kind, resource) {
        case (.refreshResolverCache, .resolverCache): return .refreshResolverCache
        case (.renewDHCP, .physicalInterface(let name)): return .renewDHCP(interface: name)
        case (.removeOrphanedRoute, .route(let destination, let prefix, let name, _)):
            return .removeOrphanedRoute(destination: destination, prefix: prefix, interface: name)
        default: return nil
        }
    }

    private func collectBounded() async -> RawNetworkSnapshot? {
        let (stream, output) = AsyncStream.makeStream(of: RawNetworkSnapshot?.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task { output.yield(await collector.collect()); output.finish() }
        let timer = Task { try? await Task.sleep(for: .seconds(8)); output.yield(nil); output.finish() }
        var iterator = stream.makeAsyncIterator()
        let result = await withTaskCancellationHandler { await iterator.next() ?? nil } onCancel: {
            output.yield(nil); output.finish(); worker.cancel(); timer.cancel()
        }
        worker.cancel(); timer.cancel(); output.finish()
        return result
    }

    private func checkBounded(_ id: String, snapshot: RawNetworkSnapshot,
                              context: OperationContext) async -> OperationResult? {
        let (stream, output) = AsyncStream.makeStream(of: OperationResult?.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task { output.yield(await checks.run(id, snapshot: snapshot, context: context)); output.finish() }
        let timer = Task { try? await Task.sleep(for: .seconds(6)); output.yield(nil); output.finish() }
        var iterator = stream.makeAsyncIterator()
        let result = await withTaskCancellationHandler { await iterator.next() ?? nil } onCancel: {
            output.yield(nil); output.finish(); worker.cancel(); timer.cancel()
        }
        worker.cancel(); timer.cancel(); output.finish()
        return result
    }

    private func authorized(_ plan: RepairPlan, _ snapshot: RawNetworkSnapshot) -> Bool {
        guard let action = privilegedAction(plan.resource, kind: plan.kind) else { return plan.kind == .retryCheck }
        return (try? RepairPolicy.authorize(.init(action: action), snapshot: snapshot,
                                            dhcpInterfaces: dhcpInterfaces())) != nil
    }

    private func sameResource(_ resource: RepairResource, _ lhs: RawNetworkSnapshot, _ rhs: RawNetworkSnapshot) -> Bool {
        switch resource {
        case .check: return true
        case .resolverCache:
            return lhs.resolvers.count == rhs.resolvers.count && lhs.proxy?.settings == rhs.proxy?.settings &&
                zip(lhs.resolvers, rhs.resolvers).allSatisfy { a, b in
                    a.domain == b.domain && a.searchDomains == b.searchDomains &&
                    a.nameservers == b.nameservers && a.interfaceName == b.interfaceName
                }
        case .physicalInterface(let name):
            let a = lhs.interfaces.filter { $0.name == name }, b = rhs.interfaces.filter { $0.name == name }
            return a.count == 1 && b.count == 1 && a[0].type == b[0].type && a[0].isUp == b[0].isUp && a[0].addresses == b[0].addresses
        case .route(let destination, let prefix, let name, let gateway):
            let key = "\(destination)/\(prefix)"
            return [lhs, rhs].allSatisfy { snap in
                snap.routes.filter { $0.destination == key }.count == 1 &&
                snap.routes.contains { $0.destination == key && $0.interfaceName == name && $0.gateway == gateway && !$0.isDefault }
            }
        }
    }

    private func stateWorsened(_ before: RawNetworkSnapshot, _ after: RawNetworkSnapshot) -> Bool {
        if before.path?.status == "satisfied" && after.path?.status != "satisfied" { return true }
        let physical = before.interfaces.filter { $0.isUp && ["wifi", "ethernet", "wired"].contains($0.type.lowercased()) }
        if physical.contains(where: { original in
            !after.interfaces.contains(where: { $0.name == original.name && $0.isUp })
        }) { return true }
        if !before.resolvers.isEmpty && after.resolvers.isEmpty { return true }
        if before.routes.contains(where: \.isDefault) && !after.routes.contains(where: \.isDefault) { return true }
        return false
    }
}
