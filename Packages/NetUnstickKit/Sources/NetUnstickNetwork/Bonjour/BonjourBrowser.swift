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

