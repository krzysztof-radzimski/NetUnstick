import Foundation
import NetUnstickCore

/// Read-only entry point for a future UI. The raw snapshot never crosses the result boundary.
public struct NetworkStateCheck: DiagnosticCheck {
    public let id = "network_state"
    public let name = "network_state"
    private let collector: any NetworkStateCollecting
    private let detector: VPNStateDetector

    public init(collector: any NetworkStateCollecting, detector: VPNStateDetector = VPNStateDetector()) {
        self.collector = collector
        self.detector = detector
    }

    public func run(context: OperationContext) async -> OperationResult {
        let started = context.clock.now()
        let cancelledBefore: Bool
        do { try context.cancellation.checkCancellation(); cancelledBefore = false }
        catch { cancelledBefore = true }
        let raw: RawNetworkSnapshot
        if cancelledBefore {
            raw = RawNetworkSnapshot(startedAt: started, endedAt: started, path: nil,
                                     interfaces: [], routes: [], resolvers: [], proxy: nil,
                                     dynamicStoreVPNKeys: [], errors: [NetworkCollectionError(code: "cancelled")])
        } else {
            raw = await collector.collect()
        }
        let vpn = detector.assess(raw)
        let safe = SanitizedNetworkSnapshot(raw: raw)
        let ended = max(context.clock.now(), started)
        let outcome: OperationOutcome
        let code: String?
        let cancelledAfter: Bool
        do { try context.cancellation.checkCancellation(); cancelledAfter = false }
        catch { cancelledAfter = true }
        if cancelledBefore || cancelledAfter || Task.isCancelled || raw.errors.contains(where: { $0.code.hasSuffix("_cancelled") }) {
            outcome = .cancelled; code = "cancelled"
        } else if raw.errors.contains(where: { $0.code.hasSuffix("_timed_out") || $0.code == "timed_out" }) {
            outcome = .timedOut; code = "timed_out"
        } else if raw.errors.contains(where: { $0.code.hasSuffix("_permission_denied") || $0.code == "permission_denied" }) {
            outcome = .permissionDenied; code = "permission_denied"
        } else if !raw.errors.isEmpty {
            outcome = .failure; code = raw.errors[0].code
        } else {
            outcome = .success; code = nil
        }
        let evidence = EvidenceSanitizer.sanitize([
            .networkStatus: .status(safe.pathAvailable ? .available : .unknown),
            .vpnStatus: .status(vpn.state == .active ? .active : vpn.state == .inactive ? .inactive : .unknown),
            .count: .count(safe.interfaceTypes.count),
            .interfaceType: .interfaceType(safe.interfaceTypes.first ?? .other),
            .errorCode: .errorCode(code ?? vpn.reasonCode.rawValue)
        ])
        return try! OperationResult(
            operationID: id, name: name, kind: .diagnostic,
            startedAt: started, endedAt: ended, outcome: outcome,
            after: evidence,
            error: code.flatMap { try? OperationError(domain: "network", code: $0) },
            nextStep: vpn.permitsNetworkChange ? NextStep.reviewDetails.rawValue : NextStep.waitForVPN.rawValue
        )
    }
}
