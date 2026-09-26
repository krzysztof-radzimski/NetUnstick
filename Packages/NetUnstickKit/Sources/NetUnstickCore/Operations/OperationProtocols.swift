import Foundation

public protocol OperationClock: Sendable {
    func now() -> Date
}

public struct SystemOperationClock: OperationClock {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol CancellationChecking: Sendable {
    func checkCancellation() throws
}

public struct TaskCancellationChecker: CancellationChecking {
    public init() {}
    public func checkCancellation() throws { try Task.checkCancellation() }
}

public struct OperationContext: Sendable {
    public let clock: any OperationClock
    public let cancellation: any CancellationChecking

    public init(clock: any OperationClock = SystemOperationClock(),
                cancellation: any CancellationChecking = TaskCancellationChecker()) {
        self.clock = clock
        self.cancellation = cancellation
    }
}

/// Implementations may observe state and perform bounded probes, but must not mutate network settings.
public protocol DiagnosticCheck: Sendable {
    var id: String { get }
    var name: String { get }
    func run(context: OperationContext) async -> OperationResult
}

public enum RepairPrivilege: String, Codable, Sendable {
    case none, administrator
}

public enum RepairResourceScope: String, Codable, Sendable {
    case wifiInterface, physicalInterface, dnsResolver, localDiscovery, localRoute, diagnosticCheck
}

/// A repair implementation must check VPN state immediately before changing its declared resource.
/// The caller must explicitly authorize each run and verify the associated check before and after.
public protocol RepairAction: Sendable {
    var id: String { get }
    var name: String { get }
    var repairedCheckID: String { get }
    var requiredPrivilege: RepairPrivilege { get }
    var timeout: Duration { get }
    var resourceScope: RepairResourceScope { get }
    func run(context: OperationContext) async -> OperationResult
}
