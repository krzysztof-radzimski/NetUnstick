import Foundation
import Darwin
import NetUnstickNetwork

public enum RepairPolicyError: Error, Equatable {
    case incompatibleVersion, invalidRequest, vpnActive, vpnUnknown, ambiguousResource
}

/// One exact routing-table entry left behind by a VPN client: masked network text, prefix
/// length, tunnel interface and next hop, ready for a fixed `route` argument list.
public struct StaleTunnelRoute: Sendable, Hashable, Comparable {
    public let destination: String
    public let prefix: Int
    public let interface: String
    public let gateway: String
    public init(destination: String, prefix: Int, interface: String, gateway: String) {
        self.destination = destination; self.prefix = prefix; self.interface = interface; self.gateway = gateway
    }
    public var cidr: String { "\(destination)/\(prefix)" }
    public var target: PrivilegedRouteTarget { .init(destination: destination, prefix: prefix, interface: interface) }

    /// True when an observed routing-table row is this exact entry.
    public func matches(_ route: RawRoute) -> Bool {
        guard route.interfaceName == interface, !route.isDefault, !route.isLocal, !route.isCloned,
              let network = IPPrefix(route.destination), let expected = IPPrefix(cidr) else { return false }
        return network == expected
    }
    public static func < (lhs: StaleTunnelRoute, rhs: StaleTunnelRoute) -> Bool {
        if lhs.interface != rhs.interface { return lhs.interface < rhs.interface }
        guard let left = IPPrefix(lhs.cidr), let right = IPPrefix(rhs.cidr) else { return lhs.cidr < rhs.cidr }
        return left < right
    }
}

public enum AuthorizedRepair: Equatable {
    case renewDHCP(String)
    case removeRoute(destination: String, prefix: Int, interface: String, gateway: String)
    case removeRoutes([StaleTunnelRoute])
}

public enum RepairPolicy {
    /// A VPN client splitting one LAN prefix around excluded hosts needs at most a few entries per
    /// excluded address. A larger set is not a leftover LAN shadow and is refused as a whole.
    public static let maximumStaleTunnelRoutes = 24

    public static func authorize(_ request: PrivilegedRequest, snapshot: RawNetworkSnapshot,
                                 dhcpInterfaces: Set<String>) throws -> AuthorizedRepair {
        guard request.version == PrivilegedProtocol.version else { throw RepairPolicyError.incompatibleVersion }
        // This single exception has its own stronger disconnected-VPN and local-link proof.
        // The ordinary VPN gate remains closed for every other network-changing action.
        if case .removeStaleTunnelRoutes(let targets) = request.action {
            guard !targets.isEmpty, targets.count <= maximumStaleTunnelRoutes,
                  Set(targets).count == targets.count else { throw RepairPolicyError.invalidRequest }
            let observed = staleLocalTunnelRoutes(in: snapshot)
            guard !observed.isEmpty, Set(observed.map(\.target)) == Set(targets) else {
                throw RepairPolicyError.ambiguousResource
            }
            return .removeRoutes(observed)
        }
        let vpn = VPNStateDetector().assess(snapshot).state
        guard vpn != .active else { throw RepairPolicyError.vpnActive }
        guard vpn == .inactive else { throw RepairPolicyError.vpnUnknown }
        switch request.action {
        case .refreshResolverCache, .removeStaleTunnelRoutes, .handshake: throw RepairPolicyError.invalidRequest
        case .renewDHCP(let name):
            guard validPhysicalName(name), dhcpInterfaces.contains(name),
                  snapshot.interfaces.filter({ $0.name == name && $0.isUp && ($0.type == "wifi" || $0.type == "ethernet") }).count == 1
            else { throw RepairPolicyError.ambiguousResource }
            return .renewDHCP(name)
        case .removeOrphanedRoute(let destination, let prefix, let name):
            guard validPhysicalName(name), let network = IPPrefix("\(destination)/\(prefix)"),
                  network.family == .ipv4, (8...30).contains(prefix), network.text == destination, network.isPrivateIPv4 else {
                throw RepairPolicyError.invalidRequest
            }
            let matches = snapshot.routes.filter { IPPrefix($0.destination) == network && $0.interfaceName == name && !$0.isDefault }
            guard matches.count == 1, snapshot.interfaces.filter({ $0.name == name && $0.isUp }).isEmpty,
                  let gateway = matches[0].gateway, validIPv4(gateway),
                  snapshot.routes.filter({ IPPrefix($0.destination) == network }).count == 1
            else { throw RepairPolicyError.ambiguousResource }
            return .removeRoute(destination: destination, prefix: prefix, interface: name, gateway: gateway)
        }
    }

