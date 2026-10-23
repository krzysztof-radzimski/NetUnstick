import Foundation

/// Shared classification of tunnel interfaces and routes.
///
/// macOS keeps several `utun` devices for its own services. Each carries only an IPv6
/// link-local address and is never a VPN. A VPN tunnel has a routable address, forwards
/// traffic, or is referenced by a resolver, the dynamic store or the selected path.
public enum TunnelSignals {
    public static func isTunnelName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utun") || lower.hasPrefix("ipsec") || lower.hasPrefix("ppp")
    }

    /// True for entries that forward traffic to another network: not directly connected,
    /// not cloned from a parent entry, and not an IPv6 link-local or multicast destination.
    /// An unparseable destination counts as forwarding so it can never hide a VPN.
    public static func isForwardingRoute(_ route: RawRoute) -> Bool {
        guard !route.isLocal, !route.isCloned else { return false }
        if route.isDefault { return true }
        guard let destination = IPPrefix(route.destination) else { return true }
        return !destination.isLinkLocal && !destination.isMulticast
    }

    /// An up tunnel whose only addresses are link-local and that nothing references.
    public static func isSystemInternalTunnel(_ interface: RawInterface, in snapshot: RawNetworkSnapshot) -> Bool {
        guard isTunnelName(interface.name), interface.isUp, !interface.addresses.isEmpty,
              interface.addresses.allSatisfy({ IPPrefix(address: $0)?.isLinkLocal == true }) else { return false }
        let name = interface.name
        return !snapshot.routes.contains(where: { $0.interfaceName == name && isForwardingRoute($0) }) &&
            !snapshot.resolvers.contains(where: { $0.interfaceName == name }) &&
            !snapshot.dynamicStoreTunnelInterfaces.contains(name) &&
            !(snapshot.path?.selectedInterfaces.contains(name) ?? false)
    }

    /// Tunnel interfaces that may belong to a VPN client.
    public static func vpnTunnelInterfaces(in snapshot: RawNetworkSnapshot) -> [RawInterface] {
        snapshot.interfaces.filter { isTunnelName($0.name) && !isSystemInternalTunnel($0, in: snapshot) }
    }
    public static func vpnTunnelNames(in snapshot: RawNetworkSnapshot) -> Set<String> {
        Set(vpnTunnelInterfaces(in: snapshot).map(\.name))
    }
    public static func activeVPNTunnelNames(in snapshot: RawNetworkSnapshot) -> Set<String> {
        Set(vpnTunnelInterfaces(in: snapshot).filter(\.isUp).map(\.name))
    }
    /// Every up tunnel, including system-internal devices.
    public static func upTunnelNames(in snapshot: RawNetworkSnapshot) -> Set<String> {
        Set(snapshot.interfaces.filter { $0.isUp && isTunnelName($0.name) }.map(\.name))
    }
    /// Tunnel names used by forwarding routes.
    public static func forwardingTunnelRouteNames(in snapshot: RawNetworkSnapshot) -> Set<String> {
        Set(snapshot.routes.compactMap { route -> String? in
            guard let name = route.interfaceName, isTunnelName(name), isForwardingRoute(route) else { return nil }
            return name
        })
    }
    /// Tunnel names referenced by any route, resolver or the selected path.
    public static func referencedTunnelNames(in snapshot: RawNetworkSnapshot) -> Set<String> {
        var names = Set(snapshot.routes.compactMap { route -> String? in
            guard let name = route.interfaceName, isTunnelName(name) else { return nil }
            return name
        })
        names.formUnion(snapshot.resolvers.compactMap { resolver -> String? in
            guard let name = resolver.interfaceName, isTunnelName(name) else { return nil }
            return name
        })
        names.formUnion((snapshot.path?.selectedInterfaces ?? []).filter(isTunnelName))
        return names
    }
}
