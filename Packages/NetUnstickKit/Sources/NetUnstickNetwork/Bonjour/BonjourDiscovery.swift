import Foundation
import Network
import NetUnstickCore

public enum BonjourService: String, CaseIterable, Sendable {
    case airplay = "_airplay._tcp"
    case raop = "_raop._tcp"
}

public enum BonjourReason: String, Sendable {
    case servicesFound, noServices, permissionDenied, noPhysicalInterface, noLocalPath
    case browserFailed, timedOut, cancelled, inconclusive
}

public struct BonjourObservation: Sendable {
    public let count: Int
    public let reason: BonjourReason
    public init(count: Int, reason: BonjourReason) {
        self.count = max(0, count); self.reason = reason
    }
}

public protocol BonjourBrowsing: Sendable {
    func browse(_ service: BonjourService, timeout: Duration) async -> BonjourObservation
}

/// NWEndpoint instances remain inside Network.framework's callback and are never persisted.
public struct SystemBonjourBrowser: BonjourBrowsing {
    public init() {}
    public func browse(_ service: BonjourService, timeout: Duration) async -> BonjourObservation {
        if Task.isCancelled { return .init(count: 0, reason: .cancelled) }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: service.rawValue, domain: "local."), using: parameters)
        let gate = BrowserGate(browser: browser)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<BonjourObservation, Never>) in
                gate.install(continuation)
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.ready()
                    case .failed(let error): gate.finish(.init(count: 0, reason: Self.isPermissionError(error) ? .permissionDenied : .browserFailed))
                    case .waiting(let error) where Self.isPermissionError(error):
                        gate.finish(.init(count: 0, reason: .permissionDenied))
                    default: break
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in gate.update(count: results.count) }
                browser.start(queue: DispatchQueue(label: "NetUnstick.Bonjour.\(service.rawValue)"))
                Task {
                    do { try await Task.sleep(for: timeout); gate.deadline() }
                    catch { gate.finish(.init(count: 0, reason: .cancelled)) }
                }
            }
        } onCancel: { gate.finish(.init(count: 0, reason: .cancelled)) }
    }
    private static func isPermissionError(_ error: NWError) -> Bool {
        switch error {
        case .dns(let code): return code == -65570 // kDNSServiceErr_PolicyDenied
        case .posix(let code): return code == .EACCES || code == .EPERM
        default: return false
        }
    }
}

private final class BrowserGate: @unchecked Sendable {
    private let lock = NSLock()
    private let browser: NWBrowser
    private var continuation: CheckedContinuation<BonjourObservation, Never>?
    private var count = 0
    private var didReady = false
    private var finished = false
    init(browser: NWBrowser) { self.browser = browser }
    func install(_ value: CheckedContinuation<BonjourObservation, Never>) {
        lock.lock(); continuation = value; let cancelled = finished; lock.unlock()
        if cancelled { value.resume(returning: .init(count: 0, reason: .cancelled)) }
    }
    func ready() { lock.lock(); didReady = true; lock.unlock() }
    func update(count: Int) { lock.lock(); self.count = count; lock.unlock() }
    func deadline() {
        lock.lock(); let current = count; let ready = didReady; lock.unlock()
        finish(.init(count: current, reason: ready ? (current > 0 ? .servicesFound : .noServices) : .timedOut))
    }
    func finish(_ observation: BonjourObservation) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = continuation
        continuation = nil
        lock.unlock()
        browser.cancel()
        callback?.resume(returning: observation)
    }
}

public struct LocalMulticastPathCheck: DiagnosticCheck {
    public let id = "local_multicast_path"
    public let name = "local_multicast_path"
    private let snapshot: RawNetworkSnapshot
    public init(snapshot: RawNetworkSnapshot) { self.snapshot = snapshot }
    public func run(context: OperationContext = OperationContext()) async -> OperationResult {
        let start = context.clock.now()
        if Task.isCancelled || (try? context.cancellation.checkCancellation()) == nil {
            return makeBonjourResult(id: id, start: start, end: context.clock.now(), reason: .cancelled, counts: [:], interface: nil)
        }
        let physical = snapshot.interfaces.filter { $0.isUp && ["wifi", "ethernet", "wired"].contains($0.type.lowercased()) }
        let reason: BonjourReason
        if Task.isCancelled { reason = .cancelled }
        else if physical.isEmpty { reason = .noPhysicalInterface }
        else if snapshot.path?.status != "satisfied" { reason = .noLocalPath }
        else if !snapshot.routes.contains(where: { route in route.isLocal && physical.contains(where: { $0.name == route.interfaceName }) }) { reason = .noLocalPath }
        else { reason = .inconclusive } // A route cannot prove multicast delivery.
        return makeBonjourResult(id: id, start: start, end: context.clock.now(), reason: reason,
            counts: [:], interface: physical.first?.type)
    }
}

