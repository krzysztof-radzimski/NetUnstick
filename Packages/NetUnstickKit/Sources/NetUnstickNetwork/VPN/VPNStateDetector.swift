import Foundation

/// A network-changing action is permitted only after an `inactive` assessment.
public enum VPNState: String, Codable, Sendable {
    case active, inactive, unknown

    public var permitsNetworkChange: Bool { self == .inactive }
}

/// Closed reason codes; none contains an interface name, address, or domain.
public enum VPNReasonCode: String, Codable, Sendable {
    case tunnelRoute
    case tunnelDNS
    case tunnelPath
    case dynamicStoreTunnel
    case noVPNSignals
    case incompleteSnapshot
    case partialReadFailure
    case pathTransition
    case conflictingSignals
    case residualTunnel
    case stabilizationPending
    case stabilizationTimedOut
    case stabilizationCancelled
}

public struct VPNAssessment: Codable, Sendable, Equatable {
    public let state: VPNState
    public let reasonCode: VPNReasonCode

    public init(state: VPNState, reasonCode: VPNReasonCode) {
        self.state = state
        self.reasonCode = reasonCode
    }

    public var permitsNetworkChange: Bool { state.permitsNetworkChange }
}

public struct VPNStateDetector: Sendable {
    public init() {}

    public func assess(_ snapshot: RawNetworkSnapshot) -> VPNAssessment {
        guard snapshot.errors.isEmpty else { return .init(state: .unknown, reasonCode: .partialReadFailure) }
        guard let path = snapshot.path, !snapshot.interfaces.isEmpty,
              snapshot.endedAt >= snapshot.startedAt else {
            return .init(state: .unknown, reasonCode: .incompleteSnapshot)
        }
        guard !path.transitionObserved else { return .init(state: .unknown, reasonCode: .pathTransition) }

        let activeTunnels = Set(snapshot.interfaces.filter { $0.isUp && Self.isTunnel($0.name) }.map(\.name))
        let observedTunnels = Set(snapshot.interfaces.filter { Self.isTunnel($0.name) }.map(\.name))
        let routeTunnels = Set(snapshot.routes.compactMap { route -> String? in
            guard let name = route.interfaceName, Self.isTunnel(name) else { return nil }
            return name
        })
        let dnsTunnels = Set(snapshot.resolvers.compactMap { resolver -> String? in
            guard let name = resolver.interfaceName, Self.isTunnel(name) else { return nil }
            return name
        })
        let selectedTunnels = Set(path.selectedInterfaces.filter(Self.isTunnel))
        let storeSignal = !snapshot.dynamicStoreVPNKeys.isEmpty

        guard path.status == "satisfied" else {
            return .init(state: .unknown, reasonCode: .incompleteSnapshot)
        }

        // A route, resolver or selected path referencing an absent/down interface is
        // ambiguous after disconnect. An old utun alone is likewise insufficient.
        let referenced = routeTunnels.union(dnsTunnels).union(selectedTunnels)
        guard referenced.isSubset(of: activeTunnels) else {
            return .init(state: .unknown, reasonCode: .conflictingSignals)
        }
        if !routeTunnels.isEmpty { return .init(state: .active, reasonCode: .tunnelRoute) }
        if !dnsTunnels.isEmpty { return .init(state: .active, reasonCode: .tunnelDNS) }
        if !selectedTunnels.isEmpty { return .init(state: .active, reasonCode: .tunnelPath) }
        if storeSignal && !activeTunnels.isEmpty {
            return .init(state: .active, reasonCode: .dynamicStoreTunnel)
        }
        if !observedTunnels.isEmpty || storeSignal ||
            path.availableInterfaces.contains(where: Self.isTunnel) {
            return .init(state: .unknown, reasonCode: .residualTunnel)
        }
        return .init(state: .inactive, reasonCode: .noVPNSignals)
    }

