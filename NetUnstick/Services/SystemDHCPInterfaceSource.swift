import Foundation
import SystemConfiguration

/// Reads service metadata only; no DHCP packet, lease, address or device name is logged.
enum SystemDHCPInterfaceSource {
    static func detect() -> Set<String> {
        guard let store = SCDynamicStoreCreate(nil, "NetUnstick.DHCPReadOnly" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "Setup:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else { return [] }
        var interfaces: Set<String> = []
        for key in keys {
            guard let ipv4 = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  ipv4["ConfigMethod"] as? String == "DHCP",
                  key.hasSuffix("/IPv4") else { continue }
            let interfaceKey = String(key.dropLast("/IPv4".count)) + "/Interface"
            guard let config = SCDynamicStoreCopyValue(store, interfaceKey as CFString) as? [String: Any],
                  let name = config["DeviceName"] as? String,
                  name.range(of: #"^en[0-9]{1,2}$"#, options: .regularExpression) != nil else { continue }
            interfaces.insert(name)
        }
        return interfaces
    }
}
