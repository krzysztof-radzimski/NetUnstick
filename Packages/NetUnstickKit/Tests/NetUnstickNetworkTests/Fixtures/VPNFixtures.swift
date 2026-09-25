import Foundation
import NetUnstickNetwork

enum VPNFixtures {
    enum Scenario {
        case noVPN, activeTunnel, residualTunnel, scopedDNS, splitTunnel, fullTunnel
        case conflicting, timeout, permissionDenied, pathTransition
    }

    static func snapshot(_ scenario: Scenario) -> RawNetworkSnapshot {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let wifi = RawInterface(name: "en0", type: "wifi", isUp: true, addresses: ["192.0.2.10"])
        let tunnel = RawInterface(name: "utun5", type: "other", isUp: true, addresses: ["10.12.1.2"])
        let downTunnel = RawInterface(name: "utun5", type: "other", isUp: false, addresses: [])
        let wifiRoute = RawRoute(destination: "default", gateway: "192.0.2.1", interfaceName: "en0", isDefault: true)
        let splitRoute = RawRoute(destination: "10.0.0.0/8", gateway: nil, interfaceName: "utun5", isDefault: false)
        let fullRoute = RawRoute(destination: "default", gateway: nil, interfaceName: "utun5", isDefault: true)
        let wifiDNS = RawResolver(domain: nil, searchDomains: [], nameservers: ["192.0.2.53"], interfaceName: "en0")
        let tunnelDNS = RawResolver(domain: "private.example", searchDomains: ["private.example"],
                                    nameservers: ["10.0.0.53"], interfaceName: "utun5")
        var path = RawPathState(status: "satisfied", availableInterfaces: ["en0"],
                                selectedInterfaces: ["en0"], supportsDNS: true,
                                supportsIPv4: true, supportsIPv6: true, gateways: ["192.0.2.1"])
        var interfaces = [wifi]
        var routes = [wifiRoute]
        var resolvers = [wifiDNS]
        var errors: [NetworkCollectionError] = []
        var keys: [String] = []

        switch scenario {
        case .noVPN: break
        case .activeTunnel:
            interfaces.append(tunnel); routes.append(splitRoute)
        case .residualTunnel:
            interfaces.append(downTunnel)
        case .scopedDNS:
            interfaces.append(tunnel); resolvers.append(tunnelDNS)
        case .splitTunnel:
            interfaces.append(tunnel); routes.append(splitRoute); resolvers.append(tunnelDNS)
            keys = ["State:/Network/Service/vpn/PPP"]
        case .fullTunnel:
            interfaces.append(tunnel); routes = [fullRoute]; resolvers.append(tunnelDNS)
            path = RawPathState(status: "satisfied", availableInterfaces: ["en0", "utun5"],
                                selectedInterfaces: ["utun5"], supportsDNS: true,
                                supportsIPv4: true, supportsIPv6: true, gateways: [])
        case .conflicting:
            routes.append(splitRoute)
        case .timeout:
            errors = [.init(code: "routes_timeout")]
        case .permissionDenied:
            errors = [.init(code: "dns_permission_denied")]
        case .pathTransition:
            path = RawPathState(status: "satisfied", availableInterfaces: ["en0"],
                                selectedInterfaces: ["en0"], supportsDNS: true,
                                supportsIPv4: true, supportsIPv6: true, gateways: [],
                                transitionObserved: true)
        }
        return RawNetworkSnapshot(startedAt: start, endedAt: start.addingTimeInterval(0.1),
                                  path: path, interfaces: interfaces, routes: routes,
                                  resolvers: resolvers, proxy: nil, dynamicStoreVPNKeys: keys,
                                  errors: errors)
    }
}
