import Foundation
import NetUnstickCore

// Shared value types only. Both editions use the same stable codes and presentation labels.
// System collectors, subprocesses, configuration readers and repair APIs are in other targets.

public enum NetworkCheckReason: String, Sendable, CaseIterable {
    case healthy, dataIncomplete, environmentLimited, cancelled, timedOut
    case noPhysicalLink, noAddressLease, noGateway, noDefaultRoute, duplicateDefaultRoute, residualDefaultRoute
    case localRouteMissing, localRouteViaTunnel, resolverMissing, residualScopedDNS, resolverOrder, residualSearchDomain
    case dnsNXDomain, dnsTimeout, dnsServerUnavailable, dnsNoPath, dnsFailure
    case localPathUnavailable, internetUnavailable, internetReachable, activeProxy, activePAC
    case orphanedTunnel, routingConflict, expectedInterfaceMissing, unstableAfterDisconnect
    case routeViaInactiveTunnel

    public var message: String {
        switch self {
        case .healthy: return L10n.text("network_healthy")
        case .dataIncomplete: return L10n.text("network_dataIncomplete")
        case .environmentLimited: return L10n.text("network_environmentLimited")
        case .cancelled: return L10n.text("network_cancelled")
        case .timedOut: return L10n.text("network_timedOut")
        case .noPhysicalLink: return L10n.text("network_noPhysicalLink")
        case .noAddressLease: return L10n.text("network_noAddressLease")
        case .noGateway: return L10n.text("network_noGateway")
        case .noDefaultRoute: return L10n.text("network_noDefaultRoute")
        case .duplicateDefaultRoute: return L10n.text("network_duplicateDefaultRoute")
        case .residualDefaultRoute: return L10n.text("network_residualDefaultRoute")
        case .localRouteMissing: return L10n.text("network_localRouteMissing")
        case .localRouteViaTunnel: return L10n.text("network_localRouteViaTunnel")
        case .resolverMissing: return L10n.text("network_resolverMissing")
        case .residualScopedDNS: return L10n.text("network_residualScopedDNS")
        case .resolverOrder: return L10n.text("network_resolverOrder")
        case .residualSearchDomain: return L10n.text("network_residualSearchDomain")
        case .dnsNXDomain: return L10n.text("network_dnsNXDomain")
        case .dnsTimeout: return L10n.text("network_dnsTimeout")
        case .dnsServerUnavailable: return L10n.text("network_dnsServerUnavailable")
        case .dnsNoPath: return L10n.text("network_dnsNoPath")
        case .dnsFailure: return L10n.text("network_dnsFailure")
        case .localPathUnavailable: return L10n.text("network_localPathUnavailable")
        case .internetUnavailable: return L10n.text("network_internetUnavailable")
        case .internetReachable: return L10n.text("network_internetReachable")
        case .activeProxy: return L10n.text("network_activeProxy")
        case .activePAC: return L10n.text("network_activePAC")
        case .orphanedTunnel: return L10n.text("network_orphanedTunnel")
        case .routingConflict: return L10n.text("network_routingConflict")
        case .routeViaInactiveTunnel: return L10n.text("network_routeViaInactiveTunnel")
        case .expectedInterfaceMissing: return L10n.text("network_expectedInterfaceMissing")
        case .unstableAfterDisconnect: return L10n.text("network_unstableAfterDisconnect")
        }
    }
}

public enum NetworkCheckKind: String, Sendable, CaseIterable {
    case physicalLink, defaultRoute, localSubnetRoute, resolverConfiguration
    case unicastDNSResolution, internetPath, proxyConfiguration, interfaceConsistency
    public var id: String {
        switch self {
        case .physicalLink: return "physical_link"
        case .defaultRoute: return "default_route"
        case .localSubnetRoute: return "local_subnet_route"
        case .resolverConfiguration: return "resolver_configuration"
        case .unicastDNSResolution: return "unicast_dns_resolution"
        case .internetPath: return "internet_path"
        case .proxyConfiguration: return "proxy_configuration"
        case .interfaceConsistency: return "interface_consistency"
        }
    }
    public var timeout: Duration {
        switch self {
        case .unicastDNSResolution, .internetPath: return .seconds(3)
        default: return .seconds(1)
        }
    }
}