public struct BonjourPermissionCheck: DiagnosticCheck {
    public let id = "bonjour_permission"
    public let name = "bonjour_permission"
    private let observation: BonjourObservation
    public init(observation: BonjourObservation) { self.observation = observation }
    public func run(context: OperationContext = OperationContext()) async -> OperationResult {
        let reason: BonjourReason = observation.reason == .permissionDenied ? .permissionDenied :
            observation.reason == .browserFailed ? .browserFailed : .inconclusive
        let now = context.clock.now()
        return makeBonjourResult(id: id, start: now, end: context.clock.now(), reason: reason, counts: [:], interface: nil)
    }
}

public struct BonjourDiscoveryChecking: DiagnosticCheck {
    public let id = "bonjour_discovery"
    public let name = "bonjour_discovery"
    private let snapshot: RawNetworkSnapshot
    private let browser: any BonjourBrowsing
    private let timeout: Duration
    public init(snapshot: RawNetworkSnapshot, browser: any BonjourBrowsing = SystemBonjourBrowser(), timeout: Duration = .seconds(2)) {
        self.snapshot = snapshot; self.browser = browser; self.timeout = timeout
    }
    public func run(context: OperationContext = OperationContext()) async -> OperationResult {
        let start = context.clock.now()
        if Task.isCancelled || (try? context.cancellation.checkCancellation()) == nil {
            return makeBonjourResult(id: id, start: start, end: context.clock.now(), reason: .cancelled, counts: [:], interface: nil)
        }
        let physical = snapshot.interfaces.first { $0.isUp && ["wifi", "ethernet", "wired"].contains($0.type.lowercased()) }
        guard let physical else {
            return makeBonjourResult(id: id, start: start, end: context.clock.now(), reason: .noPhysicalInterface, counts: [:], interface: nil)
        }
        guard snapshot.path?.status == "satisfied" else {
            return makeBonjourResult(id: id, start: start, end: context.clock.now(), reason: .noLocalPath, counts: [:], interface: physical.type)
        }
        let airplay = await browser.browse(.airplay, timeout: timeout)
        let raop = Task.isCancelled ? BonjourObservation(count: 0, reason: .cancelled) : await browser.browse(.raop, timeout: timeout)
        let reasons = [airplay.reason, raop.reason]
        let reason: BonjourReason
        if Task.isCancelled || reasons.contains(.cancelled) { reason = .cancelled }
        else if reasons.contains(.permissionDenied) { reason = .permissionDenied }
        else if reasons.contains(.browserFailed) { reason = .browserFailed }
        else if reasons.contains(.timedOut) { reason = .timedOut }
        else if airplay.count + raop.count > 0 { reason = .servicesFound }
        else { reason = .noServices }
        return makeBonjourResult(id: id, start: start, end: context.clock.now(), reason: reason,
            counts: [.airplayCount: airplay.count, .raopCount: raop.count], interface: physical.type)
    }
}

private func makeBonjourResult(id: String, start: Date, end: Date, reason: BonjourReason,
                               counts: [EvidenceKey: Int], interface: String?) -> OperationResult {
    let outcome: OperationOutcome
    switch reason {
    case .servicesFound: outcome = .success
    case .permissionDenied: outcome = .permissionDenied
    case .browserFailed, .noLocalPath: outcome = .failure
    case .timedOut: outcome = .timedOut
    case .cancelled: outcome = .cancelled
    default: outcome = .skipped
    }
    var fields: [EvidenceKey: EvidenceValue] = [.errorCode: .errorCode(reason.rawValue),
        .checkStatus: .status(outcome == .success ? .passed : outcome == .failure ? .failed : .unknown)]
    for (key, count) in counts { fields[key] = .count(count) }
    if let interface {
        let type: InterfaceType = interface.lowercased() == "wifi" ? .wifi :
            ["ethernet", "wired"].contains(interface.lowercased()) ? .ethernet : .other
        fields[.interfaceType] = .interfaceType(type)
    }
    return try! OperationResult(operationID: id, name: id, kind: .diagnostic, startedAt: start,
        endedAt: max(start, end), outcome: outcome, after: EvidenceSanitizer.sanitize(fields),
        error: [.failure, .permissionDenied, .timedOut].contains(outcome)
            ? try? OperationError(domain: "bonjour", code: reason.rawValue) : nil,
        nextStep: reason == .permissionDenied ? NextStep.checkPermissions.rawValue :
            reason == .noServices ? NextStep.reviewDetails.rawValue : NextStep.retryCheck.rawValue)
}
