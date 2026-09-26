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
        connection.remoteObjectInterface = NSXPCInterface(with: NetUnstickHelperXPC.self)
        connection.interruptionHandler = { completion(nil, NSError(domain: "helper", code: 1)); connection.invalidate() }
        connection.invalidationHandler = { completion(nil, NSError(domain: "helper", code: 2)) }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ completion(nil, $0); connection.invalidate() }) as? NetUnstickHelperXPC else {
            completion(nil, NSError(domain: "helper", code: 3)); connection.invalidate(); return
        }
        proxy.perform(request) { data in completion(data, nil); connection.invalidate() }
    }
}

public final class PrivilegedHelperClient {
    private let transport: PrivilegedRequestTransport
    private let service = SMAppService.daemon(plistName: PrivilegedProtocol.plistName)
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
                lastRegistrationError = "Pakiet musi być podpisany tym samym zespołem co helper."
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
