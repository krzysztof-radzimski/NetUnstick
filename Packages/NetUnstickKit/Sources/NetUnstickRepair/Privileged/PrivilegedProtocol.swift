import Foundation
import NetUnstickCore
import NetUnstickNetwork

public enum PrivilegedProtocol {
    public static let version = 1
    public static let machService = "org.netunstick.NetUnstick.helper"
    public static let plistName = "org.netunstick.NetUnstick.helper.plist"
}

/// No executable, shell text, or argument array crosses this boundary.
public enum PrivilegedAction: Codable, Sendable, Equatable {
    case refreshResolverCache
    case renewDHCP(interface: String)
    case removeOrphanedRoute(destination: String, prefix: Int, interface: String)
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
