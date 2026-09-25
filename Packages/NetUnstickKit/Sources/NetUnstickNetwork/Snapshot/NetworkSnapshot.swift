import Foundation
import Network
import CryptoKit
import NetUnstickCore

/// Ephemeral observations. Never persist, encode, or pass this object to Logger.
public struct RawNetworkSnapshot: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let startedAt: Date
    public let endedAt: Date
    public let path: RawPathState?
    public let interfaces: [RawInterface]
    public let routes: [RawRoute]
    public let resolvers: [RawResolver]
    public let proxy: RawProxy?
    public let dynamicStoreVPNKeys: [String]
    public let errors: [NetworkCollectionError]

    public init(startedAt: Date, endedAt: Date, path: RawPathState?, interfaces: [RawInterface],
                routes: [RawRoute], resolvers: [RawResolver], proxy: RawProxy?,
                dynamicStoreVPNKeys: [String], errors: [NetworkCollectionError]) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.path = path
        self.interfaces = interfaces
        self.routes = routes
        self.resolvers = resolvers
        self.proxy = proxy
        self.dynamicStoreVPNKeys = dynamicStoreVPNKeys
        self.errors = errors
    }

    public var description: String { "<RawNetworkSnapshot redacted>" }
    public var debugDescription: String { description }
}

public protocol NetworkStateCollecting: Sendable {
    func collect() async -> RawNetworkSnapshot
}

public struct RawPathState: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The live Network.framework path is retained only in the ephemeral raw object.
    public let nwPath: NWPath?
    public let status: String
    public let availableInterfaces: [String]
    public let selectedInterfaces: [String]
    public let supportsDNS: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let gateways: [String]
    public let transitionObserved: Bool

    public init(status: String, availableInterfaces: [String], selectedInterfaces: [String],
                supportsDNS: Bool, supportsIPv4: Bool, supportsIPv6: Bool,
                gateways: [String], transitionObserved: Bool = false, nwPath: NWPath? = nil) {
        self.status = status
        self.availableInterfaces = availableInterfaces
        self.selectedInterfaces = selectedInterfaces
        self.supportsDNS = supportsDNS
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.gateways = gateways
        self.transitionObserved = transitionObserved
        self.nwPath = nwPath
    }
    public var description: String { "<RawPathState redacted>" }
    public var debugDescription: String { description }
}

public struct RawInterface: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let name: String
    public let type: String
    public let isUp: Bool
    public let addresses: [String]
    public init(name: String, type: String, isUp: Bool, addresses: [String]) {
        self.name = name; self.type = type; self.isUp = isUp; self.addresses = addresses
    }
    public var description: String { "<RawInterface redacted>" }
    public var debugDescription: String { description }
}

public struct RawRoute: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let destination: String
    public let gateway: String?
    public let interfaceName: String?
    public let isDefault: Bool
    public let isLocal: Bool
    public init(destination: String, gateway: String?, interfaceName: String?, isDefault: Bool, isLocal: Bool = false) {
        self.destination = destination; self.gateway = gateway; self.interfaceName = interfaceName
        self.isDefault = isDefault; self.isLocal = isLocal
    }
    public var description: String { "<RawRoute redacted>" }
    public var debugDescription: String { description }
}

public struct RawResolver: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let domain: String?
    public let searchDomains: [String]
    public let nameservers: [String]
    public let interfaceName: String?
    public init(domain: String?, searchDomains: [String], nameservers: [String], interfaceName: String?) {
        self.domain = domain; self.searchDomains = searchDomains; self.nameservers = nameservers
        self.interfaceName = interfaceName
    }
    public var description: String { "<RawResolver redacted>" }
    public var debugDescription: String { description }
}

public struct RawProxy: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let settings: [String: String]
    public init(settings: [String: String]) { self.settings = settings }
    public var description: String { "<RawProxy redacted>" }
    public var debugDescription: String { description }
}

public struct NetworkCollectionError: Error, Sendable, CustomStringConvertible {
    public let code: String
    public init(code: String) { self.code = StableIdentifier.isValid(code) ? code : "invalid_error_code" }
    public var description: String { "<NetworkCollectionError \(code)>" }
}

/// The only snapshot form allowed to cross into a session, report, or OperationResult.
public struct SanitizedNetworkSnapshot: Codable, Sendable, Equatable {
    public let startedAt: Date
    public let endedAt: Date
    public let pathAvailable: Bool
    public let interfaceTypes: [InterfaceType]
    public let interfaceCorrelationIDs: [String]
    public let routeCount: Int
    public let resolverCount: Int
    public let proxyPresent: Bool
    public let errorCodes: [String]

    public init(raw: RawNetworkSnapshot, correlationSalt: UUID = UUID()) {
        startedAt = raw.startedAt
        endedAt = raw.endedAt
        pathAvailable = raw.path != nil
        interfaceTypes = raw.interfaces.map { Self.safeType($0.type) }
        let key = SymmetricKey(data: Data(correlationSalt.uuidString.utf8))
        interfaceCorrelationIDs = raw.interfaces.map { item in
            let digest = HMAC<SHA256>.authenticationCode(for: Data(item.name.utf8), using: key)
            return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        }
        routeCount = raw.routes.count
        resolverCount = raw.resolvers.count
        proxyPresent = raw.proxy != nil
        errorCodes = raw.errors.map(\.code)
    }

    public var evidence: SafeEvidence {
        EvidenceSanitizer.sanitize([
            .networkStatus: .status(pathAvailable ? .available : .unknown),
            .count: .count(interfaceTypes.count),
            .interfaceType: .interfaceType(interfaceTypes.first ?? .other),
            .errorCode: .errorCode(errorCodes.first ?? "none")
        ])
    }

    private static func safeType(_ raw: String) -> InterfaceType {
        switch raw.lowercased() {
        case "wifi", "wi-fi": return .wifi
        case "ethernet", "wired": return .ethernet
        case "cellular": return .cellular
        case "loopback": return .loopback
        default: return .other
        }
    }
}
