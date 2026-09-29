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
    /// Fallback after an update: remove the stale job, wait until the system reports it gone,
    /// then register again. Removing and re-adding too quickly was observed to create a new
    /// Login Items record that waits for approval, so the removal must settle first.
    public func refreshRegistrationAfterUpdate() async -> HelperRegistrationStatus {
        _ = unregisterForUpdate()
        let deadline = Date().addingTimeInterval(5)
        while status != .notRegistered && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return registerForSelectedRepair()
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
