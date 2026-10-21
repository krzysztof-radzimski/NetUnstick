#if APP_STORE
import Foundation
import Darwin
import Network
import NetUnstickCore
import NetUnstickStoreNetwork

enum StoreCheck: String, CaseIterable, Sendable {
    case path = "physical_link"
    case dns = "unicast_dns_resolution"
    case internet = "internet_path"
}

protocol StoreNetworkProbing: Sendable {
    func run(_ check: StoreCheck) async -> OperationResult
    func device(host: String, port: UInt16) async -> OperationResult
}

/// Public system APIs only. The DNS result, endpoint and user input never enter evidence or logs.
struct StoreNetworkProbe: StoreNetworkProbing {
    func run(_ check: StoreCheck) async -> OperationResult {
        let started = Date()
        if Task.isCancelled { return Self.result(id: check.rawValue, started: started, outcome: .cancelled, reason: "cancelled") }
        switch check {
        case .path:
            let signal = await path()
            return Self.result(id: check.rawValue, started: started, outcome: signal.outcome,
                reason: signal == .reachable ? NetworkCheckReason.healthy.rawValue :
                    signal == .cancelled ? "cancelled" : signal == .timedOut ? "timedOut" : "noPhysicalLink")
        case .dns:
            let signal = await resolveFixedName()
            return Self.result(id: check.rawValue, started: started, outcome: signal.outcome,
                reason: signal == .reachable ? "healthy" : signal == .nameUnresolved ? "dnsNXDomain" :
                    signal == .timedOut ? "dnsTimeout" : signal == .cancelled ? "cancelled" : "dnsFailure")
        case .internet:
            let signal = await connect(host: "1.1.1.1", port: 443, seconds: 3)
            return Self.result(id: check.rawValue, started: started,
                outcome: signal == .reachable ? .success : signal == .cancelled ? .cancelled : .skipped,
                reason: signal == .reachable ? "internetReachable" : signal == .cancelled ? "cancelled" : "internetUnavailable")
        }
    }

    func device(host: String, port: UInt16) async -> OperationResult {
        let started = Date()
        guard DeviceConnectionInput.isValidHost(host), port > 0 else {
            return Self.result(id: "device_connection", started: started, outcome: .skipped, reason: "invalidInput")
        }
        let signal = await connect(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port, seconds: 5)
        return Self.result(id: "device_connection", started: started, outcome: signal.outcome,
            reason: signal.rawValue)
    }

    static func result(id: String, started: Date, outcome: OperationOutcome, reason: String, count: Int? = nil) -> OperationResult {
        var evidence: [EvidenceKey: EvidenceValue] = [
            .checkStatus: .status(outcome == .success ? .passed : outcome == .skipped || outcome == .cancelled ? .unknown : .failed),
            .errorCode: .errorCode(reason)
        ]
        if let count { evidence[.count] = .count(count) }
        let needsError = [.failure, .timedOut, .permissionDenied].contains(outcome)
        return try! OperationResult(operationID: id, name: id, kind: .diagnostic,
            startedAt: started, endedAt: max(started, Date()), outcome: outcome,
            after: EvidenceSanitizer.sanitize(evidence),
            error: needsError ? try? OperationError(domain: "store_network", code: reason) : nil,
            nextStep: outcome == .success ? NextStep.reviewDetails.rawValue :
                outcome == .permissionDenied ? NextStep.checkPermissions.rawValue : NextStep.retryCheck.rawValue)
    }

    private func path() async -> StoreSignal {
        let monitor = NWPathMonitor()
        let gate = StoreProbeGate<StoreSignal>(cancelled: .cancelled, cleanup: { monitor.cancel() })
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard gate.install(continuation) else { return }
                monitor.pathUpdateHandler = { gate.finish($0.status == .satisfied ? .reachable : .unreachable) }
                monitor.start(queue: DispatchQueue(label: "NetUnstick.Store.Path"))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { gate.finish(.timedOut) }
            }
        } onCancel: { gate.cancel() }
    }

    private func resolveFixedName() async -> StoreSignal {
        let gate = StoreProbeGate<StoreSignal>(cancelled: .cancelled)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard gate.install(continuation) else { return }
                // getaddrinfo is a public resolver API. A late resolver reply is discarded by the
                // one-shot gate; it cannot prolong the operation or disclose its addresses.
                DispatchQueue.global(qos: .utility).async {
                    var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC,
                        ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0,
                        ai_canonname: nil, ai_addr: nil, ai_next: nil)
                    var addresses: UnsafeMutablePointer<addrinfo>?
                    let code = getaddrinfo("example.com", nil, &hints, &addresses)
                    if let addresses { freeaddrinfo(addresses) }
                    gate.finish(code == 0 ? .reachable : code == EAI_NONAME ? .nameUnresolved : .failed)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { gate.finish(.timedOut) }
            }
        } onCancel: { gate.cancel() }
    }

    private func connect(host: String, port: UInt16, seconds: TimeInterval) async -> StoreSignal {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return .failed }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let gate = StoreProbeGate<StoreSignal>(cancelled: .cancelled, cleanup: { connection.cancel() })
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard gate.install(continuation) else { return }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.finish(.reachable)
                    case .failed(let error): gate.finish(Self.classify(error))
                    case .waiting(let error):
                        if case .dns = error { gate.finish(Self.classify(error)) }
                        else if case .posix(let code) = error, code == .EACCES || code == .EPERM { gate.finish(.permissionDenied) }
                    case .cancelled: gate.finish(.cancelled)
                    default: break
                    }
                }
                connection.start(queue: DispatchQueue(label: "NetUnstick.Store.Connection"))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { gate.finish(.timedOut) }
            }
        } onCancel: { gate.cancel() }
    }

    static func classify(_ error: NWError) -> StoreSignal {
        switch error {
        case .dns(let code) where code == -65570: .permissionDenied
        case .dns: .nameUnresolved
        case .posix(.ECONNREFUSED): .refused
        case .posix(.ETIMEDOUT): .timedOut
        case .posix(.EHOSTUNREACH), .posix(.ENETUNREACH), .posix(.ENETDOWN): .unreachable
        case .posix(.EPERM), .posix(.EACCES): .permissionDenied
        default: .failed
        }
    }
}

enum StoreSignal: String, Sendable {
    case reachable, refused, timedOut, unreachable, nameUnresolved, failed, cancelled, permissionDenied
    var outcome: OperationOutcome {
        switch self {
        case .reachable: .success
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .permissionDenied: .permissionDenied
        default: .failure
        }
    }
}

/// A cancellation before continuation installation is retained. Timeout, late callbacks and
/// cancellation race safely; cleanup and continuation resumption happen exactly once.
final class StoreProbeGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var completed: Value?
    private let cancelled: Value
    private let cleanup: @Sendable () -> Void
    init(cancelled: Value, cleanup: @escaping @Sendable () -> Void = {}) {
        self.cancelled = cancelled; self.cleanup = cleanup
    }
    func cancel() { finish(cancelled) }
    func install(_ value: CheckedContinuation<Value, Never>) -> Bool {
        lock.lock()
        if let completed { lock.unlock(); value.resume(returning: completed); return false }
        continuation = value
        lock.unlock()
        return true
    }
    func finish(_ value: Value) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        completed = value
        let callback = continuation
        continuation = nil
        lock.unlock()
        cleanup()
        callback?.resume(returning: value)
    }
}
#endif
