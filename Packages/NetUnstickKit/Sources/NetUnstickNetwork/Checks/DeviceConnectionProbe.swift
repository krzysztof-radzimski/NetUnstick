import Foundation
import Darwin
import Network
import NetUnstickCore

/// Closed outcome codes of a direct connection test to a device chosen by the user.
public enum DeviceConnectionReason: String, Sendable, CaseIterable {
    case reachable, refused, timedOut, unreachable, nameUnresolved, invalidInput, failed, cancelled

    public var message: String {
        switch self {
        case .reachable: return "Urządzenie przyjęło połączenie na tym porcie; sieć między komputerami działa, a usługa nasłuchuje."
        case .refused: return "Sieć między komputerami działa: urządzenie odpowiada, ale odrzuca połączenie na tym porcie, bo usługa jest wyłączona albo używa innego portu."
        case .timedOut: return "Brak odpowiedzi w wyznaczonym czasie; pakiety nie docierają albo odpowiedzi wracają inną drogą, np. przez tunel lub router bez zawracania ruchu."
        case .unreachable: return "Ten komputer nie ma drogi do żadnego adresu tego urządzenia albo urządzenie nie odpowiada na tym łączu."
        case .nameUnresolved: return "Nie udało się rozwiązać nazwy urządzenia."
        case .invalidInput: return "Podaj nazwę lub adres urządzenia oraz port z zakresu 1–65535."
        case .failed: return "Połączenie nie powiodło się z innego powodu."
        case .cancelled: return "Test został anulowany."
        }
    }

    /// Order used to pick one verdict from several attempts: a peer that answers outranks silence.
    static let priority: [DeviceConnectionReason] = [.reachable, .refused, .timedOut, .unreachable, .failed, .cancelled]
    static func best(_ reasons: [DeviceConnectionReason]) -> DeviceConnectionReason? {
        priority.first { reasons.contains($0) } ?? reasons.first
    }
}

public enum AddressFamily: String, Sendable, CaseIterable {
    case ipv4, ipv6
}

/// Outcome of one anonymous SMB session opened by this Mac's own SMB client (`smbutil view -N`).
/// Exit 0 lists shares, 77 (EX_NOPERM) means the session was negotiated and the guest login
/// rejected, 68 (EX_NOHOST) while the port answers means the client never got a session: the
/// server closed the connection right after the negotiate. Seen between a macOS 27.0 client and a
/// macOS 26.6 server; limiting the client to SMB 2 (`protocol_vers_map=2` in nsmb.conf) fixed it.
public enum SMBSessionOutcome: String, Sendable, CaseIterable {
    case sharesListed, authRejected, sessionFailed, timedOut, otherExit, unknown

    public static func classify(exitStatus: Int32) -> SMBSessionOutcome {
        switch exitStatus {
        case 0: return .sharesListed
        case 77: return .authRejected
        case 68: return .sessionFailed
        default: return .otherExit
        }
    }
}

public protocol SMBSessionProbing: Sendable {
    func probe(host: String) async -> SMBSessionOutcome
}

/// Runs the system SMB client once, anonymously, with a fixed path and argument list; only the
/// exit status is read, the share listing is discarded.
public struct SystemSMBSessionProbe: SMBSessionProbing {
    public static let executable = "/usr/bin/smbutil"
    public init() {}
    public func probe(host: String) async -> SMBSessionOutcome {
        guard DeviceConnectionInput.isValidHost(host) else { return .unknown }
        let target = "//" + host.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let output = try await BoundedProcess.run(executable: Self.executable, arguments: ["view", "-N", target],
                                                      timeout: 8, outputLimit: 65_536)
            return .classify(exitStatus: output.exitStatus)
        } catch ProcessRunError.nonZeroExit(let status) {
            return .classify(exitStatus: status)
        } catch ProcessRunError.timedOut {
            return .timedOut
        } catch {
            return .unknown
        }
    }
}