    /// Tunnel routes that shadow the directly connected LAN after a VPN disconnect.
    ///
    /// Requires a configured VPN service to report disconnected, a physical default path,
    /// and one directly connected private network on that physical interface. Every
    /// unscoped, non-cloned forwarding entry through a still-present `utun` whose
    /// destination lies strictly inside that network is returned; a VPN client that
    /// excluded single hosts from a LAN prefix leaves several such entries at once.
    /// Any collection error, tunnel trace in DNS or dynamic store, duplicate destination
    /// or an oversized set yields no candidate.
    public static func staleLocalTunnelRoutes(in snapshot: RawNetworkSnapshot) -> [StaleTunnelRoute] {
        guard snapshot.errors.isEmpty, snapshot.vpnServices == .disconnected,
              let path = snapshot.path, path.status == "satisfied", !path.transitionObserved,
              Set(path.selectedInterfaces).count == 1, let physicalName = path.selectedInterfaces.first,
              validPhysicalName(physicalName),
              snapshot.routes.contains(where: { $0.isDefault && $0.interfaceName == physicalName }) else { return [] }
        let physical = snapshot.interfaces.filter {
            $0.name == physicalName && $0.isUp && ["wifi", "ethernet", "wired"].contains($0.type.lowercased())
        }
        guard physical.count == 1 else { return [] }
        let hosts = physical[0].addresses.compactMap { IPPrefix(address: $0) }
            .filter { $0.family == .ipv4 && !$0.isLinkLocal && !$0.isLoopback }
        guard !hosts.isEmpty else { return [] }
        let localNetworks = snapshot.routes.compactMap { route -> IPPrefix? in
            guard route.interfaceName == physicalName, route.isLocal, !route.isDefault, !route.isCloned,
                  let network = IPPrefix(route.destination), network.family == .ipv4, network.prefix < 32,
                  network.isPrivateIPv4, !network.isLinkLocal, hosts.contains(where: network.contains) else { return nil }
            return network
        }
        guard !localNetworks.isEmpty else { return [] }
        var occurrences: [IPPrefix: Int] = [:]
        for route in snapshot.routes {
            if let network = IPPrefix(route.destination) { occurrences[network, default: 0] += 1 }
        }
        let candidates = snapshot.routes.compactMap { route -> StaleTunnelRoute? in
            guard let tunnel = route.interfaceName, validTunnelName(tunnel),
                  !route.isDefault, !route.isLocal, !route.isCloned, !route.isScoped,
                  snapshot.interfaces.contains(where: { $0.name == tunnel }),
                  !snapshot.dynamicStoreTunnelInterfaces.contains(tunnel),
                  !snapshot.resolvers.contains(where: { $0.interfaceName == tunnel }),
                  let gateway = route.gateway, validIPv4(gateway),
                  let network = IPPrefix(route.destination), network.family == .ipv4,
                  (8...32).contains(network.prefix), network.isPrivateIPv4, !network.isLinkLocal,
                  localNetworks.contains(where: { $0.prefix < network.prefix && $0.contains(network) }),
                  occurrences[network] == 1
            else { return nil }
            return StaleTunnelRoute(destination: network.text, prefix: network.prefix, interface: tunnel, gateway: gateway)
        }
        guard !candidates.isEmpty, candidates.count <= maximumStaleTunnelRoutes,
              Set(candidates).count == candidates.count else { return [] }
        return candidates.sorted()
    }

    private static func validPhysicalName(_ name: String) -> Bool {
        name.range(of: #"^en[0-9]{1,2}$"#, options: .regularExpression) != nil
    }
    private static func validTunnelName(_ name: String) -> Bool {
        name.range(of: #"^utun[0-9]{1,2}$"#, options: .regularExpression) != nil
    }
    private static func validIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }
}
