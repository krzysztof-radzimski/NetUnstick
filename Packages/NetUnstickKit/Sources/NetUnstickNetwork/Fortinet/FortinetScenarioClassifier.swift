import Foundation
import NetUnstickCore

public enum FortinetScenario: String, Codable, Sendable {
    case localSubnetViaTunnel, residualResolver, residualProxy, activeProxy, orphanedTunnel
    case managedLocalLANRestriction, clientSideCandidate, infrastructureMDNSCandidate
}

public enum FortinetEvidenceCode: String, Codable, Sendable {
    case localRouteViaTunnel, tunnelResolverAfterDisconnect, searchDomainAfterDisconnect
    case proxyAfterDisconnect, proxyActive, tunnelInterfaceUnreferenced, tunnelRouteOrphaned, activeTunnel
    case localPathUnavailable, bonjourUnavailable, noServicesObserved, physicalPathAvailable
    case multipleSegmentsReported, directIPTestNeeded, compareWithoutVPNNeeded
    case gatewayPolicyReviewNeeded, versionCheckNeeded
}

public struct FortinetFinding: Codable, Sendable, Equatable {
    public let scenario: FortinetScenario
    public let status: String // Always a hypothesis; public observations do not identify policy ownership.
    public let observed: [FortinetEvidenceCode]
    public let neededToConfirm: [FortinetEvidenceCode]
    public let nextStep: String
    public let productVersion: String?
    public let versionedGuidance: String?
}

public struct FortiClientMetadataReader: Sendable {
    public init() {}
    public func redactedVersion() -> String? {
        guard let bundle = Bundle(path: "/Applications/FortiClient.app"),
              let raw = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              raw.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil else { return nil }
        return "FortiClient " + raw
    }
}

public struct FortinetScenarioClassifier: Sendable {
    public init() {}
    public func classify(snapshot: RawNetworkSnapshot, vpn: VPNAssessment,
                         checks: [OperationResult], previous: RawNetworkSnapshot? = nil,
                         multipleSegmentsReported: Bool = false,
                         productVersion: String? = nil) -> [FortinetFinding] {
        let reasons = Set(checks.compactMap { $0.after.values[.errorCode] })
        let bonjour = checks.first { $0.operationID == "bonjour_discovery" }
        let physical = snapshot.interfaces.contains { $0.isUp && ["wifi", "ethernet", "wired"].contains($0.type.lowercased()) }
        let tunnelNames = Set(snapshot.interfaces.filter { isTunnel($0.name) }.map(\.name))
        let activeTunnels = Set(snapshot.interfaces.filter { $0.isUp && isTunnel($0.name) }.map(\.name))
        let orphanRoute = snapshot.routes.contains { $0.interfaceName.map(isTunnel) == true && !activeTunnels.contains($0.interfaceName ?? "") }
        let previousTunnel = previous?.interfaces.contains { isTunnel($0.name) && $0.isUp } == true
        let disconnected = vpn.state != .active && (previousTunnel || !tunnelNames.isEmpty || orphanRoute)
        let version = sanitizedVersion(productVersion)
        var findings: [FortinetFinding] = []
        func add(_ scenario: FortinetScenario, _ observed: [FortinetEvidenceCode], _ needed: [FortinetEvidenceCode], _ step: NextStep) {
            findings.append(.init(scenario: scenario, status: "hypothesis", observed: observed,
                                  neededToConfirm: needed, nextStep: step.rawValue, productVersion: version,
                                  versionedGuidance: version.map {
                "Ask your administrator to verify \($0) compatibility with macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)."
            }))
        }
        if reasons.contains(NetworkCheckReason.localRouteViaTunnel.rawValue) {
            add(.localSubnetViaTunnel, [.localRouteViaTunnel], [.directIPTestNeeded, .compareWithoutVPNNeeded], .contactSupport)
        }
        let tunnelResolver = snapshot.resolvers.contains { $0.interfaceName.map(isTunnel) == true && !activeTunnels.contains($0.interfaceName ?? "") }
        let residualSearch = disconnected && snapshot.resolvers.contains { !$0.searchDomains.isEmpty }
        if tunnelResolver || residualSearch || reasons.contains(NetworkCheckReason.residualSearchDomain.rawValue) {
            add(.residualResolver, tunnelResolver ? [.tunnelResolverAfterDisconnect] : [.searchDomainAfterDisconnect],
                [.compareWithoutVPNNeeded], .contactSupport)
        }
        if reasons.contains(NetworkCheckReason.activeProxy.rawValue) || reasons.contains(NetworkCheckReason.activePAC.rawValue) {
            add(disconnected ? .residualProxy : .activeProxy,
                [disconnected ? .proxyAfterDisconnect : .proxyActive],
                [.compareWithoutVPNNeeded], .contactSupport)
        }
        if disconnected && (!tunnelNames.isEmpty || orphanRoute || reasons.contains(NetworkCheckReason.orphanedTunnel.rawValue)) {
            add(.orphanedTunnel, [orphanRoute ? .tunnelRouteOrphaned : .tunnelInterfaceUnreferenced],
                [.compareWithoutVPNNeeded], .contactSupport)
        }
        if vpn.state == .active && (reasons.contains(NetworkCheckReason.localRouteViaTunnel.rawValue) ||
            reasons.contains(BonjourReason.noLocalPath.rawValue)) {
            add(.managedLocalLANRestriction, [.activeTunnel, .localPathUnavailable],
                [.gatewayPolicyReviewNeeded, .compareWithoutVPNNeeded, .versionCheckNeeded], .contactSupport)
        }
        if physical && disconnected && bonjour?.outcome == .failure {
            add(.clientSideCandidate, [.physicalPathAvailable, .bonjourUnavailable],
                [.compareWithoutVPNNeeded, .directIPTestNeeded, .versionCheckNeeded], .contactSupport)
        }
        if physical && multipleSegmentsReported && bonjour?.after.values[.errorCode] == BonjourReason.noServices.rawValue {
            add(.infrastructureMDNSCandidate, [.physicalPathAvailable, .multipleSegmentsReported, .noServicesObserved],
                [.directIPTestNeeded, .gatewayPolicyReviewNeeded], .contactSupport)
        }
        return findings
    }
    private func isTunnel(_ name: String) -> Bool {
        let value = name.lowercased()
        return value.hasPrefix("utun") || value.hasPrefix("ipsec") || value.hasPrefix("ppp")
    }
    private func sanitizedVersion(_ value: String?) -> String? {
        guard let value, value.hasPrefix("FortiClient "),
              value.dropFirst(12).range(of: #"^[0-9]+(?:\.[0-9]+){0,3}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
}
