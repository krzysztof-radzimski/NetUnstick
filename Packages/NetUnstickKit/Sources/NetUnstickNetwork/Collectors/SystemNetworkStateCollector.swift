import Foundation
import Network
import SystemConfiguration
import Darwin

/// Read-only collection. Raw values never leave the returned ephemeral snapshot.
public struct SystemNetworkStateCollector: NetworkStateCollecting {
    private let process: any ProcessRunning
    private let pathTimeout: TimeInterval
    private let pathTransitions: PathTransitionTracker

    public init(process: any ProcessRunning = SystemProcessRunner(), pathTimeout: TimeInterval = 2) {
        self.process = process
        self.pathTimeout = min(max(pathTimeout, 0.1), 10)
        self.pathTransitions = PathTransitionTracker()
    }

    public func collect() async -> RawNetworkSnapshot {
        let startedAt = Date()
        var errors: [NetworkCollectionError] = []
        var path: RawPathState?
        var interfaces: [RawInterface] = []
        var routes: [RawRoute] = []
        var resolvers: [RawResolver] = []
        var proxy: RawProxy?
        var vpnKeys: [String] = []

        do {
            try Task.checkCancellation()
            path = pathTransitions.observe(try await PathSnapshotReader.read(timeout: pathTimeout))
        } catch {
            errors.append(NetworkCollectionError(code: error is CancellationError ? "network_path_cancelled" : "network_path_timed_out"))
        }

        if !Task.isCancelled {
            let result = Self.readInterfaces()
            interfaces = result.items.map { item in
                let nwType = path?.nwPath?.availableInterfaces.first { $0.name == item.name }?.type
                return RawInterface(name: item.name, type: Self.mediaType(nwType) ?? item.type,
                                    isUp: item.isUp, addresses: item.addresses)
            }
            if let code = result.errorCode { errors.append(NetworkCollectionError(code: code)) }
        }

        if !Task.isCancelled {
            let result = Self.readDynamicStore()
            resolvers = result.resolvers
            proxy = result.proxy
            vpnKeys = result.vpnKeys
            errors += result.errorCodes.map(NetworkCollectionError.init(code:))
        }

        if !Task.isCancelled {
            do {
                let output = try await process.run(.scutilDNS)
                let scoped = ScutilDNSParser.parse(output.stdout)
                if scoped.isEmpty && resolvers.isEmpty {
                    errors.append(NetworkCollectionError(code: "network_dns_parse_failed"))
                }
                // DynamicStore exposes service DNS; scutil also exposes scoped and supplemental resolvers.
                resolvers += scoped
            } catch let error as ProcessRunError {
                errors.append(NetworkCollectionError(code: Self.commandErrorCode("network_dns", error)))
            } catch {
                errors.append(NetworkCollectionError(code: "network_dns_read_failed"))
            }
        }

        for command in [ReadOnlyNetworkCommand.netstatIPv4, .netstatIPv6] {
            guard !Task.isCancelled else { break }
            do {
                let output = try await process.run(command)
                let parsed = NetstatRouteParser.parse(output.stdout,
                                                       family: command == .netstatIPv4 ? "ipv4" : "ipv6")
                if parsed.isEmpty { errors.append(NetworkCollectionError(code: "network_routes_parse_failed")) }
                routes += parsed
            } catch let error as ProcessRunError {
                errors.append(NetworkCollectionError(code: Self.commandErrorCode("network_routes", error)))
            } catch {
                errors.append(NetworkCollectionError(code: "network_routes_read_failed"))
            }
        }

        if Task.isCancelled { errors.append(NetworkCollectionError(code: "network_collection_cancelled")) }
        return RawNetworkSnapshot(startedAt: startedAt, endedAt: Date(), path: path,
                                  interfaces: interfaces, routes: routes, resolvers: resolvers,
                                  proxy: proxy, dynamicStoreVPNKeys: vpnKeys, errors: errors)
    }

    private static func commandErrorCode(_ prefix: String, _ error: ProcessRunError) -> String {
        switch error {
        case .timedOut: return "\(prefix)_timed_out"
        case .cancelled: return "\(prefix)_cancelled"
        case .permissionDenied: return "\(prefix)_permission_denied"
        case .outputTooLarge: return "\(prefix)_output_too_large"
        case .nonZeroExit: return "\(prefix)_nonzero_exit"
        case .launchFailed: return "\(prefix)_launch_failed"
        case .invalidEncoding: return "\(prefix)_invalid_encoding"
        }
    }

