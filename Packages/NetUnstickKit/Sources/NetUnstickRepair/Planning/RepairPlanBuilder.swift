import Foundation
import NetUnstickCore
import NetUnstickNetwork

public enum RepairKind: String, Sendable, CaseIterable {
    case retryCheck, refreshResolverCache, renewDHCP, removeOrphanedRoute
}

public struct ConfirmationSummary: Sendable, Equatable {
    public let change: String
    public let resource: String
    public let purpose: String
    public let requiresAdministrator: Bool
    public let possibleImpact: String
    public let verification: String
}

public struct RepairPlan: Sendable {
    public let kind: RepairKind
    public let reasonCode: String
    public let checkID: String
    public let resource: RepairResource
    public let summary: ConfirmationSummary
    public init(kind: RepairKind, reasonCode: String, checkID: String, resource: RepairResource,
                summary: ConfirmationSummary) {
        self.kind = kind; self.reasonCode = reasonCode; self.checkID = checkID
        self.resource = resource; self.summary = summary
    }
}

public enum RepairResource: Sendable, Equatable {
    case check(String), resolverCache, physicalInterface(String)
    case route(destination: String, prefix: Int, interface: String, gateway: String)
}

public struct RepairPlanningResult: Sendable {
    public let plans: [RepairPlan]
    public let nextSteps: [String]
}

public enum RepairCatalog {
    public static func permits(_ plan: RepairPlan) -> Bool {
        switch (plan.kind, plan.checkID, plan.reasonCode, plan.resource) {
        case (.retryCheck, "unicast_dns_resolution", "dnsFailure", .check("unicast_dns_resolution")),
             (.retryCheck, "bonjour_discovery", "browserFailed", .check("bonjour_discovery")),
             (.retryCheck, "bonjour_discovery", "noServices", .check("bonjour_discovery")),
             (.refreshResolverCache, "unicast_dns_resolution", "dnsFailure", .resolverCache),
             (.refreshResolverCache, "bonjour_discovery", "browserFailed", .resolverCache),
             (.renewDHCP, "physical_link", "noAddressLease", .physicalInterface): return true
        default: return false
        }
    }
    public static let safeNextSteps: [String: String] = [
        NetworkCheckReason.activeProxy.rawValue: NextStep.contactSupport.rawValue,
        NetworkCheckReason.activePAC.rawValue: NextStep.contactSupport.rawValue,
        NetworkCheckReason.localRouteViaTunnel.rawValue: NextStep.contactSupport.rawValue,
        NetworkCheckReason.residualScopedDNS.rawValue: NextStep.contactSupport.rawValue,
        NetworkCheckReason.residualSearchDomain.rawValue: NextStep.contactSupport.rawValue,
        NetworkCheckReason.resolverOrder.rawValue: NextStep.contactSupport.rawValue,
        NetworkCheckReason.orphanedTunnel.rawValue: NextStep.contactSupport.rawValue,
        NetworkCheckReason.expectedInterfaceMissing.rawValue: NextStep.contactSupport.rawValue,
        NetworkCheckReason.routingConflict.rawValue: NextStep.contactSupport.rawValue
    ]
    public static let blockedScenarios: Set<FortinetScenario> = [
        .managedLocalLANRestriction, .infrastructureMDNSCandidate, .activeProxy,
        .residualProxy, .localSubnetViaTunnel, .residualResolver, .orphanedTunnel
    ]
}

public struct RepairPlanBuilder {
    public init() {}

    /// `snapshot` remains ephemeral. The caller must obtain it from the same collection
    /// as the report; execution re-collects and compares the exact target again.
    public func build(report: DiagnosisReport, snapshot: RawNetworkSnapshot,
                      dhcpInterfaces: Set<String>) -> RepairPlanningResult {
        let freshVPN = VPNStateDetector().assess(snapshot)
        guard report.vpn.state == .inactive, freshVPN.state == .inactive else {
            let step: NextStep = report.vpn.state == .active || freshVPN.state == .active ? .waitForVPN : .verifyVPN
            return .init(plans: [], nextSteps: [step.rawValue])
        }
        let blocked = !Set(report.fortinetFindings.map(\.scenario)).isDisjoint(with: RepairCatalog.blockedScenarios)
        var plans: [RepairPlan] = []
        var steps: [String] = []
        for result in report.results where result.kind == .diagnostic {
            guard let code = result.after.values[.errorCode], result.outcome == .failure ||
                    (result.operationID == "bonjour_discovery" && code == BonjourReason.noServices.rawValue)
            else { continue }
            if let step = RepairCatalog.safeNextSteps[code] { steps.append(step); continue }
            guard !blocked else { steps.append(NextStep.contactSupport.rawValue); continue }
            let check = result.operationID
            switch (check, code) {
            case ("unicast_dns_resolution", NetworkCheckReason.dnsFailure.rawValue),
                 ("bonjour_discovery", BonjourReason.browserFailed.rawValue):
                plans.append(make(.retryCheck, code, check, .check(check)))
                // A failed lookup/discovery is only a symptom. Cache refresh remains a
                // candidate and is offered only when the same failure persists on revalidation.
                plans.append(make(.refreshResolverCache, code, check, .resolverCache))
            case ("bonjour_discovery", BonjourReason.noServices.rawValue):
                plans.append(make(.retryCheck, code, check, .check(check)))
            case ("physical_link", NetworkCheckReason.noAddressLease.rawValue):
                let physical = snapshot.interfaces.filter { $0.isUp && ["wifi", "ethernet"].contains($0.type) && $0.name.range(of: #"^en[0-9]{1,2}$"#, options: .regularExpression) != nil }
                if physical.count == 1, dhcpInterfaces == Set([physical[0].name]) {
                    plans.append(make(.renewDHCP, code, check, .physicalInterface(physical[0].name)))
                } else { steps.append(NextStep.contactSupport.rawValue) }
            default: break
            }
        }
        return .init(plans: plans, nextSteps: Array(Set(steps)).sorted())
    }

    private func make(_ kind: RepairKind, _ code: String, _ check: String, _ resource: RepairResource) -> RepairPlan {
        let label: String
        switch resource {
        case .check: label = "Powiązane sprawdzenie"
        case .resolverCache: label = "Cache resolvera i mDNS"
        case .physicalInterface: label = "Jedyny wybrany interfejs fizyczny"
        case .route: label = "Jedna wskazana trasa lokalna"
        }
        let change: String
        switch kind {
        case .retryCheck: change = "Ponowienie sprawdzenia bez zmiany systemu"
        case .refreshResolverCache: change = "Odświeżenie cache resolvera i mDNS"
        case .renewDHCP: change = "Odnowienie dzierżawy DHCP"
        case .removeOrphanedRoute: change = "Usunięcie jednej osieroconej trasy"
        }
        return .init(kind: kind, reasonCode: code, checkID: check, resource: resource,
                     summary: .init(change: change, resource: label, purpose: "Weryfikacja: \(check)",
                                    requiresAdministrator: kind != .retryCheck,
                                    possibleImpact: kind == .retryCheck ? "Brak zmian sieci" : "Krótkie zakłócenie łączności",
                                    verification: "Nowy snapshot i ponowienie: \(check)"))
    }
}
