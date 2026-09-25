import Foundation
import NetUnstickCore

public enum DiagnosisState: String, Codable, Sendable {
    case healthy, fault, insufficientData, environmentLimited
}

public struct CandidateCause: Codable, Sendable, Equatable {
    public let reasonCode: String
    public let explanation: String
    public let unsafeWhileVPNPresent: Bool
    public init(reasonCode: NetworkCheckReason, unsafeWhileVPNPresent: Bool) {
        self.reasonCode = reasonCode.rawValue
        self.explanation = reasonCode.message
        self.unsafeWhileVPNPresent = unsafeWhileVPNPresent
    }
}

public struct DiagnosisReport: Sendable {
    public let state: DiagnosisState
    public let vpn: VPNAssessment
    public let snapshot: SanitizedNetworkSnapshot
    public let results: [OperationResult]
    public let candidates: [CandidateCause]
    public let fortinetFindings: [FortinetFinding]
}

public struct DiagnosisEngine: Sendable {
    private let collector: any NetworkStateCollecting
    private let probe: any NetworkConnectivityProbing
    private let detector: VPNStateDetector
    private let collectionTimeout: Duration
    private let bonjourBrowser: any BonjourBrowsing
    public init(collector: any NetworkStateCollecting = SystemNetworkStateCollector(),
                probe: any NetworkConnectivityProbing = SystemNetworkConnectivityProbe(),
                detector: VPNStateDetector = VPNStateDetector(), collectionTimeout: Duration = .seconds(8),
                bonjourBrowser: any BonjourBrowsing = SystemBonjourBrowser()) {
        self.collector = collector; self.probe = probe; self.detector = detector
        self.collectionTimeout = collectionTimeout
        self.bonjourBrowser = bonjourBrowser
    }

    public func diagnose(context: OperationContext = OperationContext()) async -> DiagnosisReport {
        let raw = await boundedCollection()
        let vpn = detector.assess(raw)
        var results: [OperationResult] = []
        // Physical state first, then routes, DNS, path, proxy and cross-checks.
        let checks: [any DiagnosticCheck] = [
            PhysicalLinkCheck(snapshot: raw, probe: probe),
            DefaultRouteCheck(snapshot: raw, probe: probe),
            LocalSubnetRouteCheck(snapshot: raw, probe: probe),
            ResolverConfigurationCheck(snapshot: raw, probe: probe),
            UnicastDNSResolutionCheck(snapshot: raw, probe: probe),
            InternetPathCheck(snapshot: raw, probe: probe),
            ProxyConfigurationCheck(snapshot: raw, probe: probe),
            InterfaceConsistencyCheck(snapshot: raw, probe: probe)
        ]
        for check in checks { results.append(await check.run(context: context)) }
        results.append(await LocalMulticastPathCheck(snapshot: raw).run(context: context))
        let discovery = await BonjourDiscoveryChecking(snapshot: raw, browser: bonjourBrowser).run(context: context)
        results.append(discovery)
        let discoveryReason = BonjourReason(rawValue: discovery.after.values[.errorCode] ?? "") ?? .inconclusive
        results.append(await BonjourPermissionCheck(observation: .init(count: 0, reason: discoveryReason)).run(context: context))
        let reasons = results.compactMap { $0.after.values[.errorCode].flatMap(NetworkCheckReason.init(rawValue:)) }
        let candidateReasons = reasons.filter { reason in
            switch reason {
            case .healthy, .internetReachable, .dataIncomplete, .environmentLimited,
                 .cancelled, .timedOut, .dnsTimeout, .dnsNXDomain, .internetUnavailable,
                 .localRouteMissing, .dnsNoPath: return false
            default: return true
            }
        }
        // One candidate per distinct symptom; no collapse of DNS and routing faults.
        let candidates = Array(Set(candidateReasons.map(\.rawValue))).sorted().compactMap(NetworkCheckReason.init(rawValue:))
            .map { CandidateCause(reasonCode: $0, unsafeWhileVPNPresent: !vpn.permitsNetworkChange) }
        let state: DiagnosisState
        if !candidates.isEmpty { state = .fault }
        else if reasons.contains(.dataIncomplete) || reasons.contains(.cancelled) || reasons.contains(.timedOut) || reasons.contains(.localRouteMissing) { state = .insufficientData }
        else if reasons.contains(.environmentLimited) || reasons.contains(.internetUnavailable) || reasons.contains(.dnsNXDomain) || reasons.contains(.dnsTimeout) || reasons.contains(.dnsNoPath) { state = .environmentLimited }
        else { state = .healthy }
        let findings = FortinetScenarioClassifier().classify(snapshot: raw, vpn: vpn, checks: results,
                                      productVersion: FortiClientMetadataReader().redactedVersion())
        return DiagnosisReport(state: state, vpn: vpn, snapshot: SanitizedNetworkSnapshot(raw: raw),
                               results: results, candidates: candidates, fortinetFindings: findings)
    }

    private func boundedCollection() async -> RawNetworkSnapshot {
        let (stream, continuation) = AsyncStream.makeStream(of: RawNetworkSnapshot?.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task { continuation.yield(await collector.collect()); continuation.finish() }
        let timer = Task { try? await Task.sleep(for: collectionTimeout); continuation.yield(nil); continuation.finish() }
        var iterator = stream.makeAsyncIterator()
        let result = await withTaskCancellationHandler { await iterator.next() ?? nil } onCancel: {
            continuation.yield(nil); continuation.finish(); worker.cancel(); timer.cancel()
        }
        worker.cancel(); timer.cancel(); continuation.finish()
        if let result { return result }
        let now = Date()
        return RawNetworkSnapshot(startedAt: now, endedAt: now, path: nil, interfaces: [], routes: [],
                                  resolvers: [], proxy: nil, dynamicStoreVPNKeys: [],
                                  errors: [.init(code: Task.isCancelled ? "collection_cancelled" : "collection_timed_out")])
    }
}