/// Ephemeral observation of one probe. The host and its addresses never leave the caller's memory.
public struct DeviceConnectionObservation: Sendable, Equatable {
    public let reason: DeviceConnectionReason
    public let interfaceType: InterfaceType?
    public let viaTunnel: Bool
    /// Verdict per address family; nil when the name resolved to no address of that family.
    public let ipv4: DeviceConnectionReason?
    public let ipv6: DeviceConnectionReason?
    /// Port 445 only: what this Mac's SMB client got once the port answered.
    public let smb: SMBSessionOutcome?
    /// Local filter state, read only when the SMB session failed.
    public let firewallEnabled: Bool?
    public let contentFilterActive: Bool?
    public init(reason: DeviceConnectionReason, interfaceType: InterfaceType? = nil, viaTunnel: Bool = false,
                ipv4: DeviceConnectionReason? = nil, ipv6: DeviceConnectionReason? = nil,
                smb: SMBSessionOutcome? = nil, firewallEnabled: Bool? = nil, contentFilterActive: Bool? = nil) {
        self.reason = reason; self.interfaceType = interfaceType; self.viaTunnel = viaTunnel
        self.ipv4 = ipv4; self.ipv6 = ipv6
        self.smb = smb; self.firewallEnabled = firewallEnabled; self.contentFilterActive = contentFilterActive
    }
}

public protocol DeviceConnectionProbing: Sendable {
    func probe(host: String, port: UInt16, timeout: Duration) async -> DeviceConnectionObservation
}

public enum DeviceConnectionInput {
    /// Host names, Bonjour names and literal addresses only; no spaces, quotes or shell characters.
    public static func isValidHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == ":" || scalar == "%" || scalar == "_"
        }
    }
    public static func port(from text: String) -> UInt16? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return UInt16(value)
    }
}

/// One resolved address; kept in memory only for the duration of the probe.
public struct ResolvedAddress: Sendable, Hashable {
    public let family: AddressFamily
    public let literal: String
    public init(family: AddressFamily, literal: String) { self.family = family; self.literal = literal }
}

/// Resolves a name with `getaddrinfo` (unicast DNS, /etc/hosts and Bonjour for `.local`) on a
/// detached thread, so a slow or absent answer cannot block the caller past the timeout.
public enum DeviceNameResolver {
    public static func resolve(_ host: String, timeout: TimeInterval) async -> [ResolvedAddress]? {
        await withCheckedContinuation { continuation in
            let gate = ResolveCompletion(continuation)
            Thread.detachNewThread { gate.finish(lookup(host)) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.05, timeout)) { gate.finish(nil) }
        }
    }

    /// Both families are requested on purpose: a peer that advertises an address family this
    /// Mac cannot use is exactly the mismatch the test has to expose.
    static func lookup(_ host: String) -> [ResolvedAddress]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(first) }
        var result: [ResolvedAddress] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            node = current.pointee.ai_next
            guard let address = current.pointee.ai_addr else { continue }
            let family: AddressFamily
            switch current.pointee.ai_family {
            case AF_INET: family = .ipv4
            case AF_INET6: family = .ipv6
            default: continue
            }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let entry = ResolvedAddress(family: family, literal: String(cString: buffer))
            if !result.contains(entry) { result.append(entry) }
        }
        return result
    }
}

private final class ResolveCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[ResolvedAddress]?, Never>?
    init(_ continuation: CheckedContinuation<[ResolvedAddress]?, Never>) { self.continuation = continuation }
    func finish(_ value: [ResolvedAddress]?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: value)
    }
}

struct AddressAttempt: Sendable {
    let family: AddressFamily
    let reason: DeviceConnectionReason
    let interfaceType: InterfaceType?
    let viaTunnel: Bool
}

/// Resolves the name itself and connects to every address separately through Network.framework.
/// A single connection to a host name would stop at the first address the framework treats as
/// unreachable, hiding that another family works; per-address attempts keep both verdicts.
/// No payload is sent and nothing is stored.
public struct SystemDeviceConnectionProbe: DeviceConnectionProbing {
    public static let maximumAddressesPerFamily = 4
    public static let resolutionTimeout: TimeInterval = 3
    public static let smbPort: UInt16 = 445
    private let smb: any SMBSessionProbing
    private let filters: any ContentFilterProbing
    public init(smb: any SMBSessionProbing = SystemSMBSessionProbe(),
                filters: any ContentFilterProbing = SystemContentFilterProbe()) {
        self.smb = smb; self.filters = filters
    }

