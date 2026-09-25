import Foundation
import Darwin
import Network
import NetUnstickCore

/// Closed reason codes. User-facing copy is kept beside each stable code.
public enum NetworkCheckReason: String, Sendable, CaseIterable {
    case healthy, dataIncomplete, environmentLimited, cancelled, timedOut
    case noPhysicalLink, noAddressLease, noGateway, noDefaultRoute, duplicateDefaultRoute, residualDefaultRoute
    case localRouteMissing, localRouteViaTunnel, resolverMissing, residualScopedDNS, resolverOrder, residualSearchDomain
    case dnsNXDomain, dnsTimeout, dnsServerUnavailable, dnsNoPath, dnsFailure
    case localPathUnavailable, internetUnavailable, internetReachable, activeProxy, activePAC
    case orphanedTunnel, routingConflict, expectedInterfaceMissing, unstableAfterDisconnect

    public var message: String {
        switch self {
        case .healthy: return "Nie wykryto problemu w tym sprawdzeniu."
        case .dataIncomplete: return "Brakuje danych, aby ocenić ten obszar."
        case .environmentLimited: return "Warunki sieciowe ograniczają to sprawdzenie."
        case .cancelled: return "Sprawdzenie zostało anulowane."
        case .timedOut: return "Sprawdzenie przekroczyło limit czasu."
        case .noPhysicalLink: return "Nie ma aktywnego fizycznego połączenia."
        case .noAddressLease: return "Interfejs nie ma użytecznej adresacji."
        case .noGateway: return "Nie znaleziono bramy na fizycznym połączeniu."
        case .noDefaultRoute: return "Nie znaleziono trasy domyślnej."
        case .duplicateDefaultRoute: return "Wykryto konkurujące trasy domyślne."
        case .residualDefaultRoute: return "Trasa domyślna wskazuje interfejs tunelowy."
        case .localRouteMissing: return "Nie można potwierdzić trasy do lokalnej podsieci."
        case .localRouteViaTunnel: return "Ruch do lokalnej podsieci może trafiać do tunelu."
        case .resolverMissing: return "Nie znaleziono dostępnego serwera DNS."
        case .residualScopedDNS: return "Resolver powiązany z tunelem może nadal działać."
        case .resolverOrder: return "Kolejność resolverów może kierować zapytania do tunelu."
        case .residualSearchDomain: return "Domena wyszukiwania może pochodzić z tunelu."
        case .dnsNXDomain: return "Serwer DNS zgłosił brak tej nazwy."
        case .dnsTimeout: return "Odpowiedź DNS nie nadeszła na czas."
        case .dnsServerUnavailable: return "Serwer DNS jest niedostępny."
        case .dnsNoPath: return "Brak ścieżki sieciowej do zapytania DNS."
        case .dnsFailure: return "Rozwiązanie nazwy nie powiodło się."
        case .localPathUnavailable: return "Lokalne połączenie nie jest dostępne."
        case .internetUnavailable: return "Nie potwierdzono ścieżki internetowej."
        case .internetReachable: return "Ścieżka internetowa jest dostępna."
        case .activeProxy: return "Aktywny proxy może wpływać na łączność po VPN."
        case .activePAC: return "Aktywna konfiguracja PAC może wpływać na łączność po VPN."
        case .orphanedTunnel: return "Pozostał interfejs tunelowy bez aktywnego połączenia."
        case .routingConflict: return "Trasy i interfejsy są niespójne."
        case .expectedInterfaceMissing: return "Brakuje interfejsu używanego przez trasę."
        case .unstableAfterDisconnect: return "Stan sieci nadal się zmienia po rozłączeniu."
        }
    }
}

public enum ProbeOutcome: Sendable { case reachable, nxdomain, timeout, serverUnavailable, noPath, failed }
public protocol NetworkConnectivityProbing: Sendable {
    func resolveFixedName() async -> ProbeOutcome
    func probeInternet() async -> ProbeOutcome
}

/// Controlled, read-only probes. Neither resolved addresses nor command output leave this type.
public struct SystemNetworkConnectivityProbe: NetworkConnectivityProbing {
    public init() {}
    public func resolveFixedName() async -> ProbeOutcome {
        await Task.detached(priority: .utility) {
            var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                                 ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo("example.com", nil, &hints, &result)
            if let result { freeaddrinfo(result) }
            switch status {
            case 0: return ProbeOutcome.reachable
            case EAI_NONAME: return .nxdomain
            case EAI_AGAIN: return .timeout
            case EAI_FAIL: return .serverUnavailable
            default: return .failed
            }
        }.value
    }
    public func probeInternet() async -> ProbeOutcome {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
            let gate = ProbeCompletion(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.reachable)
                case .failed: gate.finish(.noPath)
                case .cancelled: gate.finish(.failed)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "NetUnstick.InternetProbe"))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { gate.finish(.timeout) }
        }
    }
}

