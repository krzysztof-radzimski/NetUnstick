import Foundation
import NetUnstickCore

/// A single, explicitly selected plan. Construction does not execute it.
public struct PlannedRepairAction: RepairAction {
    public let plan: RepairPlan
    private let executor: RepairExecutor
    public init(plan: RepairPlan, executor: RepairExecutor) {
        self.plan = plan; self.executor = executor
    }
    public var id: String { plan.kind.rawValue }
    public var name: String { plan.kind.rawValue }
    public var repairedCheckID: String { plan.checkID }
    public var requiredPrivilege: RepairPrivilege { plan.kind == .retryCheck ? .none : .administrator }
    public var timeout: Duration { .seconds(90) }
    public var resourceScope: RepairResourceScope {
        switch plan.resource {
        case .check: return .diagnosticCheck
        case .resolverCache: return .dnsResolver
        case .physicalInterface: return .physicalInterface
        case .route: return .localRoute
        }
    }
    public func run(context: OperationContext) async -> OperationResult {
        await executor.execute(plan, context: context)
    }
}
