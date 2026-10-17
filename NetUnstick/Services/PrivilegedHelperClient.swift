import Foundation
import ServiceManagement
import NetUnstickRepair
import NetUnstickCore

public enum HelperRegistrationStatus: String {
    case notRegistered, enabled, requiresApproval, notFound
    var guidance: String {
        switch self {
        case .enabled: return "Helper jest gotowy."
        case .notRegistered: return "Włącz helper tylko przed wybraną naprawą."
        case .requiresApproval: return "Zatwierdź helper w Ustawieniach systemowych > Ogólne > Elementy logowania."
        case .notFound: return "Zainstaluj ponownie poprawny pakiet aplikacji."
        }
    }
}

private final class XPCTransport: PrivilegedRequestTransport {
    func perform(_ request: Data, completion: @escaping (Data?, Error?) -> Void) {
        let connection = NSXPCConnection(machServiceName: PrivilegedProtocol.machService, options: .privileged)
        let gate = XPCCompletionGate(completion)
        connection.remoteObjectInterface = NSXPCInterface(with: NetUnstickHelperXPC.self)
        connection.interruptionHandler = { gate.finish(nil, NSError(domain: "helper", code: 1)); connection.invalidate() }
        connection.invalidationHandler = { gate.finish(nil, NSError(domain: "helper", code: 2)) }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ gate.finish(nil, $0); connection.invalidate() }) as? NetUnstickHelperXPC else {
            gate.finish(nil, NSError(domain: "helper", code: 3)); connection.invalidate(); return
        }
        proxy.perform(request) { data in gate.finish(data, nil); connection.invalidate() }
    }
}

private final class XPCCompletionGate {
    private let lock = NSLock()
    private var completion: ((Data?, Error?) -> Void)?
    init(_ completion: @escaping (Data?, Error?) -> Void) { self.completion = completion }
    func finish(_ data: Data?, _ error: Error?) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(data, error)
    }
}

enum HelperRegistrationRefreshError: Error {
    case timedOut
}

/// A completion callback confirms that ServiceManagement has reaped the old job.
/// Merely observing .notRegistered does not provide that ordering guarantee.
enum HelperRegistrationRefresh {
    static func perform(
        unregister: (@escaping (Error?) -> Void) -> Void,
        register: () -> HelperRegistrationStatus,
        timeout: Duration = .seconds(5)
    ) async throws -> HelperRegistrationStatus {
        let gate = HelperUnregistrationGate()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard gate.install(continuation) else { return }
                let timer = Task {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    gate.finish(.failure(HelperRegistrationRefreshError.timedOut))
                }
                gate.installTimeout(timer)
                unregister { error in
                    if let error { gate.finish(.failure(error)) }
                    else { gate.finish(.success(())) }
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return register()
    }
}

/// Callback, deadline and cancellation may race; only the first completion wins.
private final class HelperUnregistrationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }
    func installTimeout(_ timer: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            timer.cancel()
            return
        }
        self.timer = timer
        lock.unlock()
    }
    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}

public final class PrivilegedHelperClient {
    private let transport: PrivilegedRequestTransport
    /// A fresh handle for every query, so an approval granted in System Settings is seen without relaunching.
    private var service: SMAppService { SMAppService.daemon(plistName: PrivilegedProtocol.plistName) }
    public private(set) var lastRegistrationError: String?
    public init(transport: PrivilegedRequestTransport? = nil) { self.transport = transport ?? XPCTransport() }
    public var status: HelperRegistrationStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    /// Invoke only from an explicit user control.
    @discardableResult public func registerForSelectedRepair() -> HelperRegistrationStatus {
        lastRegistrationError = nil
        do { try service.register() } catch {
            let ns = error as NSError
            if ns.domain == "SMAppServiceErrorDomain" && ns.code == Int(kSMErrorInvalidSignature) {
                lastRegistrationError = "Aplikacja i helper muszą mieć ten sam ważny certyfikat podpisu."
            } else if ns.domain == "SMAppServiceErrorDomain" && ns.code == Int(kSMErrorAuthorizationFailure) {
                lastRegistrationError = "System odmówił uprawnienia. Sprawdź zgodę administratora."
            } else if ns.domain == "SMAppServiceErrorDomain" && ns.code == Int(kSMErrorLaunchDeniedByUser) {
                lastRegistrationError = "System odmówił uruchomienia helpera. Sprawdź Elementy logowania."
            } else {
                lastRegistrationError = "Rejestracja nie powiodła się. Sprawdź podpis i instalację aplikacji."
            }
            return status
        }
        return status
    }
    public func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    /// Read-only liveness check of the registered daemon; nothing is observed or changed.
    public func handshake(completion: @escaping (PrivilegedReply) -> Void) { perform(.handshake, completion: completion) }
    /// After an update, launchd may still hold the code requirement of the previous daemon build.
    /// A plain re-registration is tried first: it keeps the Login Items record untouched.
    @discardableResult public func reregisterInPlace() -> HelperRegistrationStatus {
        lastRegistrationError = nil
        do { try service.register() } catch {
            lastRegistrationError = "Ponowna rejestracja nie powiodła się. Sprawdź Elementy logowania."
        }
        return status
    }
    /// Fallback after an update: wait for ServiceManagement to reap the stale job before
    /// registering its replacement. Timeout, cancellation or an error stop the migration.
    public func refreshRegistrationAfterUpdate() async -> HelperRegistrationStatus {
        lastRegistrationError = nil
        let registrationService = service
        do {
            return try await HelperRegistrationRefresh.perform(
                unregister: { registrationService.unregister(completionHandler: $0) },
                register: { self.registerForSelectedRepair() }
            )
        } catch is CancellationError {
            lastRegistrationError = "Odświeżanie helpera anulowano. Sprawdź jego stan przed ponowną rejestracją."
        } catch HelperRegistrationRefreshError.timedOut {
            lastRegistrationError = "System nie potwierdził wyrejestrowania helpera w ciągu 5 sekund. Sprawdź jego stan i spróbuj ponownie."
        } catch {
            lastRegistrationError = "Wyrejestrowanie helpera nie powiodło się. Sprawdź Elementy logowania przed ponowną rejestracją."
        }
        return status
    }
    /// Invoke only from an explicit user control, e.g. after updating the bundle so launchd
    /// stops the old daemon instance; the next registration may need approval again.
    @discardableResult public func unregisterForUpdate() -> HelperRegistrationStatus {
        lastRegistrationError = nil
        do { try service.unregister() } catch {
            lastRegistrationError = "Wyrejestrowanie nie powiodło się. Sprawdź Elementy logowania."
        }
        return status
    }
    public func perform(_ action: PrivilegedAction, completion: @escaping (PrivilegedReply) -> Void) {
        switch status {
        case .enabled:
            PrivilegedRequestClient.perform(action, transport: transport, completion: completion)
        case .requiresApproval:
            completion(PrivilegedRequestClient.failure(.approvalRequired))
        case .notRegistered:
            completion(PrivilegedRequestClient.failure(.notRegistered))
        case .notFound:
            completion(PrivilegedRequestClient.failure(.notFound))
        }
    }
}
