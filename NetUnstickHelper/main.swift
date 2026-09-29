import Foundation
import Security
import CryptoKit
import os
import NetUnstickRepair

private let log = Logger(subsystem: "org.netunstick.NetUnstick", category: "helper")

private func clientRequirement() -> String? {
    var selfCode: SecCode?
    guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
    guard SecCodeCheckValidity(selfCode, [], nil) == errSecSuccess else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let info = information as? [String: Any],
          let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certificates.first else { return nil }
    let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
    let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
    return ClientIdentityPolicy.requirement(forLeafCertificateSHA1: fingerprint)
}

/// Ends the daemon after a quiet minute. launchd starts a fresh instance on the next
/// connection, so an updated bundle never keeps serving stale code.
private final class IdleExit: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?
    private let limit: TimeInterval = 60
    func begin() { lock.lock(); inFlight += 1; lastActivity = Date(); lock.unlock() }
    func end() { lock.lock(); inFlight -= 1; lastActivity = Date(); lock.unlock() }
    func start() {
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + 15, repeating: 15)
        source.setEventHandler { [self] in
            lock.lock()
            let idle = inFlight == 0 && Date().timeIntervalSince(lastActivity) > limit
            lock.unlock()
            if idle { log.info("helper idle exit"); exit(0) }
        }
        source.resume()
        timer = source
    }
}

private let idle = IdleExit()

private final class HelperService: NSObject, NetUnstickHelperXPC {
    private let executor = PrivilegedRepairExecutor()
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard request.count <= PrivilegedProtocol.maximumRequestBytes,
              let decoded = try? JSONDecoder().decode(PrivilegedRequest.self, from: request) else {
            log.error("helper request rejected: \(request.count, privacy: .public) bytes")
            reply(try! JSONEncoder().encode(PrivilegedRepairExecutor.rejectMalformedRequest()))
            return
        }
        log.info("helper request accepted: \(request.count, privacy: .public) bytes")
        idle.begin()
        Task {
            let result = await executor.perform(decoded)
            reply((try? JSONEncoder().encode(result)) ?? Data())
            log.info("helper reply sent: \(result.code.rawValue, privacy: .public)")
            idle.end()
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let requirement: String
    init(requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: NetUnstickHelperXPC.self)
        connection.exportedObject = HelperService()
        connection.resume()
        log.info("helper connection accepted")
        return true
    }
}

guard geteuid() == 0, let requirement = clientRequirement() else { exit(77) }
log.info("helper listener starting, protocol \(PrivilegedProtocol.version, privacy: .public)")
private let delegate = ListenerDelegate(requirement: requirement)
let listener = NSXPCListener(machServiceName: PrivilegedProtocol.machService)
listener.delegate = delegate
listener.resume()
idle.start()
RunLoop.current.run()
