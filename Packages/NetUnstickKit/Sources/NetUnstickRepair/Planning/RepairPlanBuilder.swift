import Foundation
import NetUnstickCore
import NetUnstickNetwork

public enum RepairKind: String, Sendable, CaseIterable {
    case retryCheck, refreshResolverCache, renewDHCP, removeStaleTunnelRoutes
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
    /// Every stale tunnel route that shadows the directly connected LAN, removed together.
    case tunnelRoutes([StaleTunnelRoute])
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
             (.renewDHCP, "physical_link", "noAddressLease", .physicalInterface): return true
        case (.removeStaleTunnelRoutes, "local_subnet_route", "localRouteViaTunnel", .tunnelRoutes(let routes)):
            return !routes.isEmpty && routes.count <= RepairPolicy.maximumStaleTunnelRoutes
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
        NetworkCheckReason.orphanedTunnel.rawValue: NextStep.restartVPNClient.rawValue,
        NetworkCheckReason.expectedInterfaceMissing.rawValue: NextStep.contactSupport.rawValue,
        NetworkCheckReason.routingConflict.rawValue: NextStep.contactSupport.rawValue,
        NetworkCheckReason.routeViaInactiveTunnel.rawValue: NextStep.verifyVPN.rawValue,
        // Enabling an account for SMB stores a password hash; that is a user decision in System Settings.
        FileSharingReason.accountNotEnabledForSMB.rawValue: NextStep.enableSMBAccount.rawValue,
        FileSharingReason.noLoginMethod.rawValue: NextStep.enableSMBAccount.rawValue
    ]
    public static let blockedScenarios: Set<FortinetScenario> = [
        .managedLocalLANRestriction, .infrastructureMDNSCandidate, .activeProxy,
        .residualProxy, .localSubnetViaTunnel, .residualResolver, .orphanedTunnel
    ]
}

public struct RepairPlanBuilder {
    public init() {}

    /// `snapshot` remains ephemeral. The caller must obtain it from the same collection
    /// as the report; execution re-collects and compares the exact targets again.
    public func build(report: DiagnosisReport, snapshot: RawNetworkSnapshot,
                      dhcpInterfaces: Set<String>) -> RepairPlanningResult {
        if report.results.contains(where: {
            $0.operationID == "local_subnet_route" && $0.outcome == .failure &&
            $0.after.values[.errorCode] == NetworkCheckReason.localRouteViaTunnel.rawValue
        }) {
            let stale = RepairPolicy.staleLocalTunnelRoutes(in: snapshot)
            if !stale.isEmpty {
                let plan = make(.removeStaleTunnelRoutes, NetworkCheckReason.localRouteViaTunnel.rawValue,
                                "local_subnet_route", .tunnelRoutes(stale))
                return .init(plans: [plan], nextSteps: [])
            }
        }
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
        var routeCount = 0
        switch resource {
        case .check: label = L10n.text("repair_resource_check")
        case .resolverCache: label = L10n.text("repair_resource_resolver")
        case .physicalInterface: label = L10n.text("repair_resource_interface")
        case .tunnelRoutes(let routes):
            routeCount = routes.count
            label = Self.routeLabel(routes.count)
        }
        let change: String
        switch kind {
        case .retryCheck: change = L10n.text("repair_retry")
        case .refreshResolverCache: change = L10n.text("repair_refresh_cache")
        case .renewDHCP: change = L10n.text("repair_renew_dhcp")
        case .removeStaleTunnelRoutes: change = L10n.format("repair_remove_routes", routeCount)
        }
        let impact: String
        switch kind {
        case .retryCheck: impact = L10n.text("repair_no_change")
        case .removeStaleTunnelRoutes:
            impact = L10n.text("repair_route_impact")
        default: impact = L10n.text("repair_short_interruption")
        }
        return .init(kind: kind, reasonCode: code, checkID: check, resource: resource,
                     summary: .init(change: change, resource: label, purpose: L10n.format("repair_purpose", L10n.operationTitle(check)),
                                    requiresAdministrator: kind != .retryCheck,
                                    possibleImpact: impact,
                                    verification: L10n.format("repair_verification", L10n.operationTitle(check))))
    }

    /// A count label avoids embedding any address, interface name, or language-specific
    /// plural decision in the repair plan. All words come from the shared resource bundle.
    static func routeLabel(_ count: Int) -> String {
        L10n.format("repair_routes_count", count)
    }
}