private final class ProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProbeOutcome, Never>?
    private let connection: NWConnection
    init(continuation: CheckedContinuation<ProbeOutcome, Never>, connection: NWConnection) {
        self.continuation = continuation; self.connection = connection
    }
    func finish(_ value: ProbeOutcome) {
        lock.lock(); let callback = continuation; continuation = nil; lock.unlock()
        guard let callback else { return }
        connection.cancel(); callback.resume(returning: value)
    }
}

public enum NetworkCheckKind: String, Sendable, CaseIterable {
    case physicalLink, defaultRoute, localSubnetRoute, resolverConfiguration
    case unicastDNSResolution, internetPath, proxyConfiguration, interfaceConsistency
    public var id: String {
        switch self {
        case .physicalLink: return "physical_link"
        case .defaultRoute: return "default_route"
        case .localSubnetRoute: return "local_subnet_route"
        case .resolverConfiguration: return "resolver_configuration"
        case .unicastDNSResolution: return "unicast_dns_resolution"
        case .internetPath: return "internet_path"
        case .proxyConfiguration: return "proxy_configuration"
        case .interfaceConsistency: return "interface_consistency"
        }
    }
    public var timeout: Duration {
        switch self {
        case .unicastDNSResolution, .internetPath: return .seconds(3)
        default: return .seconds(1)
        }
    }
}

