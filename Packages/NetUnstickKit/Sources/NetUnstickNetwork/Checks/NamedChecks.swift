import Foundation
import NetUnstickCore

public struct PhysicalLinkCheck: DiagnosticCheck {
    private let check: SnapshotDiagnosticCheck
    public var id: String { check.id }
    public var name: String { check.name }
    public init(snapshot: RawNetworkSnapshot,
                probe: any NetworkConnectivityProbing = SystemNetworkConnectivityProbe(),
                timeout: Duration? = nil) {
        check = SnapshotDiagnosticCheck(kind: .physicalLink, snapshot: snapshot, probe: probe, timeout: timeout)
    }
    public func run(context: OperationContext) async -> OperationResult { await check.run(context: context) }
}

public struct DefaultRouteCheck: DiagnosticCheck {
    private let check: SnapshotDiagnosticCheck
    public var id: String { check.id }
    public var name: String { check.name }
    public init(snapshot: RawNetworkSnapshot,
                probe: any NetworkConnectivityProbing = SystemNetworkConnectivityProbe(),
                timeout: Duration? = nil) {
        check = SnapshotDiagnosticCheck(kind: .defaultRoute, snapshot: snapshot, probe: probe, timeout: timeout)
    }
    public func run(context: OperationContext) async -> OperationResult { await check.run(context: context) }
}

public struct LocalSubnetRouteCheck: DiagnosticCheck {
    private let check: SnapshotDiagnosticCheck
    public var id: String { check.id }
    public var name: String { check.name }
    public init(snapshot: RawNetworkSnapshot,
                probe: any NetworkConnectivityProbing = SystemNetworkConnectivityProbe(),
                timeout: Duration? = nil) {
        check = SnapshotDiagnosticCheck(kind: .localSubnetRoute, snapshot: snapshot, probe: probe, timeout: timeout)
    }
    public func run(context: OperationContext) async -> OperationResult { await check.run(context: context) }
}

public struct ResolverConfigurationCheck: DiagnosticCheck {
    private let check: SnapshotDiagnosticCheck
    public var id: String { check.id }
    public var name: String { check.name }
    public init(snapshot: RawNetworkSnapshot,
                probe: any NetworkConnectivityProbing = SystemNetworkConnectivityProbe(),
                timeout: Duration? = nil) {
        check = SnapshotDiagnosticCheck(kind: .resolverConfiguration, snapshot: snapshot, probe: probe, timeout: timeout)
    }
    public func run(context: OperationContext) async -> OperationResult { await check.run(context: context) }
}

public struct UnicastDNSResolutionCheck: DiagnosticCheck {
    private let check: SnapshotDiagnosticCheck
    public var id: String { check.id }
    public var name: String { check.name }
    public init(snapshot: RawNetworkSnapshot,
                probe: any NetworkConnectivityProbing = SystemNetworkConnectivityProbe(),
                timeout: Duration? = nil) {
        check = SnapshotDiagnosticCheck(kind: .unicastDNSResolution, snapshot: snapshot, probe: probe, timeout: timeout)
    }
    public func run(context: OperationContext) async -> OperationResult { await check.run(context: context) }
}

public struct InternetPathCheck: DiagnosticCheck {
    private let check: SnapshotDiagnosticCheck
    public var id: String { check.id }
    public var name: String { check.name }
    public init(snapshot: RawNetworkSnapshot,
                probe: any NetworkConnectivityProbing = SystemNetworkConnectivityProbe(),
                timeout: Duration? = nil) {
        check = SnapshotDiagnosticCheck(kind: .internetPath, snapshot: snapshot, probe: probe, timeout: timeout)
    }
    public func run(context: OperationContext) async -> OperationResult { await check.run(context: context) }
}

public struct ProxyConfigurationCheck: DiagnosticCheck {
    private let check: SnapshotDiagnosticCheck
    public var id: String { check.id }
    public var name: String { check.name }
    public init(snapshot: RawNetworkSnapshot,
                probe: any NetworkConnectivityProbing = SystemNetworkConnectivityProbe(),
                timeout: Duration? = nil) {
        check = SnapshotDiagnosticCheck(kind: .proxyConfiguration, snapshot: snapshot, probe: probe, timeout: timeout)
    }
    public func run(context: OperationContext) async -> OperationResult { await check.run(context: context) }
}

public struct InterfaceConsistencyCheck: DiagnosticCheck {
    private let check: SnapshotDiagnosticCheck
    public var id: String { check.id }
    public var name: String { check.name }
    public init(snapshot: RawNetworkSnapshot,
                probe: any NetworkConnectivityProbing = SystemNetworkConnectivityProbe(),
                timeout: Duration? = nil) {
        check = SnapshotDiagnosticCheck(kind: .interfaceConsistency, snapshot: snapshot, probe: probe, timeout: timeout)
    }
    public func run(context: OperationContext) async -> OperationResult { await check.run(context: context) }
}

