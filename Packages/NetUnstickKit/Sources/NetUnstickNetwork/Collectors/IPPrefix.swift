import Foundation
import Darwin

/// A normalized IPv4 or IPv6 network prefix parsed from netstat, getifaddrs or policy text.
/// Accepts netstat's abbreviated IPv4 forms ("127", "192.168.1", "224.0.0/4"), host
/// addresses without a length, and IPv6 zone suffixes ("fe80::%utun0/64"). The stored
/// bytes are masked to the prefix length, so equality and containment ignore host bits.
public struct IPPrefix: Sendable, Hashable, Comparable {
    public enum Family: Int, Sendable, Hashable { case ipv4, ipv6 }
    public let family: Family
    public let bytes: [UInt8]
    public let prefix: Int

    public init?(_ text: String) {
        let components = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(components.count), !components[0].isEmpty else { return nil }
        let address = String(components[0].split(separator: "%", omittingEmptySubsequences: false)[0])
        guard !address.isEmpty else { return nil }
        var length: Int?
        if components.count == 2 {
            guard !components[1].isEmpty, components[1].allSatisfy(\.isNumber), let value = Int(components[1]) else { return nil }
            length = value
        }
        if address.contains(":") {
            var raw = in6_addr()
            guard address.withCString({ inet_pton(AF_INET6, $0, &raw) }) == 1 else { return nil }
            let bits = length ?? 128
            guard (0...128).contains(bits) else { return nil }
            let octets = withUnsafeBytes(of: raw) { Array($0.prefix(16)) }
            self.init(family: .ipv6, bytes: octets, prefix: bits)
        } else {
            let pieces = address.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(pieces.count),
                  pieces.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && UInt8($0) != nil })
            else { return nil }
            let bits = length ?? pieces.count * 8
            guard (0...32).contains(bits) else { return nil }
            let octets = pieces.compactMap { UInt8($0) } + Array(repeating: 0, count: 4 - pieces.count)
            self.init(family: .ipv4, bytes: octets, prefix: bits)
        }
    }

    /// A single host address as a /32 or /128 prefix. Abbreviated networks are rejected.
    public init?(address text: String) {
        guard !text.contains("/"), let value = IPPrefix(text),
              value.prefix == (value.family == .ipv4 ? 32 : 128) else { return nil }
        self = value
    }

    private init(family: Family, bytes: [UInt8], prefix: Int) {
        self.family = family
        self.prefix = prefix
        self.bytes = Self.mask(bytes, prefix: prefix)
    }

    private static func mask(_ bytes: [UInt8], prefix: Int) -> [UInt8] {
        bytes.enumerated().map { index, byte in
            let remaining = prefix - index * 8
            let mask: UInt8 = remaining >= 8 ? 0xff : remaining <= 0 ? 0 : UInt8((0xff << (8 - remaining)) & 0xff)
            return byte & mask
        }
    }

    public var isLinkLocal: Bool {
        switch family {
        case .ipv4: return prefix >= 16 && bytes[0] == 169 && bytes[1] == 254
        case .ipv6: return prefix >= 10 && bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        }
    }
    public var isMulticast: Bool {
        switch family {
        case .ipv4: return prefix >= 4 && (224...239).contains(bytes[0])
        case .ipv6: return prefix >= 8 && bytes[0] == 0xff
        }
    }
    public var isLoopback: Bool {
        switch family {
        case .ipv4: return prefix >= 8 && bytes[0] == 127
        case .ipv6: return prefix == 128 && bytes == Array(repeating: 0, count: 15) + [1]
        }
    }
    /// RFC 1918 and IPv4 link-local space: the only destinations a local-LAN repair may touch.
    public var isPrivateIPv4: Bool {
        guard family == .ipv4 else { return false }
        return (prefix >= 8 && bytes[0] == 10) ||
            (prefix >= 12 && bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (prefix >= 16 && bytes[0] == 192 && bytes[1] == 168) ||
            (prefix >= 16 && bytes[0] == 169 && bytes[1] == 254)
    }

    /// Masked network text: dotted quad for IPv4, compressed form for IPv6.
    public var text: String {
        switch family {
        case .ipv4:
            return bytes.map(String.init).joined(separator: ".")
        case .ipv6:
            var raw = in6_addr()
            withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: bytes) }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil else { return "" }
            return String(cString: buffer)
        }
    }
    public var cidr: String { "\(text)/\(prefix)" }

    /// True when `other` lies inside this network (same family, equal or longer prefix).
    public func contains(_ other: IPPrefix) -> Bool {
        guard family == other.family, prefix <= other.prefix else { return false }
        return Self.mask(other.bytes, prefix: prefix) == bytes
    }
    public func contains(address text: String) -> Bool {
        guard let host = IPPrefix(address: text) else { return false }
        return contains(host)
    }

    public static func < (lhs: IPPrefix, rhs: IPPrefix) -> Bool {
        if lhs.family != rhs.family { return lhs.family.rawValue < rhs.family.rawValue }
        if lhs.bytes != rhs.bytes { return lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
        return lhs.prefix < rhs.prefix
    }
}