    public func probe(host: String, port: UInt16, timeout: Duration) async -> DeviceConnectionObservation {
        guard DeviceConnectionInput.isValidHost(host), let nwPort = NWEndpoint.Port(rawValue: port) else {
            return .init(reason: .invalidInput)
        }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let total = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let started = Date()
        guard let addresses = await DeviceNameResolver.resolve(trimmed, timeout: min(total, Self.resolutionTimeout)),
              !addresses.isEmpty else {
            return .init(reason: .nameUnresolved)
        }
        if Task.isCancelled { return .init(reason: .cancelled) }
        let remaining = max(0.5, total - Date().timeIntervalSince(started))
        let selected = Self.select(addresses)
        let attempts = await withTaskGroup(of: AddressAttempt.self) { group in
            for address in selected {
                group.addTask { await Self.connect(address, port: nwPort, timeout: remaining) }
            }
            var collected: [AddressAttempt] = []
            for await attempt in group { collected.append(attempt) }
            return collected
        }
        let transport = Self.aggregate(attempts)
        // The port answering is not the same as an SMB session: a socket content filter on this Mac
        // can end the kernel client's session before its first byte. Ask the real client once.
        guard port == Self.smbPort, transport.reason == .reachable, !Task.isCancelled else { return transport }
        let session = await smb.probe(host: trimmed)
        var firewall: Bool?
        var filter: Bool?
        if session == .sessionFailed {
            let local = await filters.observe()
            firewall = local.firewallEnabled
            filter = local.filterActive
        }
        return .init(reason: transport.reason, interfaceType: transport.interfaceType, viaTunnel: transport.viaTunnel,
                     ipv4: transport.ipv4, ipv6: transport.ipv6, smb: session,
                     firewallEnabled: firewall, contentFilterActive: filter)
    }

    /// Keeps resolution order (system preference) and caps the attempts per family.
    static func select(_ addresses: [ResolvedAddress]) -> [ResolvedAddress] {
        var counts: [AddressFamily: Int] = [:]
        return addresses.filter { address in
            let seen = counts[address.family, default: 0]
            guard seen < maximumAddressesPerFamily else { return false }
            counts[address.family] = seen + 1
            return true
        }
    }

    /// One verdict per family, and the overall verdict from the best attempt of any family.
    static func aggregate(_ attempts: [AddressAttempt]) -> DeviceConnectionObservation {
        let ipv4 = DeviceConnectionReason.best(attempts.filter { $0.family == .ipv4 }.map(\.reason))
        let ipv6 = DeviceConnectionReason.best(attempts.filter { $0.family == .ipv6 }.map(\.reason))
        let overall = DeviceConnectionReason.best(attempts.map(\.reason)) ?? .failed
        let representative = attempts.first { $0.reason == overall }
        return .init(reason: overall, interfaceType: representative?.interfaceType,
                     viaTunnel: representative?.viaTunnel ?? false, ipv4: ipv4, ipv6: ipv6)
    }

    private static func connect(_ address: ResolvedAddress, port: NWEndpoint.Port, timeout: TimeInterval) async -> AddressAttempt {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(address.literal), port: port, using: .tcp)
            let gate = DeviceProbeCompletion(family: address.family, continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.reachable)
                case .failed(let error): gate.finish(classify(error))
                case .waiting(let error):
                    // With a literal address there is nothing else to try: a refusal, a missing
                    // route or a missing name is the final answer for this address.
                    let reason = classify(error)
                    if reason != .failed { gate.finish(reason) }
                case .cancelled: gate.finish(.cancelled)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "NetUnstick.DeviceProbe"))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.05, timeout)) { gate.finish(.timedOut) }
        }
    }

    static func classify(_ error: NWError) -> DeviceConnectionReason {
        switch error {
        case .dns: return .nameUnresolved
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .refused
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN, .EADDRNOTAVAIL: return .unreachable
            case .ETIMEDOUT: return .timedOut
            case .ECANCELED: return .cancelled
            default: return .failed
            }
        default: return .failed
        }
    }
}