public struct SnapshotDiagnosticCheck: DiagnosticCheck {
    public let kind: NetworkCheckKind
    public var id: String { kind.id }
    public var name: String { kind.id }
    private let snapshot: RawNetworkSnapshot
    private let probe: any NetworkConnectivityProbing
    private let limit: Duration
    public init(kind: NetworkCheckKind, snapshot: RawNetworkSnapshot,
                probe: any NetworkConnectivityProbing = SystemNetworkConnectivityProbe(), timeout: Duration? = nil) {
        self.kind = kind; self.snapshot = snapshot; self.probe = probe; self.limit = timeout ?? kind.timeout
    }
    public func run(context: OperationContext) async -> OperationResult {
        let start = context.clock.now()
        let reason: NetworkCheckReason
        if Task.isCancelled || (try? context.cancellation.checkCancellation()) == nil {
            reason = .cancelled
        } else {
            reason = await boundedDecision()
        }
        let finalReason = Task.isCancelled || (try? context.cancellation.checkCancellation()) == nil ? .cancelled : reason
        let outcome: OperationOutcome
        switch finalReason {
        case .healthy, .internetReachable: outcome = .success
        case .dataIncomplete, .environmentLimited, .internetUnavailable, .localRouteMissing: outcome = .skipped
        case .cancelled: outcome = .cancelled
        case .timedOut, .dnsTimeout: outcome = .timedOut
        default: outcome = .failure
        }
        let evidence = EvidenceSanitizer.sanitize([
            .checkStatus: .status(outcome == .success ? .passed : outcome == .failure ? .failed : .unknown),
            .errorCode: .errorCode(finalReason.rawValue),
            .count: .count(kind == .physicalLink ? Set(snapshot.interfaces.filter { $0.isUp && ($0.type == "wifi" || $0.type == "ethernet" || $0.type == "wired" || $0.type == "cellular") }.flatMap { $0.addresses.map { $0.contains(":") ? "ipv6" : "ipv4" } }).count : snapshot.interfaces.count)
        ])
        return try! OperationResult(operationID: id, name: name, kind: .diagnostic,
                                    startedAt: start, endedAt: max(start, context.clock.now()), outcome: outcome,
                                    after: evidence,
                                    error: outcome == .failure || outcome == .timedOut
                                        ? try? OperationError(domain: "network_diagnosis", code: finalReason.rawValue) : nil,
                                    nextStep: outcome == .success ? NextStep.reviewDetails.rawValue : NextStep.retryCheck.rawValue)
    }
    private func boundedDecision() async -> NetworkCheckReason {
        // The bounded race also handles probes that ignore task cancellation.
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkCheckReason.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task { continuation.yield(await decide()); continuation.finish() }
        let timer = Task {
            try? await Task.sleep(for: limit)
            continuation.yield(.timedOut); continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        let value = await withTaskCancellationHandler { await iterator.next() ?? .cancelled } onCancel: {
            continuation.yield(.cancelled); continuation.finish(); worker.cancel(); timer.cancel()
        }
        worker.cancel(); timer.cancel(); continuation.finish()
        return value
    }
    private func decide() async -> NetworkCheckReason {
        let s = snapshot
        guard s.endedAt >= s.startedAt else { return .dataIncomplete }
        let relevantErrors = s.errors.filter { error in
            switch kind {
            case .physicalLink, .interfaceConsistency: return error.code.contains("interface") || error.code.contains("path") || error.code.contains("collection")
            case .defaultRoute, .localSubnetRoute: return error.code.contains("route") || error.code.contains("collection")
            case .resolverConfiguration, .unicastDNSResolution: return error.code.contains("dns") || error.code.contains("path") || error.code.contains("collection")
            case .internetPath: return error.code.contains("path") || error.code.contains("collection")
            case .proxyConfiguration: return error.code.contains("proxy") || error.code.contains("collection")
            }
        }
        if relevantErrors.contains(where: { $0.code.contains("cancelled") }) { return .cancelled }
        if relevantErrors.contains(where: { $0.code.contains("timed_out") || $0.code.contains("timeout") }) { return .timedOut }
        if !relevantErrors.isEmpty { return .dataIncomplete }
        guard let path = s.path, !s.interfaces.isEmpty else { return .dataIncomplete }
        if path.status == "unsatisfied" { return .environmentLimited }
        let physical = s.interfaces.filter { $0.isUp && ($0.type == "wifi" || $0.type == "ethernet" || $0.type == "wired" || $0.type == "cellular") }
        let physicalNames = Set(physical.map(\.name))
        let tunnels = Set(s.interfaces.filter { Self.isTunnel($0.name) }.map(\.name))
        let activeTunnels = Set(s.interfaces.filter { $0.isUp && Self.isTunnel($0.name) }.map(\.name))
        switch kind {
        case .physicalLink:
            guard !physical.isEmpty else { return s.path?.status == "unsatisfied" ? .noPhysicalLink : .dataIncomplete }
            guard physical.contains(where: { $0.addresses.contains(where: Self.usableAddress) }) else { return .noAddressLease }
            return s.routes.contains(where: { $0.isDefault && $0.interfaceName.map(physicalNames.contains) == true && $0.gateway != nil }) || !(s.path?.gateways.isEmpty ?? true) ? .healthy : .noGateway
        case .defaultRoute:
            guard !s.routes.isEmpty else { return .dataIncomplete }
            let defaults = s.routes.filter(\.isDefault)
            guard !defaults.isEmpty else { return .noDefaultRoute }
            if defaults.contains(where: { $0.interfaceName.map(Self.isTunnel) == true && (s.path?.selectedInterfaces.contains($0.interfaceName ?? "") != true || !activeTunnels.contains($0.interfaceName ?? "")) }) { return .residualDefaultRoute }
            let families = Dictionary(grouping: defaults, by: { $0.destination.contains(":") ? "ipv6" : "ipv4" })
            return families.values.contains(where: { $0.count > 1 }) ? .duplicateDefaultRoute : .healthy
        case .localSubnetRoute:
            guard !physical.isEmpty else { return .dataIncomplete }
            let addresses = physical.flatMap(\.addresses)
            let candidates = s.routes.filter { route in !route.isDefault && addresses.contains(where: { Self.matches($0, route.destination) }) }
            guard !candidates.isEmpty else { return .localRouteMissing }
            let longest = candidates.map { Self.prefix($0.destination) }.max()!
            let best = candidates.filter { Self.prefix($0.destination) == longest }
            return best.allSatisfy { $0.interfaceName.map(physicalNames.contains) == true } ? .healthy : .localRouteViaTunnel
        case .resolverConfiguration:
            guard !s.resolvers.isEmpty else { return .resolverMissing }
            guard s.resolvers.contains(where: { !$0.nameservers.isEmpty }) else { return .resolverMissing }
            let tunnelResolvers = s.resolvers.filter { $0.interfaceName.map(Self.isTunnel) == true }
            if !tunnelResolvers.isEmpty {
                if tunnelResolvers.contains(where: { !activeTunnels.contains($0.interfaceName ?? "") }) { return .residualScopedDNS }
                if let first = s.resolvers.first, first.interfaceName.map(Self.isTunnel) == true,
                   s.resolvers.contains(where: { $0.interfaceName.map(physicalNames.contains) == true }) { return .resolverOrder }
                return .residualScopedDNS
            }
            if s.resolvers.contains(where: { !$0.searchDomains.isEmpty && $0.interfaceName == nil }) && !tunnels.isEmpty { return .residualSearchDomain }
            return .healthy
        case .unicastDNSResolution:
            guard let path = s.path else { return .dataIncomplete }
            guard path.status == "satisfied" else { return .dnsNoPath }
            guard s.resolvers.contains(where: { !$0.nameservers.isEmpty }) else { return .dnsServerUnavailable }
            switch await probe.resolveFixedName() {
            case .reachable: return .healthy
            case .nxdomain: return .dnsNXDomain
            case .timeout: return .dnsTimeout
            case .serverUnavailable: return .dnsServerUnavailable
            case .noPath: return .dnsNoPath
            case .failed: return .dnsFailure
            }
        case .internetPath:
            guard let path = s.path else { return .dataIncomplete }
            guard path.status == "satisfied", !physical.isEmpty else { return .localPathUnavailable }
            return await probe.probeInternet() == .reachable ? .internetReachable : .internetUnavailable
        case .proxyConfiguration:
            guard let settings = s.proxy?.settings else { return .dataIncomplete }
            if settings["ProxyAutoConfigEnable"] == "1" || settings["ProxyAutoDiscoveryEnable"] == "1" { return .activePAC }
            if ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "FTPEnable"].contains(where: { settings[$0] == "1" }) { return .activeProxy }
            return .healthy
        case .interfaceConsistency:
            if s.path?.transitionObserved == true { return .unstableAfterDisconnect }
            let all = Set(s.interfaces.map(\.name))
            if s.routes.contains(where: { $0.interfaceName.map { !all.contains($0) } == true }) { return .expectedInterfaceMissing }
            if s.routes.contains(where: { $0.interfaceName.map(Self.isTunnel) == true && !activeTunnels.contains($0.interfaceName ?? "") }) { return .routingConflict }
            let grouped = Dictionary(grouping: s.routes.filter { !$0.isDefault }, by: \.destination)
            if grouped.values.contains(where: { Set($0.compactMap(\.interfaceName)).count > 1 }) { return .routingConflict }
            if !tunnels.isEmpty && s.path?.selectedInterfaces.allSatisfy({ !Self.isTunnel($0) }) == true && !s.routes.contains(where: { $0.interfaceName.map(Self.isTunnel) == true }) { return .orphanedTunnel }
            return .healthy
        }
    }
    private static func isTunnel(_ name: String) -> Bool {
        let n = name.lowercased(); return n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp")
    }
    private static func usableAddress(_ address: String) -> Bool {
        !address.hasPrefix("169.254.") && !address.hasPrefix("fe80:") && address != "0.0.0.0" && address != "::"
    }
    private static func prefix(_ cidr: String) -> Int { Int(cidr.split(separator: "/").last ?? "") ?? (cidr.contains(":") ? 128 : 32) }
    private static func matches(_ address: String, _ destination: String) -> Bool {
        let parts = destination.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), bits >= 0 else { return false }
        if address.contains(":") || destination.contains(":") {
            guard bits <= 128 else { return false }
            var host = in6_addr(); var network = in6_addr()
            let hostText = String(address.split(separator: "%")[0])
            let networkText = String(parts[0].split(separator: "%")[0])
            guard inet_pton(AF_INET6, hostText, &host) == 1,
                  inet_pton(AF_INET6, networkText, &network) == 1 else { return false }
            let hostBytes = withUnsafeBytes(of: host) { Array($0.prefix(16)) }
            let networkBytes = withUnsafeBytes(of: network) { Array($0.prefix(16)) }
            for index in 0..<16 {
                let remaining = bits - index * 8
                let mask: UInt8 = remaining >= 8 ? 255 : remaining <= 0 ? 0 : UInt8(255 << (8 - remaining))
                if hostBytes[index] & mask != networkBytes[index] & mask { return false }
            }
            return true
        }
        guard bits <= 32 else { return false }
        var ip = in_addr(); var net = in_addr()
        let rawNetwork = String(parts[0])
        let pieces = rawNetwork.split(separator: ".")
        let padded = pieces.count >= 1 && pieces.count < 4 ? (pieces.map(String.init) + Array(repeating: "0", count: 4 - pieces.count)).joined(separator: ".") : rawNetwork
        guard inet_pton(AF_INET, address, &ip) == 1, inet_pton(AF_INET, padded, &net) == 1 else { return false }
        let mask: UInt32 = bits == 0 ? 0 : UInt32.max << (32 - bits)
        return (UInt32(bigEndian: ip.s_addr) & mask) == (UInt32(bigEndian: net.s_addr) & mask)
    }
}
