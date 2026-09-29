import Foundation
import Darwin
import Network
import NetUnstickCore

/// Closed outcome codes of a direct connection test to a device chosen by the user.
public enum DeviceConnectionReason: String, Sendable, CaseIterable {
    case reachable, refused, timedOut, unreachable, nameUnresolved, invalidInput, failed, cancelled

    public var message: String {
        switch self {
        case .reachable: return "Urządzenie przyjęło połączenie na tym porcie."
        case .refused: return "Urządzenie odpowiada, ale odrzuca połączenie na tym porcie; usługa jest wyłączona albo port jest inny."
        case .timedOut: return "Brak odpowiedzi w wyznaczonym czasie; pakiety nie docierają albo odpowiedzi wracają inną drogą."
        case .unreachable: return "System nie ma trasy do tego urządzenia albo urządzenie jest niedostępne."
        case .nameUnresolved: return "Nie udało się rozwiązać nazwy urządzenia."
        case .invalidInput: return "Podaj nazwę lub adres urządzenia oraz port z zakresu 1–65535."
        case .failed: return "Połączenie nie powiodło się z innego powodu."
        case .cancelled: return "Test został anulowany."
        }
    }
}

/// Ephemeral observation of one probe. The host never leaves the caller's memory.
public struct DeviceConnectionObservation: Sendable, Equatable {
    public let reason: DeviceConnectionReason
    public let interfaceType: InterfaceType?
    public let viaTunnel: Bool
    public init(reason: DeviceConnectionReason, interfaceType: InterfaceType? = nil, viaTunnel: Bool = false) {
        self.reason = reason; self.interfaceType = interfaceType; self.viaTunnel = viaTunnel
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

/// A bounded TCP connect through Network.framework. No payload is sent and nothing is stored.
public struct SystemDeviceConnectionProbe: DeviceConnectionProbing {
    public init() {}
    public func probe(host: String, port: UInt16, timeout: Duration) async -> DeviceConnectionObservation {
        guard DeviceConnectionInput.isValidHost(host), let nwPort = NWEndpoint.Port(rawValue: port) else {
            return .init(reason: .invalidInput)
        }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(trimmed), port: nwPort, using: .tcp)
            let gate = DeviceProbeCompletion(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.reachable)
                case .failed(let error): gate.finish(Self.classify(error))
                case .waiting(let error):
                    // Network.framework keeps waiting after a refusal, a missing name or a missing route
                    // in case a better path appears; for a one-shot test these answers are final.
                    let reason = Self.classify(error)
                    if reason != .failed { gate.finish(reason) }
                case .cancelled: gate.finish(.cancelled)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "NetUnstick.DeviceProbe"))
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.05, seconds)) { gate.finish(.timedOut) }
        }
    }

    private static func classify(_ error: NWError) -> DeviceConnectionReason {
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
    private var continuation: CheckedContinuation<DeviceConnectionObservation, Never>?
    private let connection: NWConnection
    init(continuation: CheckedContinuation<DeviceConnectionObservation, Never>, connection: NWConnection) {
        self.continuation = continuation; self.connection = connection
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
        pending.resume(returning: .init(reason: reason, interfaceType: type, viaTunnel: viaTunnel))
    }
}

/// The read-only device test as a structured operation. The host and port are inputs only;
/// the result carries the outcome code and interface type, never the address or name.
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
        let outcome: OperationOutcome
        switch observation.reason {
        case .reachable: outcome = .success
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
        let next: NextStep
        switch observation.reason {
        case .reachable: next = .reviewDetails
        case .invalidInput, .cancelled: next = .retryCheck
        case .refused: next = .checkPermissions
        default: next = observation.viaTunnel ? .verifyVPN : .retryCheck
        }
        return try! OperationResult(operationID: id, name: name, kind: .diagnostic, startedAt: start,
            endedAt: max(start, context.clock.now()), outcome: outcome, after: EvidenceSanitizer.sanitize(values),
            error: outcome == .failure || outcome == .timedOut ? try? OperationError(domain: "device_connection", code: observation.reason.rawValue) : nil,
            nextStep: next.rawValue)
    }
}