    /// Fixed maximum of five samples. Every sample is raced against the remaining
    /// window, so a disconnect never starts an unbounded polling loop.
    public func stabilizeAfterDisconnect(
        collecting collector: any NetworkStateCollecting,
        sampleCount: Int = 3,
        interval: Duration = .milliseconds(200),
        window: Duration = .seconds(3)
    ) async -> VPNAssessment {
        let count = min(5, max(2, sampleCount))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: window)
        var last: VPNAssessment?
        var lastDefiniteState: VPNState?
        var uncertain: VPNAssessment?
        var previousPath: RawPathState?
        for index in 0..<count {
            if Task.isCancelled { return .init(state: .unknown, reasonCode: .stabilizationCancelled) }
            let remaining = clock.now.duration(to: deadline)
            if remaining <= .zero { return .init(state: .unknown, reasonCode: .stabilizationTimedOut) }
            guard let snapshot = await sample(collector, within: remaining) else {
                return .init(state: .unknown, reasonCode: Task.isCancelled ? .stabilizationCancelled : .stabilizationTimedOut)
            }
            let current = assess(snapshot)
            if let previousPath, let path = snapshot.path, Self.pathChanged(previousPath, path) {
                uncertain = .init(state: .unknown, reasonCode: .pathTransition)
            }
            previousPath = snapshot.path
            if current.state == .unknown { uncertain = uncertain ?? current }
            if let lastDefiniteState, current.state != .unknown,
               lastDefiniteState != current.state {
                return .init(state: .unknown, reasonCode: .conflictingSignals)
            }
            if current.state != .unknown { lastDefiniteState = current.state }
            last = current
            if index + 1 < count {
                do { try await Task.sleep(for: interval) }
                catch { return .init(state: .unknown, reasonCode: .stabilizationCancelled) }
            }
        }
        return uncertain ?? last ?? .init(state: .unknown, reasonCode: .stabilizationPending)
    }

    /// Converts raw observations to an AsyncSequence of sanitized state changes.
    /// Only the latest assessment is retained by the output stream.
    public func changes(from snapshots: AsyncStream<RawNetworkSnapshot>) -> AsyncStream<VPNAssessment> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                var previous: VPNAssessment?
                var previousPath: RawPathState?
                for await snapshot in snapshots {
                    let current: VPNAssessment
                    if let previousPath, let path = snapshot.path, Self.pathChanged(previousPath, path) {
                        current = .init(state: .unknown, reasonCode: .pathTransition)
                    } else {
                        current = assess(snapshot)
                    }
                    previousPath = snapshot.path
                    if current != previous {
                        continuation.yield(current)
                        previous = current
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func sample(_ collector: any NetworkStateCollecting, within limit: Duration) async -> RawNetworkSnapshot? {
        // A task group waits for every child on scope exit. That would defeat the
        // deadline if a faulty collector ignored cancellation. The stream races two
        // unstructured tasks and returns the first value without joining either.
        var output: AsyncStream<RawNetworkSnapshot?>.Continuation!
        let stream = AsyncStream<RawNetworkSnapshot?>(bufferingPolicy: .bufferingNewest(1)) {
            output = $0
        }
        let collection = Task {
            output.yield(await collector.collect())
            output.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            output.yield(nil)
            output.finish()
        }
        var iterator = stream.makeAsyncIterator()
        let result = await withTaskCancellationHandler {
            await iterator.next() ?? nil
        } onCancel: {
            output.finish()
            collection.cancel()
            timer.cancel()
        }
        collection.cancel()
        timer.cancel()
        output.finish()
        return result
    }

    private static func isTunnel(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utun") || lower.hasPrefix("ipsec") || lower.hasPrefix("ppp")
    }

    private static func pathChanged(_ previous: RawPathState, _ current: RawPathState) -> Bool {
        previous.status != current.status ||
        Set(previous.selectedInterfaces) != Set(current.selectedInterfaces) ||
        Set(previous.gateways) != Set(current.gateways)
    }
}
