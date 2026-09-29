import Foundation
import NetUnstickCore
import NetUnstickNetwork

public enum PrivilegedProtocol {
    /// Version 2 adds the grouped stale-tunnel-route removal; older helpers reject it.
    public static let version = 2
    public static let machService = "org.netunstick.NetUnstick.helper"
    public static let plistName = "org.netunstick.NetUnstick.helper.plist"
    /// Upper bound of one encoded request accepted by the helper listener.
    public static let maximumRequestBytes = 4096
}

/// One routing-table entry named by its masked network, prefix length and tunnel interface.
public struct PrivilegedRouteTarget: Codable, Sendable, Hashable {
    public let destination: String
    public let prefix: Int
    public let interface: String
    public init(destination: String, prefix: Int, interface: String) {
        self.destination = destination; self.prefix = prefix; self.interface = interface
    }
}

/// No executable, shell text, or argument array crosses this boundary.
public enum PrivilegedAction: Codable, Sendable, Equatable {
    case refreshResolverCache
    case renewDHCP(interface: String)
    case removeOrphanedRoute(destination: String, prefix: Int, interface: String)
    /// Every stale tunnel route shadowing the directly connected LAN, removed together.
    case removeStaleTunnelRoutes(routes: [PrivilegedRouteTarget])
    /// Read-only liveness check: launchd could start this daemon build and the versions agree.
    case handshake
}

public struct PrivilegedRequest: Codable, Sendable, Equatable {
    public let version: Int
    public let action: PrivilegedAction
    public init(version: Int = PrivilegedProtocol.version, action: PrivilegedAction) {
        self.version = version; self.action = action
    }
}

public enum PrivilegedCode: String, Codable, Sendable {
    case success, incompatibleVersion, invalidRequest, vpnActive, vpnUnknown
    case ambiguousResource, permissionDenied, timedOut, nonZeroExit
    case outputLimit, executionFailed, disconnected, approvalRequired, notRegistered, notFound
}

public struct PrivilegedReply: Codable, Sendable {
    public let code: PrivilegedCode
    public let result: OperationResult
    public init(code: PrivilegedCode, result: OperationResult) { self.code = code; self.result = result }
}

@objc public protocol NetUnstickHelperXPC {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}