public enum DeviceConnectionReason: String, Sendable, CaseIterable {
    case reachable, refused, timedOut, unreachable, nameUnresolved, invalidInput, failed, cancelled

    public var message: String {
        switch self {
        case .reachable: return L10n.text("device_reachable")
        case .refused: return L10n.text("device_refused")
        case .timedOut: return L10n.text("device_timedOut")
        case .unreachable: return L10n.text("device_unreachable")
        case .nameUnresolved: return L10n.text("device_nameUnresolved")
        case .invalidInput: return L10n.text("device_invalidInput")
        case .failed: return L10n.text("device_failed")
        case .cancelled: return L10n.text("device_cancelled")
        }
    }

    /// Order used to pick one verdict from several attempts: a peer that answers outranks silence.
    public static let priority: [DeviceConnectionReason] = [.reachable, .refused, .timedOut, .unreachable, .failed, .cancelled]
    public static func best(_ reasons: [DeviceConnectionReason]) -> DeviceConnectionReason? {
        priority.first { reasons.contains($0) } ?? reasons.first
    }
}

public enum AddressFamily: String, Sendable, CaseIterable {
    case ipv4, ipv6
}

public enum SMBSessionOutcome: String, Sendable, CaseIterable {
    case sharesListed, authRejected, sessionFailed, timedOut, otherExit, unknown

    public static func classify(exitStatus: Int32) -> SMBSessionOutcome {
        switch exitStatus {
        case 0: return .sharesListed
        case 77: return .authRejected
        case 68: return .sessionFailed
        default: return .otherExit
        }
    }
}

public enum DeviceConnectionInput {
    /// Host names, Bonjour names and literal addresses only; no spaces, quotes or shell characters.
    public static func isValidHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == ":" || scalar == "%" || scalar == "_"
        }
    }
    public static func port(from text: String) -> UInt16? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return UInt16(value)
    }
}

public enum FileSharingReason: String, Sendable, CaseIterable {
    case healthy, guestRejected, sharingOff, accountNotEnabledForSMB, noLoginMethod, noSharedFolders, dataIncomplete, cancelled

    public var message: String {
        switch self {
        case .healthy:
            return L10n.text("sharing_healthy")
        case .guestRejected:
            return L10n.text("sharing_guestRejected")
        case .noLoginMethod:
            return L10n.text("sharing_noLoginMethod")
        case .sharingOff:
            return L10n.text("sharing_sharingOff")
        case .accountNotEnabledForSMB:
            return L10n.text("sharing_accountNotEnabledForSMB")
        case .noSharedFolders:
            return L10n.text("sharing_noSharedFolders")
        case .dataIncomplete:
            return L10n.text("sharing_dataIncomplete")
        case .cancelled:
            return L10n.text("sharing_cancelled")
        }
    }
}

public enum ContentFilterReason: String, Sendable, CaseIterable {
    case noFilter, firewallFilterActive, thirdPartyFilterActive, filterActive, dataIncomplete, cancelled

    public var message: String {
        switch self {
        case .noFilter:
            return L10n.text("filter_noFilter")
        case .firewallFilterActive:
            return L10n.text("filter_firewallFilterActive")
        case .thirdPartyFilterActive:
            return L10n.text("filter_thirdPartyFilterActive")
        case .filterActive:
            return L10n.text("filter_filterActive")
        case .dataIncomplete:
            return L10n.text("filter_dataIncomplete")
        case .cancelled:
            return L10n.text("filter_cancelled")
        }
    }
}

public enum VPNState: String, Codable, Sendable {
    case active, inactive, unknown

    public var permitsNetworkChange: Bool { self == .inactive }
}

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

public enum VPNServiceStatus: String, Sendable {
    case disconnected, connected, unknown
}