    private static func readInterfaces() -> (items: [RawInterface], errorCode: String?) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return ([], "network_interfaces_read_failed")
        }
        defer { freeifaddrs(first) }
        var rows: [String: (type: String, isUp: Bool, addresses: [String])] = [:]
        var addressReadFailed = false
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = current {
            let entry = pointer.pointee
            current = entry.ifa_next
            let name = String(cString: entry.ifa_name)
            guard !name.isEmpty else { continue }
            let isUp = (entry.ifa_flags & UInt32(IFF_UP)) != 0
            var row = rows[name] ?? (type: interfaceType(name), isUp: false, addresses: [])
            row.isUp = row.isUp || isUp
            if let address = entry.ifa_addr, [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length: socklen_t = address.pointee.sa_family == UInt8(AF_INET)
                    ? socklen_t(MemoryLayout<sockaddr_in>.size)
                    : socklen_t(MemoryLayout<sockaddr_in6>.size)
                if getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    row.addresses.append(String(cString: buffer))
                } else {
                    addressReadFailed = true
                }
            }
            rows[name] = row
        }
        return (rows.keys.sorted().map { name in
            RawInterface(name: name, type: rows[name]!.type, isUp: rows[name]!.isUp,
                         addresses: rows[name]!.addresses)
        }, addressReadFailed ? "network_interface_address_read_failed" : nil)
    }

    private static func interfaceType(_ name: String) -> String {
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return "tunnel" }
        if name.hasPrefix("lo") { return "loopback" }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return "wifi" }
        if name.hasPrefix("en") { return "other" } // A macOS en interface can be Wi-Fi or wired.
        return "other"
    }

    private static func mediaType(_ type: NWInterface.InterfaceType?) -> String? {
        guard let type else { return nil }
        switch type {
        case .wifi: return "wifi"
        case .wiredEthernet: return "ethernet"
        case .cellular: return "cellular"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "other"
        }
    }

    private struct DynamicStoreRead {
        var resolvers: [RawResolver] = []
        var proxy: RawProxy?
        var vpnKeys: [String] = []
        var errorCodes: [String] = []
    }

    private static func readDynamicStore() -> DynamicStoreRead {
        var result = DynamicStoreRead()
        guard let store = SCDynamicStoreCreate(nil, "NetUnstick.NetworkState" as CFString, nil, nil) else {
            result.errorCodes.append("network_dynamic_store_unavailable")
            return result
        }

        if let keys = SCDynamicStoreCopyKeyList(store, #"State:/Network/(Global|Service/.+)/(DNS|IPv4|IPv6|PPP|IPSec|VPN)"# as CFString) as? [String] {
            for key in keys.sorted() {
                guard let dictionary = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else {
                    result.errorCodes.append("network_dynamic_store_value_unavailable")
                    continue
                }
                if key.hasSuffix("/DNS") {
                    result.resolvers.append(RawResolver(
                        domain: dictionary["DomainName"] as? String,
                        searchDomains: dictionary["SearchDomains"] as? [String] ?? [],
                        nameservers: dictionary["ServerAddresses"] as? [String] ?? [],
                        interfaceName: dictionary["InterfaceName"] as? String))
                }
                let interfaceName = dictionary["InterfaceName"] as? String ?? ""
                if key.hasSuffix("/PPP") || key.hasSuffix("/IPSec") || key.hasSuffix("/VPN") ||
                    interfaceName.hasPrefix("utun") || interfaceName.hasPrefix("ipsec") || interfaceName.hasPrefix("ppp") {
                    result.vpnKeys.append(key)
                }
            }
        } else {
            result.errorCodes.append("network_dynamic_store_keys_unavailable")
        }

        if let settings = SCDynamicStoreCopyProxies(store) as? [String: Any] {
            // Password keys and arbitrary values are deliberately excluded even from raw memory.
            let allowed = ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
                           "FTPEnable", "FTPProxy", "FTPPort", "SOCKSEnable", "SOCKSProxy", "SOCKSPort",
                           "ProxyAutoConfigEnable", "ProxyAutoConfigURLString", "ProxyAutoDiscoveryEnable",
                           "ExceptionsList", "ExcludeSimpleHostnames"]
            var captured: [String: String] = [:]
            for key in allowed {
                if let value = settings[key] as? String { captured[key] = value }
                else if let value = settings[key] as? NSNumber { captured[key] = value.stringValue }
                else if let values = settings[key] as? [String] { captured[key] = values.joined(separator: ",") }
            }
            result.proxy = RawProxy(settings: captured)
        } else {
            result.errorCodes.append("network_proxy_read_failed")
        }
        return result
    }
}

private final class PathSnapshotReader: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RawPathState, Error>?
    private let monitor = NWPathMonitor()
    private var completed = false

    static func read(timeout: TimeInterval) async throws -> RawPathState {
        let reader = PathSnapshotReader()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.lock.lock()
                reader.continuation = continuation
                reader.lock.unlock()
                if Task.isCancelled {
                    reader.finish(.failure(CancellationError()))
                    return
                }
                reader.monitor.pathUpdateHandler = { path in
                    reader.finish(.success(RawPathState(
                        status: String(describing: path.status),
                        availableInterfaces: path.availableInterfaces.map(\.name),
                        selectedInterfaces: path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name),
                        supportsDNS: path.supportsDNS, supportsIPv4: path.supportsIPv4,
                        supportsIPv6: path.supportsIPv6,
                        gateways: path.gateways.map { String(describing: $0) }, nwPath: path)))
                }
                reader.monitor.start(queue: DispatchQueue(label: "NetUnstick.NetworkPath"))
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    reader.finish(.failure(PathReadError.timeout))
                }
            }
        } onCancel: {
            reader.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<RawPathState, Error>) {
        lock.lock()
        guard !completed, let continuation else { lock.unlock(); return }
        completed = true
        self.continuation = nil
        lock.unlock()
        monitor.cancel()
        continuation.resume(with: result)
    }
}

private enum PathReadError: Error { case timeout }

final class PathTransitionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: String?

    func observe(_ path: RawPathState) -> RawPathState {
        let signature = ([path.status] + path.selectedInterfaces.sorted() + path.gateways.sorted()).joined(separator: "\u{0}")
        lock.lock()
        let transitioned = previous.map { $0 != signature } ?? false
        previous = signature
        lock.unlock()
        return RawPathState(status: path.status, availableInterfaces: path.availableInterfaces,
                            selectedInterfaces: path.selectedInterfaces, supportsDNS: path.supportsDNS,
                            supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6,
                            gateways: path.gateways, transitionObserved: transitioned, nwPath: path.nwPath)
    }
}
