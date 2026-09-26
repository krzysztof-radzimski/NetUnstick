import Foundation
import NetUnstickCore

public protocol PrivilegedRequestTransport {
    func perform(_ request: Data, completion: @escaping (Data?, Error?) -> Void)
}

/// Transport-independent response handling used by the app's XPC adapter.
public enum PrivilegedRequestClient {
    public static func perform(_ action: PrivilegedAction, transport: PrivilegedRequestTransport,
                               timeout: TimeInterval = 8, completion: @escaping (PrivilegedReply) -> Void) {
        guard let request = try? JSONEncoder().encode(PrivilegedRequest(action: action)) else {
            completion(failure(.invalidRequest)); return
        }
        let gate = CompletionGate(completion)
        transport.perform(request) { data, error in
            if let data, let reply = try? JSONDecoder().decode(PrivilegedReply.self, from: data) {
                gate.finish(reply)
            } else if let error = error as NSError?, error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                gate.finish(failure(.permissionDenied))
            } else {
                gate.finish(failure(.disconnected))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, timeout)) {
            gate.finish(failure(.timedOut))
        }
    }
    public static func failure(_ code: PrivilegedCode) -> PrivilegedReply {
        let now = Date()
        let outcome: OperationOutcome = code == .timedOut ? .timedOut :
            [.approvalRequired, .notRegistered, .permissionDenied].contains(code) ? .permissionDenied : .failure
        let next: String
        switch code {
        case .approvalRequired: next = "Zatwierdź helper w Elementach logowania."
        case .notRegistered: next = "Zarejestruj helper jawnym przyciskiem przed naprawą."
        case .notFound: next = "Zainstaluj ponownie podpisany pakiet aplikacji."
        case .timedOut: next = "Sprawdź stan VPN i spróbuj później."
        case .permissionDenied: next = "Sprawdź uprawnienia helpera i zgodę systemową."
        default: next = "Uruchom ponownie aplikację i sprawdź status helpera."
        }
        let result = try! OperationResult(operationID: UUID().uuidString, name: "privileged_repair", kind: .repair,
            startedAt: now, endedAt: now, outcome: outcome,
            error: try! OperationError(domain: "helper", code: code.rawValue), nextStep: next)
        return PrivilegedReply(code: code, result: result)
    }
}

private final class CompletionGate {
    private let lock = NSLock()
    private var finished = false
    private let completion: (PrivilegedReply) -> Void
    init(_ completion: @escaping (PrivilegedReply) -> Void) { self.completion = completion }
    func finish(_ result: PrivilegedReply) {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        lock.unlock()
        if shouldFinish { completion(result) }
    }
}
