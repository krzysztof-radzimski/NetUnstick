import Foundation
import Darwin
import NetUnstickNetwork

public enum RepairPolicyError: Error, Equatable {
    case incompatibleVersion, invalidRequest, vpnActive, vpnUnknown, ambiguousResource
}

public enum AuthorizedRepair: Equatable {
    case refreshResolverCache
    case renewDHCP(String)
    case removeRoute(destination: String, prefix: Int, interface: String, gateway: String)
}

public enum RepairPolicy {
    public static func authorize(_ request: PrivilegedRequest, snapshot: RawNetworkSnapshot,
                                 dhcpInterfaces: Set<String>) throws -> AuthorizedRepair {
        guard request.version == PrivilegedProtocol.version else { throw RepairPolicyError.incompatibleVersion }
        let vpn = VPNStateDetector().assess(snapshot).state
        guard vpn != .active else { throw RepairPolicyError.vpnActive }
        guard vpn == .inactive else { throw RepairPolicyError.vpnUnknown }
        switch request.action {
        case .refreshResolverCache: return .refreshResolverCache
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

    private static func validPhysicalName(_ name: String) -> Bool {
        name.range(of: #"^en[0-9]{1,2}$"#, options: .regularExpression) != nil
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