private final class DeviceProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AddressAttempt, Never>?
    private let connection: NWConnection
    private let family: AddressFamily
    init(family: AddressFamily, continuation: CheckedContinuation<AddressAttempt, Never>, connection: NWConnection) {
        self.family = family; self.continuation = continuation; self.connection = connection
    }
    func finish(_ reason: DeviceConnectionReason) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        guard let pending else { return }
        let path = connection.currentPath
        let interfaceName = path?.availableInterfaces.first?.name
        let type: InterfaceType? = path.map { path in
            path.usesInterfaceType(.wifi) ? .wifi : path.usesInterfaceType(.wiredEthernet) ? .ethernet :
                path.usesInterfaceType(.cellular) ? .cellular : path.usesInterfaceType(.loopback) ? .loopback : .other
        }
        let viaTunnel = interfaceName.map(TunnelSignals.isTunnelName) ?? false
        connection.cancel()
        pending.resume(returning: .init(family: family, reason: reason, interfaceType: type, viaTunnel: viaTunnel))
    }
}

/// The read-only device test as a structured operation. The host and port are inputs only;
/// the result carries the outcome codes and interface type, never the address or name.
public struct DeviceConnectionCheck: DiagnosticCheck {
    public let id = "device_connection"
    public let name = "device_connection"
    private let host: String
    private let port: UInt16
    private let probe: any DeviceConnectionProbing
    private let timeout: Duration
    public init(host: String, port: UInt16, probe: any DeviceConnectionProbing = SystemDeviceConnectionProbe(),
                timeout: Duration = .seconds(5)) {
        self.host = host; self.port = port; self.probe = probe; self.timeout = timeout
    }
    public func run(context: OperationContext) async -> OperationResult {
        let start = context.clock.now()
        let observation: DeviceConnectionObservation
        if Task.isCancelled || (try? context.cancellation.checkCancellation()) == nil {
            observation = .init(reason: .cancelled)
        } else if !DeviceConnectionInput.isValidHost(host) {
            observation = .init(reason: .invalidInput)
        } else {
            observation = await probe.probe(host: host, port: port, timeout: timeout)
        }
        let sessionFailed = observation.smb == .sessionFailed
        let outcome: OperationOutcome
        switch observation.reason {
        case .reachable: outcome = sessionFailed ? .failure : .success
        case .cancelled: outcome = .cancelled
        case .timedOut: outcome = .timedOut
        case .invalidInput: outcome = .skipped
        default: outcome = .failure
        }
        var values: [EvidenceKey: EvidenceValue] = [
            .checkStatus: .status(outcome == .success ? .passed : outcome == .failure || outcome == .timedOut ? .failed : .unknown),
            .errorCode: .errorCode(observation.reason.rawValue),
            .networkStatus: .status(observation.viaTunnel ? .active : .inactive)
        ]
        if let type = observation.interfaceType { values[.interfaceType] = .interfaceType(type) }
        if let ipv4 = observation.ipv4 { values[.ipv4Result] = .errorCode(ipv4.rawValue) }
        if let ipv6 = observation.ipv6 { values[.ipv6Result] = .errorCode(ipv6.rawValue) }
        if let smb = observation.smb { values[.smbResult] = .errorCode(smb.rawValue) }
        if let firewall = observation.firewallEnabled { values[.firewallStatus] = .status(firewall ? .active : .inactive) }
        if let filter = observation.contentFilterActive { values[.contentFilterStatus] = .status(filter ? .active : .inactive) }
        let next: NextStep
        switch observation.reason {
        case .reachable:
            switch observation.smb {
            case .sessionFailed: next = .limitSMBToVersion2
            case .authRejected: next = .connectAsAccount
            case .timedOut, .otherExit: next = .retryCheck
            default: next = .reviewDetails
            }
        case .invalidInput, .cancelled: next = .retryCheck
        case .refused: next = .checkPermissions
        default: next = observation.viaTunnel ? .verifyVPN : .retryCheck
        }
        let errorCode = sessionFailed ? "smbSessionFailed" : observation.reason.rawValue
        return try! OperationResult(operationID: id, name: name, kind: .diagnostic, startedAt: start,
            endedAt: max(start, context.clock.now()), outcome: outcome, after: EvidenceSanitizer.sanitize(values),
            error: outcome == .failure || outcome == .timedOut ? try? OperationError(domain: "device_connection", code: errorCode) : nil,
            nextStep: next.rawValue)
    }
}
