import Foundation
import Darwin
import NetUnstickNetwork

public enum RepairPolicyError: Error, Equatable {
    case incompatibleVersion, invalidRequest, vpnActive, vpnUnknown, ambiguousResource
}

public enum AuthorizedRepair: Equatable {
    case renewDHCP(String)
    case removeRoute(destination: String, prefix: Int, interface: String, gateway: String)
}

public enum RepairPolicy {
    public static func authorize(_ request: PrivilegedRequest, snapshot: RawNetworkSnapshot,
                                 dhcpInterfaces: Set<String>) throws -> AuthorizedRepair {
        guard request.version == PrivilegedProtocol.version else { throw RepairPolicyError.incompatibleVersion }
        // This single exception has its own stronger disconnected-VPN and local-link proof.
        // The ordinary VPN gate remains closed for every other network-changing action.
        if case .removeOrphanedRoute(let destination, let prefix, let name) = request.action,
           let stale = staleLocalTunnelRoute(in: snapshot),
           case .removeRoute(let expectedDestination, let expectedPrefix, let expectedName, _) = stale,
           expectedDestination == destination, expectedPrefix == prefix, expectedName == name {
            return stale
        }
        let vpn = VPNStateDetector().assess(snapshot).state
        guard vpn != .active else { throw RepairPolicyError.vpnActive }
        guard vpn == .inactive else { throw RepairPolicyError.vpnUnknown }
        switch request.action {
        case .refreshResolverCache: throw RepairPolicyError.invalidRequest
        case .renewDHCP(let name):
            guard validPhysicalName(name), dhcpInterfaces.contains(name),
                  snapshot.interfaces.filter({ $0.name == name && $0.isUp && ($0.type == "wifi" || $0.type == "ethernet") }).count == 1
            else { throw RepairPolicyError.ambiguousResource }
            return .renewDHCP(name)
        case .removeOrphanedRoute(let destination, let prefix, let name):
            guard validPhysicalName(name), validLocalNetwork(destination, prefix: prefix) else {
                throw RepairPolicyError.invalidRequest
            }
            let matches = snapshot.routes.filter { $0.destination == "\(destination)/\(prefix)" && $0.interfaceName == name && !$0.isDefault }
            guard matches.count == 1, snapshot.interfaces.filter({ $0.name == name && $0.isUp }).isEmpty,
                  let gateway = matches[0].gateway, validIPv4(gateway),
                  snapshot.routes.filter({ $0.destination == matches[0].destination }).count == 1
            else { throw RepairPolicyError.ambiguousResource }
            return .removeRoute(destination: destination, prefix: prefix, interface: name, gateway: gateway)
        }
    }

    /// An exact tunnel route may shadow the directly connected LAN after a VPN disconnect.
    /// Require a configured VPN service to report disconnected, a physical default path,
    /// and a unique more-specific tunnel route covering the physical host address.
    public static func staleLocalTunnelRoute(in snapshot: RawNetworkSnapshot) -> AuthorizedRepair? {
        guard snapshot.errors.isEmpty, snapshot.vpnServices == .disconnected,
              let path = snapshot.path, path.status == "satisfied", !path.transitionObserved,
              Set(path.selectedInterfaces).count == 1, let physicalName = path.selectedInterfaces.first,
              validPhysicalName(physicalName),
              snapshot.routes.contains(where: { $0.isDefault && $0.interfaceName == physicalName }) else { return nil }
        let physical = snapshot.interfaces.filter {
            $0.name == physicalName && $0.isUp && ["wifi", "ethernet", "wired"].contains($0.type.lowercased())
        }
        guard physical.count == 1 else { return nil }
        let localNetworks = snapshot.routes.compactMap { route -> IPv4Network? in
            guard route.interfaceName == physicalName, route.isLocal, !route.isDefault else { return nil }
            return IPv4Network(route.destination)
        }
        let candidates = snapshot.routes.compactMap { route -> AuthorizedRepair? in
            guard let tunnel = route.interfaceName, validTunnelName(tunnel),
                  !route.isDefault, !route.isLocal, !route.isScoped,
                  snapshot.interfaces.contains(where: { $0.name == tunnel && $0.isUp }),
                  !snapshot.dynamicStoreTunnelInterfaces.contains(tunnel),
                  !snapshot.resolvers.contains(where: { $0.interfaceName == tunnel }),
                  let gateway = route.gateway, validIPv4(gateway),
                  let network = IPv4Network(route.destination), (8...30).contains(network.prefix),
                  route.destination == "\(network.dotted)/\(network.prefix)",
                  validLocalNetwork(network.dotted, prefix: network.prefix),
                  localNetworks.contains(where: { $0.prefix < network.prefix && $0.contains(network) }),
                  physical[0].addresses.contains(where: { network.contains(address: $0) }),
                  snapshot.routes.filter({ $0.destination == route.destination }).count == 1
            else { return nil }
            return .removeRoute(destination: network.dotted, prefix: network.prefix,
                                interface: tunnel, gateway: gateway)
        }
        return candidates.count == 1 ? candidates[0] : nil
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
    private static func validLocalNetwork(_ text: String, prefix: Int) -> Bool {
        guard (8...30).contains(prefix), validIPv4(text) else { return false }
        let octets = text.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        let value = octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let mask = UInt32.max << (32 - prefix)
        guard value & ~mask == 0 else { return false }
        return (octets[0] == 10 && prefix >= 8) ||
            (octets[0] == 172 && (16...31).contains(octets[1]) && prefix >= 12) ||
            (octets[0] == 192 && octets[1] == 168 && prefix >= 16) ||
            (octets[0] == 169 && octets[1] == 254 && prefix >= 16)
    }
}

private struct IPv4Network {
    let address: UInt32
    let prefix: Int
    var mask: UInt32 { prefix == 0 ? 0 : UInt32.max << (32 - prefix) }
    var dotted: String {
        [24, 16, 8, 0].map { String((address >> $0) & 0xff) }.joined(separator: ".")
    }
    init?(_ text: String) {
        let components = text.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 2 else { return nil }
        let octets = components[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(octets.count),
              octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt8($0) != nil }),
              let bits = components.count == 2 ? Int(components[1]) : octets.count * 8,
              (0...32).contains(bits) else { return nil }
        let value = (octets.compactMap { UInt8($0) } + Array(repeating: 0, count: 4 - octets.count))
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let netmask = bits == 0 ? UInt32(0) : UInt32.max << (32 - bits)
        guard value & ~netmask == 0 else { return nil }
        self.address = value
        self.prefix = bits
    }
    func contains(_ other: IPv4Network) -> Bool {
        prefix <= other.prefix && other.address & mask == address
    }
    func contains(address text: String) -> Bool {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        let value = octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return value & mask == address
    }
}
